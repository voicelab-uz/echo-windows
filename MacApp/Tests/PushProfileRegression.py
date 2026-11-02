"""Provisioning safety regression tests; no Apple account, private keys or real profiles."""
import datetime as dt
import hashlib
import importlib.util
from pathlib import Path
import plistlib
import subprocess
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("push_profile", ROOT / "scripts/push_profile.py")
profile = importlib.util.module_from_spec(spec)
spec.loader.exec_module(profile)
TEAM = "ABCDEFGHIJ"
BUNDLE = "uz.voicelab.desktop"
CERT = b"Public certificate test fixture (not a real certificate)"
FINGERPRINT = hashlib.sha1(CERT).hexdigest().upper()
NOW = dt.datetime(2026, 10, 29, tzinfo=dt.timezone.utc)


def payload():
    return {
        "UUID": "1a5669f6-647f-4daa-a0b8-ed5375d43100", "TeamIdentifier": [TEAM],
        "Platform": ["OSX"], "ProvisionsAllDevices": True,
        "CreationDate": dt.datetime(2026, 10, 28), "ExpirationDate": dt.datetime(2040, 1, 1),
        "DeveloperCertificates": [CERT],
        "Entitlements": {"com.apple.application-identifier": f"{TEAM}.{BUNDLE}",
                         "com.apple.developer.team-identifier": TEAM,
                         "com.apple.developer.aps-environment": "production"},
    }


