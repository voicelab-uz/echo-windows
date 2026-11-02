"""GitHub publication safety tests: mocked CLI/API only, no credentials or writes."""
import base64
import copy
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))
import publish_github as publisher

KEY = "11qYAYKxCrfVS/7TyWQHOg7hcvPapiMlrwIaaPcHURo="
SIGNATURE = base64.b64encode(bytes(range(64))).decode()


def signed_bytes(content):
    return content + publisher.release.SIGNATURE_PREFIX + f"edSignature: {SIGNATURE}\nlength: {len(content)}\n-->\n".encode()


class FakeGitHub:
    def __init__(self, publication):
        self.publication = publication
        self.remote_release = None
        self.remote_assets = {}
        self.feed = None
        self.operations = []
        self.ambiguous = set()
        self.conflict_on_put = False
        self.public = True
        self.immutable_enabled = True
        self.lock_on_publish = True
        self.put_count = 0
        self.temporary_draft_urls = False

    def api(self, endpoint, method="GET", payload=None, missing=False):
        self.operations.append((method, endpoint, copy.deepcopy(payload)))
        if endpoint == publisher.API:
            return {"full_name": publisher.REPOSITORY, "private": not self.public, "visibility": "public" if self.public else "private", "archived": False, "default_branch": "main"}
        if endpoint.endswith("/immutable-releases"):
            return {"enabled": self.immutable_enabled}
        if "/contents/" in endpoint:
            if method == "GET":
                return copy.deepcopy(self.feed)
            self.put_count += 1
            if self.conflict_on_put:
                self.set_feed(b"another publisher won")
                raise publisher.GitHubError("PUT", 409)
            if self.feed is not None and payload.get("sha") != self.feed["sha"]:
                raise publisher.GitHubError("PUT", 409)
            if self.feed is None and "sha" in payload:
                raise publisher.GitHubError("PUT", 409)
            self.set_feed(base64.b64decode(payload["content"]))
            if "feed" in self.ambiguous:
                self.ambiguous.remove("feed")
                raise publisher.GitHubError("PUT")
            return {"content": copy.deepcopy(self.feed)}
        if endpoint == f"{publisher.API}/releases" and method == "POST":
            self.remote_release = {**payload, "id": 99, "immutable": False}
            if "create" in self.ambiguous:
                self.ambiguous.remove("create")
                raise publisher.GitHubError("POST")
            return copy.deepcopy(self.remote_release)
        if endpoint == f"{publisher.API}/releases/99":
            if method == "GET":
                return copy.deepcopy(self.remote_release)
            self.remote_release.update(payload)
            self.remote_release["immutable"] = self.lock_on_publish
            for name, asset in self.remote_assets.items():
                asset["browser_download_url"] = self.publication["_assets"][name]["url"]
            if "publish" in self.ambiguous:
                self.ambiguous.remove("publish")
                raise publisher.GitHubError("PATCH")
            return copy.deepcopy(self.remote_release)
        raise AssertionError((endpoint, method, payload))

    def set_feed(self, data):
        self.feed = {"type": "file", "encoding": "base64", "content": base64.b64encode(data).decode(), "size": len(data), "sha": hashlib.sha1(b"blob " + str(len(data)).encode() + b"\0" + data).hexdigest()}

    def find_release(self, tag):
        return copy.deepcopy(self.remote_release)

    def assets(self, identifier):
        return copy.deepcopy(list(self.remote_assets.values()))

    def upload(self, tag, path):
        name = path.name
        assert name not in self.remote_assets, "Existing assets must never be replaced"
        self.operations.append(("UPLOAD", name, None))
        entry = self.publication["_assets"][name]
        self.remote_assets[name] = {"name": name, "state": "uploaded", "size": path.stat().st_size,
            "digest": "sha256:" + publisher.release.digest(path), "browser_download_url": entry["url"]}
        if self.temporary_draft_urls:
            self.remote_assets[name]["browser_download_url"] = f"{publisher.ASSET_BASE}/untagged-9f630ec7eee3c3a82f82/{name}"
        if "upload" in self.ambiguous:
            self.ambiguous.remove("upload")
            raise publisher.GitHubError("UPLOAD")


class PublicationTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="Echo GitHub publication ")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name).resolve()
        self.env = patch.dict(os.environ, {"ECHO_SPARKLE_PUBLIC_KEY": KEY, "ECHO_TEAM_ID": "FWCSVFT76D"})
        self.env.start()
        self.addCleanup(self.env.stop)
        self.signature = patch.object(publisher.release, "verify_file")
        self.signature.start()
        self.addCleanup(self.signature.stop)
        self.manifest = self.make_fixture()
        self.publication = self.load()
        self.github = FakeGitHub(self.publication)
        self.visited = []
        self.public_check = patch.object(publisher, "verify_public", side_effect=self.verify_public)
        self.public_check.start()
        self.addCleanup(self.public_check.stop)

    def make_fixture(self, channel="test", dirty=True, previous=None):
        version, build = "2.0.0", "102"
        tag = f"{channel}-{version}-{build}"
        suffix = "" if channel == "stable" else "-" + channel
        name = f"Echo-{version}-{build}-universal{suffix}.dmg"
        folder = self.root / "releases" / tag
        folder.mkdir(parents=True, exist_ok=True)
        archive = folder / name
        archive.write_bytes(b"signed, notarized, stapled universal DMG fixture")
        metadata = {"schemaVersion": 1, "channel": channel, "version": version, "build": build,
            "sourceDirty": dirty, "sourceCommit": "a" * 40, "teamID": "FWCSVFT76D", "publicEDKey": KEY,
            "bundleIdentifier": "uz.voicelab.desktop", "architectures": ["arm64", "x86_64"],
            "filename": name, "bytes": archive.stat().st_size, "sha256": publisher.release.digest(archive)}
        (folder / "release.json").write_text(json.dumps(metadata))
        (folder / "SHA256SUMS.txt").write_text(metadata["sha256"] + "  " + name + "\n")
        notes = folder / "release-notes.html"
        notes.write_bytes(b"<p>Reviewed release notes.</p>\n")
        rss = ET.Element("rss")
        rss_channel = ET.SubElement(rss, "channel")
        ET.SubElement(rss_channel, "link").text = f"{publisher.FEED_BASE}/{channel}/appcast.xml"
        item = ET.SubElement(rss_channel, "item")
        ET.SubElement(item, f"{{{publisher.release.SPARKLE}}}version").text = build
        ET.SubElement(item, "enclosure", {"url": f"{publisher.ASSET_BASE}/{tag}/{name}", "length": str(archive.stat().st_size), f"{{{publisher.release.SPARKLE}}}edSignature": SIGNATURE})
        ET.SubElement(item, f"{{{publisher.release.SPARKLE}}}releaseNotesLink", {f"{{{publisher.release.SPARKLE}}}length": str(notes.stat().st_size), f"{{{publisher.release.SPARKLE}}}edSignature": SIGNATURE}).text = f"{publisher.ASSET_BASE}/{tag}/release-notes.html"
        feed = self.root / channel / "appcast.xml"
        feed.parent.mkdir(exist_ok=True)
        feed.write_bytes(signed_bytes(ET.tostring(rss) + b"\n"))
        files = []
        for path in sorted(folder.iterdir()) + [feed]:
            files.append({"path": path.relative_to(self.root).as_posix(), "url": f"{publisher.FEED_BASE}/{channel}/appcast.xml" if path == feed else f"{publisher.ASSET_BASE}/{tag}/{path.name}", "immutable": path != feed,
                          "sha256": publisher.release.digest(path), "bytes": path.stat().st_size})
        manifest = {"schemaVersion": 1, "hostMode": "github", "repository": publisher.REPOSITORY, "releaseTag": tag,
            **{key: metadata[key] for key in ("channel", "version", "build", "sourceDirty", "sourceCommit", "teamID", "publicEDKey")},
            "feedMustNotExist": previous is None, "previousFeedSHA256": hashlib.sha256(previous).hexdigest() if previous else None, "files": files}
        (self.root / "publication.json").write_text(json.dumps(manifest))
        return manifest

    def load(self, promote=False):
        return publisher.load_publication(self.root, promote, Path("public-verifier"))

    def rewrite(self):
        (self.root / "publication.json").write_text(json.dumps(self.manifest))

    def verify_public(self, entry):
        self.assertFalse(self.github.remote_release["draft"])
        self.assertTrue(self.github.remote_release["immutable"])
        if entry["immutable"]:
            self.assertEqual(self.github.put_count, 0)
        else:
            self.assertIsNotNone(self.github.feed)
        self.visited.append(entry["url"])

    def run_publisher(self):
        publisher.Publisher(self.publication, self.github, Path("public-verifier")).run()

    def test_assets_are_verified_before_feed_and_prerelease_never_latest(self):
        self.run_publisher()
        self.assertEqual(len(self.visited), 5)
        self.assertEqual(self.github.put_count, 1)
        self.assertTrue(self.github.remote_release["prerelease"])
        self.assertEqual(self.github.remote_release["make_latest"], "false")
        put = next(op for op in self.github.operations if op[0] == "PUT")
        self.assertEqual(put[1], f"{publisher.API}/contents/test/appcast.xml")
        self.assertNotIn("sha", put[2])
        self.assertTrue(all("stable" not in op[1] for op in self.github.operations))

    def test_ambiguous_create_upload_publish_and_feed_success_reconcile(self):
        self.github.ambiguous = {"create", "upload", "publish", "feed"}
        self.run_publisher()
        self.assertEqual(len(self.github.remote_assets), 4)
        self.assertEqual(self.github.put_count, 1)
        self.assertEqual(sum(op[0] == "POST" for op in self.github.operations), 1)
        self.assertEqual(sum(op[0] == "UPLOAD" for op in self.github.operations), 4)

    def test_exact_published_retry_does_not_mutate(self):
        self.run_publisher()
        self.github.operations.clear()
        with patch.object(publisher, "verify_public"):
            self.run_publisher()
        self.assertFalse(any(op[0] in ("POST", "PATCH", "PUT", "UPLOAD") for op in self.github.operations))

    def test_real_cli_reconciles_ambiguous_lock_with_same_exception_identity(self):
        # Run the actual __main__ entry point, not an imported main(). A second
        # publish_github module would create a different GitHubError class and
        # fail to reconcile these two ambiguous API outcomes.
        fixture = self.root / 'cli-fixture'
        fixture.mkdir()
        (fixture / 'sitecustomize.py').write_text(
            "from pathlib import Path\nimport update_release as r\n"
            "r.verifier=lambda directory:Path('/synthetic-verifier')\n"
            "r.verify_file=lambda *args:None\n")
        state = fixture / 'state.json'
        state.write_text(json.dumps({'lock':None,'operations':[]}))
        executable = fixture / 'gh'
        executable.write_text('#!' + sys.executable + '\n' + r'''
import json,os,sys
from pathlib import Path
p=Path(os.environ['ECHO_FAKE_GITHUB_STATE']);state=json.loads(p.read_text())
args=sys.argv[1:];endpoint=next(a for a in args if a.startswith('repos/'))
method=args[args.index('--method')+1];state['operations'].append([method,endpoint])
status=200;body={};prefix='repos/voicelab-uz/echo-releases'
if endpoint==prefix+'/git/ref/heads/echo-release-operation':
 status=200 if state['lock'] else 404;body={'object':{'sha':state['lock']}}
elif endpoint==prefix+'/git/ref/heads/main':body={'object':{'sha':'a'*40}}
elif endpoint==prefix+'/git/commits/'+'a'*40:body={'tree':{'sha':'b'*40}}
elif endpoint==prefix+'/git/commits':body={'sha':'c'*40}
elif endpoint==prefix+'/git/refs':
 payload=json.load(sys.stdin);state['lock']=payload['sha'];status=502
elif endpoint==prefix+'/git/refs/heads/echo-release-operation':
 state['lock']=None;status=502
elif endpoint==prefix:
 body={'full_name':'voicelab-uz/echo-releases','private':True,'visibility':'private','archived':False,'default_branch':'main'}
else:raise SystemExit('Unexpected fixture API')
p.write_text(json.dumps(state));print(f'HTTP/2 {status}\n\n'+json.dumps(body));sys.exit(0 if status==200 else 1)
''')
        executable.chmod(0o755)
        env = {**os.environ, 'PATH':str(fixture)+os.pathsep+os.environ['PATH'],
               'PYTHONPATH':str(fixture)+os.pathsep+str(ROOT/'scripts'),
               'ECHO_FAKE_GITHUB_STATE':str(state)}
        result = subprocess.run([sys.executable,str(ROOT/'scripts/publish_github.py'),str(self.root),'--skip-retention'],
                                env=env,text=True,capture_output=True,timeout=20)
        self.assertEqual(result.returncode,1)
        self.assertIn('Publisher requires the active public Echo artifacts-only repo',result.stderr)
        final=json.loads(state.read_text())
        self.assertIsNone(final['lock'])
        self.assertIn(['DELETE',publisher.API+'/git/refs/heads/echo-release-operation'],final['operations'])

    def test_lost_operation_lock_fences_publication_mutation(self):
        class LostLock:
            def check(self):raise ValueError('Operation ownership changed')
        with self.assertRaisesRegex(ValueError,'ownership'):
            publisher.Publisher(self.publication,self.github,Path('verifier'),LostLock()).run()
        self.assertFalse(any(op[0] in ('POST','PATCH','PUT','UPLOAD') for op in self.github.operations))

    def test_partial_draft_resume_uploads_only_missing_assets(self):
        job = publisher.Publisher(self.publication, self.github, Path("verifier"))
        job.ensure_draft()
        entry = next(iter(self.publication["_assets"].values()))
        self.github.upload(self.publication["releaseTag"], self.root / entry["path"])
        self.github.operations.clear()
        self.run_publisher()
        self.assertEqual(sum(op[0] == "UPLOAD" for op in self.github.operations), 3)

    def test_draft_temporary_asset_urls_resume_and_become_exact_published_urls(self):
        self.github.temporary_draft_urls = True
        job = publisher.Publisher(self.publication, self.github, Path("verifier"))
        job.ensure_draft()
        entry = next(iter(self.publication["_assets"].values()))
        self.github.upload(self.publication["releaseTag"], self.root / entry["path"])
        self.github.operations.clear()
        self.run_publisher()
        self.assertEqual(sum(op[0] == "UPLOAD" for op in self.github.operations), 3)
        for name, asset in self.github.remote_assets.items():
            self.assertEqual(asset["browser_download_url"], self.publication["_assets"][name]["url"])

    def test_temporary_url_allowed_only_for_same_repo_filename_and_validated_draft(self):
        self.github.temporary_draft_urls = True
        job = publisher.Publisher(self.publication, self.github, Path("verifier"))
        job.ensure_draft()
        entry = next(iter(self.publication["_assets"].values()))
        self.github.upload(self.publication["releaseTag"], self.root / entry["path"])
        asset = next(iter(self.github.remote_assets.values()))
        valid = asset["browser_download_url"]
        self.assertTrue(job.check_assets(99, draft=True))
        with self.assertRaisesRegex(ValueError, "never be overwritten"):
            job.check_assets(99, draft=False)
        for bad in (valid.replace("echo-releases", "echo"), valid + "?anything=1", valid.replace("untagged-9f630ec7eee3c3a82f82", "other-tag"), valid + ".extra"):
            asset["browser_download_url"] = bad
            with self.subTest(url=bad), self.assertRaisesRegex(ValueError, "never be overwritten"):
                job.check_assets(99, draft=True)

    def test_conflicting_asset_never_overwritten_or_published(self):
        job = publisher.Publisher(self.publication, self.github, Path("verifier"))
        job.ensure_draft()
        entry = next(iter(self.publication["_assets"].values()))
        self.github.upload(self.publication["releaseTag"], self.root / entry["path"])
        asset = next(iter(self.github.remote_assets.values()))
        for field, bad in (("digest", "sha256:" + "b" * 64), ("size", -1), ("state", "starter")):
            old = asset[field]
            asset[field] = bad
            with self.subTest(field=field), self.assertRaisesRegex(ValueError, "never be overwritten"):
                self.run_publisher()
            asset[field] = old
        self.assertTrue(self.github.remote_release["draft"])
        self.assertEqual(self.github.put_count, 0)

    def test_conflicting_draft_metadata_is_not_rewritten(self):
        job = publisher.Publisher(self.publication, self.github, Path("verifier"))
        job.ensure_draft()
        self.github.remote_release["body"] = "someone else's draft"
        self.github.operations.clear()
        with self.assertRaisesRegex(ValueError, "metadata conflicts"):
            self.run_publisher()
        self.assertFalse(any(op[0] in ("POST", "PATCH", "PUT", "UPLOAD") for op in self.github.operations))

    def test_private_or_mutable_repository_is_rejected_before_writes(self):
        for private, mutable in ((True, False), (False, True)):
            self.github.public = not private
            self.github.immutable_enabled = not mutable
            with self.subTest(private=private), self.assertRaises(ValueError):
                self.run_publisher()
        self.assertIsNone(self.github.remote_release)

    def test_published_release_must_actually_be_immutable(self):
        self.github.lock_on_publish = False
        with self.assertRaisesRegex(ValueError, "not immutable"):
            self.run_publisher()
        self.assertEqual(self.github.put_count, 0)

    def test_new_initial_feed_never_replaces_an_existing_feed(self):
        self.github.set_feed(b"existing feed")
        with self.assertRaisesRegex(ValueError, "Feed changed"):
            self.run_publisher()
        self.assertIsNone(self.github.remote_release)

    def test_existing_previous_signed_feed_uses_git_blob_sha_for_cas(self):
        content = f'<rss><channel><link>{publisher.FEED_BASE}/test/appcast.xml</link></channel></rss>'.encode()
        previous = signed_bytes(content)
        self.manifest = self.make_fixture(previous=previous)
        self.publication = self.load()
        self.github = FakeGitHub(self.publication)
        self.github.set_feed(previous)
        expected = self.github.feed["sha"]
        self.run_publisher()
        put = next(op for op in self.github.operations if op[0] == "PUT")
        self.assertEqual(put[2]["sha"], expected)
        self.assertNotEqual(expected, self.manifest["previousFeedSHA256"])

    def test_concurrent_feed_promotion_is_never_overwritten(self):
        self.github.conflict_on_put = True
        with self.assertRaisesRegex(ValueError, "Feed changed"):
            self.run_publisher()
        self.assertEqual(self.github.put_count, 1)
        self.assertEqual(base64.b64decode(self.github.feed["content"]), b"another publisher won")

    def test_failed_public_download_never_promotes_feed(self):
        with patch.object(publisher, "verify_public", side_effect=ValueError("download corrupt")), self.assertRaisesRegex(ValueError, "download corrupt"):
            self.run_publisher()
        self.assertEqual(self.github.put_count, 0)
        self.assertFalse(self.github.remote_release["draft"])

    def test_feed_commit_succeeds_but_raw_cache_pending_is_explicit_and_retry_safe(self):
        def cached_feed(entry):
            if not entry["immutable"]:
                raise ValueError("Public download bytes differ from the prepared publication.")
        with patch.object(publisher, "verify_public", side_effect=cached_feed), self.assertRaises(publisher.PublicFeedPending) as pending:
            self.run_publisher()
        self.assertIn("feed commit is confirmed", str(pending.exception))
        self.assertEqual(self.github.put_count, 1)
        self.github.operations.clear()
        with patch.object(publisher, "verify_public"):
            self.run_publisher()
        self.assertFalse(any(op[0] in ("POST", "PATCH", "PUT", "UPLOAD") for op in self.github.operations))

    def test_previous_feed_with_newer_build_blocks_downgrade_before_staging(self):
        content = f'<rss xmlns:sparkle="{publisher.release.SPARKLE}"><channel><link>{publisher.FEED_BASE}/test/appcast.xml</link><item><sparkle:version>103</sparkle:version></item></channel></rss>'.encode()
        previous = signed_bytes(content)
        self.manifest = self.make_fixture(previous=previous)
        self.publication = self.load()
        self.github = FakeGitHub(self.publication)
        self.github.set_feed(previous)
        with self.assertRaisesRegex(ValueError, "downgrades are forbidden"):
            self.run_publisher()
        self.assertIsNone(self.github.remote_release)

    def test_feed_mutation_after_path_check_cannot_submit_unverified_bytes(self):
        original_check = publisher.local_file
        def tamper_after_check(root, entry):
            checked = original_check(root, entry)
            if entry.get("immutable") is False:
                checked.write_bytes(b"changed after check")
            return checked
        with patch.object(publisher, "local_file", side_effect=tamper_after_check), self.assertRaisesRegex(ValueError, "signed feed changed"):
            self.run_publisher()
        self.assertEqual(self.github.put_count, 0)

    def test_feed_submit_uses_verified_buffer_even_if_file_changes_after_read(self):
        original_read = Path.read_bytes
        signed_feed = self.root / self.publication["_feed"]["path"]
        reads = 0
        def mutate_after_read(path):
            nonlocal reads
            data = original_read(path)
            if path == signed_feed:
                reads += 1
                path.write_bytes(b"changed after captured buffer")
            return data
        with patch.object(Path, "read_bytes", mutate_after_read):
            self.run_publisher()
        self.assertEqual(reads, 1)
        self.assertEqual(hashlib.sha256(base64.b64decode(self.github.feed["content"])).hexdigest(), self.publication["_feed"]["sha256"])

    def test_stable_requires_explicit_promotion_and_clean_provenance(self):
        self.manifest = self.make_fixture(channel="stable", dirty=True)
        for promote in (False, True):
            with self.subTest(promote=promote), self.assertRaisesRegex(ValueError, "clean source"):
                self.load(promote)
        self.manifest = self.make_fixture(channel="stable", dirty=False)
        with self.assertRaisesRegex(ValueError, "--promote"):
            self.load()
        self.assertEqual(self.load(True)["channel"], "stable")

    def test_modified_local_bytes_untrusted_key_path_or_extra_assets_rejected(self):
        original = copy.deepcopy(self.manifest)
        for mutate in (lambda m: m.update(publicEDKey=base64.b64encode(b"x" * 32).decode()),
                       lambda m: m["files"][0].update(path="../secret"),
                       lambda m: m["files"].insert(0, m["files"][0]),
                       lambda m: m["files"][0].update(sha256="c" * 64)):
            self.manifest = copy.deepcopy(original)
            mutate(self.manifest)
            self.rewrite()
            with self.assertRaises(ValueError):
                self.load()


