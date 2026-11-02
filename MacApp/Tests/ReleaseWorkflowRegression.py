"""Exercise release safety gates with fake Apple services and real ZIP/plist tools and checksum validation.

No credentials, signing, Apple submissions, or CDN uploads are performed.
"""

import hashlib
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
FINGERPRINT = "A" * 40
TEAM = "ABCDEFGHIJ"
SUBMISSION = "12345678-1234-1234-1234-123456789abc"

# Only Apple-facing tools are mocked. Packaging, checksum generation, shell
# control flow, plist parsing, extraction, and failure cleanup use real tools.
FAKE_TOOL = r'''#!/usr/bin/env python3
import json, os, pathlib, plistlib, shutil, subprocess, sys
tool = pathlib.Path(sys.argv[0]).name
args = sys.argv[1:]
with open(os.environ["RELEASE_TEST_EVENTS"], "a") as events:
    events.write(json.dumps([tool, *args]) + "\n")
def argument(name):
    return args[args.index(name) + 1]
def setting(name):
    return next(value.split("=", 1)[1] for value in args if value.startswith(name + "="))
def app_at_archive():
    return pathlib.Path(argument("-archivePath")) / "Products/Applications/Echo.app"
if tool == "security":
    kind = os.environ.get("RELEASE_TEST_CERT_KIND", "Developer ID Application")
    print('  1) ' + 'A' * 40 + ' "' + kind + ': Test Team (ABCDEFGHIJ)"')
elif tool == "xcodebuild":
    if args == ["-version"]:
        print("Xcode test fixture")
    elif "archive" in args:
        if os.environ.get("RELEASE_TEST_ARCHIVE_FAIL"):
            sys.exit(65)
        app = app_at_archive()
        (app / "Contents/MacOS").mkdir(parents=True)
        (app / "Contents/MacOS/Echo").write_bytes(bytes.fromhex("cffaedfe") + b"test executable")
        with (app / "Contents/Info.plist").open("wb") as output:
            plistlib.dump({
                "CFBundleIdentifier": "uz.voicelab.desktop",
                "CFBundleShortVersionString": setting("MARKETING_VERSION"),
                "CFBundleVersion": setting("CURRENT_PROJECT_VERSION"),
                "CFBundleExecutable": "Echo", "LSMinimumSystemVersion": "14.0",
                "CFBundleIconFile": "AppIcon",
                "NSMicrophoneUsageDescription": "Record dictation",
                "SUFeedURL": setting("ECHO_UPDATE_FEED_URL"),
                "SUPublicEDKey": setting("ECHO_SPARKLE_PUBLIC_KEY"),
                "EchoUpdateChannel": setting("ECHO_UPDATE_CHANNEL"),
                "SUVerifyUpdateBeforeExtraction": True, "SURequireSignedFeed": True,
                "SUSignedFeedFailureExpirationInterval": 0, "SUEnableSystemProfiling": False, "SUEnableJavaScript": False,
            }, output)
        (app / "Contents/Resources").mkdir()
        (app / "Contents/Resources/AppIcon.icns").write_bytes(b"icns fixture")
        if os.environ.get("RELEASE_TEST_UNSAFE_UPDATE_SETTING"):
            path = app / "Contents/Info.plist"
            info = plistlib.loads(path.read_bytes())
            key = os.environ["RELEASE_TEST_UNSAFE_UPDATE_SETTING"]
            info[key] = 1728000 if key == "SUSignedFeedFailureExpirationInterval" else True
            path.write_bytes(plistlib.dumps(info))
        helper = app / "Contents/Library/LoginItems/EchoWakeHelper.app"
        (helper / "Contents/MacOS").mkdir(parents=True)
        (helper / "Contents/MacOS/EchoWakeHelper").write_bytes(bytes.fromhex("cffaedfe") + b"helper")
        with (helper / "Contents/Info.plist").open("wb") as output:
            plistlib.dump({"CFBundleIdentifier": "uz.voicelab.desktop.WakeHelper", "CFBundleVersion": setting("CURRENT_PROJECT_VERSION")}, output)
        framework = app / "Contents/Frameworks/Sparkle.framework"
        (framework / "Versions/B/Resources").mkdir(parents=True)
        (framework / "Resources").symlink_to("Versions/B/Resources")
        with (framework / "Resources/Info.plist").open("wb") as output:
            plistlib.dump({"CFBundleIdentifier": "org.sparkle-project.Sparkle", "CFBundleShortVersionString": "2.10.1"}, output)
        for suffix in ("Sparkle", "Autoupdate", "Updater.app/Contents/MacOS/Updater", "XPCServices/Installer.xpc/Contents/MacOS/Installer", "XPCServices/Downloader.xpc/Contents/MacOS/Downloader"):
            binary = framework / "Versions/B" / suffix
            binary.parent.mkdir(parents=True, exist_ok=True)
            binary.write_bytes(bytes.fromhex("cffaedfe") + b"Sparkle executable")
        for suffix, identifier in (("Updater.app", "org.sparkle-project.Sparkle.Updater"), ("XPCServices/Installer.xpc", "org.sparkle-project.InstallerLauncher"), ("XPCServices/Downloader.xpc", "org.sparkle-project.DownloaderService")):
            with (framework / "Versions/B" / suffix / "Contents/Info.plist").open("wb") as output:
                plistlib.dump({"CFBundleIdentifier": identifier}, output)
        if os.environ.get("RELEASE_TEST_MISSING_HELPER"):
            (helper / "Contents/MacOS/EchoWakeHelper").unlink()
        if os.environ.get("RELEASE_TEST_ESCAPE_SYMLINK"):
            (app / "Contents/escape").symlink_to("/Applications")
    elif "-exportArchive" in args:
        shutil.copytree(app_at_archive(), pathlib.Path(argument("-exportPath")) / "Echo.app")
    else:
        sys.exit("unexpected xcodebuild invocation")
elif tool == "codesign":
    if "--sign" in args:
        if os.environ.get("RELEASE_TEST_DMG_SIGN_FAIL"):
            sys.exit(1)
    elif "--verify" in args:
        if os.environ.get("RELEASE_TEST_SIGNATURE_FAIL"):
            sys.exit(1)
    elif "--entitlements" in args:
        entitlements = {"com.apple.security.device.audio-input": True}
        if os.environ.get("RELEASE_TEST_DEBUG_ENTITLEMENT"):
            entitlements["com.apple.security.get-task-allow"] = True
        sys.stdout.buffer.write(plistlib.dumps(entitlements))
    else:
        if os.environ.get("RELEASE_TEST_ARCHIVED_HELPER_ADHOC") and "Echo.xcarchive" in args[-1] and args[-1].endswith("Autoupdate"):
            print("Signature=adhoc", file=sys.stderr)
            print("TeamIdentifier=not set", file=sys.stderr)
            sys.exit(0)
        print("Authority=Developer ID Application: Test Team (ABCDEFGHIJ)", file=sys.stderr)
        team = os.environ.get("RELEASE_TEST_SIGNED_TEAM", "ABCDEFGHIJ")
        if os.environ.get("RELEASE_TEST_NESTED_WRONG_TEAM") and "Autoupdate" in args[-1]:
            team = "WRONGTEAM1"
        print("TeamIdentifier=" + team, file=sys.stderr)
        runtime = "0x0(none)" if os.environ.get("RELEASE_TEST_NO_RUNTIME") else "0x10000(runtime)"
        print("CodeDirectory v=20500 size=123 flags=" + runtime, file=sys.stderr)
        print("Timestamp=Oct 21, 2026", file=sys.stderr)
elif tool == "xcrun":
    if args[0] == "--find":
        print("/fake/" + args[1])
    elif args[0] == "clang":
        executable = pathlib.Path(argument("-o"))
        executable.write_text("#!/usr/bin/env python3\nimport os, pathlib, struct, sys\nif os.environ.get('RELEASE_TEST_LAYOUT_FAIL'): sys.exit(1)\nif sys.argv[1]=='verify-alias' and os.environ.get('RELEASE_TEST_ALIAS_VERIFY_FAIL'): sys.exit(1)\nif sys.argv[1] in ('autoopen','verify-autoopen','verify-alias'): sys.exit(0)\noutput=pathlib.Path(sys.argv[3])\noutput.write_bytes(b'TIFF fixture' if sys.argv[1]=='background' else bytes(4)+struct.pack('>HH',154,2)+bytes(142)+struct.pack('>hh',-1,0))\n")
        if any(value.endswith("InstallerVolumeIcon.m") for value in args):
            executable.write_text(r"""#!/usr/bin/env python3
import json, os, pathlib, sys
mode, mount = sys.argv[1], pathlib.Path(sys.argv[2])
with open(os.environ['RELEASE_TEST_EVENTS'], 'a') as output:
    output.write(json.dumps(['installer-volume-icon', *sys.argv[1:]]) + '\n')
source = mount / 'Echo.app/Contents/Resources/AppIcon.icns'
destination = mount / '.VolumeIcon.icns'
if mode == 'apply':
    destination.write_bytes(source.read_bytes())
elif mode == 'verify':
    if os.environ.get('RELEASE_TEST_VOLUME_ICON_VERIFY_FAIL'): sys.exit(1)
    assert destination.read_bytes() == source.read_bytes()
else:
    sys.exit('unexpected volume icon mode')
""")
        executable.chmod(0o755)
    elif args[0] == "lipo":
        print(os.environ.get("RELEASE_TEST_BINARY_ARCHS", os.environ.get("ECHO_ARCHS", "arm64 x86_64")))
    elif args[0] == "stapler":
        artifact = pathlib.Path(args[-1])
        if artifact.suffix == ".dmg":
            if args[1] == "staple":
                with artifact.open("ab") as output: output.write(b"TEST-NOTARY-TICKET")
            elif not artifact.read_bytes().endswith(b"TEST-NOTARY-TICKET"):
                sys.exit(1)
        else:
            ticket = artifact / "Contents/test-notary-ticket"
            if args[1] == "staple":
                ticket.write_text("accepted")
            elif args[1] == "validate" and not ticket.exists():
                sys.exit(1)
    elif args[:2] == ["notarytool", "submit"]:
        if os.environ.get("RELEASE_TEST_SUBMIT_UNKNOWN"):
            sys.exit(1)
        identifier = "12345678-1234-1234-1234-123456789abd" if args[2].endswith(".dmg") else "12345678-1234-1234-1234-123456789abc"
        print(json.dumps({"id": identifier}))
    elif args[:2] == ["notarytool", "wait"]:
        status_key = "RELEASE_TEST_DMG_NOTARY_STATUS" if args[2].endswith("abd") else "RELEASE_TEST_NOTARY_STATUS"
        result = os.environ.get(status_key, "Accepted")
        print(json.dumps({"status": result}))
        if result == "In Progress":
            sys.exit(1)
    elif args[:2] == ["notarytool", "log"]:
        pathlib.Path(args[-1]).write_text('{"issues": []}')
    else:
        sys.exit("unexpected xcrun invocation")
elif tool == "ditto":
    if os.environ.get("RELEASE_TEST_ZIP_INTERRUPTED") and args[-1].endswith("notary-upload.zip"):
        pathlib.Path(args[-1]).write_bytes(b"partial upload archive")
        sys.exit(1)
    sys.exit(subprocess.run(["/usr/bin/ditto", *args]).returncode)
elif tool == "hdiutil":
    if args[0] == "create":
        subprocess.run(["ditto", "-c", "-k", argument("-srcfolder"), args[-1]], check=True)
    elif args[0] == "attach":
        mount = pathlib.Path(argument("-mountpoint"))
        subprocess.run(["ditto", "-x", "-k", args[-1], str(mount)], check=True)
        if "-readonly" not in args:
            (mount.parent / "mounted-image.txt").write_text(args[-1])
    elif args[0] == "detach":
        mount = pathlib.Path(args[-1])
        marker = mount.parent / "mounted-image.txt"
        if marker.exists():
            subprocess.run(["ditto", "-c", "-k", str(mount), marker.read_text()], check=True)
            marker.unlink()
    elif args[0] == "convert":
        if os.environ.get("RELEASE_TEST_DMG_CONVERT_FAIL"):
            pathlib.Path(argument("-o")).write_bytes(b"partial DMG")
            sys.exit(1)
        shutil.copyfile(args[1], argument("-o"))
    else:
        sys.exit("unexpected hdiutil invocation")
elif tool == "spctl":
    if os.environ.get("RELEASE_TEST_GATEKEEPER_FAIL"):
        sys.exit(1)
else:
    sys.exit("unexpected tool")
'''


class ReleaseWorkflowTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="Echo release tests ")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        (self.root / "scripts").mkdir()
        self.script = self.root / "scripts/release.sh"
        shutil.copy2(ROOT / "scripts/release.sh", self.script)
        shutil.copy2(ROOT / "scripts/update_release.py", self.root / "scripts/update_release.py")
        shutil.copy2(ROOT / "scripts/create-installer-dmg.sh", self.root / "scripts/create-installer-dmg.sh")
        shutil.copytree(ROOT / "scripts/installer", self.root / "scripts/installer", ignore=shutil.ignore_patterns('__pycache__'))
        fake_bin = self.root / "fake-tools"
        fake_bin.mkdir()
        for tool in ("xcodebuild", "xcrun", "codesign", "security", "spctl", "hdiutil", "ditto"):
            executable = fake_bin / tool
            executable.write_text(FAKE_TOOL)
            executable.chmod(0o755)
        self.events_path = self.root / "events.jsonl"
        self.env = {
            **os.environ,
            "PATH": str(fake_bin) + os.pathsep + os.environ["PATH"],
            "ECHO_TEAM_ID": TEAM,
            "ECHO_SIGNING_IDENTITY": FINGERPRINT,
            "ECHO_NOTARY_PROFILE": "test-profile",
            "ECHO_ARCHS": "arm64 x86_64",
            "ECHO_UPDATE_CHANNEL": "stable",
            "ECHO_UPDATE_FEED_URL": "https://updates.example.invalid/echo/stable/appcast.xml",
            "ECHO_UPDATE_RELEASE_BASE_URL": "https://updates.example.invalid/echo/releases",
            "ECHO_SPARKLE_PUBLIC_KEY": "11qYAYKxCrfVS/7TyWQHOg7hcvPapiMlrwIaaPcHURo=",
            "ECHO_PREVIOUS_BUILD": "41",
            "ECHO_PUSH_ENABLED": "0",
            "ECHO_PUSH_PROFILE": "",
            "RELEASE_TEST_EVENTS": str(self.events_path),
        }
        subprocess.run(["git", "init", "-q", str(self.root)], check=True)
        (self.root / ".gitignore").write_text("build/\ndist/\nevents.jsonl\n")
        subprocess.run(["git", "-C", str(self.root), "add", "."], check=True)
        subprocess.run([
            "git", "-C", str(self.root), "-c", "user.name=Release Test",
            "-c", "user.email=release@example.invalid", "-c", "commit.gpgsign=false",
            "commit", "--allow-empty", "-qm", "fixture",
        ], check=True)
        self.name = "Echo-1.2.3-42-universal"
        self.work = self.root / "build/releases" / self.name
        self.destination = self.root / "dist" / self.name

    def run_stage(self, action, *, succeeds=True, **environment):
        arguments = ["/bin/bash", str(self.script), action]
        if action not in ("check", "--help"):
            arguments += ["1.2.3", "42"]
        result = subprocess.run(arguments, env={**self.env, **environment}, text=True,
                                stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        if succeeds:
            self.assertEqual(result.returncode, 0, result.stdout)
        else:
            self.assertNotEqual(result.returncode, 0, result.stdout)
            self.assertFalse(self.destination.exists(), result.stdout)
        return result.stdout

    def events(self, tool, action=None):
        entries = [json.loads(line) for line in self.events_path.read_text().splitlines()]
        return [entry for entry in entries if entry[0] == tool and
                (action is None or action in entry)]

    def test_push_required_without_profile_fails_before_build(self):
        output = self.run_stage("all", succeeds=False, ECHO_PUSH_ENABLED="1")
        self.assertIn("Push is required", output)
        self.assertFalse(self.events_path.exists())

    def test_push_config_does_not_silently_fall_back(self):
        for settings in ({"ECHO_PUSH_ENABLED": "true"},
                         {"ECHO_PUSH_PROFILE": "/missing/profile.provisionprofile"},
                         {"ECHO_PUSH_ENABLED": "1", "ECHO_PUSH_PROFILE": "relative.provisionprofile"}):
            with self.subTest(settings=settings):
                self.run_stage("check", succeeds=False, **settings)
                self.assertFalse(self.events_path.exists())

    def test_full_release_and_existing_artifact_is_immutable(self):
        self.run_stage("all")
        files = sorted(item.name for item in self.destination.iterdir())
        self.assertEqual(files, [self.name + ".dmg", "SHA256SUMS.txt", "release.json"])
        archive = self.destination / (self.name + ".dmg")
        digest = hashlib.sha256(archive.read_bytes()).hexdigest()
        metadata = json.loads((self.destination / "release.json").read_text())
        self.assertEqual(metadata["sha256"], digest)
        self.assertEqual(metadata["bytes"], archive.stat().st_size)
        self.assertEqual(metadata["architectures"], ["arm64", "x86_64"])
        self.assertEqual(metadata["notarizationID"], SUBMISSION)
        self.assertEqual(metadata["build"], "42")
        self.assertEqual(len(self.events("installer-volume-icon", "apply")), 1)
        self.assertEqual(len(self.events("installer-volume-icon", "verify")), 1)
        self.assertEqual((self.destination / "SHA256SUMS.txt").read_text(),
                         digest + "  " + self.name + ".dmg\n")
        result = subprocess.run(["/bin/bash", str(self.script), "all", "1.2.3", "42"],
                                env=self.env, capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(hashlib.sha256(archive.read_bytes()).hexdigest(), digest)
        self.assertEqual(len(self.events("xcrun", "submit")), 2)

    def test_notary_timeout_resumes_without_resubmission(self):
        self.run_stage("all", succeeds=False, RELEASE_TEST_NOTARY_STATUS="In Progress")
        self.assertTrue((self.work / "notary-submission.json").exists())
        self.run_stage("notarize")
        self.run_stage("package")
        self.assertEqual(len(self.events("xcrun", "submit")), 2)
        self.assertEqual(len(self.events("xcrun", "wait")), 3)

    def test_incomplete_zip_is_not_submitted_or_reused(self):
        self.run_stage("all", succeeds=False, RELEASE_TEST_ZIP_INTERRUPTED="1")
        self.assertFalse((self.work / "notary-upload.zip").exists())
        self.assertFalse(self.events("xcrun", "submit"))
        self.run_stage("notarize")
        self.run_stage("package")
        self.assertEqual(len(self.events("xcrun", "submit")), 2)

    def test_failed_dmg_signing_does_not_block_retry_or_resubmit_app(self):
        self.run_stage("all", succeeds=False, RELEASE_TEST_DMG_SIGN_FAIL="1")
        self.assertFalse((self.work / "dmg-upload.dmg").exists())
        self.assertFalse(list(self.work.glob("dmg-publish.*")))
        create = self.events("hdiutil", "create")[-1]
        content = Path(create[create.index("-srcfolder") + 1])
        self.assertFalse(content.parent.exists())
        self.assertFalse(content.is_relative_to(self.work))
        self.run_stage("notarize")
        self.run_stage("package")
        self.assertEqual(len(self.events("xcrun", "submit")), 2)

    def test_installer_layout_failure_never_submits_dmg_and_is_retryable(self):
        self.run_stage("all", succeeds=False, RELEASE_TEST_LAYOUT_FAIL="1")
        self.assertFalse((self.work / "dmg-upload.dmg").exists())
        self.assertEqual(len(self.events("xcrun", "submit")), 1)
        self.run_stage("notarize")
        self.run_stage("package")
        self.assertEqual(len(self.events("xcrun", "submit")), 2)

    def test_remounted_background_failure_prevents_signing_or_submission(self):
        self.run_stage("all", succeeds=False, RELEASE_TEST_ALIAS_VERIFY_FAIL="1")
        self.assertFalse((self.work / "dmg-upload.dmg").exists())
        self.assertEqual(len(self.events("xcrun", "submit")), 1)
        self.assertFalse(self.events("codesign", "--sign"))
        attach = self.events("hdiutil", "attach")[-1]
        mount = Path(attach[attach.index("-mountpoint") + 1])
        self.assertFalse(mount.parent.exists())
        self.run_stage("notarize")
        self.run_stage("package")
        self.assertEqual(len(self.events("xcrun", "submit")), 2)

    def test_remounted_volume_icon_failure_prevents_signing_or_submission(self):
        self.run_stage("all", succeeds=False, RELEASE_TEST_VOLUME_ICON_VERIFY_FAIL="1")
        self.assertFalse((self.work / "dmg-upload.dmg").exists())
        self.assertEqual(len(self.events("xcrun", "submit")), 1)
        self.assertFalse(self.events("codesign", "--sign"))
        self.assertEqual(len(self.events("installer-volume-icon", "apply")), 1)
        self.assertEqual(len(self.events("installer-volume-icon", "verify")), 1)
        self.run_stage("notarize")
        self.run_stage("package")
        self.assertEqual(len(self.events("xcrun", "submit")), 2)

    def test_partial_installer_conversion_is_not_reused(self):
        self.run_stage("all", succeeds=False, RELEASE_TEST_DMG_CONVERT_FAIL="1")
        self.assertFalse((self.work / "dmg-upload.dmg").exists())
        self.assertEqual(len(self.events("xcrun", "submit")), 1)
        create = self.events("hdiutil", "create")[-1]
        self.assertFalse(Path(create[create.index("-srcfolder") + 1]).parent.exists())
        self.run_stage("notarize")
        self.run_stage("package")
        self.assertEqual(len(self.events("xcrun", "submit")), 2)

    def test_dmg_timeout_resumes_original_submission_and_staples_only_final_copy(self):
        self.run_stage("all", succeeds=False, RELEASE_TEST_DMG_NOTARY_STATUS="In Progress")
        submitted = (self.work / "dmg-upload.dmg").read_bytes()
        self.run_stage("notarize")
        self.assertEqual((self.work / "dmg-upload.dmg").read_bytes(), submitted)
        self.run_stage("package")
        self.assertEqual(len(self.events("xcrun", "submit")), 2)
        self.assertEqual(len(self.events("xcrun", "wait")), 3)

    def test_test_channel_dirty_source_requires_explicit_opt_in(self):
        (self.root / "uncommitted.txt").write_text("test only")
        self.name += "-test"
        self.work = self.root / "build/releases" / self.name
        self.destination = self.root / "dist" / self.name
        settings = {"ECHO_UPDATE_CHANNEL": "test", "ECHO_UPDATE_FEED_URL": "https://updates.example.invalid/echo/test/appcast.xml"}
        self.run_stage("build", succeeds=False, **settings)
        self.assertFalse((self.work / "source.plist").exists())
        self.run_stage("all", ECHO_ALLOW_DIRTY_TEST="1", **settings)
        metadata = json.loads((self.destination / "release.json").read_text())
        self.assertTrue(metadata["sourceDirty"])
        self.assertEqual(metadata["channel"], "test")

    def test_rejected_notarization_never_packages(self):
        self.run_stage("all", succeeds=False, RELEASE_TEST_NOTARY_STATUS="Invalid")
        self.run_stage("package", succeeds=False)
        self.assertTrue((self.work / "notary-log.json").exists())
        self.assertFalse(self.events("xcrun", "staple"))

    def test_unknown_submission_outcome_does_not_blindly_resubmit(self):
        self.run_stage("all", succeeds=False, RELEASE_TEST_SUBMIT_UNKNOWN="1")
        self.run_stage("notarize", succeeds=False)
        self.assertEqual(len(self.events("xcrun", "submit")), 1)

    def test_changed_upload_is_rejected_on_resume(self):
        self.run_stage("all", succeeds=False, RELEASE_TEST_NOTARY_STATUS="In Progress")
        with (self.work / "notary-upload.zip").open("ab") as archive:
            archive.write(b"tampered")
        self.run_stage("notarize", succeeds=False)
        self.assertEqual(len(self.events("xcrun", "wait")), 1)

    def test_signing_and_architecture_gates(self):
        for setting, value in (
            ("RELEASE_TEST_DEBUG_ENTITLEMENT", "1"),
            ("RELEASE_TEST_NO_RUNTIME", "1"),
            ("RELEASE_TEST_SIGNED_TEAM", "WRONGTEAM1"),
            ("RELEASE_TEST_BINARY_ARCHS", "arm64"),
            ("RELEASE_TEST_SIGNATURE_FAIL", "1"),
            ("RELEASE_TEST_NESTED_WRONG_TEAM", "1"),
            ("RELEASE_TEST_MISSING_HELPER", "1"),
            ("RELEASE_TEST_ESCAPE_SYMLINK", "1"),
        ):
            with self.subTest(setting=setting):
                if self.work.exists():
                    shutil.rmtree(self.work)
                self.run_stage("all", succeeds=False, **{setting: value})
                self.assertFalse(self.events("xcrun", "submit"))

    def test_updater_security_and_privacy_defaults_are_required(self):
        for key in ("SUSignedFeedFailureExpirationInterval", "SUEnableSystemProfiling", "SUEnableJavaScript"):
            with self.subTest(key=key):
                if self.work.exists():
                    shutil.rmtree(self.work)
                self.run_stage("all", succeeds=False, RELEASE_TEST_UNSAFE_UPDATE_SETTING=key)
                self.assertFalse(self.events("xcodebuild", "-exportArchive"))

    def test_dirty_source_is_rejected_before_archive(self):
        (self.root / "uncommitted.txt").write_text("not reviewed")
        self.run_stage("all", succeeds=False)
        self.assertFalse(self.events("xcodebuild", "archive"))
        self.assertFalse((self.work / "source.plist").exists())

    def test_build_number_cannot_go_backwards(self):
        self.run_stage("all", succeeds=False, ECHO_PREVIOUS_BUILD="42")
        self.assertFalse(self.events_path.exists())

    def test_configuration_cannot_change_after_build(self):
        self.run_stage("build")
        self.run_stage("sign", succeeds=False, ECHO_UPDATE_RELEASE_BASE_URL="https://updates.example.invalid/other/releases")
        self.assertFalse(self.events("xcodebuild", "-exportArchive"))

    def test_export_may_resign_original_sparkle_helpers(self):
        self.run_stage("all", RELEASE_TEST_ARCHIVED_HELPER_ADHOC="1")
        self.assertTrue(self.destination.exists())
        self.assertEqual(len(self.events("xcodebuild", "-exportArchive")), 1)

    def test_dmg_bytes_are_stapled_after_submission_and_before_final_checksum(self):
        self.run_stage("all")
        submitted = (self.work / "dmg-upload.dmg").read_bytes()
        final = (self.destination / (self.name + ".dmg")).read_bytes()
        self.assertFalse(submitted.endswith(b"TEST-NOTARY-TICKET"))
        self.assertEqual(final, submitted + b"TEST-NOTARY-TICKET")

    def test_development_certificate_is_rejected_before_build(self):
        self.run_stage("all", succeeds=False, RELEASE_TEST_CERT_KIND="Apple Development")
        self.assertFalse(self.events("xcodebuild", "archive"))

    def test_missing_notary_profile_fails_before_build(self):
        self.run_stage("all", succeeds=False, ECHO_NOTARY_PROFILE="")
        self.assertFalse(self.events_path.exists())

    def test_archive_failure_survives_tee_and_does_not_export(self):
        self.run_stage("all", succeeds=False, RELEASE_TEST_ARCHIVE_FAIL="1")
        self.assertFalse(self.events("xcodebuild", "-exportArchive"))
        self.assertFalse(Path(str(self.work) + ".lock").exists())

    def test_gatekeeper_and_missing_staple_block_packaging(self):
        self.run_stage("build")
        self.run_stage("sign")
        self.run_stage("notarize")
        self.run_stage("package", succeeds=False, RELEASE_TEST_GATEKEEPER_FAIL="1")
        (self.work / "export/Echo.app/Contents/test-notary-ticket").unlink()
        self.run_stage("package", succeeds=False)


if __name__ == "__main__":
    unittest.main(verbosity=2)
