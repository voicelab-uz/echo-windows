# Regenerating the handoff (macOS only)

The assets are exported from the Mac app with macOS tools (AppKit renders the SVGs and symbols).

```sh
cd DesignHandoff/Tools
mkdir -p /tmp/handoff
for t in svg2png traymark sfsym; do swiftc $t.swift -o /tmp/handoff/$t; done
# edit MAC / OUT at the top of build.py to your checkout paths, then:
python3 build.py
```

`build.py` rebuilds every folder except `HANDOFF.md`, `README.md` and `Tools/`.
`traymark.swift` is a direct port of `Voicelab/Shared/MenuBarIcon.swift`.
