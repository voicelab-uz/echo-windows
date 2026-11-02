"""Exercise feed/CDN boundaries without private keys, credentials or network writes."""
import argparse
import base64
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("update_release", ROOT / "scripts/update_release.py")
release = importlib.util.module_from_spec(spec)
spec.loader.exec_module(release)
KEY = "11qYAYKxCrfVS/7TyWQHOg7hcvPapiMlrwIaaPcHURo="  # RFC 8032 public test key
SIGNATURE = base64.b64encode(bytes(range(64))).decode()  # Fake signer only, never a real signature
CONFIG = {"ECHO_UPDATE_HOST_MODE": "cdn", "ECHO_TEAM_ID": "ABCDEFGHIJ", "ECHO_UPDATE_CHANNEL": "test", "ECHO_UPDATE_FEED_URL": "https://cdn.example.invalid/echo/test/appcast.xml",
          "ECHO_UPDATE_RELEASE_BASE_URL": "https://cdn.example.invalid/echo/releases", "ECHO_SPARKLE_PUBLIC_KEY": KEY,
          "ECHO_PREVIOUS_BUILD": "41"}


def signed_bytes(content):
    return content + release.SIGNATURE_PREFIX + f"edSignature: {SIGNATURE}\nlength: {len(content)}\n-->\n".encode()


class PublicationTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="Echo publication tests ")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.source = self.root / "release"
        self.source.mkdir()
        self.name = "Echo-2.0.0-42-universal-test.dmg"
        artifact = self.source / self.name
        artifact.write_bytes(b"already signed, notarized and stapled fixture")
        self.metadata = {"schemaVersion": 1, "version": "2.0.0", "build": "42", "filename": self.name,
            "bytes": artifact.stat().st_size, "sha256": release.digest(artifact), "minimumSystemVersion": "14.0",
            "architectures": ["arm64", "x86_64"], "bundleIdentifier": "uz.voicelab.desktop", "sparkleVersion": "2.10.1",
            "channel": "test", "feedURL": CONFIG["ECHO_UPDATE_FEED_URL"], "releaseBaseURL": CONFIG["ECHO_UPDATE_RELEASE_BASE_URL"],
            "publicEDKey": KEY, "sourceDirty": True, "sourceCommit": "a" * 40, "teamID": "ABCDEFGHIJ"}
        self.write_metadata()
        (self.source / "SHA256SUMS.txt").write_text(self.metadata["sha256"] + "  " + self.name + "\n")
        self.notes = self.root / "notes.html"
        self.notes.write_text("<h1>Echo update</h1><p>Reviewed release notes.</p>\n")
        self.env = patch.dict(os.environ, CONFIG)
        self.env.start()
        self.addCleanup(self.env.stop)

    def write_metadata(self):
        (self.source / "release.json").write_text(json.dumps(self.metadata))

    def args(self, **overrides):
        args = dict(release=self.source, notes=self.notes, output=self.root / "publication",
                    previous_feed=None, initial_feed=True, phased_interval=86400, keep_releases=None)
        return argparse.Namespace(**{**args, **overrides})

    def fake_sign(self, path, tool):
        if path.suffix == ".xml":
            path.write_bytes(signed_bytes(path.read_bytes()))
            return ""
        return SIGNATURE

    def fake_verifier(self, directory):
        path = Path(directory) / "verify-update-signature"
        path.touch()
        return path

    def prepare(self, args=None):
        with patch.object(release, "signing_tool", return_value=Path("sign_update")), \
             patch.object(release, "verifier", side_effect=self.fake_verifier), \
             patch.object(release, "sign", side_effect=self.fake_sign), \
             patch.object(release, "verify_file") as verification:
            release.prepare(args or self.args())
            return verification.call_args_list

    def test_preparation_has_verified_archive_notes_feed_and_feed_last(self):
        calls = self.prepare()
        self.assertEqual(len(calls), 3)
        output = self.root / "publication"
        manifest = json.loads((output / "publication.json").read_text())
        self.assertTrue(manifest["feedMustNotExist"])
        self.assertIsNone(manifest["previousFeedSHA256"])
        self.assertFalse(manifest["files"][-1]["immutable"])
        self.assertTrue(all(item["immutable"] for item in manifest["files"][:-1]))
        for entry in manifest["files"]:
            path = output / entry["path"]
            self.assertEqual(release.digest(path), entry["sha256"])
            self.assertEqual(path.stat().st_size, entry["bytes"])
        feed, _ = release.feed_content((output / "test/appcast.xml").read_bytes())
        item = ET.fromstring(feed).find("channel/item")
        self.assertEqual(item.findtext(f"{{{release.SPARKLE}}}version"), "42")
        self.assertEqual(item.findtext(f"{{{release.SPARKLE}}}minimumSystemVersion"), "14.0.0")
        self.assertEqual(item.findtext(f"{{{release.SPARKLE}}}phasedRolloutInterval"), "86400")
        self.assertEqual(item.find("enclosure").get("length"), str(self.metadata["bytes"]))
        self.assertIn("/releases/test/2.0.0/42/", item.find("enclosure").get("url"))
        with self.assertRaisesRegex(ValueError, "already exists"):
            self.prepare()

    def previous_feed(self, build="41", url=None):
        root = ET.Element("rss")
        channel = ET.SubElement(root, "channel")
        ET.SubElement(channel, "link").text = url or CONFIG["ECHO_UPDATE_FEED_URL"]
        item = release.make_item({**self.metadata, "build": build},
            f"https://cdn.example.invalid/echo/releases/test/2.0.0/{build}/Echo-2.0.0-{build}-universal-test.dmg",
            SIGNATURE, "https://cdn.example.invalid/notes.html", SIGNATURE, 50, 86400)
        channel.append(item)
        path = self.root / "previous.xml"
        path.write_bytes(signed_bytes(ET.tostring(root) + b"\n"))
        return path

    def test_previous_feed_preserves_old_releases_and_compare_and_swap_hash(self):
        previous = self.previous_feed()
        self.prepare(self.args(previous_feed=previous, initial_feed=False, keep_releases=2))
        output = self.root / "publication"
        manifest = json.loads((output / "publication.json").read_text())
        self.assertEqual(manifest["previousFeedSHA256"], release.digest(previous))
        feed, _ = release.feed_content((output / "test/appcast.xml").read_bytes())
        items = ET.fromstring(feed).findall("channel/item")
        self.assertEqual([i.findtext(f"{{{release.SPARKLE}}}version") for i in items], ["42", "41"])

    def test_reused_build_or_wrong_channel_is_rejected_before_signing(self):
        for build, url in (("42", None), ("43", None), ("41", "https://cdn.example.invalid/echo/stable/appcast.xml")):
            with self.subTest(build=build, url=url), self.assertRaises(ValueError):
                self.prepare(self.args(previous_feed=self.previous_feed(build, url), initial_feed=False))
            self.assertFalse((self.root / "publication").exists())

    def test_default_test_feed_prunes_history_and_signs_the_result(self):
        previous = self.previous_feed()
        self.prepare(self.args(previous_feed=previous, initial_feed=False))
        feed, signature = release.feed_content((self.root / "publication/test/appcast.xml").read_bytes())
        self.assertEqual(signature, SIGNATURE)
        self.assertEqual([i.findtext(f"{{{release.SPARKLE}}}version") for i in ET.fromstring(feed).findall("channel/item")], ["42"])

    def test_changed_dmg_and_dirty_stable_metadata_are_rejected(self):
        (self.source / self.name).write_bytes(b"changed after stapling")
        with self.assertRaisesRegex(ValueError, "changed after"):
            release.validated_metadata(self.source)
        with patch.dict(os.environ, {"ECHO_UPDATE_CHANNEL": "stable", "ECHO_UPDATE_FEED_URL": "https://cdn.example.invalid/echo/stable/appcast.xml"}):
            self.metadata.update(channel="stable", feedURL=os.environ["ECHO_UPDATE_FEED_URL"])
            self.write_metadata()
            with self.assertRaisesRegex(ValueError, "Dirty source"):
                release.validated_metadata(self.source)

    def test_feed_unsigned_trailing_content_entities_and_length_are_rejected(self):
        valid = signed_bytes(b"<rss><channel /></rss>\n")
        for data in (b"<rss />", valid + b"<item />", valid.replace(b"length: 23", b"length: 99"),
                     signed_bytes(b'<!DOCTYPE rss [<!ENTITY x SYSTEM "file:///private">]><rss/>')):
            with self.subTest(data=data), self.assertRaises(ValueError):
                release.feed_content(data)

    def test_public_key_and_url_configuration_are_strict(self):
        for change in ({"ECHO_SPARKLE_PUBLIC_KEY": "not a key"}, {"ECHO_SPARKLE_PUBLIC_KEY": base64.b64encode(bytes(32)).decode()},
                       {"ECHO_UPDATE_FEED_URL": "http://cdn.example.invalid/echo/test/appcast.xml"},
                       {"ECHO_UPDATE_FEED_URL": "https://token@cdn.example.invalid/echo/test/appcast.xml"},
                       {"ECHO_UPDATE_FEED_URL": "https://cdn.example.invalid/echo/stable/appcast.xml"},
                       {"ECHO_UPDATE_RELEASE_BASE_URL": "https://other.example.invalid/releases"}):
            with self.subTest(change=change), patch.dict(os.environ, change), self.assertRaises(ValueError):
                release.config()

    def test_public_cdn_verification_checks_bytes_headers_and_waits_to_check_feed(self):
        self.prepare()
        output = self.root / "publication"
        manifest = json.loads((output / "publication.json").read_text())
        entries = {entry["url"]: entry for entry in manifest["files"]}
        requested = []
        def response(request, timeout):
            entry = entries[request.full_url]
            requested.append(request.full_url)
            data = (output / entry["path"]).read_bytes()
            ranged = request.get_header("Range")
            end = int(ranged.split("-")[-1]) if ranged else None
            result = io.BytesIO(data[:end + 1] if ranged else data)
            result.status = 206 if ranged else 200
            result.headers = {"Content-Length": str(entry["bytes"]), "Content-Type": entry["contentType"], "Cache-Control": entry["cacheControl"]}
            if ranged:
                result.headers["Content-Range"] = f"bytes 0-{end}/{entry['bytes']}"
            return result
        with patch.object(release, "build_opener") as opener:
            opener.return_value.open.side_effect = response
            release.verify_public(argparse.Namespace(publication=output, include_feed=False))
        self.assertEqual(len(requested), len(entries))  # Assets plus one DMG byte-range probe.
        self.assertNotIn(CONFIG["ECHO_UPDATE_FEED_URL"], requested)
        def corrupt_response(request, timeout):
            result = response(request, timeout)
            result.seek(0)
            result.write(b"x")
            result.seek(0)
            return result
        with patch.object(release, "build_opener") as opener, self.assertRaisesRegex(ValueError, "differs"):
            opener.return_value.open.side_effect = corrupt_response
            release.verify_public(argparse.Namespace(publication=output, include_feed=True))
        def wrong_cache_response(request, timeout):
            result = response(request, timeout)
            result.headers["Cache-Control"] = "private, no-store"
            return result
        with patch.object(release, "build_opener") as opener, self.assertRaisesRegex(ValueError, "Cache-Control"):
            opener.return_value.open.side_effect = wrong_cache_response
            release.verify_public(argparse.Namespace(publication=output, include_feed=True))

    def test_github_release_contract_keeps_source_private_and_feed_separate(self):
        settings = {"ECHO_UPDATE_HOST_MODE": "github", "ECHO_UPDATE_FEED_URL": release.GITHUB_FEED_BASE + "/test/appcast.xml",
                    "ECHO_UPDATE_RELEASE_BASE_URL": release.GITHUB_ASSET_BASE}
        with patch.dict(os.environ, settings):
            self.metadata.update(feedURL=settings["ECHO_UPDATE_FEED_URL"], releaseBaseURL=settings["ECHO_UPDATE_RELEASE_BASE_URL"])
            self.write_metadata()
            self.prepare()
            manifest = json.loads((self.root / "publication/publication.json").read_text())
            self.assertEqual(manifest["repository"], "voicelab-uz/echo-releases")
            self.assertEqual(manifest["releaseTag"], "test-2.0.0-42")
            self.assertEqual(manifest["artifactVersionedPath"], "releases/test-2.0.0-42")
            self.assertTrue(manifest["sourceDirty"])
            self.assertEqual(manifest["sourceCommit"], "a" * 40)
            self.assertEqual(manifest["files"][-1]["url"], settings["ECHO_UPDATE_FEED_URL"])
            self.assertTrue(all(entry["url"].startswith(release.GITHUB_ASSET_BASE + "/test-2.0.0-42/") for entry in manifest["files"][:-1]))
            with patch.dict(os.environ, {"ECHO_UPDATE_RELEASE_BASE_URL": "https://github.com/voicelab-uz/echo/releases/download"}), self.assertRaises(ValueError):
                release.config()

    def test_github_redirects_are_bounded_https_get_only(self):
        handler = release.GitHubRedirect()
        request = release.Request(release.GITHUB_ASSET_BASE + "/test-2.0.0-42/Echo.dmg")
        allowed = "https://release-assets.githubusercontent.com/github-production-release-asset/x?token=signed"
        redirected = handler.redirect_request(request, None, 302, "Found", {}, allowed)
        self.assertEqual(redirected.full_url, allowed)
        self.assertEqual(handler.max_redirections, 5)
        for url in ("http://release-assets.githubusercontent.com/x", "https://example.com/x", "https://token@github.com/x"):
            with self.subTest(url=url), self.assertRaises(ValueError):
                handler.redirect_request(request, None, 302, "Found", {}, url)
        with self.assertRaises(ValueError):
            handler.redirect_request(release.Request(request.full_url, data=b"write"), None, 302, "Found", {}, allowed)

    def test_wrong_signer_tool_checksum_is_rejected(self):
        (self.root / "sign_update").write_text("untrusted tool")
        with patch.dict(os.environ, {"ECHO_SPARKLE_TOOLS_DIR": str(self.root)}), self.assertRaisesRegex(ValueError, "checksum"):
            release.signing_tool()

    def test_signature_verification_failure_leaves_no_publishable_output(self):
        with patch.object(release, "signing_tool", return_value=Path("sign_update")), \
             patch.object(release, "verifier", side_effect=self.fake_verifier), \
             patch.object(release, "sign", side_effect=self.fake_sign), \
             patch.object(release, "verify_file", side_effect=ValueError("invalid signature")), self.assertRaises(ValueError):
            release.prepare(self.args())
        self.assertFalse((self.root / "publication").exists())
        self.assertFalse(list(self.root.glob(".echo-publication-*")))


