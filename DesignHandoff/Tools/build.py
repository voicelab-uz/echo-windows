import json, os, shutil, struct, subprocess, glob

MAC = "/Users/abdulrohman/vocielab echo/echo"
ASSETS = f"{MAC}/Voicelab/Assets.xcassets"
OUT = "/Users/abdulrohman/vocielab echo/VoiceLabEcho.Windows/DesignHandoff"
T = "/tmp/handoff"
INK_LIGHT, INK_DARK = "1A1A1A", "E9E8E1"     # WorkspaceAccent (text/icons) light / dark
MUTED_LIGHT, MUTED_DARK = "6E6E75", "A6A6B0"
ACCENT_LIGHT, ACCENT_DARK = "3D63F2", "7394FF"

def mk(path): os.makedirs(path, exist_ok=True); return path
def run(*args): subprocess.run(args, check=True, capture_output=True)
def svg(src, dst, size, color): run(f"{T}/svg2png", src, dst, str(size), color)
def resize(src, dst, size): run("sips", "-z", str(size), str(size), src, "--out", dst)

def write_ico(dst, pngs):
    """Multi-size .ico with PNG-compressed entries (supported since Windows Vista)."""
    blobs = [open(p, "rb").read() for _, p in pngs]
    header = struct.pack("<HHH", 0, 1, len(pngs))
    offset = 6 + 16 * len(pngs)
    entries = b""
    for (size, _), blob in zip(pngs, blobs):
        b = 0 if size >= 256 else size
        entries += struct.pack("<BBBBHHII", b, b, 0, 0, 1, 32, len(blob), offset)
        offset += len(blob)
    with open(dst, "wb") as f: f.write(header + entries + b"".join(blobs))

# Rebuild the generated folders only; HANDOFF.md, README.md and Tools/ are hand-written.
for generated in ("Brand", "Icons", "Onboarding", "EmptyStates", "Localization", "Reference"):
    if os.path.exists(f"{OUT}/{generated}"): shutil.rmtree(f"{OUT}/{generated}")
mk(OUT)

# ---------- Brand: colours, logo, fonts ----------
brand = mk(f"{OUT}/Brand")
colors = {}
for p in sorted(glob.glob(f"{ASSETS}/*.colorset/Contents.json")):
    name = os.path.basename(os.path.dirname(p)).replace(".colorset", "")
    if name in ("AccentColor", "StatisticsAccent"): continue  # duplicates of VoicelabAccent
    vals = {}
    for c in json.load(open(p)).get("colors", []):
        mode = "dark" if any(x.get("value") == "dark" for x in c.get("appearances", [])) else "light"
        comp = c["color"]["components"]
        h = lambda x: int(x, 16) if str(x).startswith("0x") else round(float(x) * 255) if float(x) <= 1 else int(float(x))
        vals[mode] = "#%02X%02X%02X" % (h(comp["red"]), h(comp["green"]), h(comp["blue"]))
    colors[name] = vals
json.dump(colors, open(f"{brand}/colors.json", "w"), indent=2)

logo = mk(f"{brand}/Logo")
shutil.copy(f"{ASSETS}/AppIcon.appiconset/icon_512x512@2x.png", f"{logo}/echo-app-icon-1024.png")
for s in (512, 256, 128, 64, 48, 32, 24, 16):
    resize(f"{logo}/echo-app-icon-1024.png", f"{logo}/echo-app-icon-{s}.png", s)
shutil.copy(f"{ASSETS}/EchoLogo.imageset/echo.png", f"{logo}/echo-logo-512.png")

fonts = mk(f"{brand}/Fonts")
for f in glob.glob(f"{MAC}/Voicelab/Features/Onboarding/Experience/Resources/Fonts/*"):
    shutil.copy(f, fonts)

# ---------- Icons: app icon, tray, logo, navigation, full set, third-party brands ----------
icons = mk(f"{OUT}/Icons")
ico_sizes = (16, 20, 24, 32, 40, 48, 64, 128, 256)
tmp = mk(f"{T}/ico")
write_ico(f"{icons}/app-icon.ico", [(s, f"{tmp}/a{s}.png") for s in ico_sizes
          if resize(f"{logo}/echo-app-icon-1024.png", f"{tmp}/a{s}.png", s) is None])
# Tray: the Mac menu bar mark (MenuBarIcon.swift), idle and recording, for light and dark taskbars.
for variant, color in (("light-taskbar", "000000"), ("dark-taskbar", "FFFFFF")):
    for state in ("", "recording"):
        suffix = "-recording" if state else ""
        pngs = []
        for s in (16, 20, 24, 32, 40, 48):
            p = f"{tmp}/t-{variant}{suffix}-{s}.png"
            run(f"{T}/traymark", p, str(s), color, *( [state] if state else [] )); pngs.append((s, p))
        write_ico(f"{icons}/tray-icon-{variant}{suffix}.ico", pngs)
        shutil.copy(f"{tmp}/t-{variant}{suffix}-16.png", f"{icons}/tray-icon-{variant}{suffix}-16.png")
        shutil.copy(f"{tmp}/t-{variant}{suffix}-32.png", f"{icons}/tray-icon-{variant}{suffix}-32.png")
resize(f"{logo}/echo-app-icon-1024.png", f"{icons}/logo.png", 256)

svgs = {os.path.basename(p): p for p in glob.glob(f"{ASSETS}/WorkspaceIcon-*.imageset/*.svg")}
nav_map = {"home": "home.svg", "statistics": None, "vocabulary": "knowledge.svg",
           "notes": "notes.svg", "getting-started": "info.svg", "settings": "settings.svg"}
