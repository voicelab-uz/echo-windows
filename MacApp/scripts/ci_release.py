#!/usr/bin/env python3
"""GitHub Actions orchestration. Apple/Sparkle/publication checks stay in existing tools.

Only a workflow_dispatch on main may reserve a build or produce a candidate.
Build reservations live in the private source repo; deleting release artifacts
never resets the sequence. A publish run accepts only a successful preparation
from this repository and verifies the downloaded candidate before publication.
"""
import argparse
import base64
import hashlib
import html
import json
import os
from pathlib import Path, PurePosixPath
import posixpath
import re
import subprocess
import sys
import tarfile
import tempfile
import time
from urllib.request import Request, urlopen

import publish_github as publish
import update_release as release

ROOT = Path(__file__).resolve().parents[1]
STATE = ROOT / "build/ci"
SOURCE_REPO = "voicelab-uz/echo"
SOURCE_API = f"repos/{SOURCE_REPO}"
LEDGER_BRANCH = "echo-release-builds"
PREPARE_WORKFLOW = ".github/workflows/prepare-release.yml"
PUBLIC_KEY = "XzFmEWjxWA+1rQc1mHl1tokbcYSWaSJMcCvFEOLwLHc="
TEAM = "FWCSVFT76D"
require = release.require


def run(*args):
    subprocess.run(args, cwd=ROOT, check=True)


def read_json(path):
    return json.loads(Path(path).read_text())