class FeedRetentionTests(unittest.TestCase):
    def items(self, count=5, minimum="14.0"):
        return [release.make_item({"version": "1.0.0" if build == 115 else "2.0.0", "build": str(build),
                    "minimumSystemVersion": minimum, "bytes": 100},
                    f"https://cdn.example.invalid/Echo-1.0.0-{build}-universal.dmg", SIGNATURE,
                    "https://cdn.example.invalid/notes.html", SIGNATURE, 50, 86400)
                for build in range(115, 115 - count, -1)]

    def test_newest_three_stable_preserve_item_bytes_despite_marketing_reset(self):
        items = self.items()
        before = [ET.tostring(item) for item in items]
        kept = release.retained_feed_items(items, "stable")
        self.assertEqual([i.findtext(f"{{{release.SPARKLE}}}version") for i in kept], ["115", "114", "113"])
        self.assertEqual([ET.tostring(item) for item in kept], before[:3])
        self.assertEqual([ET.tostring(item) for item in items], before)

    def test_testing_channels_are_bounded_and_explicit_keep_is_supported(self):
        for channel in ("test", "beta"):
            self.assertEqual(len(release.retained_feed_items(self.items(), channel)), 1)
        self.assertEqual(len(release.retained_feed_items(self.items(), "stable", 4)), 4)
        for count in (0, -1, 101, True):
            with self.subTest(count=count), self.assertRaises(ValueError):
                release.retained_feed_items(self.items(), "stable", count)

    def test_removing_last_older_macos_branch_is_refused(self):
        items = self.items(minimum="15.0")
        items[-1].find(f"{{{release.SPARKLE}}}minimumSystemVersion").text = "14.0"
        with self.assertRaisesRegex(ValueError, "last release"):
            release.retained_feed_items(items, "stable")
        self.assertEqual(len(release.retained_feed_items(items, "stable", 5)), 5)
        items[1].find(f"{{{release.SPARKLE}}}minimumSystemVersion").text = "14.0.0"
        self.assertEqual(len(release.retained_feed_items(items, "stable")), 3)

    def test_unrecognized_upgrade_constraints_are_not_silently_dropped(self):
        for constraint in ("maximumSystemVersion", "minimumAutoupdateVersion", "deltas", "channel"):
            items = self.items()
            ET.SubElement(items[-1], f"{{{release.SPARKLE}}}{constraint}").text = "15.0"
            with self.subTest(constraint=constraint), self.assertRaisesRegex(ValueError, "retention review"):
                release.retained_feed_items(items, "stable")
            self.assertEqual(len(release.retained_feed_items(items, "stable", 5)), 5)
        items = self.items()
        items[-1].find("enclosure").set(f"{{{release.SPARKLE}}}os", "macos-arm64")
        with self.assertRaisesRegex(ValueError, "retention review"):
            release.retained_feed_items(items, "stable")

    def test_invalid_duplicate_or_disordered_builds_fail_closed(self):
        items = self.items()
        for builds in (["115", "114", "114", "112", "111"], ["115", "113", "114", "112", "111"],
                       ["115", "114", "bad", "112", "111"]):
            for item, build in zip(items, builds):
                item.find(f"{{{release.SPARKLE}}}version").text = build
            with self.subTest(builds=builds), self.assertRaises(ValueError):
                release.retained_feed_items(items, "stable")


class PublicVerifierTests(unittest.TestCase):
    def test_rfc8032_signature_and_tampering(self):
        # RFC 8032 section 7.1 TEST 1. Public key, signature and empty message only;
        # no private key is generated or read by this test.
        signature = bytes.fromhex("e5564300c360ac729086e2cc806e828a84877f1eb8e5d974d873e06522490155"
                                  "5fb8821590a33bacc61e39701cf9b46bd25bf5f0595bbe24655141438e7a100b")
        with tempfile.TemporaryDirectory(prefix="Echo public verifier ") as temporary:
            executable = release.verifier(temporary)
            message = Path(temporary) / "message"
            message.write_bytes(b"")
            release.verify_file(message, base64.b64encode(signature).decode(), KEY, executable)
            message.write_bytes(b"tampered")
            with self.assertRaises(subprocess.CalledProcessError):
                release.verify_file(message, base64.b64encode(signature).decode(), KEY, executable)


if __name__ == "__main__":
    unittest.main(verbosity=2)
