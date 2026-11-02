#!/usr/bin/env python3
"""Plan and reconcile bounded cleanup of immutable Echo GitHub releases.

Only whole, proven-managed releases are removable. Signed feeds, website download
targets and the newest channel builds always win over the storage target.
No credential is read: authenticated operations use the existing gh wrapper.
"""
import argparse
import base64
import hashlib
import json
import os
from pathlib import Path
import re
import sys
import tempfile
import time
from urllib.error import HTTPError
from urllib.request import Request, build_opener
import uuid

import publish_github as pub
import update_release as release

API = pub.API
REPOSITORY = pub.REPOSITORY
LOCK = "heads/echo-release-operation"
TAG = re.compile(r"(stable|test|beta)-([0-9]+\.[0-9]+(?:\.[0-9]+)?)-([1-9][0-9]{0,17})")
HEX = re.compile(r"[a-f0-9]{64}")
DEFAULT_KEEP = {"stable": 3, "test": 1, "beta": 1}
PROTECTION_URLS = {
    "https://echo.voicelab.uz/.well-known/echo-release-protection.json",
    "https://voicelab.uz/.well-known/echo-release-protection.json",
}
MAX_PAGES = 20
MAX_DELETE = 20
MAX_PLAN = 16 * 1024 * 1024
require = release.require


def canonical(value):
    return json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode()


def sha(data):
    return hashlib.sha256(data).hexdigest()


class OperationLock:
    """Atomic cross-machine exclusion shared by every supported publisher/pruner.

    No timeout stealing: an interrupted holder requires operator reconciliation.
    An API timeout is reconciled by its unique commit, never another holder's ref.
    """
    def __init__(self, github, operation):
        self.github, self.operation, self.commit = github, operation, None

    def __enter__(self):
        require(self.github.api(f"{API}/git/ref/{LOCK}", missing=True) is None,
                "Another release operation holds the GitHub lock; reconcile it before retrying.")
        head = self.github.api(f"{API}/git/ref/heads/main")["object"]["sha"]
        tree = self.github.api(f"{API}/git/commits/{head}")["tree"]["sha"]
        commit = self.github.api(f"{API}/git/commits", "POST", {
            "message": f"Echo {self.operation} operation {uuid.uuid4()}", "tree": tree, "parents": [head]})
        self.commit = commit["sha"]
        try:
            self.github.api(f"{API}/git/refs", "POST", {"ref": "refs/" + LOCK, "sha": self.commit})
        except pub.GitHubError:
            value = self.github.api(f"{API}/git/ref/{LOCK}", missing=True)
            require(value is not None and value["object"]["sha"] == self.commit,
                    "Another release operation won the lock, or lock acquisition is unconfirmed.")
        self.check()
        return self

    def check(self):
        value = self.github.api(f"{API}/git/ref/{LOCK}", missing=True)
        require(value is not None and value["object"]["sha"] == self.commit,
                "Release operation lock changed; no further mutation is safe.")

    def __exit__(self, kind, value, traceback):
        try:
            self.check()
            try:
                self.github.api(f"{API}/git/refs/{LOCK}", "DELETE")
            except pub.GitHubError:
                require(self.github.api(f"{API}/git/ref/{LOCK}", missing=True) is None,
                        "Operation lock removal is unconfirmed.")
        except (ValueError, pub.GitHubError, KeyError, TypeError):
            # A verified publication/deletion remains successful. Fail closed on
            # the next operation instead of misleadingly asking to republish it.
            print("Release operation finished, but its lock needs manual reconciliation before the next operation.", file=sys.stderr)


def policy(path):
    require(path.is_file() and not path.is_symlink() and path.stat().st_size <= 16384, "Invalid retention policy file.")
    return validate_policy(json.loads(path.read_text()))


def validate_policy(value):
    require(set(value) == {"schema_version", "repository", "keep", "protection_urls", "minimum_age_hours"}, "Unexpected retention policy fields.")
    require(value["schema_version"] == 1 and value["repository"] == REPOSITORY, "Retention policy repository differs.")
    require(set(value["keep"]) == set(DEFAULT_KEEP) and all(type(n) is int and DEFAULT_KEEP[c] <= n <= 100 for c, n in value["keep"].items()), "Retention cannot keep fewer than 3 stable/1 test/1 beta builds.")
    require(type(value["minimum_age_hours"]) is int and 24 <= value["minimum_age_hours"] <= 8760, "Cleanup requires at least a 24-hour grace period.")
    urls = value["protection_urls"]
    require(isinstance(urls, list) and len(urls) == 2 and len(set(urls)) == 2, "Both website protection endpoints are required.")
    require(set(urls) == PROTECTION_URLS, "Retention requires both reviewed production website origins.")
    for url in urls:
        parsed = pub.urlparse(url)
        require(parsed.scheme == "https" and parsed.hostname and parsed.port is None and not parsed.username and not parsed.password and not parsed.query and not parsed.fragment and parsed.path == "/.well-known/echo-release-protection.json", "Invalid website protection URL.")
    return value


