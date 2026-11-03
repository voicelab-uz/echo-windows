#!/usr/bin/env python3
"""Publish a prepared Echo publication to its public artifacts-only GitHub repo.

No credentials are read by this script: authenticated operations use gh. Assets
are staged in a draft, verified, locked by publication, and downloaded publicly
before the signed feed is updated with a Contents API compare-and-swap.

References: https://docs.github.com/en/rest/releases/releases
https://docs.github.com/en/rest/repos/repos#check-if-immutable-releases-are-enabled-for-a-repository
https://docs.github.com/en/rest/repos/contents#create-or-update-file-contents
"""
import argparse
import base64
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import shutil
import subprocess
import sys
import tempfile
import time
from urllib.error import HTTPError, URLError
from urllib.parse import urlparse
from urllib.request import Request, HTTPRedirectHandler, build_opener
import xml.etree.ElementTree as ET

import update_release as release

REPOSITORY = "voicelab-uz/echo-releases"
API = f"repos/{REPOSITORY}"
FEED_BASE = f"https://raw.githubusercontent.com/{REPOSITORY}/main"
ASSET_BASE = f"https://github.com/{REPOSITORY}/releases/download"
MAX_CONTENTS_BYTES = 1024 * 1024  # Contents API returns base64 only up to 1 MiB.
PUBLIC_HOSTS = {"github.com", "release-assets.githubusercontent.com", "objects.githubusercontent.com", "raw.githubusercontent.com"}
require = release.require


class PublicFeedPending(RuntimeError):
    """The feed commit succeeded; public CDN verification is not complete yet."""


class GitHubError(RuntimeError):
    def __init__(self, operation, status=None):
        self.status = status
        super().__init__(f"GitHub {operation} failed" + (f" (HTTP {status})" if status else "") + ". Re-run the same publication to reconcile remote state.")


def github_cli():
    executable = shutil.which("gh")
    if executable:
        return executable
    for candidate in ("/opt/homebrew/bin/gh", "/usr/local/bin/gh"):
        if Path(candidate).is_file() and os.access(candidate, os.X_OK):
            return candidate
    raise ValueError("GitHub CLI is not installed. Install gh and authenticate before publishing.")


class GitHub:
    """Small credential-free wrapper; never prints gh's stderr or response bodies."""
    def api(self, endpoint, method="GET", payload=None, missing=False):
        command = [github_cli(), "api", "--hostname", "github.com", "--include", "--method", method,
                   "-H", "Accept: application/vnd.github+json", "-H", "X-GitHub-Api-Version: 2026-03-10", endpoint]
        if payload is not None:
            command += ["--input", "-"]
        try:
            result = subprocess.run(command, input=json.dumps(payload).encode() if payload is not None else None,
                                    stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=90, check=False)
        except subprocess.TimeoutExpired:
            raise GitHubError(method) from None
        output = result.stdout.replace(b"\r\n", b"\n")
        match = re.match(rb"HTTP/[^ ]+ ([0-9]{3})[^\n]*\n", output)
        status = int(match[1]) if match else None
        if missing and status == 404:
            return None
        if result.returncode or status is None or not 200 <= status < 300:
            raise GitHubError(method, status)
        _, separator, body = output.partition(b"\n\n")
        require(separator, "Malformed GitHub CLI response headers.")
        return json.loads(body) if body.strip() else None

    def find_release(self, tag):
        # Authenticated list includes drafts; get-by-tag alone can omit them.
        matches = []
        for page in range(1, 101):
            rows = self.api(f"{API}/releases?per_page=100&page={page}")
            require(isinstance(rows, list), "Invalid GitHub release list.")
            matches.extend(row for row in rows if row.get("tag_name") == tag)
            if len(rows) < 100:
                require(len(matches) <= 1, "Multiple releases use this tag; resolve the conflict before publishing.")
                return matches[0] if matches else None
        raise ValueError("Release pagination limit reached; no mutation attempted.")

    def assets(self, identifier):
        values = self.api(f"{API}/releases/{identifier}/assets?per_page=100")
        require(isinstance(values, list) and len(values) < 100, "Unexpected release asset list.")
        return values

    def upload(self, tag, path):
        try:
            result = subprocess.run([github_cli(), "release", "upload", tag, str(path), "--repo", "github.com/" + REPOSITORY],
                                    stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=1800, check=False)
        except subprocess.TimeoutExpired:
            raise GitHubError("asset upload") from None
        if result.returncode:
            raise GitHubError("asset upload")


