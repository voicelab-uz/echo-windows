import SwiftUI
import UIKit

/// System-wide keyboard with voice input. Extensions can't use the microphone, so the mic
/// button drives the VoiceInput app through `VoiceBridge` and inserts the transcripts it returns.
final class KeyboardViewController: UIInputViewController {
    private let model = KeyboardModel()
    private var hostingController: UIHostingController<KeyboardView>?

    private var lastSpaceAt = Date.distantPast
    private let dictionary = UzbekKeyboardDictionary()
    private var heightConstraint: NSLayoutConstraint?
    private var candidateContext: String?
    private var candidateDocument: UUID?
    private var correctionUndo: (original: String, inserted: String, before: String, after: String, document: UUID)?
    private var keepOriginalContext: String?
    private var keepOriginalDocument: UUID?
    private var keepOriginalAfter: String?

    private static let keyboardHeight: CGFloat = 264

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        hasDictationKey = true
        model.actions = KeyboardActions(
            insertText: { [weak self] text in self?.insertTypedText(text) },
            insertDictation: { [weak self] text in self?.insertDictation(text) },
            deleteBackward: { [weak self] in
                self?.deleteTypedBackward()
            },
            nextKeyboard: { [weak self] in self?.advanceToNextInputMode() },
            shouldCapitalize: { [weak self] in self?.shouldCapitalize() ?? false },
            openApp: { [weak self] in self?.openVoiceInputApp() ?? false },
            openSettings: { [weak self] in self?.openVoiceInputApp(route: "settings") ?? false },
            openSubscription: { [weak self] in self?.openVoiceInputApp(route: "subscription") ?? false },
            activateKeyboardSession: { [weak self] in self?.openVoiceInputApp(readySession: true) ?? false },
            adjustCursorByCharacterOffset: { [weak self] offset in
                guard let self else { return }
                self.lastSpaceAt = .distantPast
                self.correctionUndo = nil
                self.keepOriginalContext = nil
                self.keepOriginalDocument = nil
                self.keepOriginalAfter = nil
                self.textDocumentProxy.adjustTextPosition(byCharacterOffset: offset)
                self.refreshSuggestions()
            },
            handleInputModeList: { [weak self] sender, event in
                guard let self, let view = sender as? UIView, let event = event as? UIEvent else { return }
                self.handleInputModeList(from: view, with: event)
            },
            insertEmoji: { [weak self] emoji in self?.insertEmoji(emoji) }
        )

        model.chooseSuggestion = { [weak self] in self?.acceptSuggestion($0) }
        model.preferencesChanged = { [weak self] in
            self?.correctionUndo = nil
            self?.keepOriginalContext = nil
            self?.refreshSuggestions()
        }