def unlock(github, expected):
    require(re.fullmatch(r"[a-f0-9]{40}|[a-f0-9]{64}", expected), "Expected exact operation commit SHA.")
    value = github.api(f"{API}/git/ref/{LOCK}", missing=True)
    require(value is not None and value["object"]["sha"] == expected, "Operation lock no longer matches the reviewed commit.")
    github.api(f"{API}/git/refs/{LOCK}", "DELETE")
    require(github.api(f"{API}/git/ref/{LOCK}", missing=True) is None, "Lock removal is unconfirmed; inspect before retrying.")


def public_bytes(url, limit, missing=False, website=False):
    if not website:
        pub.public_url(url)
    opener = build_opener(release.NoRedirect() if website else pub.SafeRedirect())
    request = Request(url, headers={"Accept-Encoding": "identity", "Cache-Control": "no-cache"})
    try:
        with opener.open(request, timeout=30) as response:
            require(response.status == 200 and response.headers.get("Content-Encoding", "identity").lower() == "identity", "Public response is transformed or unavailable.")
            if website:
                require(response.geturl() == url and "no-store" in response.headers.get("Cache-Control", "").lower(), "Website protection must be direct and no-store.")
            data = response.read(limit + 1)
            require(len(data) <= limit, "Public metadata exceeds its bound.")
            return data
    except HTTPError as error:
        if error.code == 404 and missing:
            return None
        raise ValueError("Public metadata is unavailable; cleanup is deferred.") from None


def contents(github, path):
    value = github.api(f"{API}/contents/{path}?ref=main", missing=True)
    if value is None:
        return None
    require(value.get("type") == "file" and value.get("encoding") == "base64" and type(value.get("size")) is int and value["size"] <= pub.MAX_CONTENTS_BYTES, "Unexpected repository metadata.")
    data = base64.b64decode(re.sub(r"\s", "", value.get("content", "")), validate=True)
    require(len(data) == value["size"], "Repository metadata length differs.")
    return data


def tag_from_url(url):
    prefix = pub.ASSET_BASE + "/"
    require(isinstance(url, str) and url.startswith(prefix), "Signed feed references an unmanaged artifact host/path.")
    path = url[len(prefix):].split("/")
    require(len(path) == 2 and TAG.fullmatch(path[0]) and path[1] and not any(c in url for c in ("?", "#", "%", "\\")), "Signed feed artifact path is unsupported; retain it manually.")
    return path[0]


def protection(github, settings, key, verifier, fetch=public_bytes):
    feeds, websites, protected = {}, {}, set()
    for channel in DEFAULT_KEEP:
        path = f"{channel}/appcast.xml"
        data = contents(github, path)
        public = fetch(f"{pub.FEED_BASE}/{path}", pub.MAX_CONTENTS_BYTES, missing=True)
        require(data == public, "Signed feed and public CDN disagree; cleanup is deferred.")
        feeds[channel] = sha(data) if data is not None else None
        if data is None:
            continue
        with tempfile.NamedTemporaryFile() as file:
            file.write(data); file.flush()
            parsed = release.verify_feed(file.name, key, verifier)
        require(parsed.findtext("channel/link") == f"{pub.FEED_BASE}/{path}", "Signed feed belongs to another channel.")
        require(parsed.findall("channel/item"), "An active signed feed cannot be empty.")
        # Walk every enclosure, including delta enclosures and all notes links.
        for node in parsed.iter():
            if node.tag == "enclosure":
                protected.add(tag_from_url(node.get("url")))
            if node.tag == f"{{{release.SPARKLE}}}releaseNotesLink":
                protected.add(tag_from_url(node.text))
    require(feeds["stable"] is not None, "A verified stable feed is required before automated retention.")
    for url in settings["protection_urls"]:
        data = fetch(url, 16384, website=True)
        value = json.loads(data)
        require(set(value) == {"schema_version", "repository", "protected_tags"} and value["schema_version"] == 1 and value["repository"] == REPOSITORY, "Website protection schema differs.")
        tags = value["protected_tags"]
        require(isinstance(tags, list) and 0 < len(tags) <= 20 and all(isinstance(t, str) and TAG.fullmatch(t) and t.startswith("stable-") for t in tags), "Website protection must include valid stable tags.")
        protected.update(tags)
        websites[url] = sha(canonical(value))
    return {"feeds": feeds, "websites": websites, "protected_tags": sorted(protected)}