def local_file(root, entry):
    value = entry.get("path", "")
    path = PurePosixPath(value)
    require(value and not path.is_absolute() and all(part not in (".", "..") for part in value.split("/")), "Unsafe publication path.")
    candidate = root / value
    require(candidate.resolve().is_relative_to(root) and not any(part.is_symlink() for part in [candidate, *candidate.parents] if part != root.parent), "Publication paths cannot contain symlinks.")
    require(candidate.is_file(), "Missing publication file.")
    require(type(entry.get("bytes")) is int and entry["bytes"] >= 0 and candidate.stat().st_size == entry["bytes"], "Local publication size changed.")
    require(re.fullmatch(r"[a-f0-9]{64}", entry.get("sha256", "")) and release.digest(candidate) == entry["sha256"], "Local publication bytes changed.")
    return candidate


def load_publication(directory, promote, verifier):
    root = directory.resolve()
    manifest_path = root / "publication.json"
    require(manifest_path.is_file() and not manifest_path.is_symlink() and manifest_path.stat().st_size <= 65536, "Missing or oversized publication manifest.")
    manifest = json.loads(manifest_path.read_text())
    require(manifest.get("schemaVersion") == 1 and manifest.get("hostMode") == "github" and manifest.get("repository") == REPOSITORY, "Expected a prepared GitHub publication for the public Echo artifacts repo.")
    channel, version, build = (manifest.get(key, "") for key in ("channel", "version", "build"))
    require(channel in ("test", "beta", "stable"), "Invalid update channel.")
    require(re.fullmatch(r"[0-9]+\.[0-9]+(?:\.[0-9]+)?", version) and re.fullmatch(r"[1-9][0-9]{0,17}", build), "Invalid version or build.")
    require(manifest.get("teamID") == os.environ.get("ECHO_TEAM_ID"), "Publication does not match the independently configured ECHO_TEAM_ID.")
    require(type(manifest.get("sourceDirty")) is bool, "Missing source cleanliness provenance.")
    require(channel == "test" or (promote and manifest["sourceDirty"] is False), "Stable/beta publication requires --promote and clean source provenance.")
    require(re.fullmatch(r"[a-f0-9]{40}|[a-f0-9]{64}", manifest.get("sourceCommit", "")) and re.fullmatch(r"[A-Z0-9]{10}", manifest.get("teamID", "")), "Missing release commit/team provenance.")
    key = release.public_key(os.environ.get("ECHO_SPARKLE_PUBLIC_KEY", ""))
    require(manifest.get("publicEDKey") == key, "Publication does not match the independently configured ECHO_SPARKLE_PUBLIC_KEY.")
    tag = f"{channel}-{version}-{build}"
    require(manifest.get("releaseTag") == tag, "Release tag does not match channel/version/build.")
    initial, previous = manifest.get("feedMustNotExist"), manifest.get("previousFeedSHA256")
    require(type(initial) is bool and ((initial and previous is None) or (not initial and isinstance(previous, str) and re.fullmatch(r"[a-f0-9]{64}", previous))), "Publication must specify either an absent initial feed or its previous SHA256.")
    files = manifest.get("files")
    require(isinstance(files, list) and len(files) == 5, "Expected exactly DMG, release notes, checksums, metadata, and feed.")
    suffix = "" if channel == "stable" else "-" + channel
    filename = f"Echo-{version}-{build}-universal{suffix}.dmg"
    expected = {filename, "release-notes.html", "SHA256SUMS.txt", "release.json"}
    assets = {}
    for entry in files[:-1]:
        require(entry.get("immutable") is True, "Only the final feed may be mutable.")
        path = local_file(root, entry)
        require(path.name in expected and path.name not in assets and entry["path"] == f"releases/{tag}/{path.name}" and entry.get("url") == f"{ASSET_BASE}/{tag}/{path.name}", "Unexpected publication asset path or URL.")
        assets[path.name] = entry
    require(set(assets) == expected, "Incomplete publication asset set.")
    feed = files[-1]
    require(feed.get("immutable") is False and feed.get("path") == f"{channel}/appcast.xml" and feed.get("url") == f"{FEED_BASE}/{channel}/appcast.xml" and feed.get("bytes", 0) <= MAX_CONTENTS_BYTES, "Unexpected feed path, URL, or size.")
    feed_path = local_file(root, feed)
    metadata = json.loads((root / assets["release.json"]["path"]).read_text())
    for field in ("channel", "version", "build", "sourceCommit", "sourceDirty", "teamID", "publicEDKey"):
        require(metadata.get(field) == manifest[field], f"Release metadata disagrees with manifest: {field}.")
    require(metadata.get("bundleIdentifier") == "uz.voicelab.desktop" and metadata.get("architectures") == ["arm64", "x86_64"] and metadata.get("filename") == filename and metadata.get("sha256") == assets[filename]["sha256"] and metadata.get("bytes") == assets[filename]["bytes"], "Invalid app identity, architecture, or DMG metadata.")
    checksums = (root / assets["SHA256SUMS.txt"]["path"]).read_text()
    require(checksums == f"{assets[filename]['sha256']}  {filename}\n", "Checksum file does not match the DMG.")
    parsed = release.verify_feed(feed_path, key, verifier)
    require(parsed.findtext("channel/link") == feed["url"], "Signed feed belongs to another channel.")
    items = parsed.findall("channel/item")
    require(items and items[0].findtext(f"{{{release.SPARKLE}}}version") == build, "Signed feed does not start with this build.")
    builds = [item.findtext(f"{{{release.SPARKLE}}}version", "") for item in items]
    require(all(re.fullmatch(r"[1-9][0-9]{0,17}", value) for value in builds) and len(set(builds)) == len(builds) and all(int(value) < int(build) for value in builds[1:]), "Feed contains duplicate or newer builds.")
    enclosure = items[0].find("enclosure")
    notes = items[0].find(f"{{{release.SPARKLE}}}releaseNotesLink")
    require(enclosure is not None and notes is not None, "Signed feed omits artifact or release notes.")
    for node, name, url, length in ((enclosure, filename, enclosure.get("url"), enclosure.get("length")),
                                  (notes, "release-notes.html", notes.text, notes.get(f"{{{release.SPARKLE}}}length"))):
        entry = assets[name]
        require(url == entry["url"] and length == str(entry["bytes"]), "Signed feed artifact bytes or URL disagree with manifest.")
        release.verify_file(root / entry["path"], node.get(f"{{{release.SPARKLE}}}edSignature", ""), key, verifier)
    manifest["_root"], manifest["_assets"], manifest["_feed"] = root, assets, feed
    manifest["_binding"] = release.digest(manifest_path)
    return manifest


