#!/usr/bin/env python3
"""Prepare and verify Echo's signed, static CDN releases. Never uploads anything.

All signing is delegated to the checksum-pinned Sparkle tool. Public verification
uses CryptoKit; it never reads a Keychain item or needs a private signing key.
"""
import argparse
import base64
import copy
from datetime import datetime, timezone
from email.utils import format_datetime
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import sys
import tempfile
from urllib.parse import urlparse, urljoin
from urllib.request import Request, urlopen, build_opener, HTTPRedirectHandler
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]
SPARKLE_VERSION = "2.10.1"
GITHUB_REPOSITORY = "voicelab-uz/echo-releases"
GITHUB_ASSET_BASE = f"https://github.com/{GITHUB_REPOSITORY}/releases/download"
GITHUB_FEED_BASE = f"https://raw.githubusercontent.com/{GITHUB_REPOSITORY}/main"
SPARKLE_ARCHIVE_SHA256 = "4c2e48a3e50ebcc2c88a58a4c7264a1a99c3c31857ce754357afb9cdb323022a"
SIGN_UPDATE_SHA256 = "43c249771bafc3aa581228abae00731a012d324691b8292860896635050be76b"
SPARKLE = "http://www.andymatuschak.org/xml-namespaces/sparkle"
ET.register_namespace("sparkle", SPARKLE)
MAX_FEED_BYTES = 2 * 1024 * 1024
MAX_NOTES_BYTES = 256 * 1024
IMMUTABLE_CACHE = "public, max-age=31536000, immutable"
FEED_CACHE = "public, max-age=60, must-revalidate, no-transform"
FEED_RELEASE_LIMITS = {"stable": 3, "beta": 1, "test": 1}
SIGNATURE_PREFIX = b"<!-- sparkle-signatures:\n"


def require(condition, message):
    if not condition:
        raise ValueError(message)


def digest(path):
    result = hashlib.sha256()
    with Path(path).open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            result.update(chunk)
    return result.hexdigest()


def https_url(value):
    parsed = urlparse(value)
    require(parsed.scheme == "https" and parsed.hostname and not parsed.username and
            not parsed.password and not parsed.query and not parsed.fragment and
            parsed.port in (None, 443), "Expected a public HTTPS URL without credentials, query, fragment, or custom port.")
    require(not any(c.isspace() for c in value) and "%" not in parsed.path and
            all(p not in (".", "..") for p in parsed.path.split("/")), "Unsafe URL path.")
    return value


def public_key(value):
    try:
        data = base64.b64decode(value, validate=True)
    except (ValueError, TypeError):
        raise ValueError("ECHO_SPARKLE_PUBLIC_KEY must be a base64 Ed25519 public key.") from None
    require(len(data) == 32 and base64.b64encode(data).decode() == value,
            "ECHO_SPARKLE_PUBLIC_KEY must encode exactly 32 bytes.")
    require(any(data), "A zero public key is not a release key.")
    return value


def host_mode():
    value = os.environ.get("ECHO_UPDATE_HOST_MODE", "cdn")
    require(value in ("cdn", "github"), "ECHO_UPDATE_HOST_MODE must be cdn or github.")
    return value


def config():
    channel = os.environ.get("ECHO_UPDATE_CHANNEL", "")
    require(channel in ("stable", "beta", "test"), "Set ECHO_UPDATE_CHANNEL to stable, beta, or test.")
    feed = https_url(os.environ.get("ECHO_UPDATE_FEED_URL", ""))
    base = https_url(os.environ.get("ECHO_UPDATE_RELEASE_BASE_URL", "").rstrip("/"))
    require(feed.endswith(f"/{channel}/appcast.xml"), "Feed URL must end with /CHANNEL/appcast.xml; test and production feeds must be separate.")
    if host_mode() == "github":
        require(feed == f"{GITHUB_FEED_BASE}/{channel}/appcast.xml" and base == GITHUB_ASSET_BASE,
                "GitHub hosting must use the dedicated public echo-releases repository and exact feed/asset routes.")
    else:
        require(urlparse(feed).netloc == urlparse(base).netloc, "Feed and release URLs must use the same CDN host.")
    return {"channel": channel, "feedURL": feed, "releaseBaseURL": base,
            "publicEDKey": public_key(os.environ.get("ECHO_SPARKLE_PUBLIC_KEY", ""))}


