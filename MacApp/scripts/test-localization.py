#!/usr/bin/env python3
"""Require complete workspace translations and safe printf arguments for every picker language."""
import collections
import json
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]
source = (ROOT / "Voicelab/App/AppLocalization.swift").read_text()
enum_cases = source.split("enum InterfaceLanguage", 1)[1].split("var id:", 1)[0]
languages = set()
for line in enum_cases.splitlines():
    if "case " not in line:
        continue
    for item in line.split("case ", 1)[1].split(","):
        languages.add(item.split("=", 1)[-1].strip().strip('"'))

catalog = json.loads((ROOT / "Voicelab/Resources/Localizable.xcstrings").read_text())
tokens = re.compile(r"%(?:(\d+)\$)?[-+ #0]*(?:\d+)?(?:\.\d+)?(lld|ld|[difu@%])")


def signature(text):
    result = collections.Counter()
    next_index = 1
    for match in tokens.finditer(text):
        position, kind = match.groups()
        if kind == "%":
            continue
        result[(int(position) if position else next_index, kind)] += 1
        next_index += 1
    return result


checked = 0
for key, entry in catalog["strings"].items():
    localizations = entry.get("localizations", {})
    if "en" not in localizations:
        # Brand names, punctuation and format-only strings need no translation.
        continue
    assert languages <= localizations.keys(), (key, languages - localizations.keys())
    for language in sorted(languages):
        unit = localizations[language]["stringUnit"]
        assert unit["state"] == "translated", (key, language, "not translated")
        assert unit["value"].strip(), (key, language, "empty translation")
        assert signature(key) == signature(unit["value"]), (key, language, "format mismatch")
        assert not any(0x202A <= ord(c) <= 0x202E for c in unit["value"]), (key, language, "bidi override")
    checked += 1

# Prevent new literal lookups from silently falling back to an untranslated source key.
for path in (ROOT / "Voicelab").rglob("*.swift"):
    for key in re.findall(r'AppLocalization\.text\(\s*"((?:[^"\\]|\\.)*)"', path.read_text()):
        if "\\(" not in key:
            key = key.replace("\\n", "\n").replace('\\"', '"')
            assert key in catalog["strings"], (str(path.relative_to(ROOT)), key, "missing catalog key")

project = (ROOT / "Voicelab.xcodeproj/project.pbxproj").read_text()
regions = project.split("knownRegions = (", 1)[1].split(");", 1)[0]
known = {region.strip().strip('"') for region in regions.split(",")}
assert languages <= known, ("missing Xcode regions", languages - known)
print(f"PASS: {checked} interface strings in {len(languages)} languages; format arguments and lookup coverage valid.")
