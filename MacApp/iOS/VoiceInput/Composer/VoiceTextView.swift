import SwiftUI
import UIKit

/// Multi-line text view that writes dictated text at the cursor it was dictated from.
/// Wraps UITextView because SwiftUI's TextField can't replace a range in place.
struct VoiceTextView: UIViewRepresentable {
    let model: ComposerModel
    // Passed in (not read from the model here) so the parent re-renders when they change.
    let text: String
    let focusRequest: Int

    private static let maxLines: CGFloat = 4

    func makeCoordinator() -> Coordinator {
        Coordinator(model: model)
    }

    func makeUIView(context: Context) -> UITextView {
        let textView = UITextView()
        textView.font = .preferredFont(forTextStyle: .body)
        textView.adjustsFontForContentSizeCategory = true
        textView.backgroundColor = .clear
        textView.isScrollEnabled = false
        textView.keyboardDismissMode = .interactive
        textView.textContainer.lineFragmentPadding = 0
        textView.textContainerInset = UIEdgeInsets(top: 10, left: 12, bottom: 10, right: 4)
        textView.setContentHuggingPriority(.defaultLow, for: .horizontal)
        textView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        textView.delegate = context.coordinator
        let dismissSwipe = UISwipeGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.swipeToDismiss(_:)))
        dismissSwipe.direction = .down
        dismissSwipe.cancelsTouchesInView = false
        dismissSwipe.delegate = context.coordinator
        textView.addGestureRecognizer(dismissSwipe)
        context.coordinator.attach(to: textView)
        return textView
    }

    func updateUIView(_ textView: UITextView, context: Context) {
        if textView.text != text {
            textView.text = text
        }
        context.coordinator.apply(focusRequest: focusRequest)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextView, context: Context) -> CGSize? {
        let width = proposal.width.flatMap { $0.isFinite && $0 > 0 ? $0 : nil } ?? 240
        let fitting = uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        let lineHeight = uiView.font?.lineHeight ?? UIFont.preferredFont(forTextStyle: .body).lineHeight
        let insets = uiView.textContainerInset
        let maxHeight = ceil(lineHeight * Self.maxLines + insets.top + insets.bottom)
        let scrolls = fitting.height > maxHeight
        if uiView.isScrollEnabled != scrolls {
            uiView.isScrollEnabled = scrolls
        }
        return CGSize(width: width, height: min(fitting.height, maxHeight))
    }

    @MainActor
    final class Coordinator: NSObject, UITextViewDelegate, UIGestureRecognizerDelegate, DictationTextTarget {
        private let model: ComposerModel
        private weak var textView: UITextView?
        private var handledFocusRequest = 0
        private var focusGeneration = 0
        /// Where the transcript will be written, and the separator placed before it.
        private var dictationRange: NSRange?
        private var dictationPrefix = ""

        init(model: ComposerModel) {
            self.model = model
        }

        func attach(to textView: UITextView) {
            self.textView = textView
            model.textTarget = self
        }

        func apply(focusRequest: Int) {
            guard focusRequest != handledFocusRequest else { return }
            handledFocusRequest = focusRequest
            guard let textView, !textView.isFirstResponder else { return }
            // Not during a SwiftUI update pass.
            let generation = focusGeneration
            Task { @MainActor [weak self, weak textView] in
                guard let self, self.focusGeneration == generation else { return }
                _ = textView?.becomeFirstResponder()
            }
        }

        // MARK: UITextViewDelegate

        func textViewDidBeginEditing(_ textView: UITextView) {
            model.keyboardFocusChanged(true)
        }

        func textViewDidEndEditing(_ textView: UITextView) {
            model.keyboardFocusChanged(false)
        }

        @objc func swipeToDismiss(_ recognizer: UISwipeGestureRecognizer) {
            if recognizer.state == .ended { dismissKeyboard() }
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
            true
        }

        func textViewDidChange(_ textView: UITextView) {
            model.draft = textView.text
        }

        /// Typing is paused while dictating, so the insertion point stays valid.
        func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
            dictationRange == nil
        }

        // MARK: DictationTextTarget

        func dismissKeyboard() {
            // Invalidate any focus request queued by a dictation start.
            focusGeneration += 1
            textView?.resignFirstResponder()
        }

        func beginDictation() {
            guard let textView else { return }
            let selection = textView.selectedRange
            if selection.length > 0 {
                replace(selection, with: "")
            }
            let location = selection.location
            dictationPrefix = needsSeparator(before: location, in: textView) ? " " : ""
            dictationRange = NSRange(location: location, length: 0)
        }

        func endDictation(keeping text: String?) {
            if let range = dictationRange {
                replace(range, with: text.map { dictationPrefix + $0 } ?? "")
            }
            dictationRange = nil
        }

        @discardableResult
        private func replace(_ range: NSRange, with string: String) -> NSRange {
            guard let textView else { return range }
            let storage = textView.textStorage
            let safe = NSIntersectionRange(range, NSRange(location: 0, length: storage.length))
            storage.replaceCharacters(in: safe, with: NSAttributedString(string: string, attributes: textView.typingAttributes))
            let written = NSRange(location: safe.location, length: (string as NSString).length)
            textView.selectedRange = NSRange(location: NSMaxRange(written), length: 0)
            textView.scrollRangeToVisible(textView.selectedRange)
            model.draft = textView.text
            return written
        }

        private func needsSeparator(before location: Int, in textView: UITextView) -> Bool {
            guard location > 0 else { return false }
            let text = textView.text as NSString
            let previous = text.substring(with: NSRange(location: location - 1, length: 1))
            return previous.rangeOfCharacter(from: .whitespacesAndNewlines) == nil
        }
    }
}