def validate_build(build):
    require(re.fullmatch(r"[1-9][0-9]{0,17}", build), "Build must be a positive integer of at most 18 digits.")
    settings = config()
    previous = os.environ.get("ECHO_PREVIOUS_BUILD", "0" if settings["channel"] == "test" else "")
    require(re.fullmatch(r"0|[1-9][0-9]{0,17}", previous), "Set ECHO_PREVIOUS_BUILD to the largest published build (0 only for first release).")
    require(int(build) > int(previous), "Build must be greater than every previously published build; never reset it with a marketing version.")


def read_plist(path):
    with Path(path).open("rb") as source:
        return plistlib.load(source)


def validate_app(app):
    app = Path(app)
    info = read_plist(app / "Contents/Info.plist")
    settings = config()
    for key, expected in {"SUFeedURL": settings["feedURL"], "SUPublicEDKey": settings["publicEDKey"],
                          "EchoUpdateChannel": settings["channel"], "SUVerifyUpdateBeforeExtraction": True,
                          "SURequireSignedFeed": True, "SUSignedFeedFailureExpirationInterval": 0,
                          "SUEnableSystemProfiling": False, "SUEnableJavaScript": False}.items():
        require(info.get(key) == expected, f"App Info.plist has incorrect {key}.")
    helper = read_plist(app / "Contents/Library/LoginItems/EchoWakeHelper.app/Contents/Info.plist")
    require(helper.get("CFBundleIdentifier") == "uz.voicelab.desktop.WakeHelper", "Unexpected WakeHelper identity.")
    require(helper.get("CFBundleVersion") == info.get("CFBundleVersion"), "WakeHelper build differs from app.")
    framework = read_plist(app / "Contents/Frameworks/Sparkle.framework/Resources/Info.plist")
    require(framework.get("CFBundleShortVersionString") == SPARKLE_VERSION, "Unexpected Sparkle framework version.")
    require(framework.get("CFBundleIdentifier") == "org.sparkle-project.Sparkle", "Unexpected Sparkle framework identity.")
    for path, identifier in (("Updater.app", "org.sparkle-project.Sparkle.Updater"),
                             ("XPCServices/Installer.xpc", "org.sparkle-project.InstallerLauncher"),
                             ("XPCServices/Downloader.xpc", "org.sparkle-project.DownloaderService")):
        nested = read_plist(app / "Contents/Frameworks/Sparkle.framework/Versions/B" / path / "Contents/Info.plist")
        require(nested.get("CFBundleIdentifier") == identifier, f"Unexpected Sparkle helper identity: {path}")


def code_inventory(app):
    app = Path(app).resolve()
    magic = {b"\xfe\xed\xfa\xce", b"\xce\xfa\xed\xfe", b"\xfe\xed\xfa\xcf", b"\xcf\xfa\xed\xfe",
             b"\xca\xfe\xba\xbe", b"\xbe\xba\xfe\xca", b"\xca\xfe\xba\xbf", b"\xbf\xba\xfe\xca"}
    paths = []
    for item in sorted(app.rglob("*")):
        require("\n" not in str(item) and "\r" not in str(item), "Invalid newline in bundle path.")
        if item.is_symlink():
            require(item.resolve().is_relative_to(app), "Bundle symlink escapes the app.")
            require(item.exists(), "Broken bundle symlink.")
        elif item.is_file():
            with item.open("rb") as source:
                if source.read(4) in magic:
                    paths.append(item.relative_to(app).as_posix())
    expected = ["Contents/Library/LoginItems/EchoWakeHelper.app/Contents/MacOS/EchoWakeHelper"]
    base = "Contents/Frameworks/Sparkle.framework/Versions/B/"
    expected += [base + suffix for suffix in ("Sparkle", "Autoupdate", "Updater.app/Contents/MacOS/Updater",
                  "XPCServices/Installer.xpc/Contents/MacOS/Installer", "XPCServices/Downloader.xpc/Contents/MacOS/Downloader")]
    require(set(expected).issubset(paths), "A required WakeHelper/Sparkle executable is missing or is not Mach-O.")
    return paths


def verifier(directory):
    target = Path(directory) / "verify-update-signature"
    subprocess.run(["xcrun", "swiftc", str(ROOT / "scripts/verify-update-signature.swift"), "-o", str(target)], check=True)
    return target