def write_json(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(".tmp")
    temporary.write_text(json.dumps(value, indent=2) + "\n")
    temporary.replace(path)


def output(name, value):
    require("\n" not in str(value), "Invalid workflow output.")
    if os.environ.get("GITHUB_OUTPUT"):
        with open(os.environ["GITHUB_OUTPUT"], "a") as stream:
            stream.write(f"{name}={value}\n")


def trusted_context():
    require(os.environ.get("GITHUB_REPOSITORY") == SOURCE_REPO and
            os.environ.get("GITHUB_REF") == "refs/heads/main" and
            os.environ.get("GITHUB_EVENT_NAME") == "workflow_dispatch",
            "Release workflows must be dispatched from main in the Echo source repository.")


def request(version, channel, notes, sha, run_id):
    require(re.fullmatch(r"(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)", version), "Use a version such as 1.0.1.")
    require(channel in ("stable", "beta", "test"), "Invalid channel.")
    require(0 < len(notes.strip()) <= 8000, "Provide 1–8000 characters of reviewed release notes.")
    require(re.fullmatch(r"[a-f0-9]{40}", sha) and re.fullmatch(r"[1-9][0-9]*", run_id), "Invalid run identity.")
    return {"version": version, "channel": channel, "notesSHA256": hashlib.sha256(notes.strip().encode()).hexdigest(),
            "sourceCommit": sha, "runID": run_id}


def verify_publisher(github):
    # create-github-app-token already requested Contents:write; GitHub rejects
    # minting if the installation cannot grant it. App-token repository responses
    # do not include user-oriented permissions.push. Check the actual token scope.
    value = github.api("installation/repositories?per_page=100")
    require(isinstance(value, dict) and type(value.get("total_count")) is int and value["total_count"] == 1 and
            isinstance(value.get("repositories"), list) and len(value["repositories"]) == 1 and
            isinstance(value["repositories"][0], dict) and value["repositories"][0].get("full_name") == publish.REPOSITORY,
            "Publisher token must have access only to voicelab-uz/echo-releases.")
    print("Scoped release publisher verified; no release or feed changed.")


def highest_tag_build(github):
    highest = 115  # Public launch floor; a removed tag must never reset it.
    for page in range(1, 101):
        tags = github.api(f"{publish.API}/tags?per_page=100&page={page}")
        require(isinstance(tags, list), "Invalid release tag list.")
        for tag in tags:
            match = re.fullmatch(r"(?:stable|beta|test)-[0-9]+\.[0-9]+(?:\.[0-9]+)?-([1-9][0-9]{0,17})", tag["name"])
            if match:
                highest = max(highest, int(match[1]))
        if len(tags) < 100:
            return highest
    raise ValueError("Release tag pagination exceeded; no build reserved.")


def reserve(github, desired, published_floor):
    # A separate branch keeps counter commits out of main and avoids CI loops.
    ref = f"{SOURCE_API}/git/ref/heads/{LEDGER_BRANCH}"
    if github.api(ref, missing=True) is None:
        try:
            github.api(f"{SOURCE_API}/git/refs", "POST",
                       {"ref": f"refs/heads/{LEDGER_BRANCH}", "sha": desired["sourceCommit"]})
        except publish.GitHubError:
            require(github.api(ref, missing=True) is not None, "Cannot create release build ledger.")
    endpoint = f"{SOURCE_API}/contents/release-builds.json"
    for _ in range(5):
        current = github.api(f"{endpoint}?ref={LEDGER_BRANCH}", missing=True)
        ledger = json.loads(base64.b64decode(current["content"])) if current else {"schemaVersion": 1, "highestBuild": 115, "reservations": {}}
        require(ledger.get("schemaVersion") == 1 and type(ledger.get("highestBuild")) is int and
                isinstance(ledger.get("reservations"), dict), "Invalid build ledger; refusing to reset it.")
        existing = ledger["reservations"].get(desired["runID"])
        if existing:
            require(all(existing.get(k) == v for k, v in desired.items()), "Retry inputs differ from the reserved release.")
            return existing
        require(int(os.environ.get("GITHUB_RUN_ATTEMPT", "1")) == 1,
                "Retry reservation is missing or expired. Start a new preparation run; never recreate its old build.")
        previous = max(ledger["highestBuild"], published_floor)
        require(previous < 10**18 - 1, "Build counter exhausted.")
        result = {**desired, "build": str(previous + 1), "previousBuild": str(previous)}
        ledger["highestBuild"] = previous + 1
        ledger["reservations"][desired["runID"]] = result
        # Keep the high-water mark forever, but bound retry metadata. Recovery
        # artifacts expire after three days; missing older reservations fail shut.
        ledger["reservations"] = dict(sorted(ledger["reservations"].items(), key=lambda item: int(item[0]))[-256:])
        payload = {"branch": LEDGER_BRANCH, "message": f"Reserve Echo build {previous + 1} for Actions run {desired['runID']}",
                   "content": base64.b64encode((json.dumps(ledger, indent=2) + "\n").encode()).decode()}
        if current:
            payload["sha"] = current["sha"]
        try:
            github.api(endpoint, "PUT", payload)
            return result
        except publish.GitHubError as error:
            # Re-read even on an unknown result: the reservation may have succeeded.
            if error.status not in (None, 409, 422):
                raise
    raise ValueError("Build reservation could not be confirmed; retry the same workflow run.")


def configure(record):
    values = {"ECHO_TEAM_ID": TEAM, "ECHO_UPDATE_HOST_MODE": "github", "ECHO_UPDATE_CHANNEL": record["channel"],
              "ECHO_UPDATE_FEED_URL": f"{publish.FEED_BASE}/{record['channel']}/appcast.xml",
              "ECHO_UPDATE_RELEASE_BASE_URL": publish.ASSET_BASE, "ECHO_SPARKLE_PUBLIC_KEY": PUBLIC_KEY,
              "ECHO_PREVIOUS_BUILD": record["previousBuild"], "ECHO_PUSH_ENABLED": "1", "ECHO_ARCHS": "arm64 x86_64"}
    os.environ.update(values)
    return values


def release_name(record):
    suffix = "" if record["channel"] == "stable" else "-" + record["channel"]
    return f"Echo-{record['version']}-{record['build']}-universal{suffix}"


def plan():
    trusted_context()
    desired = request(os.environ["RELEASE_VERSION"], os.environ["RELEASE_CHANNEL"], os.environ["RELEASE_NOTES"],
                      os.environ["GITHUB_SHA"], os.environ["GITHUB_RUN_ID"])
    github = publish.GitHub()
    record = reserve(github, desired, highest_tag_build(github))
    record = {**record, "notes": os.environ["RELEASE_NOTES"].strip()}
    path = STATE / "request.json"
    if path.exists():
        require(read_json(path) == record, "Recovery belongs to another release.")
    write_json(path, record)
    values = configure(record)
    with open(os.environ["GITHUB_ENV"], "a") as stream:
        stream.write("".join(f"{key}={value}\n" for key, value in values.items()))
    output("build", record["build"])
    output("tag", f"{record['channel']}-{record['version']}-{record['build']}")
    output("attempt_before", int(os.environ["GITHUB_RUN_ATTEMPT"]) - 1)
    feed = STATE / "previous-feed.xml"
    if not feed.exists() and not (STATE / "initial-feed").exists():
        current = github.api(f"{publish.API}/contents/{record['channel']}/appcast.xml?ref=main", missing=True)
        if current is None:
            require(record["channel"] != "stable", "Stable feed is missing; refusing to bootstrap over an outage.")
            (STATE / "initial-feed").touch()
        else:
            require(current.get("encoding") == "base64", "Invalid feed encoding.")
            feed.write_bytes(base64.b64decode(current["content"]))
    (STATE / "release-notes.html").write_text("<!doctype html><meta charset=\"utf-8\"><h1>Echo " +
        html.escape(record["version"]) + "</h1>\n<ul>" + "".join("<li>" + html.escape(line.strip()) + "</li>"
        for line in record["notes"].splitlines() if line.strip()) + "</ul>\n")


def build():
    trusted_context()
    record = read_json(STATE / "request.json")
    configure(record)
    require(subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip() == record["sourceCommit"],
            "Checkout differs from reserved source.")
    checkpoint = STATE / "checkpoint.json"
    completed = read_json(checkpoint) if checkpoint.exists() else []
    for stage in ("build", "sign", "notarize", "package"):
        if stage not in completed:
            run("/bin/bash", "scripts/release.sh", stage, record["version"], record["build"])
            completed.append(stage)
            write_json(checkpoint, completed)
    candidate = STATE / "candidate"
    publication = candidate / "publication"
    if not publication.exists():
        previous = ["--previous-feed", str(STATE / "previous-feed.xml")] if (STATE / "previous-feed.xml").exists() else ["--initial-feed"]
        run(sys.executable, "scripts/update_release.py", "prepare", str(ROOT / "dist" / release_name(record)),
            "--notes", str(STATE / "release-notes.html"), "--output", str(publication), *previous)
    with tempfile.TemporaryDirectory() as temporary:
        manifest = publish.load_publication(publication, True, release.verifier(temporary))
    require(manifest["sourceCommit"] == record["sourceCommit"] and manifest["build"] == record["build"], "Candidate provenance differs.")
    write_json(candidate / "candidate.json", {"schemaVersion": 1, "runID": record["runID"],
        "sourceCommit": record["sourceCommit"], "releaseTag": manifest["releaseTag"],
        "publicationSHA256": release.digest(publication / "publication.json")})
    with open(os.environ["GITHUB_STEP_SUMMARY"], "a") as stream:
        stream.write(f"## Candidate {manifest['releaseTag']}\n\nSource: `{record['sourceCommit']}`\n\n"
                     "Download the candidate artifact, install its DMG, and test sign-in, Fn, microphone, text insertion and updating. "
                     "Then dispatch **Publish release** with this run ID and the exact release tag. Nothing is public yet.\n")


def snapshot(destination):
    if not (STATE / "request.json").exists():
        return
    record = read_json(STATE / "request.json")
    paths = ["build/ci", f"build/releases/{release_name(record)}", f"dist/{release_name(record)}"]
    destination.parent.mkdir(parents=True, exist_ok=True)
    run("/usr/bin/tar", "-czf", str(destination), "--exclude=DerivedData", "--exclude=candidate",
        *[path for path in paths if (ROOT / path).exists()])


def restore(archive):
    # Inspect the complete link graph before extraction: checking each link in
    # isolation misses escapes through another link that is not on disk yet.
    prefixes = ("build/ci", "build/releases", "dist")
    def allowed(path):
        return any(path == prefix or path.startswith(prefix + "/") for prefix in prefixes)
    entries = {}
    links = {}
    with tarfile.open(archive) as stream:
        for member in stream:
            path = PurePosixPath(member.name)
            # bsdtar stores directory extended attributes in sibling AppleDouble
            # files (e.g. build/._ci). They must be regular metadata, never links.
            metadata = path.name.startswith("._")
            logical_path = path.with_name(path.name[2:]) if metadata and len(path.name) > 2 else path
            require(not path.is_absolute() and ".." not in path.parts and allowed(str(logical_path)), "Unsafe recovery archive path.")
            require(not metadata or member.isfile(), "Unexpected recovery metadata type.")
            require(member.isfile() or member.isdir() or member.issym() or member.islnk(), "Unexpected archive member.")
            require(str(path) not in entries, "Duplicate recovery archive path.")
            entries[str(path)] = member
            if member.issym() or member.islnk():
                require(not member.linkname.startswith("/"), "Absolute recovery link.")
                links[str(path)] = posixpath.join(str(path.parent), member.linkname) if member.issym() else member.linkname
    for name in entries:
        require(not any(str(parent) in links for parent in PurePosixPath(name).parents),
                "Recovery member is nested below an archive link.")
    for name, target in links.items():
        seen = set()
        pending = list(PurePosixPath(target).parts)
        resolved = []
        while pending:
            state = (tuple(resolved), tuple(pending))
            require(state not in seen and len(seen) < 4096, "Cyclic or excessive recovery link.")
            seen.add(state)
            part = pending.pop(0)
            if part == "..":
                require(resolved, "Recovery link escapes its root.")
                resolved.pop()
            else:
                resolved.append(part)
                prefix = "/".join(resolved)
                if prefix in links:
                    pending = list(PurePosixPath(links[prefix]).parts) + pending
                    resolved = []
        target = "/".join(resolved)
        require(allowed(target) and resolved[0] == name.split("/")[0], "Recovery link escapes its root.")
    require(not (ROOT / "build").is_symlink(), "Recovery build directory is a link.")
    for prefix in prefixes:
        destination = ROOT / prefix
        require(not destination.exists() and not destination.is_symlink(), "Recovery requires a fresh checkout.")
    run("/usr/bin/tar", "-xzf", str(archive))


def preparation_run(github, run_id):
    require(re.fullmatch(r"[1-9][0-9]*", run_id), "Invalid preparation run ID.")
    value = github.api(f"{SOURCE_API}/actions/runs/{run_id}")
    require(value.get("repository", {}).get("full_name") == SOURCE_REPO and
            value.get("head_repository", {}).get("full_name") == SOURCE_REPO and
            value.get("event") == "workflow_dispatch" and value.get("head_branch") == "main" and
            value.get("path") == PREPARE_WORKFLOW and value.get("status") == "completed" and
            value.get("conclusion") == "success" and re.fullmatch(r"[a-f0-9]{40}", value.get("head_sha", "")),
            "Only a successful Prepare release run dispatched from main can be published.")
    return value


def resolve(run_id):
    trusted_context()
    value = preparation_run(publish.GitHub(), run_id)
    # An old main commit is fine; a force-pushed-away source requires review.
    run("git", "merge-base", "--is-ancestor", value["head_sha"], "origin/main")
    output("source", value["head_sha"])
    output("artifact", f"echo-candidate-{run_id}-{value['run_attempt']}")


def validate_candidate(directory, run_id, confirmation):
    value = preparation_run(publish.GitHub(), run_id)
    candidate = read_json(directory / "candidate.json")
    require(candidate.get("schemaVersion") == 1 and candidate.get("runID") == run_id and
            candidate.get("sourceCommit") == value["head_sha"] and candidate.get("releaseTag") == confirmation,
            "Candidate/run mismatch or confirmation is not the exact release tag.")
    publication = directory / "publication"
    require(release.digest(publication / "publication.json") == candidate.get("publicationSHA256"), "Candidate manifest changed.")
    os.environ.update(ECHO_TEAM_ID=TEAM, ECHO_SPARKLE_PUBLIC_KEY=PUBLIC_KEY)
    with tempfile.TemporaryDirectory() as temporary:
        manifest = publish.load_publication(publication, True, release.verifier(temporary))
    require(manifest["sourceCommit"] == value["head_sha"] and manifest["releaseTag"] == confirmation,
            "Signed publication does not match the approved candidate.")
    # Refuse an older candidate after a newer build reached any channel.
    require(int(manifest["build"]) >= highest_tag_build(publish.GitHub()), "A newer build has been published; prepare a new candidate.")
    return publication


def verify_site(directory):
    manifest = read_json(directory / "publication.json")
    if manifest["channel"] != "stable":
        return
    expected = next(entry["url"] for entry in manifest["files"] if entry["path"].endswith(".dmg"))
    pages = ("https://echo.voicelab.uz/", "https://voicelab.uz/echo", "https://voicelab.uz/download")
    pending = set(pages)
    for attempt in range(10):
        for page in list(pending):
            try:
                request = Request(page, headers={"Cache-Control": "no-cache", "User-Agent": "Echo-Release-Verification/1"})
                with urlopen(request, timeout=20) as response:
                    content = html.unescape(response.read(4 * 1024 * 1024).decode()).replace("\\/", "/")
                    if response.status == 200 and expected in content:
                        pending.remove(page)
            except (OSError, UnicodeError):
                pass
        if not pending:
            break
        if attempt < 9:
            time.sleep(20)
    require(not pending, "Release is published, but website verification is pending: " + ", ".join(sorted(pending)) +
            ". Retry this publication after checking the frontend; do not rebuild or delete the live release.")
    with open(os.environ["GITHUB_STEP_SUMMARY"], "a") as stream:
        stream.write(f"## Published {manifest['releaseTag']}\n\n[Download Echo]({expected})\n\n"
                     "Signed feed and all three website download routes verified. Retention audit is attached to this run.\n")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    commands.add_parser("plan")
    commands.add_parser("verify-publisher")
    commands.add_parser("build")
    commands.add_parser("snapshot").add_argument("path", type=Path)
    commands.add_parser("restore").add_argument("path", type=Path)
    commands.add_parser("resolve").add_argument("run_id")
    commands.add_parser("verify-site").add_argument("directory", type=Path)
    validate = commands.add_parser("validate-candidate")
    validate.add_argument("directory", type=Path)
    validate.add_argument("run_id")
    validate.add_argument("confirmation")
    args = parser.parse_args()
    if args.command == "plan": plan()
    elif args.command == "verify-publisher":
        trusted_context()
        verify_publisher(publish.GitHub())
    elif args.command == "build": build()
    elif args.command == "snapshot": snapshot(args.path)
    elif args.command == "restore": restore(args.path)
    elif args.command == "resolve": resolve(args.run_id)
    elif args.command == "verify-site": verify_site(args.directory)
    elif args.command == "validate-candidate":
        trusted_context()
        validate_candidate(args.directory, args.run_id, args.confirmation)


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError, KeyError, publish.GitHubError, subprocess.CalledProcessError) as error:
        sys.exit(f"CI release error: {error}")
