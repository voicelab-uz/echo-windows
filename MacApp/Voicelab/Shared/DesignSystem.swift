import SwiftUI

enum Design {
    static let accent = Color("WorkspaceAccent")
    /// Echo’s interactive color, chosen in Settings → General (VoiceLab blue by default).
    @MainActor static var tint: Color { AppAccent.shared.color }
    static let green = Color(nsColor: .systemGreen)
    static let border = Color.primary.opacity(0.08)
    static let surface = Color("WorkspaceSurface")
    static let canvas = Color("WorkspaceCanvas")
    static let sidebar = Color("WorkspaceSidebar")
    static let selection = Color("WorkspaceSelection")
    static let cornerRadius: CGFloat = 12
}

struct WorkspaceBackground: View {
    var body: some View {
        Design.canvas.ignoresSafeArea()
    }
}

struct WorkspaceIcon: View {
    let symbol: String
    var size: CGFloat = 42
    var tint: Color = Design.accent
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        AppIcon(systemName: symbol, size: size * 0.43)
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(tint)
            .frame(width: size, height: size)
            .background(tint.opacity(0.045), in: RoundedRectangle(cornerRadius: size * 0.25))
            .contentTransition(reduceMotion ? .identity : .opacity)
            .accessibilityHidden(true)
    }
}

struct WorkspaceSearchField: View {
    let prompt: String
    @Binding var text: String
    /// A hairline border, for when the field sits on a busy surface like the toolbar.
    var outlined = false
    var body: some View {
        HStack(spacing: 8) {
            WorkspaceAssetIcon(name: .search, size: 15).foregroundStyle(.secondary)
            TextField(prompt, text: $text).textFieldStyle(.plain)
                .accessibilityLabel(prompt)
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    AppIcon(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }.buttonStyle(.plain).accessibilityLabel(AppLocalization.text("Qidiruvni tozalash"))
            }
        }
        .font(.system(size: 12))
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(.fill.quaternary, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            if outlined {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.75)
            }
        }
    }
}

struct PageHeading: View {
    let title: String
    let subtitle: String
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.system(size: 26, weight: .semibold)).tracking(-0.5)
            Text(subtitle).font(.system(size: 13)).foregroundStyle(.secondary).lineSpacing(4)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct Surface<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        content.padding(20)
            .background(Design.surface, in: RoundedRectangle(cornerRadius: Design.cornerRadius))
            .overlay(
                RoundedRectangle(cornerRadius: Design.cornerRadius)
                    .strokeBorder(Design.border, lineWidth: 0.5)
            )
    }
}

struct ErrorBanner: View {
    let message: String
    var dismiss: (() -> Void)?
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            AppIcon(systemName: "exclamationmark.circle").foregroundStyle(.orange)
            Text(AppLocalization.text(message)).font(.callout).textSelection(.enabled).frame(
                maxWidth: .infinity, alignment: .leading)
            if let dismiss {
                Button(action: dismiss) { AppIcon(systemName: "xmark") }.buttonStyle(.plain)
                    .accessibilityLabel(
                        AppLocalization.text("Yopish"))
            }
        }.padding(14).background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    }
}

struct EmptyContent: View {
    let symbol: String
    let title: String
    let subtitle: String
    var body: some View {
        VStack(spacing: 14) {
            WorkspaceIcon(symbol: symbol, size: 64)
            Text(title).font(.title3.weight(.semibold))
            Text(subtitle).font(.callout).foregroundStyle(.secondary).lineSpacing(4)
                .multilineTextAlignment(.center).frame(maxWidth: 360)
        }.frame(maxWidth: .infinity).padding(.vertical, 48)
    }
}

struct ShortcutLabel: View {
    @Environment(\.dictationShortcut) private var shortcut
    var body: some View {
        AppLabel(shortcut.displayName, systemImage: shortcut.isFn ? "globe" : "keyboard")
            .font(.system(size: 11, weight: .medium))
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Design.border, lineWidth: 0.5))
            .accessibilityLabel(shortcut.isFn ? "Fn / Globe" : shortcut.displayName)
    }
}

/// A search that rests as a small magnifier and grows into a field when clicked.
/// It folds back once it loses focus while empty. The outer frame never changes, so the
/// toolbar host keeps a stable size while the field animates inside it.
struct ExpandingSearchField: View {
    let prompt: String
    @Binding var text: String
    var width: CGFloat = 220
    @State private var expanded = false
    @FocusState private var focused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var isOpen: Bool { expanded || !text.isEmpty }

    var body: some View {
        HStack(spacing: 8) {
            Button { open() } label: {
                WorkspaceAssetIcon(name: .search, size: 15).foregroundStyle(Design.tint)
                    .frame(width: 18, height: 18).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(prompt).accessibilityLabel(prompt)
            if isOpen {
                TextField(prompt, text: $text).textFieldStyle(.plain)
                    .focused($focused)
                    .onSubmit { focused = true }
                    .onExitCommand { text = ""; focused = false }
                    .accessibilityLabel(prompt)
                    .transition(.opacity)
                if !text.isEmpty {
                    Button { text = "" } label: {
                        AppIcon(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain).accessibilityLabel(AppLocalization.text("Qidiruvni tozalash"))
                }
            }
        }
        .font(.system(size: 12))
        .padding(.horizontal, isOpen ? 10 : 7).frame(height: 30)
        .frame(width: isOpen ? width : 32, alignment: .leading)
        .background(isOpen ? AnyShapeStyle(.fill.quaternary) : AnyShapeStyle(.clear),
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.primary.opacity(isOpen ? 0.12 : 0), lineWidth: 0.75)
        }
        .clipped()
        // A click anywhere else folds an empty search back to its icon.
        .background { if isOpen { OutsideClickMonitor { if text.isEmpty { close() } } } }
        .frame(width: width, alignment: .trailing)
        .animation(reduceMotion ? nil : .smooth(duration: 0.32), value: isOpen)
        .onChange(of: focused) { _, isFocused in
            if !isFocused && text.isEmpty { expanded = false }
        }
    }

    private func close() {
        focused = false
        expanded = false
    }

    private func open() {
        expanded = true
        // Focus after the field exists in the hierarchy.
        Task { @MainActor in focused = true }
    }
}

/// Reports left clicks in the same window that land outside this view's bounds.
struct OutsideClickMonitor: NSViewRepresentable {
    let onOutsideClick: () -> Void

    func makeNSView(context: Context) -> MonitorView {
        let view = MonitorView()
        view.onOutsideClick = onOutsideClick
        return view
    }
    func updateNSView(_ view: MonitorView, context: Context) { view.onOutsideClick = onOutsideClick }
    static func dismantleNSView(_ view: MonitorView, coordinator: ()) { view.stop() }

    final class MonitorView: NSView {
        var onOutsideClick: (() -> Void)?
        private var monitor: Any?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stop()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
                MainActor.assumeIsolated {
                    guard let self, event.window === self.window else { return }
                    let point = self.convert(event.locationInWindow, from: nil)
                    if !self.bounds.contains(point) { self.onOutsideClick?() }
                }
                return event
            }
        }

        func stop() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }
    }
}