def public_url(value):
    parsed = urlparse(value)
    require(parsed.scheme == "https" and parsed.hostname in PUBLIC_HOSTS and parsed.port in (None, 443) and not parsed.username and not parsed.password and not parsed.fragment, "Public download redirected outside approved GitHub HTTPS hosts.")


class SafeRedirect(HTTPRedirectHandler):
    def redirect_request(self, request, fp, code, message, headers, new_url):
        public_url(new_url)
        count = getattr(request, "echo_redirects", 0) + 1
        require(count <= 5, "Too many public download redirects.")
        redirected = super().redirect_request(request, fp, code, message, headers, new_url)
        require(redirected is not None, "Unexpected public download redirect.")
        redirected.echo_redirects = count
        return redirected


def verify_public(entry):
    public_url(entry["url"])
    for attempt in range(3):
        try:
            request = Request(entry["url"], headers={"Accept-Encoding": "identity", "Cache-Control": "no-cache"})
            with build_opener(SafeRedirect()).open(request, timeout=60) as response:
                public_url(response.geturl())
                require(response.status == 200 and response.headers.get("Content-Encoding", "identity").lower() == "identity", "Public download is not untransformed HTTP 200.")
                length = response.headers.get("Content-Length")
                require(length is None or length == str(entry["bytes"]), "Public download size header differs.")
                size, digest = 0, hashlib.sha256()
                while chunk := response.read(1024 * 1024):
                    size += len(chunk)
                    require(size <= entry["bytes"], "Public download exceeds expected size.")
                    digest.update(chunk)
                require(size == entry["bytes"] and digest.hexdigest() == entry["sha256"], "Public download bytes differ from the prepared publication.")
                return
        except (HTTPError, URLError) as error:
            if attempt == 2 or (isinstance(error, HTTPError) and error.code not in (404, 429, 500, 502, 503, 504)):
                raise ValueError("Public GitHub download is not available; retry the same publication. No asset is overwritten.") from None
            time.sleep(2 + attempt * 3)


