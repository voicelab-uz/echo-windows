import SwiftUI

/// The dictation keys offered during setup. Production maps each to a real shortcut.
enum OnboardingKeyChoice: String, CaseIterable, Identifiable {
    case fn, rightCommand, rightOption, custom
    var id: String { rawValue }

    /// The physical key code to watch locally, so the key lights up even before the
    /// system-wide shortcut reports it. Custom relies on the registered shortcut only.
    var keyCode: UInt16? {
        switch self {
        case .fn: 63
        case .rightCommand: 54
        case .rightOption: 61
        case .custom: nil
        }
    }

    func title(in copy: SetupCopy) -> String {
        switch self {
        case .fn: copy.keyFn
        case .rightCommand: copy.keyCommand
        case .rightOption: copy.keyOption
        case .custom: copy.keyCustom
        }
    }
}

/// Wispr-style key picker: a row of keycaps, the chosen one glowing softly, a press-to-test
/// line, and a note that hold/toggle behavior lives in Settings.
struct SetupKeyChooser: View {
    let language: WelcomeLanguage
    @Binding var choice: OnboardingKeyChoice
    @Binding var validation: SetupShortcutValidation
    var customRecorder: AnyView? = nil
    var shortcutError: String? = nil
    var onRetry: (() -> Void)? = nil
    var onOpenSettings: (() -> Void)? = nil
    @Environment(\.onboardingShortcutLabel) private var shortcut

    private var copy: SetupCopy { language.setupCopy }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            Text(copy.keyIntro)
                .font(WelcomeType.font(size: 15)).foregroundStyle(WelcomePalette.muted)
                .fixedSize(horizontal: false, vertical: true)
            HStack(alignment: .top, spacing: 10) {
                ForEach(OnboardingKeyChoice.allCases) { option in
                    Button {
                        guard choice != option else { return }
                        OnboardingHaptics.play(.selection)
                        validation.release()
                        choice = option
                    } label: {
                        VStack(spacing: 10) {
                            SetupKeycap(option: option, selected: choice == option,
                                        pressed: choice == option && validation.isPressed,
                                        customLabel: option == .custom && choice == .custom ? shortcut : nil)
                            Text(option.title(in: copy))
                                .font(WelcomeType.font(size: 12, weight: .medium))
                                .foregroundStyle(choice == option ? WelcomePalette.ink : WelcomePalette.muted)
                                .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                                .frame(width: 80)
                            // Appears under the key once the user has pressed it.
                            Text(copy.wellDone)
                                .font(WelcomeType.font(size: 13, weight: .semibold))
                                .foregroundStyle(Color(red: 0.30, green: 0.72, blue: 0.46))
                                .lineLimit(1).minimumScaleFactor(0.7).frame(width: 80)
                                .opacity(choice == option && validation.isValidated ? 1 : 0)
                                .offset(y: choice == option && validation.isValidated ? 0 : -4)
                                .accessibilityHidden(!(choice == option && validation.isValidated))
                        }
                        .contentShape(.rect)
                    }
                    .buttonStyle(SetupKeyButtonStyle())
                    .accessibilityLabel(option.title(in: copy))
                    .accessibilityAddTraits(choice == option ? .isSelected : [])
                    .accessibilityIdentifier("setup-key-\(option.rawValue)")
                }
            }
            // Space for the custom recorder is always reserved, so choosing Custom
            // never pushes the rest of the page around.
            ZStack(alignment: .leading) {
                if choice == .custom, let customRecorder {
                    customRecorder.transition(.opacity)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
            .animation(.easeOut(duration: 0.15), value: choice)
            Text(copy.shortcutHint)
                .font(WelcomeType.font(size: 14, weight: .medium))
                .foregroundStyle(WelcomePalette.muted)
                .opacity(validation.isValidated ? 0 : 1)
                .animation(.easeOut(duration: 0.18), value: validation.isValidated)
            if let shortcutError {
                VStack(alignment: .leading, spacing: 10) {
                    Text(shortcutError).font(WelcomeType.font(size: 12)).foregroundStyle(WelcomePalette.muted)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 20) {
                        if let onRetry { Button(language.permissionsCopy.checkAgain, action: onRetry) }
                        if let onOpenSettings {
                            Button(language.permissionsCopy.settings.systemSettings, action: onOpenSettings)
                        }
                    }
                    .font(WelcomeType.font(size: 12, weight: .semibold)).buttonStyle(.plain)
                }
            }
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "info.circle").font(.system(size: 14)).foregroundStyle(WelcomePalette.muted)
                Text(copy.behaviorNote)
                    .font(WelcomeType.font(size: 12)).foregroundStyle(WelcomePalette.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 14).padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(WelcomePalette.ink.opacity(0.04), in: .rect(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(WelcomePalette.ink.opacity(0.08)))
            .accessibilityElement(children: .combine)
        }
        .animation(.easeOut(duration: 0.25), value: validation.isValidated)
        .background {
            OnboardingFnInput(acceptsLocalFn: choice == .fn) { keyCode, functionDown, isFocused in
                guard shortcutError == nil else { validation.release(); return }
                // 63 also carries the registered shortcut's own press; the chosen key's
                // local press is translated so both drive the same validation.
                guard keyCode == 63 || keyCode == choice.keyCode else { return }
                let keyCode: UInt16 = 63
                let wasValidated = validation.isValidated
                if validation.receive(keyCode: keyCode, functionDown: functionDown, isFocused: isFocused),
                   !wasValidated {
                    OnboardingHaptics.play(.confirmation)
                }
            }
            .frame(width: 0, height: 0)
        }
        .onDisappear { validation.release() }
    }
}

