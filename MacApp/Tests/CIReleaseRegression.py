"""Release orchestration regressions. No signing keys or remote mutations."""
import base64
import copy
import io
import json
import os
from pathlib import Path
import sys
import tarfile
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts"))
import ci_release as ci
import publish_github as publish
import update_release as update

SHA = "a" * 40


class LedgerGitHub:
    def __init__(self):
        self.ledger = None
        self.generation = 0
        self.unknown_write = False
        self.conflict = False
        self.writes = 0

    def api(self, endpoint, method="GET", payload=None, missing=False):
        if "/git/ref/" in endpoint:
            return {"ref": "exists"}
        if method == "GET":
            if self.ledger is None:
                return None
            return {"sha": str(self.generation), "content": base64.b64encode(json.dumps(self.ledger).encode()).decode()}
        if self.conflict:
            self.conflict = False
            self.ledger = {"schemaVersion": 1, "highestBuild": 130, "reservations": {}}
            self.generation += 1
            raise publish.GitHubError("PUT", 409)
        if self.ledger and payload.get("sha") != str(self.generation):
            raise publish.GitHubError("PUT", 409)
        self.ledger = json.loads(base64.b64decode(payload["content"]))
        self.generation += 1
        self.writes += 1
        if self.unknown_write:
            self.unknown_write = False
            raise publish.GitHubError("PUT")
        return {}


