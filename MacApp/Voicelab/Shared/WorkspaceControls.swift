import SwiftUI

enum WorkspaceMotion {
    static let layout = Animation.spring(duration: 0.38, bounce: 0)
    static let selection = Animation.smooth(duration: 0.24)
    static let feedback = Animation.easeOut(duration: 0.16)
}

/// Small controls share the same native glass treatment and motion settings.
struct WorkspaceGlassButtonStyle: ButtonStyle {
    var compact = false
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .padding(.horizontal, compact ? 9 : 14)
            .frame(height: compact ? 30 : 36)
            .contentShape(Capsule())
            .modifier(NativeGlass(radius: 20, interactive: isEnabled))
            .opacity(isEnabled ? 1 : 0.4)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.96 : 1)
            .animation(reduceMotion ? nil : WorkspaceMotion.feedback, value: configuration.isPressed)
    }
}

struct WorkspaceSidebarToggle: View {
    let isExpanded: Bool
    let action: () -> Void
    private var label: String {
        AppLocalization.text(isExpanded ? "Yon menyuni yashirish" : "Yon menyuni ko‘rsatish")
    }

    var body: some View {
        Button(action: action) {
            // The icon alone reflects the state; hovering never stretches the button.
            WorkspaceAssetIcon(name: isExpanded ? .sidebarOpen : .sidebarClosed, size: 19)
                .frame(width: 36, height: 34)
                .contentShape(Capsule())
                .modifier(NativeGlass(radius: 20, interactive: true))
        }
        .buttonStyle(.plain)
        .frame(width: 36, height: 36)
        .help(label).accessibilityLabel(label)
        .accessibilityValue(AppLocalization.text(isExpanded ? "Ochiq" : "Yopiq"))
        .keyboardShortcut("s", modifiers: [.control, .command])
    }
}