/// A dark keyboard key. The chosen key gets a blue ring just outside its edge, like a focus
/// ring; the face itself never lights. Holding the key brightens the ring over 350 ms.
private struct SetupKeycap: View {
    let option: OnboardingKeyChoice
    let selected: Bool
    let pressed: Bool
    var customLabel: String?

    private static let glow = Color(red: 0.42, green: 0.62, blue: 1.0)
    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: 12, style: .continuous) }

    var body: some View {
        ZStack {
            shape.fill(Color(white: 0.07))
            shape.strokeBorder(.white.opacity(0.08), lineWidth: 1)
            content.foregroundStyle(.white).padding(.horizontal, 8).padding(.vertical, 10)
        }
        .frame(width: 72, height: 62)
        .padding(4)
        .overlay {
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .strokeBorder(Self.glow.opacity(pressed ? 1 : 0.7), lineWidth: pressed ? 2.5 : 2)
                .shadow(color: Self.glow.opacity(pressed ? 0.9 : 0.4), radius: pressed ? 8 : 3)
                .opacity(selected ? 1 : 0)
        }
        .animation(.easeInOut(duration: 0.35), value: pressed)
        // A quick cross-fade as the ring moves between keys: fluid, never sluggish.
        .animation(.easeOut(duration: 0.15), value: selected)
    }

    @ViewBuilder private var content: some View {
        switch option {
        case .fn:
            VStack {
                HStack { Spacer(); Text("fn").font(.system(size: 13, weight: .medium)) }
                Spacer()
                HStack { Image(systemName: "globe").font(.system(size: 14)); Spacer() }
            }
        case .rightCommand:
            VStack(alignment: .leading) {
                Text("⌘").font(.system(size: 15))
                Spacer()
                Text("command").font(.system(size: 11, weight: .medium)).lineLimit(1).minimumScaleFactor(0.75)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        case .rightOption:
            VStack(alignment: .leading) {
                Text("⌥").font(.system(size: 15))
                Spacer()
                Text("option").font(.system(size: 11, weight: .medium)).lineLimit(1).minimumScaleFactor(0.75)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        case .custom:
            Text(customLabel ?? "•••")
                .font(.system(size: 15, weight: .semibold))
                .lineLimit(1).minimumScaleFactor(0.5)
        }
    }
}

/// No press effect: clicking a key only moves the selection ring, instantly.
private struct SetupKeyButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { configuration.label }
}
