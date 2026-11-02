import AppKit
import SwiftUI
import VoiceLabCore

/// One recording card: the text first, a small timestamp beneath it, and Copy/Edit
/// that appear only while the card is hovered (or an action has keyboard focus).
struct HistoryRow: View {
    let transcript: Transcript
    let edit: () -> Void
    @State private var hovered = false
    /// Briefly true after Copy, so the button confirms with a check.
    @State private var copied = false
    @State private var resetCopied: Task<Void, Never>?
    @FocusState private var actionFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var showsActions: Bool { hovered || actionFocused || copied }

    var body: some View {
        // Text and time on the left; Copy and Edit vertically centred on the right.
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 8) {
                Text(transcript.text)
                    .font(.system(size: 14)).lineSpacing(4).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                Text(transcript.createdAt, format: .dateTime.hour().minute())
                    .font(.system(size: 11)).monospacedDigit().foregroundStyle(.secondary)
                    .help(AppLocalization.speechLanguage(transcript) + " · "
                          + AppLocalization.text("%d s", transcript.durationMS / 1000))
            }
            HStack(spacing: 2) {
                Button(action: copy) {
                    ZStack {
                        WorkspaceAssetIcon(name: .copy, size: 15)
                            .opacity(copied ? 0 : 1)
                            .scaleEffect(copied && !reduceMotion ? 0.6 : 1)
                        Image(systemName: "checkmark")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(.green)
                            .opacity(copied ? 1 : 0)
                            .scaleEffect(copied || reduceMotion ? 1 : 0.4)
                    }
                    .frame(width: 18, height: 18)
                }
                .help(AppLocalization.text(copied ? "Nusxalandi" : "Nusxalash"))
                .accessibilityLabel(AppLocalization.text(copied ? "Nusxalandi" : "Matnni nusxalash"))
                Button(action: edit) {
                    WorkspaceAssetIcon(name: .edit, size: 15).frame(width: 18, height: 18)
                }
                .help(AppLocalization.text("Tahrirlash"))
                .accessibilityLabel(AppLocalization.text("Matnni tahrirlash"))
            }
            .buttonStyle(.echoPlain)
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .focused($actionFocused)
            // Hidden buttons keep their space, so revealing them never reflows the text.
            .opacity(showsActions ? 1 : 0)
        }
        .padding(.horizontal, 18).padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        .animation(reduceMotion ? nil : .snappy(duration: 0.14), value: showsActions)
        .onDisappear { resetCopied?.cancel() }
    }

    /// Copies, then pops a green check in place of the icon for a moment.
    private func copy() {
        TextInsertion.copy(transcript.text)
        NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
        withAnimation(reduceMotion ? .easeOut(duration: 0.12) : .spring(response: 0.28, dampingFraction: 0.55)) {
            copied = true
        }
        resetCopied?.cancel()
        resetCopied = Task {
            try? await Task.sleep(for: .seconds(1.4))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.2)) { copied = false }
        }
    }
}