def verify_file(path, signature, key, executable):
    try:
        decoded = base64.b64decode(signature, validate=True)
    except (ValueError, TypeError):
        raise ValueError("Invalid Ed25519 signature encoding.") from None
    require(len(decoded) == 64, "Invalid Ed25519 signature length.")
    subprocess.run([str(executable), public_key(key), signature, str(path)], check=True)


def feed_content(data):
    require(len(data) <= MAX_FEED_BYTES, "Feed exceeds size limit.")
    # Match Sparkle's signed-feed format, but reject unsigned trailing XML/data.
    content, marker, block = data.rpartition(SIGNATURE_PREFIX)
    require(marker and SIGNATURE_PREFIX not in content, "Feed must have exactly one signature block.")
    match = re.fullmatch(rb"edSignature: ([A-Za-z0-9+/=]+)\nlength: ([0-9]+)\n-->\s*", block)
    require(match is not None, "Invalid signed feed block or trailing content.")
    require(int(match[2]) == len(content), "Signed feed length does not match content.")
    require(b"<!DOCTYPE" not in content.upper() and b"<!ENTITY" not in content.upper(), "DTD/entity declarations are forbidden in feeds.")
    return content, match[1].decode()


def verify_feed(path, key, executable):
    require(Path(path).stat().st_size <= MAX_FEED_BYTES, "Feed exceeds size limit.")
    content, signature = feed_content(Path(path).read_bytes())
    with tempfile.NamedTemporaryFile() as unsigned:
        unsigned.write(content)
        unsigned.flush()
        verify_file(unsigned.name, signature, key, executable)
    root = ET.fromstring(content)
    require(root.tag == "rss" and root.find("channel") is not None, "Invalid RSS feed.")
    return root


def signing_tool():
    tool = Path(os.environ.get("ECHO_SPARKLE_TOOLS_DIR", "")) / "sign_update"
    require(tool.is_file() and digest(tool) == SIGN_UPDATE_SHA256,
            "Set ECHO_SPARKLE_TOOLS_DIR to bin/ from the pinned Sparkle 2.10.1 archive. sign_update checksum must match.")
    return tool


def sign(path, tool):
    # Keychain account name is not secret. Private keys are never command arguments.
    account = os.environ.get("ECHO_SPARKLE_KEY_ACCOUNT", "uz.voicelab.echo.updates")
    require(account and "\n" not in account, "Invalid Sparkle Keychain account name.")
    key_file = os.environ.get("ECHO_SPARKLE_PRIVATE_KEY_FILE")
    key_args = ["--account", account]
    if key_file:
        private = Path(key_file)
        require(private.is_absolute() and private.is_file() and not private.is_symlink() and
                not private.resolve().is_relative_to(ROOT) and private.stat().st_mode & 0o077 == 0 and
                0 < private.stat().st_size <= 1024, "CI signing key must be a private file outside the checkout.")
        key_args = ["--ed-key-file", str(private)]
    result = subprocess.run([str(tool), *key_args, "--disable-signing-warning", "-p", str(path)],
                            stdout=subprocess.PIPE, text=True, check=True)
    return result.stdout.strip()


def validated_metadata(release):
    require((release / "release.json").stat().st_size < MAX_NOTES_BYTES, "Oversized release metadata.")
    metadata = json.loads((release / "release.json").read_text())
    require(metadata.get("schemaVersion") == 1, "Unknown release metadata schema.")
    for key, value in config().items():
        require(metadata.get(key) == value, f"Release metadata does not match configured {key}.")
    require(metadata.get("sparkleVersion") == SPARKLE_VERSION and metadata.get("bundleIdentifier") == "uz.voicelab.desktop", "Unexpected application/framework identity.")
    require(metadata.get("architectures") == ["arm64", "x86_64"], "Only universal releases may be published.")
    require(type(metadata.get("sourceDirty")) is bool, "Source dirty state is missing or invalid.")
    require(metadata.get("sourceDirty") is False or metadata["channel"] == "test", "Dirty source cannot enter a production feed.")
    require(re.fullmatch(r"[0-9a-f]{40}|[0-9a-f]{64}", metadata.get("sourceCommit", "")), "Source commit is missing or invalid.")
    require(re.fullmatch(r"[A-Z0-9]{10}", metadata.get("teamID", "")) and metadata["teamID"] == os.environ.get("ECHO_TEAM_ID"), "Release does not belong to the configured publishing team.")
    require(re.fullmatch(r"[0-9]+\.[0-9]+(?:\.[0-9]+)?", metadata.get("version", "")), "Invalid release version.")
    validate_build(metadata.get("build", ""))
    name = metadata.get("filename", "")
    require(re.fullmatch(r"Echo-[0-9.]+-[0-9]+-universal(?:-beta|-test)?\.dmg", name), "Invalid DMG filename.")
    suffix = "" if metadata["channel"] == "stable" else "-" + metadata["channel"]
    require(name == f"Echo-{metadata['version']}-{metadata['build']}-universal{suffix}.dmg", "DMG filename disagrees with release metadata.")
    require(re.fullmatch(r"[0-9]+\.[0-9]+(?:\.[0-9]+)?", metadata.get("minimumSystemVersion", "")), "Invalid minimum macOS version.")
    archive = release / name
    require(not archive.is_symlink() and archive.is_file(), "Missing regular DMG file.")
    require(digest(archive) == metadata.get("sha256") and archive.stat().st_size == metadata.get("bytes"), "Release DMG changed after notarization/packaging.")
    return metadata