class CLITests(unittest.TestCase):
    def test_cli_uses_structured_stdin_and_explicit_host_without_token_arguments(self):
        completed = subprocess.CompletedProcess([], 0, b'HTTP/2.0 201 Created\r\nContent-Type: application/json\r\n\r\n{"id":99}\n', b"")
        with patch.object(publisher, "github_cli", return_value="/opt/homebrew/bin/gh"), patch.object(publisher.subprocess, "run", return_value=completed) as run:
            result = publisher.GitHub().api(f"{publisher.API}/releases", "POST", {"body": "Text\nwith `literal` $syntax"})
        self.assertEqual(result["id"], 99)
        command = run.call_args.args[0]
        self.assertEqual(command[0], "/opt/homebrew/bin/gh")
        self.assertIn("--hostname", command)
        self.assertIn("--input", command)
        self.assertNotIn("Text", " ".join(command))
        self.assertEqual(json.loads(run.call_args.kwargs["input"])["body"], "Text\nwith `literal` $syntax")

    def test_cli_discovery_uses_path_with_homebrew_fallback(self):
        with patch.object(publisher.shutil, "which", return_value="/usr/bin/gh"):
            self.assertEqual(publisher.github_cli(), "/usr/bin/gh")
        with patch.object(publisher.shutil, "which", return_value=None), patch.object(Path, "is_file", return_value=True), patch.object(publisher.os, "access", return_value=True):
            self.assertEqual(publisher.github_cli(), "/opt/homebrew/bin/gh")
        with patch.object(publisher.shutil, "which", return_value=None), patch.object(Path, "is_file", return_value=False), self.assertRaisesRegex(ValueError, "not installed"):
            publisher.github_cli()

    def test_only_explicit_404_counts_as_missing_and_errors_hide_cli_body(self):
        for status, code in ((404, 1), (403, 1), (500, 1), (None, 1)):
            stdout = (f"HTTP/2.0 {status} Error\n\n".encode() if status else b"") + b'{"message":"private diagnostic"}'
            result = subprocess.CompletedProcess([], code, stdout, b"private diagnostic")
            with patch.object(publisher.subprocess, "run", return_value=result):
                if status == 404:
                    self.assertIsNone(publisher.GitHub().api("endpoint", missing=True))
                else:
                    with self.assertRaises(publisher.GitHubError) as caught:
                        publisher.GitHub().api("endpoint", missing=True)
                    self.assertNotIn("private diagnostic", str(caught.exception))

    def test_draft_discovery_scans_paginated_releases_and_rejects_duplicates(self):
        github = publisher.GitHub()
        with patch.object(github, "api", side_effect=[[{"tag_name": "other"}] * 100, [{"tag_name": "test-2.0.0-102", "draft": True}]]) as api:
            self.assertTrue(github.find_release("test-2.0.0-102")["draft"])
            self.assertIn("page=2", api.call_args.args[0])
        with patch.object(github, "api", return_value=[{"tag_name": "duplicate"}] * 2), self.assertRaisesRegex(ValueError, "Multiple releases"):
            github.find_release("duplicate")

    def test_upload_never_passes_clobber_and_timeout_is_recoverable(self):
        with patch.object(publisher.subprocess, "run", side_effect=subprocess.TimeoutExpired("gh", 1800)) as run, self.assertRaises(publisher.GitHubError):
            publisher.GitHub().upload("test-2.0.0-102", Path("/tmp/artifact.dmg"))
        self.assertNotIn("--clobber", run.call_args.args[0])
        self.assertIn("github.com/" + publisher.REPOSITORY, run.call_args.args[0])


