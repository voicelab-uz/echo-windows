import SwiftUI

/// A MacBook Pro keyboard, cropped to the area around the chosen dictation key: flat black
/// keys in a black well, set into space-grey aluminium. The chosen key lights up from behind
/// with a soft blue halo (its face stays dark), and the keyboard slides so it sits in view.
struct SetupKeyboard: View {
    let highlighted: OnboardingKeyChoice
    var pressed = false
    /// Key codes of a recorded custom shortcut (its key plus any modifiers), lit when Custom is chosen.
    var customKeys: Set<UInt16> = []
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    fileprivate static let unit: CGFloat = 58
    fileprivate static let gap: CGFloat = 6
    private static let inset: CGFloat = 10

    var body: some View {
        GeometryReader { geometry in
            let width = Self.rowWidth
            // Keep the chosen key a little left of centre; Custom shows the bottom-row middle.
            let target = (highlighted == .custom ? Self.centerX(ofAny: customKeys) : Self.centerX(of: highlighted))
                ?? width / 2
            let offset = min(0, max(geometry.size.width - width - 40, geometry.size.width * 0.42 - target))
            VStack(alignment: .leading, spacing: Self.gap) {
                ForEach(Array(Self.rows.enumerated()), id: \.offset) { _, row in
                    HStack(spacing: Self.gap) {
                        ForEach(row) { key in
                            KeyboardKey(key: key, unit: Self.unit, gap: Self.gap,
                                        canLight: key.choice != nil || customKeys.contains(key.keyCode),
                                        lit: isLit(key), pressed: pressed)
                        }
                    }
                }
            }
            .padding(Self.inset)
            .background { KeyboardDeck() }
            .fixedSize()
            .offset(x: offset)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .animation(reduceMotion ? nil : .smooth(duration: 0.35), value: highlighted)
            .animation(reduceMotion ? nil : .smooth(duration: 0.35), value: customKeys)
        }
        .background(Color(white: 0.035))
        // The keyboard slides past its panel edge; clipping hides that part but would
        // still let it swallow clicks meant for the key choices, so it takes no input.
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func isLit(_ key: Key) -> Bool {
        highlighted == .custom ? customKeys.contains(key.keyCode)
            : key.choice != nil && key.choice == highlighted
    }

    // MARK: Layout

    fileprivate struct Key: Identifiable {
        let id = UUID()
        /// macOS virtual key code; 0xFFFF for keys that never light (Touch ID, arrows).
        var keyCode: UInt16 = 0xFFFF
        var top: String = ""
        var bottom: String = ""
        var center: String = ""
        var symbol: String? = nil
        /// Labels sit toward the outer edge: left for left-half keys, right for right-half keys.
        var alignLeading = false
        var width: CGFloat = 1
        var height: CGFloat = 1
        var choice: OnboardingKeyChoice? = nil
        var arrows = false
        /// Function-row icon (SF Symbol), as printed on a MacBook Pro.
        var icon: String? = nil
        var touchID = false
    }

    private static func keys(_ labels: String, _ codes: [UInt16]) -> [Key] {
        zip(labels, codes).map { Key(keyCode: $1, center: String($0)) }
    }
    private static func pairs(_ tops: String, _ bottoms: String, _ codes: [UInt16]) -> [Key] {
        zip(zip(tops, bottoms), codes).map { Key(keyCode: $1, top: String($0.0), bottom: String($0.1)) }
    }
    private static let functionKeys: [(UInt16, String)] = [
        (122, "sun.min"), (120, "sun.max"), (99, "rectangle.3.group"), (118, "magnifyingglass"),
        (96, "mic"), (97, "moon"), (98, "backward"), (100, "playpause"), (101, "forward"),
        (109, "speaker.slash"), (103, "speaker.wave.1"), (111, "speaker.wave.3"),
    ]
    private static let functionHeight: CGFloat = 0.62

    fileprivate static let rows: [[Key]] = [
        [Key(keyCode: 53, bottom: "esc", alignLeading: true, width: 1.5, height: functionHeight)]
            + functionKeys.enumerated().map { index, key in
                Key(keyCode: key.0, center: "F\(index + 1)", height: functionHeight, icon: key.1)
            }
            + [Key(height: functionHeight, touchID: true)],
        pairs("~!@#$%^&*()_+", "`1234567890-=", [50, 18, 19, 20, 21, 23, 22, 26, 28, 25, 29, 27, 24])
            + [Key(keyCode: 51, bottom: "delete", width: 1.5)],
        [Key(keyCode: 48, bottom: "tab", alignLeading: true, width: 1.5)]
            + keys("QWERTYUIOP", [12, 13, 14, 15, 17, 16, 32, 34, 31, 35])
            + pairs("{}|", "[]\\", [33, 30, 42]),
        [Key(keyCode: 57, bottom: "caps lock", alignLeading: true, width: 1.8)]
            + keys("ASDFGHJKL", [0, 1, 2, 3, 5, 4, 38, 40, 37])
            + pairs(":\"", ";'", [41, 39])
            + [Key(keyCode: 36, bottom: "return", width: 1.7)],
        [Key(keyCode: 56, bottom: "shift", alignLeading: true, width: 2.25)]
            + keys("ZXCVBNM", [6, 7, 8, 9, 11, 45, 46])
            + pairs("<>?", ",./", [43, 47, 44])
            + [Key(keyCode: 60, bottom: "shift", width: 2.25)],
        [Key(keyCode: 63, top: "fn", symbol: "globe", choice: .fn),
         Key(keyCode: 59, bottom: "control", symbol: "⌃"),
         Key(keyCode: 58, bottom: "option", symbol: "⌥"),
         Key(keyCode: 55, bottom: "command", symbol: "⌘", width: 1.25),
         Key(keyCode: 49, width: 5),
         Key(keyCode: 54, bottom: "command", symbol: "⌘", alignLeading: true, width: 1.25, choice: .rightCommand),
         Key(keyCode: 61, bottom: "option", symbol: "⌥", alignLeading: true, choice: .rightOption),
         Key(width: 3, arrows: true)],
    ]

    static func width(_ units: CGFloat) -> CGFloat { units * unit + (units - 1) * gap }
    private static var rowWidth: CGFloat { width(14.5) + inset * 2 }

    /// Horizontal centre of the chosen key, measured from the keyboard's leading edge.
    private static func centerX(of choice: OnboardingKeyChoice) -> CGFloat? {
        centerX { $0.choice == choice }
    }
    /// Centre of the first lit key of a custom shortcut, preferring its main (non-modifier) key.
    private static func centerX(ofAny codes: Set<UInt16>) -> CGFloat? {
        let modifiers: Set<UInt16> = [54, 55, 56, 58, 59, 60, 61, 62, 63]
        return centerX { codes.contains($0.keyCode) && !modifiers.contains($0.keyCode) }
            ?? centerX { codes.contains($0.keyCode) }
    }
    private static func centerX(where match: (Key) -> Bool) -> CGFloat? {
        for row in rows {
            var x = inset
            for key in row {
                let w = width(key.width)
                if match(key) { return x + w / 2 }
                x += w + gap
            }
        }
        return nil
    }
}

private struct KeyboardKey: View {
    let key: SetupKeyboard.Key
    let unit: CGFloat
    let gap: CGFloat
    /// Only keys that can light carry a halo; blurring every key made switching stutter.
    let canLight: Bool
    let lit: Bool
    let pressed: Bool