def make_item(metadata, archive_url, signature, notes_url, notes_signature, notes_size, phased_interval):
    item = ET.Element("item")
    for tag, value in [("title", f"Echo {metadata['version']}"), (f"{{{SPARKLE}}}version", metadata["build"]),
                       (f"{{{SPARKLE}}}shortVersionString", metadata["version"]),
                       (f"{{{SPARKLE}}}minimumSystemVersion", metadata["minimumSystemVersion"] + ".0" if metadata["minimumSystemVersion"].count(".") == 1 else metadata["minimumSystemVersion"]),
                       ("pubDate", format_datetime(datetime.now(timezone.utc)))]:
        ET.SubElement(item, tag).text = value
    notes = ET.SubElement(item, f"{{{SPARKLE}}}releaseNotesLink", {
        f"{{{SPARKLE}}}edSignature": notes_signature, f"{{{SPARKLE}}}length": str(notes_size)})
    notes.text = notes_url
    if phased_interval:
        ET.SubElement(item, f"{{{SPARKLE}}}phasedRolloutInterval").text = str(phased_interval)
    ET.SubElement(item, "enclosure", {"url": archive_url, "length": str(metadata["bytes"]),
                    "type": "application/octet-stream", f"{{{SPARKLE}}}edSignature": signature})
    return item


def retained_feed_items(items, channel, keep=None):
    """Bound the feed without silently abandoning an older macOS branch.

    Only our ordinary universal-DMG feed format is automatically pruned. A
    future feed with architecture, OS ceilings, deltas or upgrade prerequisites
    needs an explicit retention review, rather than a guessed compatibility rule.
    """
    require(channel in FEED_RELEASE_LIMITS, "Unknown release channel.")
    keep = FEED_RELEASE_LIMITS[channel] if keep is None else keep
    require(type(keep) is int and 1 <= keep <= 100, "Keep between 1 and 100 feed releases.")
    builds = [item.findtext(f"{{{SPARKLE}}}version", "") for item in items]
    require(all(re.fullmatch(r"[1-9][0-9]{0,17}", build) for build in builds), "Feed contains an invalid build.")
    numbers = [int(build) for build in builds]
    require(numbers == sorted(set(numbers), reverse=True), "Feed builds must be unique and newest first.")
    if len(items) <= keep:
        return items

    allowed = {"title", "pubDate", "enclosure"} | {
        f"{{{SPARKLE}}}{name}" for name in ("version", "shortVersionString", "minimumSystemVersion",
                                            "releaseNotesLink", "phasedRolloutInterval")}
    floors = []
    for item in items:
        tags = [child.tag for child in item]
        require(not item.attrib and set(tags) <= allowed and len(tags) == len(set(tags)),
                "Feed uses compatibility features requiring retention review; increase --keep-releases to preserve it.")
        for child in item:
            attributes = ({"url", "length", "type", f"{{{SPARKLE}}}edSignature"} if child.tag == "enclosure" else
                          {f"{{{SPARKLE}}}edSignature", f"{{{SPARKLE}}}length"} if child.tag == f"{{{SPARKLE}}}releaseNotesLink" else set())
            require(set(child.attrib) <= attributes and not list(child),
                    "Feed uses compatibility features requiring retention review; increase --keep-releases to preserve it.")
        enclosure = item.find("enclosure")
        require(enclosure is not None and enclosure.get("type") == "application/octet-stream" and
                re.fullmatch(r"Echo-[0-9.]+-[0-9]+-universal(?:-beta|-test)?\.dmg", urlparse(enclosure.get("url", "")).path.rsplit("/", 1)[-1]),
                "Cannot automatically prune a feed without universal DMGs.")
        minimum = item.findtext(f"{{{SPARKLE}}}minimumSystemVersion", "")
        require(re.fullmatch(r"[0-9]+\.[0-9]+(?:\.[0-9]+)?", minimum), "Cannot prune a feed with an unknown macOS requirement.")
        components = [int(value) for value in minimum.split(".")]
        floors.append(tuple(components + [0] * (3 - len(components))))
    require(min(floors[:keep]) <= min(floors[keep:]),
            "Pruning would remove the last release for an older macOS version; increase --keep-releases and review storage retention.")
    return items[:keep]