nav = mk(f"{icons}/Navigation")
FLUENT_STATS = f"{T}/fluent/data-bar-vertical-24.svg"
def draw(file, dst, size, color):
    # The Mac uses Apple's SF Symbol "chart.bar.xaxis", which is licensed for Apple platforms
    # only. Windows gets Microsoft's Fluent "Data Bar Vertical" (MIT), the closest match.
    svg(FLUENT_STATS if file is None else svgs[file], dst, size, color)
for name, file in nav_map.items():
    for theme, color in (("light", INK_LIGHT), ("dark", INK_DARK)):
        draw(file, f"{nav}/{name}-{theme}.png", 24, color)
        draw(file, f"{nav}/{name}-{theme}@2x.png", 48, color)
    draw(file, f"{nav}/{name}-active-light.png", 24, ACCENT_LIGHT)
    draw(file, f"{nav}/{name}-active-dark.png", 24, ACCENT_DARK)
    # Plain names as requested: light theme, 24 px.
    shutil.copy(f"{nav}/{name}-light.png", f"{nav}/{name}.png")

full = mk(f"{icons}/IconSet")
mk(f"{full}/svg"); mk(f"{full}/png-light"); mk(f"{full}/png-dark")
for file, path in sorted(svgs.items()):
    shutil.copy(path, f"{full}/svg/{file}")
    stem = file[:-4]
    for theme, color in (("light", INK_LIGHT), ("dark", INK_DARK)):
        svg(path, f"{full}/png-{theme}/{stem}-24.png", 24, color)
        svg(path, f"{full}/png-{theme}/{stem}-48.png", 48, color)
shutil.copy(FLUENT_STATS, f"{full}/svg/statistics.svg")
shutil.copy(f"{T}/fluent/LICENSE", f"{full}/svg/statistics.LICENSE-Fluent-MIT.txt")
for theme, color in (("light", INK_LIGHT), ("dark", INK_DARK)):
    draw(None, f"{full}/png-{theme}/statistics-24.png", 24, color)
    draw(None, f"{full}/png-{theme}/statistics-48.png", 48, color)

brands = mk(f"{icons}/ThirdPartyApps")
for p in glob.glob(f"{ASSETS}/OnboardingBrand-*.imageset/*.svg"):
    name = os.path.basename(os.path.dirname(p)).replace("OnboardingBrand-", "").replace(".imageset", "")
    shutil.copy(p, f"{brands}/{name}.svg")
    svg(p, f"{brands}/{name}-64.png", 64, "none")

# ---------- Onboarding: copy in 16 languages, illustration stand-ins ----------
onb = mk(f"{OUT}/Onboarding")
copy = mk(f"{onb}/Copy")
for f in glob.glob(f"{MAC}/Voicelab/Features/Onboarding/Experience/Resources/*.json"):
    shutil.copy(f, copy)
illus = {"welcome": None, "sign-in": "shield.svg", "microphone": "mic.svg",
         "keyboard": "keyboard.svg", "complete": "star.svg"}
for name, file in illus.items():
    if file is None: resize(f"{logo}/echo-app-icon-1024.png", f"{onb}/{name}.png", 256)
    else:
        svg(svgs[file], f"{onb}/{name}.png", 256, ACCENT_LIGHT)
        svg(svgs[file], f"{onb}/{name}-dark.png", 256, ACCENT_DARK)

# ---------- Empty states ----------
empty = mk(f"{OUT}/EmptyStates")
for name, file in (("no-history", "history.svg"), ("no-notes", "notes.svg"), ("no-vocabulary", "knowledge.svg")):
    svg(svgs[file], f"{empty}/{name}.png", 128, MUTED_LIGHT)
    svg(svgs[file], f"{empty}/{name}-dark.png", 128, MUTED_DARK)

# ---------- Localization: every interface string in 16 languages ----------
loc = mk(f"{OUT}/Localization")
catalog = json.load(open(f"{MAC}/Voicelab/Resources/Localizable.xcstrings"))["strings"]
table, per = {}, {}
for key, entry in catalog.items():
    row = {}
    for lang, l in entry.get("localizations", {}).items():
        value = l.get("stringUnit", {}).get("value")
        if value is not None:
            row[lang] = value
            per.setdefault(lang, {})[key] = value
    table[key] = row
json.dump(table, open(f"{loc}/strings.json", "w"), ensure_ascii=False, indent=1, sort_keys=True)
mk(f"{loc}/by-language")
for lang, rows in per.items():
    json.dump(rows, open(f"{loc}/by-language/{lang}.json", "w"), ensure_ascii=False, indent=1, sort_keys=True)

# ---------- Reference: the shared core (API, auth, text rules) and its tests ----------
ref = mk(f"{OUT}/Reference")
shutil.copytree(f"{MAC}/Packages/VoiceLabCore/Sources", f"{ref}/VoiceLabCore/Sources")
shutil.copytree(f"{MAC}/Packages/VoiceLabCore/Tests", f"{ref}/VoiceLabCore/Tests")
# The Mac draws every onboarding illustration in code (SwiftUI). Ship that code so the
# Windows app can draw the same scenes rather than using static pictures.
onb_src = mk(f"{ref}/Onboarding")
for f in glob.glob(f"{MAC}/Voicelab/Features/Onboarding/Experience/*.swift"):
    shutil.copy(f, onb_src)
for f in ("ProductionOnboardingView.swift", "OnboardingJourney.swift"):
    shutil.copy(f"{MAC}/Voicelab/Features/Onboarding/{f}", onb_src)

print(json.dumps({"colors": len(colors), "icons": len(svgs), "strings": len(table),
                  "languages": sorted(per)}, ensure_ascii=False))
