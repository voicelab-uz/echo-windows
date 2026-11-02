import AppKit
import SwiftUI

/// Apple-style inline shortcut recorder: click the field, press a key, done.
/// Esc or clicking elsewhere cancels; a lone Delete resets to fn. Only keys typed
/// while the field is recording are read, never global typing.
struct ShortcutField: View {
    let model: AppModel
    /// Reports a rejected key so the row can explain why, or nil once it is resolved.
    let onError: (String?) -> Void
    @Environment(\.dictationShortcut) private var shortcut
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var recording = false
    /// A modifier pressed on its own; saved on release unless a key joins it first.
    @State private var pendingModifier: DictationShortcut?
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 6) {
            Button(action: toggleRecording) {
                Text(recording ? AppLocalization.text("Tugmalarni bosing…") : shortcut.displayName)
                    .font(.system(size: 13, weight: recording ? .regular : .medium))
                    .foregroundStyle(recording ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                    .lineLimit(1)
                    .frame(minWidth: 112, minHeight: 26)
                    .padding(.horizontal, 10)
                    .background(
                        Color.primary.opacity(recording ? 0.03 : hovering ? 0.1 : 0.065),
                        in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .strokeBorder(Design.tint, lineWidth: recording ? 2 : 0)
                    }
                    .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .background {
                        if recording {
                            ShortcutCaptureView(onKey: handleKey, onFlags: handleFlags, onOutsideClick: cancel)
                        }
                    }
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .disabled(model.dictation.isBusy && !recording)
            .accessibilityLabel(AppLocalization.text("Global shortcut"))
            .accessibilityValue(recording ? AppLocalization.text("Tugmalarni bosing…") : shortcut.displayName)
            if !recording {
                // One looped arrow: record the shortcut again. (Delete while recording resets to fn.)
                Button(action: toggleRecording) {
                    Image(systemName: "arrow.clockwise").font(.system(size: 11, weight: .semibold))
                        .frame(width: 18, height: 18)
                }
                .buttonStyle(.echoPlain).foregroundStyle(.secondary)
                .disabled(model.dictation.isBusy)
                .help(AppLocalization.text("Shortcutni qayta yozish"))
                .accessibilityLabel(AppLocalization.text("Shortcutni qayta yozish"))
                .transition(.opacity)
            }
        }
        .animation(reduceMotion ? nil : .snappy(duration: 0.16), value: recording)
        .animation(reduceMotion ? nil : .snappy(duration: 0.14), value: hovering)
        .onDisappear { if recording { cancel() } }
    }

    private func toggleRecording() {
        if recording { return cancel() }
        do {
            try model.beginShortcutRecording()
            pendingModifier = nil
            onError(nil)
            recording = true
        } catch { onError(AppLocalization.error(error)) }
    }

    private func handleKey(_ event: NSEvent) {
        guard !event.isARepeat else { return }
        pendingModifier = nil
        let modifiers = event.modifierFlags.intersection(DictationShortcut.modifierMask)
        if event.keyCode == 53 { return cancel() }
        if event.keyCode == 51, modifiers.isEmpty { return save(.fn) }
        if let candidate = DictationShortcut.capture(event) {
            save(candidate)
        } else {
            onError(AppLocalization.text(
                "Boshqa tugmani tanlang. Harf va raqamlar uchun ⌘, ⌥ yoki ⌃ kerak; tizim tugmalari band."))
        }
    }

    private func handleFlags(_ event: NSEvent) {
        if let modifier = DictationShortcut.captureModifier(event) {
            pendingModifier = modifier
        } else if event.modifierFlags.intersection(DictationShortcut.modifierMask.union(.function)).isEmpty,
            let modifier = pendingModifier
        {
            // Every key is up and nothing joined the modifier: it is the shortcut.
            save(modifier)
        }
    }

    private func save(_ candidate: DictationShortcut) {
        do {
            try model.changeShortcut(candidate)
            onError(nil)
        } catch { onError(AppLocalization.error(error)) }
        finish()
    }

    private func cancel() { finish() }

    private func finish() {
        recording = false
        pendingModifier = nil
        model.endShortcutRecording()
    }
}

/// Reads key and modifier events for this window through a local monitor while recording,
/// and reports clicks anywhere outside the field so recording can be cancelled.
private struct ShortcutCaptureView: NSViewRepresentable {
    let onKey: (NSEvent) -> Void
    let onFlags: (NSEvent) -> Void
    let onOutsideClick: () -> Void

    func makeNSView(context: Context) -> CaptureView {
        let view = CaptureView()
        update(view)
        return view
    }
    func updateNSView(_ view: CaptureView, context: Context) { update(view) }
    static func dismantleNSView(_ view: CaptureView, coordinator: ()) { view.stopMonitoring() }

    private func update(_ view: CaptureView) {
        view.onKey = onKey
        view.onFlags = onFlags
        view.onOutsideClick = onOutsideClick
    }

    final class CaptureView: NSView {
        var onKey: ((NSEvent) -> Void)?
        var onFlags: ((NSEvent) -> Void)?
        var onOutsideClick: (() -> Void)?
        private var monitor: Any?
        override var acceptsFirstResponder: Bool { true }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stopMonitoring()
            guard let window else { return }
            window.makeFirstResponder(self)
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged, .leftMouseDown]) {
                [weak self] event in
                // AppKit delivers local monitors on the main thread.
                let consumed = MainActor.assumeIsolated { () -> Bool in
                    guard let self, event.window === self.window else { return false }
                    switch event.type {
                    case .flagsChanged:
                        self.onFlags?(event)
                        return false
                    case .leftMouseDown:
                        // The field's own button toggles recording; anywhere else cancels.
                        let point = self.convert(event.locationInWindow, from: nil)
                        if !self.bounds.contains(point) { self.onOutsideClick?() }
                        return false
                    default:
                        self.onKey?(event)
                        // Consumed: the recorder owns every key typed while recording.
                        return true
                    }
                }
                return consumed ? nil : event
            }
        }

        func stopMonitoring() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }
    }
}