def repository(github):
    info = github.api(API)
    require(info.get("full_name") == REPOSITORY and info.get("private") is False and info.get("archived") is False and info.get("default_branch") == "main", "Retention requires the public artifacts-only repository.")
    require(github.api(f"{API}/immutable-releases").get("enabled") is True, "Repository immutability must remain enabled.")


def listing(github):
    result, identifiers, tags = [], set(), set()
    for page in range(1, MAX_PAGES + 1):
        rows = github.api(f"{API}/releases?per_page=100&page={page}")
        require(isinstance(rows, list) and len(rows) <= 100, "Invalid release list.")
        for row in rows:
            require(type(row.get("id")) is int and row["id"] > 0 and row["id"] not in identifiers and row.get("tag_name") not in tags, "Release list changed or has duplicate IDs/tags.")
            identifiers.add(row["id"]); tags.add(row.get("tag_name")); result.append(row)
        if len(rows) < 100:
            return result
    raise ValueError("Retention pagination bound reached; no deletion is safe.")


def managed(github, row, key, fetch=public_bytes):
    tag = row.get("tag_name", "")
    match = TAG.fullmatch(tag)
    require(match and row.get("draft") is False and row.get("immutable") is True, "Unmanaged/draft/mutable release is preserved.")
    channel, version, build = match.groups()
    require(row.get("prerelease") is (channel != "stable") and row.get("name") == f"Echo {version} ({build}) — {channel}", "Unmanaged release naming is preserved.")
    body = re.fullmatch(r"Echo for macOS\.\n\nPrepared publication SHA256: `([a-f0-9]{64})`\n\nSigned feed SHA256: `([a-f0-9]{64})`\n", row.get("body", ""))
    require(body, "Unmanaged release provenance is preserved.")
    filename = f"Echo-{version}-{build}-universal" + ("" if channel == "stable" else "-" + channel) + ".dmg"
    expected = {filename, "release.json", "release-notes.html", "SHA256SUMS.txt"}
    assets, small = [], {}
    for asset in github.assets(row["id"]):
        name = asset.get("name")
        require(name in expected and name not in {a["name"] for a in assets} and type(asset.get("id")) is int and asset["id"] > 0 and asset.get("state") == "uploaded" and type(asset.get("size")) is int and 0 < asset["size"] <= 2**32, "Unknown or incomplete assets are preserved.")
        require(re.fullmatch(r"sha256:[a-f0-9]{64}", asset.get("digest", "")) and asset.get("browser_download_url") == f"{pub.ASSET_BASE}/{tag}/{name}", "Unverified asset identity is preserved.")
        entry = {"id":asset["id"],"name":name,"bytes":asset["size"],"sha256":asset["digest"][7:],"url":asset["browser_download_url"]}
        assets.append(entry)
        if name != filename:
            require(entry["bytes"] <= 262144, "Audit metadata exceeds its bound.")
            data = fetch(entry["url"], 262144)
            require(len(data) == entry["bytes"] and sha(data) == entry["sha256"], "Public audit metadata differs from immutable assets.")
            small[name] = data.decode("utf-8")
    require({a["name"] for a in assets} == expected, "Incomplete release is preserved.")
    meta = json.loads(small["release.json"])
    dmg = next(a for a in assets if a["name"] == filename)
    require(all(meta.get(k) == v for k,v in {"channel":channel,"version":version,"build":build,"filename":filename,"bundleIdentifier":"uz.voicelab.desktop","publicEDKey":key,"teamID":os.environ.get("ECHO_TEAM_ID"),"architectures":["arm64","x86_64"],"bytes":dmg["bytes"],"sha256":dmg["sha256"]}.items()), "Release metadata does not prove ownership.")
    require(re.fullmatch(r"[a-f0-9]{40}|[a-f0-9]{64}", meta.get("sourceCommit", "")) and type(meta.get("sourceDirty")) is bool and (channel == "test" or not meta["sourceDirty"]), "Release provenance is incomplete.")
    require(small["SHA256SUMS.txt"] == f"{dmg['sha256']}  {filename}\n", "Release checksum metadata disagrees.")
    return {"id":row["id"],"tag":tag,"channel":channel,"version":version,"build":int(build),"published_at":row.get("published_at"),"publication_sha256":body[1],"feed_sha256":body[2],"assets":sorted(assets,key=lambda a:a["name"]),"audit_metadata":small}


