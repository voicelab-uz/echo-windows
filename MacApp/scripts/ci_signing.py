#!/usr/bin/env python3
"""Prepare isolated macOS CI signing inputs; never print secrets or export local keys."""
import argparse
import base64
import json
import os
from pathlib import Path
import secrets
import shlex
import shutil
import subprocess
import sys
from urllib.request import urlopen

import update_release as release


def command(label, args):
    result = subprocess.run(args, stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False)
    if result.returncode:
        raise ValueError(f"{label} failed (exit {result.returncode}); secret-bearing output was suppressed.")
    return result.stdout


def signing_directory():
    root = Path(os.environ["RUNNER_TEMP"]).resolve()
    release.require(root.is_dir() and not root.is_relative_to(release.ROOT), "RUNNER_TEMP must be outside the checkout.")
    return root / "echo-ci-signing"


def set_environment(values):
    with open(os.environ["GITHUB_ENV"], "a") as stream:
        for key, value in values.items():
            release.require("\n" not in str(value), "Unsafe environment path.")
            stream.write(f"{key}={value}\n")


def tools():
    directory = Path(os.environ["RUNNER_TEMP"]) / "echo-sparkle-tools"
    directory.mkdir(mode=0o700)
    archive = directory / "Sparkle.zip"
    url = f"https://github.com/sparkle-project/Sparkle/releases/download/{release.SPARKLE_VERSION}/Sparkle-for-Swift-Package-Manager.zip"
    with urlopen(url, timeout=90) as source, archive.open("wb") as target:
        shutil.copyfileobj(source, target)
    release.require(release.digest(archive) == release.SPARKLE_ARCHIVE_SHA256, "Sparkle archive checksum does not match the pinned release.")
    command("Sparkle extraction", ["ditto", "-x", "-k", str(archive), str(directory)])
    archive.unlink()
    release.require(release.digest(directory / "bin/sign_update") == release.SIGN_UPDATE_SHA256, "Unexpected Sparkle signer.")
    set_environment({"ECHO_SPARKLE_TOOLS_DIR": directory / "bin"})


def setup():
    required = ("ECHO_SIGNING_P12_BASE64", "ECHO_SIGNING_P12_PASSWORD", "ECHO_NOTARY_KEY_BASE64",
                "ECHO_NOTARY_KEY_ID", "ECHO_NOTARY_ISSUER", "ECHO_PUSH_PROFILE_BASE64", "ECHO_SPARKLE_PRIVATE_KEY")
    missing = [name for name in required if not os.environ.get(name)]
    if missing:
        print("Missing signing inputs: " + ", ".join(missing), file=sys.stderr)
    release.require(not missing, "Configure signing environment inputs: " + ", ".join(missing))
    release.require(os.environ.get("GITHUB_ACTIONS") == "true" and os.environ.get("GITHUB_REF") == "refs/heads/main",
                    "Signing setup is only supported on a trusted main workflow.")
    directory = signing_directory()
    directory.mkdir(mode=0o700)
    keychain = directory / "signing.keychain-db"
    original = shlex.split(command("Read Keychain search list", ["security", "list-keychains", "-d", "user"]).decode())
    (directory / "cleanup.json").write_text(json.dumps({"keychains": original}))

    def secret_file(name, contents):
        path = directory / name
        with path.open("xb") as stream:
            os.chmod(path, 0o600)
            stream.write(contents)
        return path

    p12 = secret_file("identity.p12", base64.b64decode(os.environ["ECHO_SIGNING_P12_BASE64"], validate=True))
    notary = secret_file("notary.p8", base64.b64decode(os.environ["ECHO_NOTARY_KEY_BASE64"], validate=True))
    profile = secret_file("push.provisionprofile", base64.b64decode(os.environ["ECHO_PUSH_PROFILE_BASE64"], validate=True))
    sparkle = secret_file("sparkle.key", os.environ["ECHO_SPARKLE_PRIVATE_KEY"].strip().encode())
    password = secrets.token_urlsafe(32)
    command("Create temporary Keychain", ["security", "create-keychain", "-p", password, str(keychain)])
    command("Configure temporary Keychain", ["security", "set-keychain-settings", "-lut", "21600", str(keychain)])
    command("Unlock temporary Keychain", ["security", "unlock-keychain", "-p", password, str(keychain)])
    command("Import Developer ID", ["security", "import", str(p12), "-k", str(keychain), "-P",
            os.environ["ECHO_SIGNING_P12_PASSWORD"], "-T", "/usr/bin/codesign", "-T", "/usr/bin/security"])
    command("Authorize signing tools", ["security", "set-key-partition-list", "-S", "apple-tool:,apple:", "-s", "-k", password, str(keychain)])
    command("Set Keychain search list", ["security", "list-keychains", "-d", "user", "-s", str(keychain), *original])
    command("Store notarization credential", ["xcrun", "notarytool", "store-credentials", "echo-ci-notary", "--key", str(notary),
            "--key-id", os.environ["ECHO_NOTARY_KEY_ID"], "--issuer", os.environ["ECHO_NOTARY_ISSUER"], "--keychain", str(keychain)])
    p12.unlink()
    notary.unlink()
    set_environment({"ECHO_NOTARY_PROFILE": "echo-ci-notary", "ECHO_NOTARY_KEYCHAIN": keychain,
                     "ECHO_PUSH_PROFILE": profile, "ECHO_SPARKLE_PRIVATE_KEY_FILE": sparkle})


def cleanup():
    directory = signing_directory()
    if not directory.exists():
        return
    record = directory / "cleanup.json"
    if record.exists():
        original = json.loads(record.read_text())["keychains"]
        command("Restore Keychain search list", ["security", "list-keychains", "-d", "user", "-s", *original])
    keychain = directory / "signing.keychain-db"
    if keychain.exists():
        command("Delete temporary Keychain", ["security", "delete-keychain", str(keychain)])
    shutil.rmtree(directory)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("tools", "setup", "cleanup"))
    args = parser.parse_args()
    try:
        {"tools": tools, "setup": setup, "cleanup": cleanup}[args.action]()
    except Exception:
        # Never render exception arguments: external tools may echo private inputs.
        print(f"CI signing {args.action} failed. Check required environment secrets and the signing runbook.", file=sys.stderr)
        sys.exit(1)