class DownloadTests(unittest.TestCase):
    def test_redirect_allowlist_rejects_credentials_http_and_external_hosts(self):
        for url in ("http://github.com/a", "https://github.com.evil.invalid/a", "https://token@github.com/a", "https://github.com:444/a", "https://example.invalid/a"):
            with self.subTest(url=url), self.assertRaises(ValueError):
                publisher.public_url(url)
        publisher.public_url("https://release-assets.githubusercontent.com/a?temporary=signed-link")

    def test_public_bytes_verified_without_authorization_headers(self):
        data = b"public artifact"
        entry = {"url": f"{publisher.ASSET_BASE}/test-2.0.0-102/Echo.dmg", "bytes": len(data), "sha256": hashlib.sha256(data).hexdigest()}
        def response(request, timeout):
            self.assertIsNone(request.get_header("Authorization"))
            result = io.BytesIO(data)
            result.status = 200
            result.headers = {"Content-Length": str(len(data)), "Content-Encoding": "identity"}
            result.geturl = lambda: "https://release-assets.githubusercontent.com/a?temporary=signed-link"
            return result
        with patch.object(publisher, "build_opener") as opener:
            opener.return_value.open.side_effect = response
            publisher.verify_public(entry)
        entry["sha256"] = "0" * 64
        with patch.object(publisher, "build_opener") as opener, self.assertRaisesRegex(ValueError, "bytes differ"):
            opener.return_value.open.side_effect = response
            publisher.verify_public(entry)


if __name__ == "__main__":
    unittest.main(verbosity=2)