def make_plan(github, settings, key, verifier, fetch=public_bytes, now=None):
    from datetime import datetime
    validate_policy(settings)
    require(re.fullmatch(r"[A-Z0-9]{10}", os.environ.get("ECHO_TEAM_ID", "")), "Set the independently reviewed ECHO_TEAM_ID.")
    now = int(time.time()) if now is None else now
    repository(github)
    before = protection(github, settings, key, verifier, fetch)
    rows = listing(github)
    # Unknown releases never consume a retained slot or become deletable.
    known, preserved = [], []
    for row in rows:
        try:
            known.append(managed(github, row, key, fetch))
        except (ValueError, TypeError, KeyError):
            preserved.append({"id":row["id"],"tag":row.get("tag_name"),"reason":"unmanaged or incomplete"})
    keep = set(before["protected_tags"])
    for channel, count in settings["keep"].items():
        ranked = sorted((r for r in known if r["channel"] == channel), key=lambda r:r["build"], reverse=True)
        keep.update(r["tag"] for r in ranked[:count])
    candidates = []
    for entry in known:
        if entry["tag"] in keep:
            continue
        try:
            date = datetime.fromisoformat(entry.get("published_at", "").replace("Z", "+00:00"))
            require(date.tzinfo is not None and now - date.timestamp() >= settings["minimum_age_hours"] * 3600, "Release is still within its grace period.")
            candidates.append(entry)
        except (ValueError, TypeError, KeyError):
            preserved.append({"id":entry["id"],"tag":entry["tag"],"reason":"within grace period or unknown publication time"})
    require(protection(github, settings, key, verifier, fetch) == before, "Protection changed while planning; retry without deleting anything.")
    # Bound each run; future runs can remove the next batch after reconciliation.
    candidates.sort(key=lambda r:(r["build"],r["id"]))
    return {"schema_version":1,"repository":REPOSITORY,"created_at":now,"policy":settings,"public_key":key,
        "protection":before,"kept_tags":sorted(keep),"preserved":preserved,"delete":candidates[:MAX_DELETE]}


def archive_plan(github, plan, digest):
    path = f"retention/audits/{digest}.json"
    data = canonical(plan) + b"\n"
    require(len(data) <= pub.MAX_CONTENTS_BYTES, "Audit exceeds Contents API bound; reduce the deletion batch.")
    existing = contents(github, path)
    if existing is None:
        try:
            github.api(f"{API}/contents/{path}", "PUT", {"message":f"Record release retention plan {digest}","branch":"main","content":base64.b64encode(data).decode()})
        except pub.GitHubError:
            require(contents(github, path) == data, "Audit commit is unconfirmed; no release may be deleted.")
    require(contents(github, path) == data, "Audit evidence differs; no release may be deleted.")


