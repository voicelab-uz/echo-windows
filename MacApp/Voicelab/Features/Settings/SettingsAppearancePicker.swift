import SwiftUI

/// Small native previews keep appearance choices readable without external artwork.
struct SettingsAppearancePicker: View {
    @Binding var selection: String
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// One reveal per preview, so the circle grows from the preview that was clicked,
    /// just like the toolbar's theme button.
    @State private var transitions = ["system": AppearanceTransition(), "light": AppearanceTransition(),
                                      "dark": AppearanceTransition()]

    /// The look a choice produces right now; "system" follows macOS.
    private func resolved(_ value: String) -> String {
        guard value == "system" else { return value }
        return UserDefaults.standard.string(forKey: "AppleInterfaceStyle") == "Dark" ? "dark" : "light"
    }

    private func choose(_ value: String) {
        guard value != selection else { return }
        let target = resolved(value)
        let current = colorScheme == .dark ? "dark" : "light"
        guard target != current, let transition = transitions[value] else { selection = value; return }
        transition.change(to: target, reduceMotion: reduceMotion) { selection = value }
    }

    var body: some View {
        // Fixed-size previews pinned to the trailing corner: resizing the window never stretches them.
        HStack(spacing: 12) {
            appearanceOption("system", title: "Tizimga mos")
            appearanceOption("light", title: "Yorug‘")
            appearanceOption("dark", title: "Qorong‘i")
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }

    private static let previewSize = CGSize(width: 150, height: 104)
    /// The previews are static artwork: a fixed VoiceLab blue, so they never shift with
    /// the accent color or the current theme.
    private static let previewBlue = Color(red: 0.24, green: 0.39, blue: 0.95)

    private func appearanceOption(_ value: String, title: String) -> some View {
        Button { choose(value) } label: {
            VStack(spacing: 10) {
                preview(value)
                    .frame(width: Self.previewSize.width, height: Self.previewSize.height)
                    .background { if let transition = transitions[value] { AppearanceTransitionAnchor(transition: transition) } }
                    .clipShape(RoundedRectangle(cornerRadius: 9))
                    .overlay {
                        RoundedRectangle(cornerRadius: 9)
                            .strokeBorder(selection == value ? Design.tint : Design.border, lineWidth: selection == value ? 2 : 1)
                    }
                // Same weight in every state so switching themes never shifts the label.
                Text(AppLocalization.text(title)).font(.system(size: 12))
                    .foregroundStyle(selection == value ? Design.accent : Design.accent.opacity(0.55))
                    .lineLimit(1).minimumScaleFactor(0.8)
                    .frame(width: Self.previewSize.width)
            }.fixedSize().contentShape(Rectangle())
        }
        .buttonStyle(StaticPreviewButtonStyle())
        .modifier(PointingHandCursor())
        .accessibilityLabel(AppLocalization.text(title))
        .accessibilityAddTraits(selection == value ? .isSelected : [])
    }

    private func preview(_ value: String) -> some View {
        GeometryReader { geometry in
            if value == "system" {
                // Never stack the full light window under the dark half: its antialiased
                // clip edge would bleed through as a light hairline. The light half only
                // overlaps the seam by a point so the halves meet without a gap.
                let half = (geometry.size.width / 2).rounded()
                ZStack {
                    miniWindow(dark: false)
                        .mask(alignment: .leading) { Rectangle().frame(width: half + 1) }
                    miniWindow(dark: true)
                        .mask(alignment: .trailing) { Rectangle().frame(width: geometry.size.width - half) }
                }
            } else {
                miniWindow(dark: value == "dark")
            }
        }.accessibilityHidden(true)
    }

    /// A tiny Echo window: traffic lights, a sidebar with a selected item, a title, a strip
    /// of stat cards and two recording rows, drawn in the light or dark palette.
    private func miniWindow(dark: Bool) -> some View {
        let ink = dark ? Color.white : Color.black
        let sidebar = dark ? Color(white: 0.15) : Color(white: 0.92)
        let canvas = dark ? Color(white: 0.1) : Color(white: 0.985)
        let card = dark ? Color(white: 0.19) : Color.white
        return HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 2.5) {
                    Circle().fill(Color(red: 1, green: 0.37, blue: 0.34))
                    Circle().fill(Color(red: 1, green: 0.74, blue: 0.18))
                    Circle().fill(Color(red: 0.16, green: 0.79, blue: 0.25))
                }
                .frame(width: 18, height: 4.5).padding(.bottom, 5)
                ForEach(0..<4) { index in
                    HStack(spacing: 3) {
                        RoundedRectangle(cornerRadius: 1)
                            .fill(index == 0 ? Self.previewBlue : ink.opacity(0.22)).frame(width: 4, height: 4)
                        RoundedRectangle(cornerRadius: 1)
                            .fill(index == 0 ? ink.opacity(0.55) : ink.opacity(0.16)).frame(width: 18, height: 3)
                    }
                    .padding(.horizontal, 3).frame(height: 8, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(index == 0 ? Self.previewBlue.opacity(dark ? 0.28 : 0.16) : .clear,
                                in: RoundedRectangle(cornerRadius: 2.5))
                }
                Spacer(minLength: 0)
                HStack(spacing: 3) {
                    Circle().strokeBorder(Self.previewBlue, lineWidth: 1).frame(width: 7, height: 7)
                    RoundedRectangle(cornerRadius: 1).fill(ink.opacity(0.18)).frame(width: 14, height: 3)
                }
            }
            .padding(7).frame(width: 46)
            .background(sidebar)
            VStack(alignment: .leading, spacing: 6) {
                RoundedRectangle(cornerRadius: 1.5).fill(ink.opacity(0.7)).frame(width: 34, height: 5)
                HStack(spacing: 4) {
                    ForEach(0..<3) { index in
                        VStack(alignment: .leading, spacing: 2.5) {
                            RoundedRectangle(cornerRadius: 1)
                                .fill(index == 0 ? Self.previewBlue : ink.opacity(0.5)).frame(width: 11, height: 4)
                            RoundedRectangle(cornerRadius: 1).fill(ink.opacity(0.14)).frame(width: 15, height: 2.5)
                        }
                        .padding(4).frame(maxWidth: .infinity, alignment: .leading)
                        .background(card, in: RoundedRectangle(cornerRadius: 3))
                    }
                }
                ForEach(0..<2) { index in
                    HStack(spacing: 4) {
                        VStack(alignment: .leading, spacing: 2.5) {
                            RoundedRectangle(cornerRadius: 1).fill(ink.opacity(0.28)).frame(height: 3)
                            RoundedRectangle(cornerRadius: 1).fill(ink.opacity(0.16)).frame(width: 30, height: 3)
                        }
                        Capsule().fill(index == 0 ? Self.previewBlue : ink.opacity(0.2)).frame(width: 11, height: 6)
                    }
                    .padding(5)
                    .background(card, in: RoundedRectangle(cornerRadius: 3.5))
                }
                Spacer(minLength: 0)
            }
            .padding(8)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(canvas)
        }
    }
}