        let hostingController = UIHostingController(rootView: KeyboardView(model: model))
        hostingController.view.backgroundColor = .clear
        hostingController.view.translatesAutoresizingMaskIntoConstraints = false
        addChild(hostingController)
        view.addSubview(hostingController.view)
        NSLayoutConstraint.activate([
            hostingController.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            hostingController.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            hostingController.view.topAnchor.constraint(equalTo: view.topAnchor),
            hostingController.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        hostingController.didMove(toParent: self)
        self.hostingController = hostingController
        updateKeyboardAppearance()

        let height = view.heightAnchor.constraint(equalToConstant: Self.keyboardHeight)
        height.priority = .defaultHigh
        height.isActive = true
        heightConstraint = height
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        updateKeyboardAppearance()
        model.appeared(hasFullAccess: hasFullAccess, needsGlobe: needsInputModeSwitchKey)
        updateReturnKey()
        refreshSuggestions()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        model.disappeared()
        correctionUndo = nil
        keepOriginalContext = nil
        candidateContext = nil
    }

    override func textDidChange(_ textInput: (any UITextInput)?) {
        super.textDidChange(textInput)
        updateKeyboardAppearance()
        model.refreshShift()
        updateReturnKey()
        validateCorrectionState()
        refreshSuggestions()
    }

    override func selectionDidChange(_ textInput: (any UITextInput)?) {
        super.selectionDidChange(textInput)
        lastSpaceAt = .distantPast
        model.refreshShift()
        updateReturnKey()
        validateCorrectionState()
        refreshSuggestions()
    }

    private func updateKeyboardAppearance() {
        let style = KeyboardAppearance.interfaceStyle(for: textDocumentProxy.keyboardAppearance ?? .default)
        if overrideUserInterfaceStyle != style { overrideUserInterfaceStyle = style }
        if hostingController?.overrideUserInterfaceStyle != style { hostingController?.overrideUserInterfaceStyle = style }
        view.backgroundColor = KeyboardAppearance.keyboardCanvas
    }

    /// Some host apps transiently return nil for UIKit's nonnull NSUUID getter.
    /// Read the Objective-C object before bridging, so field transitions cannot trap.
    private var currentDocumentIdentifier: UUID? {
        KeyboardDocumentIdentity.read(from: textDocumentProxy)
    }

    private func updateReturnKey() {
        let returnType = textDocumentProxy.returnKeyType ?? .default
        model.returnKeySymbol = returnType == .default ? "return" : nil
        model.returnKeyLabel = switch returnType {
        case .go: "Go"
        case .google, .yahoo, .search: "Search"
        case .join: "Join"
        case .next: "Next"
        case .route: "Route"
        case .send: "Send"
        case .done: "Done"
        case .emergencyCall: "Emergency call"
        case .continue: "Continue"
        case .default: "Return"
        @unknown default: "Return"
        }
    }

    /// The familiar two quick spaces → period shortcut, only in prose fields.
    private func insertTypedText(_ text: String) {
        validateCorrectionState()
        correctionUndo = nil
        let beforeInput = textDocumentProxy.documentContextBeforeInput
        if text == " ", predictionAllowed, preference("echo.keyboard.autocorrect"),
           let beforeInput, keepOriginalContext != beforeInput,
           let document = currentDocumentIdentifier,
           let word = editableWord(),
           let corrected = dictionary.correction(for: word, modern: model.usesModernUzbekAlphabet),
           corrected != word {
            replaceTrailingWord(word, with: corrected + " ")
            if let before = textDocumentProxy.documentContextBeforeInput {
                correctionUndo = (word, corrected + " ", before,
                                  textDocumentProxy.documentContextAfterInput ?? "", document)
            }
            keepOriginalContext = nil
            lastSpaceAt = Date.now
            refreshSuggestions()
            return
        }
        keepOriginalContext = nil
        let now = Date.now
        let before = textDocumentProxy.documentContextBeforeInput ?? ""
        let keyboardType = textDocumentProxy.keyboardType ?? .default
        let proseField = keyboardType == .default || keyboardType == .asciiCapable
        let permitsShortcut = proseField && textDocumentProxy.autocorrectionType != .no
        if text == " ", permitsShortcut, now.timeIntervalSince(lastSpaceAt) < 0.4,
           before.hasSuffix(" "), let previous = before.dropLast().last,
           previous.isLetter || previous.isNumber {
            textDocumentProxy.deleteBackward()
            textDocumentProxy.insertText(". ")
            lastSpaceAt = .distantPast
        } else {
            textDocumentProxy.insertText(text)
            lastSpaceAt = text == " " ? now : .distantPast
        }
        refreshSuggestions()
    }

    private func preference(_ key: String) -> Bool {
        (UserDefaults(suiteName: VoiceBridge.appGroup)?.object(forKey: key) as? Bool) ?? true
    }

    private var predictionAllowed: Bool {
        let kind = textDocumentProxy.keyboardType ?? .default
        return model.layout == .uzbek && (kind == .default || kind == .asciiCapable)
            && textDocumentProxy.autocorrectionType != .no && textDocumentProxy.spellCheckingType != .no
            && (textDocumentProxy.selectedText?.isEmpty ?? true)
    }

    /// Only whole prose tokens at the cursor are editable. Never replace part of a URL,
    /// identifier, selected text, or a word with letters remaining after the cursor.
    private func editableWord() -> String? {
        guard predictionAllowed, let before = textDocumentProxy.documentContextBeforeInput else { return nil }
        let after = textDocumentProxy.documentContextAfterInput ?? ""
        let apostrophes = "'’‘ʻʼ"
        if let next = after.first, next.isLetter || next.isNumber || apostrophes.contains(next) { return nil }
        let token = String(before.reversed().prefix { !$0.isWhitespace }.reversed())
        guard !token.isEmpty, token.count <= 40,
              token.allSatisfy({ $0.isLetter || apostrophes.contains($0) }) else { return nil }
        let word = UzbekKeyboardDictionary.trailingWord(in: before)
        return word == token ? word : nil
    }

    private func refreshSuggestions() {
        model.showsSuggestions = predictionAllowed && preference("echo.keyboard.suggestions")
        heightConstraint?.constant = Self.keyboardHeight
        model.suggestions = []
        model.typedWord = ""
        candidateContext = nil
        candidateDocument = nil
        guard model.showsSuggestions, let document = currentDocumentIdentifier,
              let word = editableWord() else { return }
        model.typedWord = word
        let others = dictionary.suggestions(for: word, modern: model.usesModernUzbekAlphabet).filter { $0 != word }
        model.suggestions = [word] + Array(others.prefix(2))
        candidateContext = textDocumentProxy.documentContextBeforeInput
        candidateDocument = document
    }

    private func acceptSuggestion(_ suggestion: String) {
        guard model.showsSuggestions, model.suggestions.contains(suggestion),
              let document = currentDocumentIdentifier, candidateDocument == document,
              candidateContext == textDocumentProxy.documentContextBeforeInput,
              let word = editableWord(), word == model.typedWord else {
            refreshSuggestions()
            return
        }
        correctionUndo = nil
        keepOriginalContext = nil
        replaceTrailingWord(word, with: suggestion + " ")
        lastSpaceAt = Date.now
        model.refreshShift()
        refreshSuggestions()
    }

    private func replaceTrailingWord(_ word: String, with replacement: String) {
        for _ in word { textDocumentProxy.deleteBackward() }
        textDocumentProxy.insertText(replacement)
    }

    private func validateCorrectionState() {
        guard predictionAllowed, let document = currentDocumentIdentifier else {
            correctionUndo = nil
            keepOriginalContext = nil
            keepOriginalDocument = nil
            keepOriginalAfter = nil
            return
        }
        if let undo = correctionUndo,
           undo.document != document
            || undo.before != textDocumentProxy.documentContextBeforeInput
            || undo.after != (textDocumentProxy.documentContextAfterInput ?? "") {
            correctionUndo = nil
        }
        if keepOriginalContext != textDocumentProxy.documentContextBeforeInput
            || keepOriginalDocument != document
            || keepOriginalAfter != (textDocumentProxy.documentContextAfterInput ?? "") {
            keepOriginalContext = nil
        }
    }

    private func deleteTypedBackward() {
        lastSpaceAt = .distantPast
        validateCorrectionState()
        if let undo = correctionUndo,
           textDocumentProxy.selectedText?.isEmpty ?? true {
            correctionUndo = nil
            replaceTrailingWord(undo.inserted, with: undo.original)
            keepOriginalContext = textDocumentProxy.documentContextBeforeInput
            keepOriginalDocument = currentDocumentIdentifier
            keepOriginalAfter = textDocumentProxy.documentContextAfterInput ?? ""
        } else {
            keepOriginalContext = nil
            textDocumentProxy.deleteBackward()
        }
        refreshSuggestions()
    }

    /// Emoji insertion bypasses correction and preserves the entire Unicode cluster.
    private func insertEmoji(_ emoji: String) {
        lastSpaceAt = .distantPast
        correctionUndo = nil
        keepOriginalContext = nil
        keepOriginalDocument = nil
        keepOriginalAfter = nil
        candidateContext = nil
        candidateDocument = nil
        textDocumentProxy.insertText(emoji)
        refreshSuggestions()
    }

    /// Inserts with a separating space when the cursor sits right after a word.
    private func insertDictation(_ text: String) {
        correctionUndo = nil
        keepOriginalContext = nil
        lastSpaceAt = .distantPast
        var piece = text
        if let previous = textDocumentProxy.documentContextBeforeInput?.last, !previous.isWhitespace {
            piece = " " + text
        }
        textDocumentProxy.insertText(piece)
        refreshSuggestions()
    }

    /// Follows the field's autocapitalization: capital after a sentence end, a new line, or
    /// at the start of the text.
    private func shouldCapitalize() -> Bool {
        let before = textDocumentProxy.documentContextBeforeInput ?? ""
        switch textDocumentProxy.autocapitalizationType ?? .none {
        case .none:
            return false
        case .allCharacters:
            return true
        case .words:
            return before.last.map(\.isWhitespace) ?? true
        case .sentences:
            let trimmed = before.trimmingCharacters(in: .whitespaces)
            guard let last = trimmed.last, !last.isNewline else { return true }
            return before.last?.isWhitespace == true && ".!?".contains(last)
        @unknown default:
            return false
        }
    }

    /// Keyboards have no public API to open their containing app. This walks the responder
    /// chain to the extension's UIApplication and calls `open(_:options:completionHandler:)`
    /// dynamically, the approach voice keyboards use. App Review may question it.
    private func openVoiceInputApp(route: String = "dictate", readySession: Bool = false) -> Bool {
        guard ["dictate", "settings", "subscription"].contains(route),
              let url = URL(string: route == "dictate"
                            ? (readySession ? VoiceBridge.readySessionURLString : VoiceBridge.dictateURLString)
                            : "voicelab-echo://\(route)") else { return false }
        let selector = NSSelectorFromString("openURL:options:completionHandler:")
        var responder: UIResponder? = self
        while let current = responder {
            if NSStringFromClass(type(of: current)) == "UIApplication", current.responds(to: selector) {
                typealias OpenURL = @convention(c) (AnyObject, Selector, NSURL, NSDictionary, AnyObject?) -> Void
                let open = unsafeBitCast(current.method(for: selector), to: OpenURL.self)
                open(current, selector, url as NSURL, NSDictionary(), nil)
                return true
            }
            responder = current.next
        }
        return false
    }
}

/// Keep the nullability boundary optional instead of invoking Swift's nonnull UUID bridge.
enum KeyboardDocumentIdentity {
    static func read(from proxy: any NSObjectProtocol) -> UUID? {
        let selector = NSSelectorFromString("documentIdentifier")
        guard proxy.responds(to: selector) else { return nil }
        return proxy.perform(selector)?.takeUnretainedValue() as? UUID
    }
}