def apply_plan(github, plan, expected_hash, verifier, fetch=public_bytes, lock=None):
    require(sha(canonical(plan)) == expected_hash, "Plan hash does not match explicit approval.")
    require(plan.get("schema_version") == 1 and plan.get("repository") == REPOSITORY and 0 <= int(time.time()) - plan["created_at"] <= 86400, "Plan is invalid or older than 24 hours; create a fresh plan.")
    key = release.public_key(os.environ.get("ECHO_SPARKLE_PUBLIC_KEY", ""))
    require(plan.get("public_key") == key and isinstance(plan.get("delete"),list) and len(plan["delete"]) <= MAX_DELETE, "Plan key/bounds differ.")
    validate_policy(plan["policy"])
    require(all(type(e.get("id")) is int and e["id"] > 0 and TAG.fullmatch(e.get("tag", "")) for e in plan["delete"]) and len({e["id"] for e in plan["delete"]}) == len(plan["delete"]) and len({e["tag"] for e in plan["delete"]}) == len(plan["delete"]), "Plan contains duplicate or unsafe release identities.")
    require(lock is not None, "Applying retention requires the shared release-operation lock.")
    lock.check()
    current = make_plan(github, plan["policy"], key, verifier, fetch)
    require(current["protection"] == plan["protection"], "Feed or website protection changed; replan.")
    by_id = {r["id"]:r for r in current["delete"]}
    for entry in plan["delete"]:
        remote = github.api(f"{API}/releases/{entry['id']}", missing=True)
        require(remote is None or by_id.get(entry["id"]) == entry, "A planned release is no longer eligible or its exact identity changed.")
    archive_plan(github, plan, expected_hash)
    removed = []
    for entry in plan["delete"]:
        lock.check()
        repository(github)
        require(protection(github, plan["policy"], key, verifier, fetch) == plan["protection"], "Protection changed during cleanup; remaining releases preserved.")
        remote = github.api(f"{API}/releases/{entry['id']}", missing=True)
        if remote is None:
            # Never delete a replacement tag ID; immutable tag reuse is forbidden.
            require(github.api(f"{API}/releases/tags/{entry['tag']}", missing=True) is None, "Deleted release tag now resolves to another release.")
            removed.append(entry["id"])
            continue
        require(managed(github, remote, key, fetch) == entry, "Release/asset identity changed; deletion refused.")
        lock.check()
        try:
            github.api(f"{API}/releases/{entry['id']}", "DELETE")
        except pub.GitHubError:
            require(github.api(f"{API}/releases/{entry['id']}", missing=True) is None, "Deletion outcome unconfirmed; resume this exact plan.")
        require(github.api(f"{API}/releases/{entry['id']}", missing=True) is None, "Release deletion was not confirmed; resume this exact plan.")
        removed.append(entry["id"])
    return removed


def after_publication(github, policy_path, verifier, lock, output):
    """Optional retention never turns a verified publication into a failure."""
    try:
        settings = policy(policy_path)
        key = release.public_key(os.environ.get("ECHO_SPARKLE_PUBLIC_KEY", ""))
        plan = make_plan(github, settings, key, verifier)
        data = canonical(plan)
        output.write_bytes(data + b"\n")
        identifier = sha(data)
        removed = apply_plan(github, plan, identifier, verifier, lock=lock) if plan["delete"] else []
        print(f"Retention reconciled {len(removed)} old releases; audit plan {identifier}.")
    except Exception as error:
        print(f"Publication succeeded; retention deferred: {error}", file=sys.stderr)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    command = commands.add_parser("plan")
    command.add_argument("--policy", type=Path, required=True)
    command.add_argument("--output", type=Path, required=True)
    command = commands.add_parser("apply")
    command.add_argument("plan", type=Path)
    command.add_argument("--confirm-sha256", required=True)
    command = commands.add_parser("unlock", help="Operator-only recovery after confirming no publisher or cleanup is still running")
    command.add_argument("--expected-commit", required=True)
    command.add_argument("--confirm-no-active-operation", action="store_true", required=True)
    args = parser.parse_args()
    github = pub.GitHub()
    if args.command == "unlock":
        unlock(github, args.expected_commit)
        print("Reviewed abandoned operation lock removed. Reconcile the original operation before creating a new release.")
        return
    with tempfile.TemporaryDirectory(prefix="echo-retention-verifier-") as temporary:
        verifier = release.verifier(temporary)
        if args.command == "plan":
            require(not args.output.exists(), "Plan output already exists; choose a new path.")
            plan = make_plan(github, policy(args.policy), release.public_key(os.environ.get("ECHO_SPARKLE_PUBLIC_KEY", "")), verifier)
            args.output.write_bytes(canonical(plan) + b"\n")
            print(f"Plan SHA256: {sha(canonical(plan))}; whole releases proposed: {len(plan['delete'])}. No deletion performed.")
        else:
            require(args.plan.is_file() and not args.plan.is_symlink() and args.plan.stat().st_size <= MAX_PLAN, "Invalid retention plan file.")
            plan = json.loads(args.plan.read_text())
            with OperationLock(github, "retention") as lock:
                removed = apply_plan(github, plan, args.confirm_sha256, verifier, lock=lock)
            print(f"Reconciled {len(removed)} whole releases. Lightweight audit evidence remains in Git.")


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError, KeyError, TypeError, pub.GitHubError) as error:
        print(f"Retention stopped safely: {error}", file=sys.stderr)
        sys.exit(1)