/// Accent swatches like System Settings: VoiceLab, follow macOS, then the macOS palette.
/// The chosen swatch gets a ring and its name underneath, exactly like System Settings.
struct AccentColorPicker: View {
    @Bindable var accent: AppAccent
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            ForEach(AppAccent.Choice.allCases) { choice in
                let selected = accent.choice == choice
                Button { accent.choice = choice } label: {
                    VStack(spacing: 5) {
                        swatch(choice)
                            .frame(width: 20, height: 20)
                            .overlay(Circle().strokeBorder(.black.opacity(0.12), lineWidth: 0.5))
                            .padding(3)
                            .overlay {
                                Circle().strokeBorder(choice.color.opacity(choice == .system ? 0.6 : 1),
                                                      lineWidth: selected ? 2 : 0)
                            }
                        // Reserve the label's line for every swatch so selecting never shifts the row.
                        Text(AppLocalization.text(choice.title))
                            .font(.system(size: 10)).foregroundStyle(.secondary)
                            .lineLimit(1).fixedSize()
                            .opacity(selected ? 1 : 0)
                            .frame(width: 26)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .modifier(PointingHandCursor())
                .help(AppLocalization.text(choice.title))
                .accessibilityLabel(AppLocalization.text(choice.title))
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .animation(reduceMotion ? nil : .snappy(duration: 0.16), value: accent.choice)
    }

    @ViewBuilder private func swatch(_ choice: AppAccent.Choice) -> some View {
        if choice == .system {
            // A multicolor wheel signals "whatever macOS uses".
            Circle().fill(AngularGradient(
                colors: [.red, .orange, .yellow, .green, .teal, .blue, .purple, .pink, .red], center: .center))
        } else {
            Circle().fill(choice.color)
        }
    }
}

/// No press dimming: clicking a theme only moves the selection ring.
private struct StaticPreviewButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { configuration.label }
}

/// Clickable swatches and previews show the pointing hand, never a text cursor.
struct PointingHandCursor: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 15.0, *) {
            content.pointerStyle(.link)
        } else {
            content.onHover { inside in
                if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
            }
        }
    }
}