def prepare(args):
    release = args.release.resolve()
    output = args.output.resolve()
    require(not output.exists(), "Output already exists; never overwrite a prepared publication.")
    metadata = validated_metadata(release)
    require(args.notes.is_file() and args.notes.stat().st_size <= MAX_NOTES_BYTES, "Release notes are missing or too large.")
    require(args.phased_interval >= 0, "Phased rollout interval cannot be negative.")
    tool = signing_tool()
    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix=".echo-publication-", dir=output.parent) as temporary:
        stage = Path(temporary)
        verify = verifier(stage)
        previous_root = None
        previous_sha = None
        if args.previous_feed:
            previous_root = verify_feed(args.previous_feed, metadata["publicEDKey"], verify)
            require(previous_root.findtext("channel/link") == metadata["feedURL"], "Previous feed belongs to another channel.")
            builds = [int(item.findtext(f"{{{SPARKLE}}}version", "0")) for item in previous_root.findall("channel/item")]
            require(not builds or int(metadata["build"]) > max(builds), "Feed would downgrade or reuse a published build.")
            previous_sha = digest(args.previous_feed)
        tag = f"{metadata['channel']}-{metadata['version']}-{metadata['build']}"
        prefix = tag if host_mode() == "github" else f"{metadata['channel']}/{metadata['version']}/{metadata['build']}"
        immutable = stage / "releases" / prefix
        immutable.mkdir(parents=True)
        for name in (metadata["filename"], "SHA256SUMS.txt", "release.json"):
            shutil.copy2(release / name, immutable / name)
        notes = immutable / "release-notes.html"
        shutil.copyfile(args.notes, notes)
        archive = immutable / metadata["filename"]
        archive_signature = sign(archive, tool)
        verify_file(archive, archive_signature, metadata["publicEDKey"], verify)
        notes_signature = sign(notes, tool)
        verify_file(notes, notes_signature, metadata["publicEDKey"], verify)
        # sign_update must never change the already notarized/stapled DMG.
        require(digest(archive) == metadata["sha256"], "Archive changed while signing.")
        base_url = metadata["releaseBaseURL"] + "/" + prefix
        root = ET.Element("rss", {"version": "2.0"})
        channel = ET.SubElement(root, "channel")
        ET.SubElement(channel, "title").text = f"Echo — {metadata['channel']} updates"
        ET.SubElement(channel, "link").text = metadata["feedURL"]
        ET.SubElement(channel, "description").text = "Echo for macOS"
        items = [make_item(metadata, base_url + "/" + metadata["filename"], archive_signature,
                           base_url + "/release-notes.html", notes_signature, notes.stat().st_size, args.phased_interval)]
        if previous_root is not None:
            items.extend(copy.deepcopy(item) for item in previous_root.findall("channel/item"))
        channel.extend(retained_feed_items(items, metadata["channel"], args.keep_releases))
        feed = stage / metadata["channel"] / "appcast.xml"
        feed.parent.mkdir()
        ET.indent(root, space="  ")
        ET.ElementTree(root).write(feed, encoding="utf-8", xml_declaration=True)
        with feed.open("ab") as destination:
            destination.write(b"\n")
        sign(feed, tool)
        verify_feed(feed, metadata["publicEDKey"], verify)
        files = []
        for path in sorted(immutable.iterdir()) + [feed]:
            is_feed = path == feed
            files.append({"path": path.relative_to(stage).as_posix(), "url": metadata["feedURL"] if is_feed else base_url + "/" + path.name,
                          "sha256": digest(path), "bytes": path.stat().st_size, "immutable": not is_feed,
                          "cacheControl": FEED_CACHE if is_feed else IMMUTABLE_CACHE,
                          "contentType": "application/xml; charset=utf-8" if is_feed else
                            "text/html; charset=utf-8" if path == notes else
                            "application/json" if path.suffix == ".json" else
                            "text/plain; charset=utf-8" if path.suffix == ".txt" else "application/x-apple-diskimage"})
        (stage / "publication.json").write_text(json.dumps({"schemaVersion": 1, "channel": metadata["channel"],
            "version": metadata["version"], "build": metadata["build"], "sourceDirty": metadata["sourceDirty"],
            "sourceCommit": metadata["sourceCommit"], "teamID": metadata["teamID"],
            "hostMode": host_mode(), "repository": GITHUB_REPOSITORY if host_mode() == "github" else None,
            "releaseTag": tag if host_mode() == "github" else None,
            "artifactVersionedPath": "releases/" + prefix,
            "publicEDKey": metadata["publicEDKey"], "previousFeedSHA256": previous_sha,
            "feedMustNotExist": bool(args.initial_feed), "files": files}, indent=2) + "\n")
        verify.unlink()
        stage.rename(output)
    print(f"Prepared {output}. Upload immutable files first; verify through public CDN; conditionally replace feed last. No upload performed.")


