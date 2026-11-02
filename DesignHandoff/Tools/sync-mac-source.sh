#!/bin/sh
# Refresh MacApp/ with an exact copy of the Mac repo (tracked files only).
# Usage: DesignHandoff/Tools/sync-mac-source.sh /path/to/echo [git-ref]
set -eu
mac="${1:?path to the Mac repo (voicelab-uz/echo)}"
ref="${2:-HEAD}"
root="$(cd "$(dirname "$0")/../.." && pwd)"
rm -rf "$root/MacApp"
mkdir "$root/MacApp"
git -C "$mac" archive --format=tar "$ref" | tar -x -C "$root/MacApp"
{
  echo "# Mac app snapshot"
  echo
  echo "Read-only copy of voicelab-uz/echo. Do not edit here; run"
  echo "\`DesignHandoff/Tools/sync-mac-source.sh\` to refresh."
  echo
  echo "- Commit: \`$(git -C "$mac" rev-parse "$ref")\`"
  echo "- Date: $(git -C "$mac" log -1 --format=%ci "$ref")"
  echo "- Subject: $(git -C "$mac" log -1 --format=%s "$ref")"
} > "$root/MacApp/SNAPSHOT.md"
echo "MacApp/ now matches $(git -C "$mac" rev-parse --short "$ref")"