    private static let glow = Color(red: 0.35, green: 0.6, blue: 1.0)
    private static let face = Color(white: 0.085)
    private static let ink = Color.white.opacity(0.72)
    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: 6, style: .continuous) }

    var body: some View {
        Group {
            if key.arrows { arrows } else { cap }
        }
        .frame(width: SetupKeyboard.width(key.width), height: unit * key.height)
        // The halo sits behind an opaque key, so only the outside of the key glows.
        .background {
            if canLight {
                shape.fill(Self.glow)
                    .padding(-3)
                    .blur(radius: pressed ? 20 : 14)
                    .opacity(lit ? (pressed ? 1 : 0.8) : 0)
            }
        }
        .animation(.smooth(duration: 0.35), value: lit)
        .animation(.smooth(duration: 0.35), value: pressed)
    }

    /// A flat, matte black cap with a hairline edge, like the MacBook Pro's keys.
    private var cap: some View {
        ZStack {
            shape.fill(Self.face)
            shape.strokeBorder(lit ? Self.glow.opacity(0.7) : .white.opacity(0.045), lineWidth: 0.75)
            if key.touchID {
                shape.inset(by: 3).strokeBorder(.white.opacity(0.06), lineWidth: 0.75)
            } else {
                labels.padding(.horizontal, 7).padding(.vertical, 6)
            }
        }
    }

    @ViewBuilder private var labels: some View {
        let edge: HorizontalAlignment = key.alignLeading ? .leading : .trailing
        let frame: Alignment = key.alignLeading ? .leading : .trailing
        if let icon = key.icon {
            VStack(spacing: 3) {
                Image(systemName: icon).font(.system(size: 10, weight: .light))
                Text(key.center).font(.system(size: 7, weight: .regular))
            }
            .foregroundStyle(Self.ink)
        } else if !key.center.isEmpty {
            Text(key.center).font(.system(size: 14, weight: .light))
                .foregroundStyle(Self.ink)
        } else if key.choice == .fn {
            VStack {
                HStack { Spacer(); Text("fn").font(.system(size: 10, weight: .light)) }
                Spacer()
                HStack { Image(systemName: "globe").font(.system(size: 10, weight: .light)); Spacer() }
            }
            .foregroundStyle(Self.ink)
        } else if let symbol = key.symbol {
            // Left-half modifiers carry their symbol top-right; right-half ones top-left.
            VStack(alignment: edge) {
                Text(symbol).font(.system(size: 11, weight: .light))
                Spacer(minLength: 0)
                Text(key.bottom).font(.system(size: 8.5, weight: .regular))
            }
            .frame(maxWidth: .infinity, alignment: frame)
            .foregroundStyle(Self.ink)
        } else if key.width > 1 || key.height < 1 {
            // Wide keys and esc label in a bottom corner toward the keyboard's outer edge.
            Text(key.bottom).font(.system(size: 8.5, weight: .regular))
                .frame(maxWidth: .infinity, maxHeight: .infinity,
                       alignment: key.alignLeading ? .bottomLeading : .bottomTrailing)
                .foregroundStyle(Self.ink)
        } else {
            VStack(spacing: 1) {
                Text(key.top).font(.system(size: 10, weight: .light))
                Text(key.bottom).font(.system(size: 12, weight: .light))
            }
            .foregroundStyle(Self.ink)
        }
    }

    /// The inverted-T arrow cluster: half-height left, up, down and right keys.
    private var arrows: some View {
        let half = (unit - 2) / 2
        let w = (SetupKeyboard.width(3) - 2 * gap) / 3
        return HStack(alignment: .bottom, spacing: gap) {
            arrow("arrowtriangle.left.fill").frame(width: w, height: half)
            VStack(spacing: 2) {
                arrow("arrowtriangle.up.fill").frame(width: w, height: half)
                arrow("arrowtriangle.down.fill").frame(width: w, height: half)
            }
            arrow("arrowtriangle.right.fill").frame(width: w, height: half)
        }
        .frame(maxHeight: .infinity, alignment: .bottom)
    }

    private func arrow(_ name: String) -> some View {
        let small = RoundedRectangle(cornerRadius: 5, style: .continuous)
        return ZStack {
            small.fill(Self.face)
            small.strokeBorder(.white.opacity(0.045), lineWidth: 0.75)
            Image(systemName: name).font(.system(size: 6)).foregroundStyle(Self.ink)
        }
    }
}

/// Space-grey aluminium around a black keyboard well, as on the MacBook Pro.
private struct KeyboardDeck: View {
    var body: some View {
        let chassis = RoundedRectangle(cornerRadius: 18, style: .continuous)
        let well = RoundedRectangle(cornerRadius: 10, style: .continuous)
        ZStack {
            chassis
                .fill(LinearGradient(colors: [Color(white: 0.24), Color(white: 0.2)],
                                     startPoint: .top, endPoint: .bottom))
                .overlay(chassis.strokeBorder(.white.opacity(0.08), lineWidth: 0.75))
                .padding(-16)
            well.fill(Color(white: 0.02))
                .overlay(well.strokeBorder(.black.opacity(0.6), lineWidth: 1))
        }
    }
}