class Publisher:
    def __init__(self, publication, github, verifier, operation_lock=None):
        self.p, self.github, self.verifier = publication, github, verifier
        self.operation_lock = operation_lock
        self.feed_endpoint = f"{API}/contents/{self.p['channel']}/appcast.xml"
        self.name = f"Echo {self.p['version']} ({self.p['build']}) — {self.p['channel']}"
        self.body = f"Echo for macOS.\n\nPrepared publication SHA256: `{self.p['_binding']}`\n\nSigned feed SHA256: `{self.p['_feed']['sha256']}`\n"

    def check_operation(self):
        if self.operation_lock is not None:
            self.operation_lock.check()

    def check_repository(self):
        repo = self.github.api(API)
        require(repo.get("full_name", "").lower() == REPOSITORY and repo.get("private") is False and repo.get("visibility") == "public" and repo.get("archived") is False and repo.get("default_branch") == "main", "Publisher requires the active public Echo artifacts-only repo with main as default branch.")
        immutable = self.github.api(f"{API}/immutable-releases")
        require(immutable and immutable.get("enabled") is True, "Enable immutable releases before publishing. The publisher will not change repository settings.")

    def feed_state(self):
        value = self.github.api(self.feed_endpoint + "?ref=main", missing=True)
        if value is None:
            require(self.p["feedMustNotExist"], "Previous signed feed is missing; refusing to recreate it.")
            return None, False
        require(value.get("type") == "file" and value.get("encoding") == "base64" and type(value.get("size")) is int and value["size"] <= MAX_CONTENTS_BYTES and re.fullmatch(r"[a-f0-9]{40}|[a-f0-9]{64}", value.get("sha", "")), "Unexpected remote feed content.")
        data = base64.b64decode(re.sub(r"\s", "", value.get("content", "")), validate=True)
        require(len(data) == value["size"], "Remote feed size disagrees with content.")
        sha = hashlib.sha256(data).hexdigest()
        if sha == self.p["_feed"]["sha256"]:
            return value["sha"], True
        require(not self.p["feedMustNotExist"] and sha == self.p["previousFeedSHA256"], "Feed changed since preparation. Prepare against its current signed bytes; no overwrite attempted.")
        with tempfile.NamedTemporaryFile(suffix=".xml") as previous:
            previous.write(data)
            previous.flush()
            parsed = release.verify_feed(previous.name, self.p["publicEDKey"], self.verifier)
        require(parsed.findtext("channel/link") == self.p["_feed"]["url"], "Remote previous feed belongs to another channel.")
        builds = [item.findtext(f"{{{release.SPARKLE}}}version", "") for item in parsed.findall("channel/item")]
        require(all(re.fullmatch(r"[1-9][0-9]{0,17}", build) and int(build) < int(self.p["build"]) for build in builds), "Remote feed already contains this build or a newer build; downgrades are forbidden.")
        return value["sha"], False

    def validate_release(self, value):
        require(isinstance(value.get("id"), int) and value.get("tag_name") == self.p["releaseTag"] and value.get("name") == self.name and value.get("body") == self.body and value.get("prerelease") is (self.p["channel"] != "stable") and type(value.get("draft")) is bool, "Existing release metadata conflicts with this exact prepared publication.")
        if not value["draft"]:
            require(value.get("immutable") is True, "Published release is not immutable; feed will not be promoted.")
        return value

    def ensure_draft(self):
        value = self.github.find_release(self.p["releaseTag"])
        if value is None:
            self.check_operation()
            try:
                value = self.github.api(f"{API}/releases", "POST", {"tag_name": self.p["releaseTag"], "target_commitish": "main", "name": self.name, "body": self.body, "draft": True, "prerelease": self.p["channel"] != "stable", "make_latest": "false", "generate_release_notes": False})
            except GitHubError:
                value = self.github.find_release(self.p["releaseTag"])
                if value is None:
                    raise
        return self.validate_release(value)

    def check_assets(self, identifier, complete=False, draft=False):
        assets = self.github.assets(identifier)
        found = {}
        for asset in assets:
            name = asset.get("name")
            require(name in self.p["_assets"] and name not in found, "Unexpected or duplicate remote release asset; refusing to publish.")
            entry = self.p["_assets"][name]
            download_url = asset.get("browser_download_url", "")
            # GitHub assigns draft assets an untagged-* URL until publication.
            # Only an already validated draft may use this exact repository/name.
            expected_url = download_url == entry["url"] or (draft and re.fullmatch(
                re.escape(ASSET_BASE) + r"/untagged-[0-9a-f]+/" + re.escape(name), download_url) is not None)
            require(asset.get("state") == "uploaded" and asset.get("size") == entry["bytes"] and asset.get("digest") == "sha256:" + entry["sha256"] and expected_url, "Existing asset differs or is incomplete; it will never be overwritten. Resolve the draft or prepare a new build.")
            found[name] = asset
        require(not complete or set(found) == set(self.p["_assets"]), "Published release has missing assets.")
        return found

    def run(self):
        self.check_repository()
        _, already_promoted = self.feed_state()  # Fail stale/concurrent promotion before staging anything.
        value = self.ensure_draft()
        require(not already_promoted or value["draft"] is False, "Feed points at a draft release; manual recovery required.")
        found = self.check_assets(value["id"], complete=not value["draft"], draft=value["draft"])
        if value["draft"]:
            for name, entry in self.p["_assets"].items():
                if name in found:
                    continue
                local_file(self.p["_root"], entry)  # Recheck immediately before uploading.
                self.check_operation()
                try:
                    self.github.upload(self.p["releaseTag"], self.p["_root"] / entry["path"])
                except GitHubError:
                    found = self.check_assets(value["id"], draft=True)
                    if name not in found:
                        raise
                found = self.check_assets(value["id"], draft=True)
                require(name in found, "Upload response succeeded but asset is missing; retry to reconcile.")
            self.check_assets(value["id"], complete=True, draft=True)
            self.feed_state()
            self.check_repository()  # Immutability may have changed while uploading.
            value = self.validate_release(self.github.api(f"{API}/releases/{value['id']}"))
            if value["draft"]:
                self.check_operation()
                try:
                    value = self.github.api(f"{API}/releases/{value['id']}", "PATCH", {"draft": False, "make_latest": "false"})
                except GitHubError:
                    value = self.github.api(f"{API}/releases/{value['id']}")
                    if value.get("draft") is not False:
                        raise
            self.validate_release(value)
            require(value["draft"] is False, "Release remained a draft; feed will not change.")
        self.check_assets(value["id"], complete=True)
        for entry in self.p["_assets"].values():
            verify_public(entry)
        sha, promoted = self.feed_state()  # Fresh CAS after all public downloads finish.
        if not promoted:
            local_file(self.p["_root"], self.p["_feed"])
            feed_bytes = (self.p["_root"] / self.p["_feed"]["path"]).read_bytes()
            require(len(feed_bytes) == self.p["_feed"]["bytes"] and hashlib.sha256(feed_bytes).hexdigest() == self.p["_feed"]["sha256"], "Local signed feed changed before promotion.")
            payload = {"message": f"Publish Echo {self.p['releaseTag']}", "branch": "main", "content": base64.b64encode(feed_bytes).decode()}
            if sha is not None:
                payload["sha"] = sha
            self.check_operation()
            try:
                self.github.api(self.feed_endpoint, "PUT", payload)
            except GitHubError:
                _, promoted = self.feed_state()
                if not promoted:
                    raise
            _, promoted = self.feed_state()
            require(promoted, "Feed update was not confirmed. Retry this exact publication.")
        # A raw CDN cache may lag Contents API. Retry later is safe and never re-publishes.
        try:
            verify_public(self.p["_feed"])
        except (ValueError, OSError) as error:
            raise PublicFeedPending(
                f"Release {self.p['releaseTag']} is immutable and the signed feed commit is confirmed. "
                "Public feed verification is still pending (GitHub's raw CDN may cache the previous feed or a 404 for several minutes). "
                "Do not treat rollout as verified yet. Re-run the same publisher command after the cache refreshes; it will verify existing state without republishing. "
                f"Verification detail: {error}") from None
        print(f"Published and verified {self.p['releaseTag']}: {self.p['_feed']['url']}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("publication", type=Path)
    parser.add_argument("--promote", action="store_true", help="Explicitly allow clean stable/beta publication; never converts a test artifact into production")
    parser.add_argument("--retention-policy", type=Path,
                        default=Path(__file__).with_name("release-retention-policy.json"),
                        help="Cleanup policy used after every verified publication; dependencies failing verification defer cleanup")
    parser.add_argument("--skip-retention", action="store_true", help="Explicitly defer cleanup for this publication; never weakens feed or artifact verification")
    args = parser.parse_args()
    # One short-lived repository ref serializes supported publishers and cleanup.
    # Feed CAS still detects older tools/manual changes. A crashed holder is never
    # stolen by age; release_retention unlock provides explicit reconciliation.
    import release_retention as retention
    with tempfile.TemporaryDirectory(prefix="echo-github-public-verifier-") as temporary:
        verifier = release.verifier(temporary)
        publication = load_publication(args.publication, args.promote, verifier)
        github = GitHub()
        with retention.OperationLock(github, "publication") as lock:
            Publisher(publication, github, verifier, operation_lock=lock).run()
            if not args.skip_retention:
                retention.after_publication(github, args.retention_policy, verifier, lock,
                                            args.publication / "retention-plan.json")


if __name__ == "__main__":
    # Retention imports the GitHub wrapper from this module. Executing this file
    # as a CLI must not create a second copy with different exception classes.
    sys.modules["publish_github"] = sys.modules[__name__]
    try:
        main()
    except PublicFeedPending as error:
        print(f"GitHub publication pending public verification: {error}", file=sys.stderr)
        sys.exit(2)
    except (ValueError, OSError, KeyError, TypeError, GitHubError, ET.ParseError, subprocess.CalledProcessError) as error:
        print(f"GitHub publication error: {error}", file=sys.stderr)
        sys.exit(1)