class PushProfileTests(unittest.TestCase):
    def validate(self, value):
        return profile.validate_payload(value, team=TEAM, bundle=BUNDLE, certificate=FINGERPRINT, now=NOW)

    def test_valid_exact_distribution_profile(self):
        result = self.validate(payload())
        self.assertEqual(result["uuid"], "1a5669f6-647f-4daa-a0b8-ed5375d43100")
        self.assertEqual(result["environment"], "production")
        self.assertEqual(result["certificateSHA1"], FINGERPRINT)

    def test_xcode_lookup_preserves_exact_signed_uuid_spelling(self):
        # Xcode rejected the normalized uppercase form of a real lowercase Mac
        # profile UUID; the original spelling successfully passed provisioning.
        for identifier in ("1a5669f6-647f-4daa-a0b8-ed5375d43100", "1A5669F6-647F-4DAA-A0B8-ED5375D43100"):
            value = payload()
            value["UUID"] = identifier
            self.assertEqual(self.validate(value)["uuid"], identifier)

    def test_rejects_wrong_identity_environment_and_debug(self):
        mutations = [
            lambda p: p.update(TeamIdentifier=["WRONGTEAM1"]),
            lambda p: p["Entitlements"].update({"com.apple.developer.team-identifier": "WRONGTEAM1"}),
            lambda p: p["Entitlements"].update({"com.apple.application-identifier": f"{TEAM}.*"}),
            lambda p: p["Entitlements"].update({"com.apple.application-identifier": f"{TEAM}.com.screensaver.Voicelab"}),
            lambda p: p["Entitlements"].update({"com.apple.developer.aps-environment": "development"}),
            lambda p: p["Entitlements"].pop("com.apple.developer.aps-environment"),
            lambda p: p["Entitlements"].update({"get-task-allow": True}),
            lambda p: p["Entitlements"].update({"com.apple.security.get-task-allow": True}),
            lambda p: p.update(DeveloperCertificates=[b"different certificate"]),
            lambda p: p.update(ProvisionsAllDevices=False),
            lambda p: p.update(ProvisionedDevices=["device"]),
            lambda p: p.update(Platform=["iOS"]),
        ]
        for mutation in mutations:
            with self.subTest(mutation=mutations.index(mutation)):
                value = payload()
                mutation(value)
                with self.assertRaises(profile.ProfileError):
                    self.validate(value)

    def test_dates_and_malformed_payload_fail_closed(self):
        for key, value in [("ExpirationDate", NOW), ("ExpirationDate", "2040"),
                           ("CreationDate", NOW + dt.timedelta(minutes=6)),
                           ("CreationDate", None), ("UUID", "../escape"), ("Platform", None),
                           ("Entitlements", []), ("DeveloperCertificates", FINGERPRINT)]:
            with self.subTest(key=key, value=value):
                item = payload()
                item[key] = value
                with self.assertRaises(profile.ProfileError):
                    self.validate(item)

    def test_metadata_alone_cannot_bypass_signature_failure(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "candidate"
            path.write_bytes(b"not signed")
            with patch.object(profile.subprocess, "run", return_value=subprocess.CompletedProcess([], 1, plistlib.dumps(payload()), b"")):
                with self.assertRaisesRegex(profile.ProfileError, "signature/trust"):
                    profile.inspect(path, verifier=Path("ignored"), team=TEAM, bundle=BUNDLE, certificate=FINGERPRINT)

    def test_verifies_and_returns_one_captured_snapshot(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "candidate"
            original = b"signed profile snapshot fixture"
            path.write_bytes(original)
            def verifier(arguments, **kwargs):
                path.write_bytes(b"changed while checking")
                self.assertEqual(Path(arguments[1]).read_bytes(), original)
                return subprocess.CompletedProcess(arguments, 0, plistlib.dumps(payload()), b"")
            with patch.object(profile.subprocess, "run", side_effect=verifier):
                metadata, data = profile.inspect(path, verifier=Path("ignored"), team=TEAM, bundle=BUNDLE, certificate=FINGERPRINT)
            self.assertEqual(data, original)
            self.assertEqual(metadata["sha256"], hashlib.sha256(original).hexdigest())

    def test_capture_size_is_bounded_before_verifier(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "candidate"
            for content in (b"", b"x" * (2 * 1024 * 1024 + 1)):
                path.write_bytes(content)
                with patch.object(profile.subprocess, "run") as verifier:
                    with self.assertRaises(profile.ProfileError):
                        profile.inspect(path, verifier=Path("ignored"), team=TEAM, bundle=BUNDLE, certificate=FINGERPRINT)
                    verifier.assert_not_called()

    def test_atomic_profile_install_never_replaces_other_content(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "nested/profile"
            profile.write_once(path, b"original")
            self.assertEqual(path.stat().st_mode & 0o777, 0o600)
            profile.write_once(path, b"original")
            with self.assertRaises(profile.ProfileError):
                profile.write_once(path, b"changed")
            self.assertEqual(path.read_bytes(), b"original")
            path.unlink()
            target = path.parent / "other"
            target.write_bytes(b"original")
            path.symlink_to(target)
            with self.assertRaises(profile.ProfileError):
                profile.write_once(path, b"original")
            self.assertEqual(target.read_bytes(), b"original")
            self.assertEqual(list(path.parent.glob(".echo-profile-*")), [])

    def test_changed_preflight_hash_does_not_stage_or_install(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            candidate = root / "candidate"
            candidate.write_bytes(b"captured")
            output = root / "stage"
            args = ["push_profile.py", str(candidate), "--verifier", "ignored", "--team", TEAM,
                    "--certificate", FINGERPRINT, "--expected-sha256", "wrong", "--stage", str(output), "--install"]
            with patch("sys.argv", args), patch.object(profile, "inspect", return_value=({"sha256": "new"}, b"new")), \
                    patch.object(profile, "write_once") as write:
                with self.assertRaises(SystemExit):
                    profile.main()
                write.assert_not_called()
            self.assertFalse(output.exists())

    def test_plaintext_profile_is_not_accepted_by_native_cms_verifier(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            executable = root / "verify-profile"
            compile = subprocess.run(["xcrun", "swiftc", "-module-cache-path", str(root / "module-cache"),
                                      str(ROOT / "scripts/verify-provisioning-profile.swift"), "-o", str(executable)],
                                     capture_output=True, text=True)
            self.assertEqual(compile.returncode, 0, compile.stderr)
            candidate = root / "plaintext.provisionprofile"
            candidate.write_bytes(plistlib.dumps(payload()))
            result = subprocess.run([str(executable), str(candidate)], capture_output=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(result.stdout, b"")


if __name__ == "__main__":
    unittest.main()