class NoRedirect(HTTPRedirectHandler):
    def redirect_request(self, request, fp, code, message, headers, new_url):
        raise ValueError("CDN verification requires direct public URLs; redirects are not accepted.")


class GitHubRedirect(HTTPRedirectHandler):
    max_redirections = 5
    max_repeats = 2

    def redirect_request(self, request, fp, code, message, headers, new_url):
        target = urlparse(urljoin(request.full_url, new_url))
        require(request.get_method() == "GET" and target.scheme == "https" and
                target.hostname in {"github.com", "release-assets.githubusercontent.com", "objects.githubusercontent.com"} and
                not target.username and not target.password and target.port in (None, 443),
                "GitHub asset redirect left the approved HTTPS hosts.")
        return super().redirect_request(request, fp, code, message, headers, new_url)


def verify_public(args):
    root = args.publication.resolve()
    manifest = json.loads((root / "publication.json").read_text())
    require(manifest.get("schemaVersion") == 1, "Unknown publication schema.")
    settings = config()
    require(manifest.get("channel") == settings["channel"] and manifest.get("publicEDKey") == settings["publicEDKey"], "Publication belongs to another channel or signing key.")
    require(manifest.get("hostMode", "cdn") == host_mode(), "Publication uses another hosting mode.")
    if host_mode() == "github":
        require(manifest.get("repository") == GITHUB_REPOSITORY and
                manifest.get("releaseTag") == f"{manifest['channel']}-{manifest['version']}-{manifest['build']}", "Unexpected GitHub repository or release tag.")
    require(isinstance(manifest.get("files"), list) and len(manifest["files"]) >= 2, "Invalid publication files.")
    require(manifest["files"][-1].get("url") == settings["feedURL"] and
            manifest["files"][-1].get("immutable") is False and
            all(entry.get("immutable") is True for entry in manifest["files"][:-1]), "Feed must be the sole mutable file and must come last.")
    opener = build_opener(GitHubRedirect if host_mode() == "github" else NoRedirect)
    for entry in manifest["files"]:
        require(type(entry.get("immutable")) is bool, "Invalid publication entry.")
        if not entry["immutable"] and not args.include_feed:
            continue
        https_url(entry["url"])
        if entry["immutable"]:
            prefix = manifest["releaseTag"] if host_mode() == "github" else settings["channel"]
            require(entry["url"].startswith(settings["releaseBaseURL"] + "/" + prefix + "/"), "Artifact URL is outside this channel's release root.")
        local = (root / entry["path"]).resolve()
        require(local.is_relative_to(root) and local.is_file(), "Unsafe or missing publication path.")
        require(digest(local) == entry["sha256"] and local.stat().st_size == entry["bytes"], "Local publication changed.")
        request = Request(entry["url"], headers={"Accept-Encoding": "identity", "Cache-Control": "no-cache"})
        result = hashlib.sha256()
        size = 0
        with opener.open(request, timeout=60) as response:
            require(response.status == 200, "CDN response was not 200.")
            require(response.headers.get("Content-Encoding", "identity") == "identity", "CDN transformed signed bytes.")
            if host_mode() == "github":
                # GitHub controls its CDN cache and may serve release assets as
                # octet-stream/raw feeds as text. Signatures/hashes remain strict.
                length = response.headers.get("Content-Length")
                require(length is None or length == str(entry["bytes"]), "GitHub Content-Length is incorrect.")
                allowed_types = {entry["contentType"].split(";", 1)[0], "application/octet-stream"}
                if not entry["immutable"]:
                    allowed_types.add("text/plain")
                require(response.headers.get("Content-Type", "").split(";", 1)[0].strip().lower() in allowed_types,
                        "Unexpected GitHub Content-Type.")
            else:
                require(response.headers.get("Content-Length") == str(entry["bytes"]), "CDN Content-Length is missing or incorrect.")
                require(response.headers.get("Content-Type", "").split(";", 1)[0].strip().lower() == entry["contentType"].split(";", 1)[0], "Unexpected CDN Content-Type.")
                expected_cache = {part.strip() for part in entry["cacheControl"].split(",")}
                actual_cache = {part.strip().lower() for part in response.headers.get("Cache-Control", "").split(",")}
                require(actual_cache == expected_cache, "CDN Cache-Control differs from publication policy.")
            while chunk := response.read(1024 * 1024):
                size += len(chunk)
                require(size <= entry["bytes"], "CDN returned more bytes than expected.")
                result.update(chunk)
        require(size == entry["bytes"] and result.hexdigest() == entry["sha256"], "CDN content differs from prepared publication.")
        if local.suffix == ".dmg":
            end = min(1024, entry["bytes"]) - 1
            ranged = Request(entry["url"], headers={"Accept-Encoding": "identity", "Range": f"bytes=0-{end}"})
            with opener.open(ranged, timeout=60) as response:
                require(response.status == 206 and response.headers.get("Content-Range") == f"bytes 0-{end}/{entry['bytes']}",
                        "Download host does not serve correct byte ranges for update resumption.")
                with local.open("rb") as source:
                    require(response.read(end + 2) == source.read(end + 1), "Download byte range differs from the release.")
        print(f"Verified public bytes: {entry['url']}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    commands.add_parser("validate-config")
    commands.add_parser("validate-build").add_argument("build")
    commands.add_parser("validate-app").add_argument("app", type=Path)
    commands.add_parser("code-inventory").add_argument("app", type=Path)
    command = commands.add_parser("prepare", help="Sign final DMG, release notes and appcast; produce publication.json without uploading")
    command.add_argument("release", type=Path)
    command.add_argument("--notes", type=Path, required=True, help="Reviewed HTML release notes")
    command.add_argument("--output", type=Path, required=True)
    previous = command.add_mutually_exclusive_group(required=True)
    previous.add_argument("--previous-feed", type=Path, help="Exact currently published signed feed bytes (verified against release key)")
    previous.add_argument("--initial-feed", action="store_true", help="Bootstrap only: publisher must conditionally create an absent feed")
    command.add_argument("--phased-interval", type=int, default=86400, help="Seconds between Sparkle rollout cohorts, 0 disables; manual checks bypass phasing")
    command.add_argument("--keep-releases", type=int, help="Feed retention: defaults to 3 stable or 1 beta/test; incompatible pruning is refused")
    command = commands.add_parser("verify-public", help="Read-only public CDN byte verification; no uploads")
    command.add_argument("publication", type=Path)
    command.add_argument("--include-feed", action="store_true", help="After promotion, also verify mutable feed bytes")
    args = parser.parse_args()
    if args.command == "validate-config": config()
    elif args.command == "validate-build": validate_build(args.build)
    elif args.command == "validate-app": validate_app(args.app)
    elif args.command == "code-inventory": print("\n".join(code_inventory(args.app)))
    elif args.command == "prepare": prepare(args)
    elif args.command == "verify-public": verify_public(args)


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError, KeyError, ET.ParseError, subprocess.CalledProcessError) as error:
        print(f"Update release error: {error}", file=sys.stderr)
        sys.exit(1)
