#!/usr/bin/env python3
"""Fail-closed Developer ID/APNs profile checks. Never reads a private key."""
import argparse
import datetime as dt
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import subprocess
import tempfile
import uuid


class ProfileError(ValueError):
    pass


def validate_payload(profile, *, team, bundle, certificate, now=None):
    now = now or dt.datetime.now(dt.timezone.utc)
    if not re.fullmatch(r"[A-Z0-9]{10}", team) or not re.fullmatch(r"[A-Fa-f0-9]{40}", certificate):
        raise ProfileError("Invalid expected team or signing certificate fingerprint.")
    if not isinstance(profile, dict):
        raise ProfileError("Profile payload must be a property-list dictionary.")
    entitlements = profile.get("Entitlements", {})
    if not isinstance(entitlements, dict):
        raise ProfileError("Profile has no entitlement dictionary.")
    if profile.get("TeamIdentifier") != [team] or entitlements.get("com.apple.developer.team-identifier") != team:
        raise ProfileError("Profile belongs to a different Apple team.")
    if entitlements.get("com.apple.application-identifier") != f"{team}.{bundle}":
        raise ProfileError("Profile must authorize the exact Echo app identifier, without a wildcard.")
    if entitlements.get("com.apple.developer.aps-environment") != "production":
        raise ProfileError("Profile must authorize production APNs.")
    if entitlements.get("get-task-allow", False) is not False or entitlements.get("com.apple.security.get-task-allow", False) is not False:
        raise ProfileError("Development/debug profiles cannot be used for a release.")
    if profile.get("ProvisionsAllDevices") is not True or profile.get("ProvisionedDevices"):
        raise ProfileError("A Developer ID distribution profile for all Macs is required.")
    platforms = profile.get("Platform", [])
    if not isinstance(platforms, list) or not all(isinstance(value, str) for value in platforms) or not set(platforms).intersection({"OSX", "macOS"}):
        raise ProfileError("Profile does not authorize macOS.")
    expiry = profile.get("ExpirationDate")
    if not isinstance(expiry, dt.datetime):
        raise ProfileError("Profile expiration date is missing.")
    expiry = expiry.replace(tzinfo=dt.timezone.utc) if expiry.tzinfo is None else expiry
    if expiry <= now:
        raise ProfileError("Provisioning profile has expired.")
    created = profile.get("CreationDate")
    if not isinstance(created, dt.datetime):
        raise ProfileError("Profile creation date is missing.")
    created = created.replace(tzinfo=dt.timezone.utc) if created.tzinfo is None else created
    if created > now + dt.timedelta(minutes=5):
        raise ProfileError("Provisioning profile is not yet valid.")
    certificates = profile.get("DeveloperCertificates", [])
    if not isinstance(certificates, list) or not any(
        isinstance(data, bytes) and hashlib.sha1(data).hexdigest().upper() == certificate.upper() for data in certificates
    ):
        raise ProfileError("Profile does not include the selected Developer ID signing certificate.")
    try:
        identifier = profile.get("UUID", "")
        parsed_identifier = uuid.UUID(identifier)
        if str(parsed_identifier) != identifier.lower():
            raise ValueError("Profile UUID is not in canonical hyphenated form.")
    except (ValueError, TypeError, AttributeError) as error:
        raise ProfileError("Profile UUID is missing or invalid.") from error
    # Xcode matches PROVISIONING_PROFILE_SPECIFIER against the signed UUID as a
    # case-sensitive string. Apple's macOS profiles can use lowercase UUIDs.
    # Validate the UUID, but preserve its exact spelling for lookup and export.
    return {"uuid": identifier, "teamID": team, "bundleIdentifier": bundle,
            "environment": "production", "expiresAt": expiry.isoformat(), "certificateSHA1": certificate.upper()}


def inspect(path, *, verifier, team, bundle, certificate):
    with path.open("rb") as source:
        data = source.read(2 * 1024 * 1024 + 1)
    if not data or len(data) > 2 * 1024 * 1024:
        raise ProfileError("Invalid provisioning-profile size.")
    # Verify the exact captured bytes later embedded/installed, not a path that
    # could change between CMS validation, metadata inspection and copying.
    with tempfile.TemporaryDirectory(prefix="echo-profile-check-") as directory:
        snapshot = Path(directory) / "profile.provisionprofile"
        snapshot.write_bytes(data)
        try:
            result = subprocess.run([str(verifier), str(snapshot)], capture_output=True, check=False, timeout=30)
        except subprocess.TimeoutExpired as error:
            raise ProfileError("Apple CMS signature/trust verification timed out.") from error
    if result.returncode:
        raise ProfileError("Apple CMS signature/trust verification failed.")
    try:
        payload = plistlib.loads(result.stdout)
    except (ValueError, plistlib.InvalidFileException) as error:
        raise ProfileError("Invalid signed profile payload.") from error
    metadata = validate_payload(payload, team=team, bundle=bundle, certificate=certificate)
    metadata["sha256"] = hashlib.sha256(data).hexdigest()
    return metadata, data


def write_once(path, data):
    path.parent.mkdir(parents=True, exist_ok=True)
    # Publish a completely written 0600 file without replacing an existing UUID.
    descriptor, temporary = tempfile.mkstemp(prefix=".echo-profile-", dir=path.parent)
    try:
        with os.fdopen(descriptor, "wb") as destination:
            destination.write(data)
            destination.flush()
            os.fsync(destination.fileno())
        try:
            os.link(temporary, path)
        except FileExistsError:
            if path.is_symlink() or path.read_bytes() != data:
                raise ProfileError("Refusing to overwrite a different provisioning profile.")
    finally:
        os.unlink(temporary)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("profile", type=Path)
    parser.add_argument("--verifier", type=Path, required=True)
    parser.add_argument("--team", required=True)
    parser.add_argument("--bundle", default="uz.voicelab.desktop")
    parser.add_argument("--certificate", required=True)
    parser.add_argument("--external-to", type=Path)
    parser.add_argument("--stage", type=Path)
    parser.add_argument("--expected-sha256", help="Reject changed bytes before staging or installing.")
    parser.add_argument("--install", action="store_true")
    args = parser.parse_args()
    try:
        path = args.profile.resolve(strict=True)
        if args.external_to and path.is_relative_to(args.external_to.resolve()):
            raise ProfileError("Keep the provisioning profile outside the source checkout.")
        metadata, data = inspect(path, verifier=args.verifier, team=args.team, bundle=args.bundle, certificate=args.certificate)
        if args.expected_sha256 and metadata["sha256"] != args.expected_sha256:
            raise ProfileError("Profile changed after preflight; nothing was staged or installed.")
        if args.stage:
            write_once(args.stage, data)
        if args.install:
            directory = Path.home() / "Library/Developer/Xcode/UserData/Provisioning Profiles"
            write_once(directory / (metadata["uuid"] + ".provisionprofile"), data)
        print(json.dumps(metadata, sort_keys=True))
    except (ProfileError, OSError) as error:
        parser.exit(1, f"Profile error: {error}\n")


if __name__ == "__main__":
    main()