class CIReleaseTests(unittest.TestCase):
    def setUp(self):
        environment = patch.dict(os.environ, {"GITHUB_RUN_ATTEMPT": "1"})
        environment.start()
        self.addCleanup(environment.stop)

    def desired(self, identifier="123"):
        return ci.request("1.0.1", "stable", "Fix dictation recovery.", SHA, identifier)

    def test_app_publisher_scope_without_user_permissions_field(self):
        class GitHub:
            def api(self, endpoint):
                self.endpoint = endpoint
                return {"total_count": 1, "repositories": [{"full_name": publish.REPOSITORY}]}
        github = GitHub()
        ci.verify_publisher(github)
        self.assertEqual(github.endpoint, "installation/repositories?per_page=100")

    def test_publisher_rejects_missing_or_broader_repository_scope(self):
        class GitHub:
            def api(self, endpoint): return self.value
        github = GitHub()
        for value in (None, {}, {"total_count": 0, "repositories": []},
                      {"total_count": 1, "repositories": [{"full_name": ci.SOURCE_REPO}]},
                      {"total_count": 2, "repositories": [{"full_name": publish.REPOSITORY}, {"full_name": ci.SOURCE_REPO}]}):
            github.value = value
            with self.subTest(value=value), self.assertRaises(ValueError): ci.verify_publisher(github)

    def test_reservation_stays_monotonic_after_retention(self):
        github = LedgerGitHub()
        first = ci.reserve(github, self.desired(), 119)
        second = ci.reserve(github, self.desired("124"), 115)
        self.assertEqual((first["build"], second["build"]), ("120", "121"))

    def test_retry_reuses_exact_reservation(self):
        github = LedgerGitHub()
        first = ci.reserve(github, self.desired(), 115)
        self.assertEqual(ci.reserve(github, self.desired(), 140), first)
        self.assertEqual(github.writes, 1)

    def test_changed_notes_or_commit_cannot_reuse_number(self):
        github = LedgerGitHub()
        ci.reserve(github, self.desired(), 115)
        for key, value in (("sourceCommit", "b" * 40), ("notesSHA256", "b" * 64), ("channel", "test")):
            with self.subTest(key=key), self.assertRaises(ValueError):
                ci.reserve(github, {**self.desired(), key: value}, 115)

    def test_unknown_write_result_reconciles_without_double_increment(self):
        github = LedgerGitHub()
        github.unknown_write = True
        self.assertEqual(ci.reserve(github, self.desired(), 115)["build"], "116")
        self.assertEqual(github.writes, 1)

    def test_concurrent_reservation_retries_cas(self):
        github = LedgerGitHub()
        github.conflict = True
        self.assertEqual(ci.reserve(github, self.desired(), 115)["build"], "131")

    def test_invalid_ledger_never_resets_counter(self):
        github = LedgerGitHub()
        github.ledger = {"highestBuild": "corrupt"}
        with self.assertRaises(ValueError):
            ci.reserve(github, self.desired(), 115)
        self.assertEqual(github.writes, 0)

    def test_expired_retry_cannot_reserve_a_different_build(self):
        github = LedgerGitHub()
        with patch.dict(os.environ, {"GITHUB_RUN_ATTEMPT": "2"}), self.assertRaises(ValueError):
            ci.reserve(github, self.desired(), 115)
        self.assertEqual(github.writes, 0)

    def test_invalid_inputs(self):
        for version in ("1.0.1; touch bad", "01.0.1", "../1.0.1", "1.0.1\nother"):
            with self.subTest(version=version), self.assertRaises(ValueError):
                ci.request(version, "stable", "Notes", SHA, "123")
        with self.assertRaises(ValueError):
            ci.request("1.0.1", "stable", " " * 5, SHA, "123")

    def test_publish_rejects_failed_fork_pr_or_other_workflow(self):
        valid = {"repository": {"full_name": ci.SOURCE_REPO}, "head_repository": {"full_name": ci.SOURCE_REPO},
                 "event": "workflow_dispatch", "head_branch": "main", "path": ci.PREPARE_WORKFLOW,
                 "status": "completed", "conclusion": "success", "head_sha": SHA}
        class GitHub:
            value = valid
            def api(self, *args): return self.value
        github = GitHub()
        self.assertEqual(ci.preparation_run(github, "123"), valid)
        for key, value in (("event", "pull_request"), ("head_branch", "feature"), ("path", ".github/workflows/ci.yml"),
                           ("conclusion", "failure"), ("head_repository", {"full_name": "attacker/fork"})):
            github.value = {**valid, key: value}
            with self.subTest(key=key), self.assertRaises(ValueError):
                ci.preparation_run(github, "123")

    def test_release_context_rejects_non_main(self):
        with patch.dict(os.environ, {"GITHUB_REPOSITORY": ci.SOURCE_REPO, "GITHUB_REF": "refs/heads/other", "GITHUB_EVENT_NAME": "workflow_dispatch"}):
            with self.assertRaises(ValueError): ci.trusted_context()

    def test_recovery_refuses_traversal_and_external_links(self):
        with tempfile.TemporaryDirectory() as temporary:
            archive = Path(temporary) / "recovery.tar.gz"
            for name, link in (("../../outside", None), ("/etc/passwd", None), ("build/ci/link", "/etc"), ("build/ci/link", "../../..")):
                with tarfile.open(archive, "w:gz") as stream:
                    member = tarfile.TarInfo(name)
                    if link:
                        member.type = tarfile.SYMTYPE
                        member.linkname = link
                    stream.addfile(member, io.BytesIO())
                with self.subTest(name=name, link=link), patch.object(ci, "run") as runner, self.assertRaises(ValueError):
                    ci.restore(archive)
                runner.assert_not_called()

    def test_ci_key_is_passed_by_file_not_secret_argument(self):
        with tempfile.TemporaryDirectory() as temporary:
            key = Path(temporary) / "private.key"
            key.write_text("test-only-secret")
            key.chmod(0o600)
            with patch.dict(os.environ, {"ECHO_SPARKLE_PRIVATE_KEY_FILE": str(key)}), patch.object(update.subprocess, "run") as runner:
                runner.return_value.stdout = "signature\n"
                self.assertEqual(update.sign("archive.dmg", Path("sign_update")), "signature")
                args = runner.call_args.args[0]
                self.assertIn("--ed-key-file", args)
                self.assertNotIn("test-only-secret", args)
                key.chmod(0o644)
                with self.assertRaises(ValueError): update.sign("archive.dmg", Path("sign_update"))

    def test_recovery_rejects_chained_links_and_path_replacement(self):
        cases = (
            [("build/releases/a", "../ci"), ("build/releases/a/out", "../..")],
            [("build/ci/link", "target"), ("build/ci/link", None)],
            [("build/ci/a", "b"), ("build/ci/b", "a")],
            [("build/releases/F/a", "../../ci"), ("build/releases/F/b", "a/../../outside")],
        )
        with tempfile.TemporaryDirectory() as temporary:
            archive = Path(temporary) / "recovery.tar.gz"
            for entries in cases:
                with tarfile.open(archive, "w:gz") as stream:
                    for name, link in entries:
                        member = tarfile.TarInfo(name)
                        if link:
                            member.type = tarfile.SYMTYPE
                            member.linkname = link
                        stream.addfile(member, io.BytesIO())
                with self.subTest(entries=entries), patch.object(ci, "ROOT", Path(temporary) / "checkout"), patch.object(ci, "run") as runner:
                    with self.assertRaises(ValueError): ci.restore(archive)
                    runner.assert_not_called()

    def test_recovery_preserves_framework_links_and_refuses_existing_output(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary) / "checkout"
            root.mkdir()
            archive = Path(temporary) / "recovery.tar.gz"
            framework = "build/releases/example/App.framework"
            with tarfile.open(archive, "w:gz") as stream:
                for name, link in ((framework + "/Versions/A/Binary", None),
                                   (framework + "/Versions/Current", "A"),
                                   (framework + "/Binary", "Versions/Current/Binary")):
                    member = tarfile.TarInfo(name)
                    if link:
                        member.type = tarfile.SYMTYPE
                        member.linkname = link
                    stream.addfile(member, io.BytesIO())
            with patch.object(ci, "ROOT", root):
                ci.restore(archive)
                self.assertTrue((root / framework / "Binary").resolve().is_file())
                with self.assertRaises(ValueError): ci.restore(archive)


if __name__ == "__main__":
    unittest.main()
