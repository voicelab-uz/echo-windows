import AppKit
import Foundation
import VoiceLabCore

/// Real preferences, recorder lifecycle, dictation model, native text editing
/// and encrypted note persistence. Only capture/network/target discovery are faked.
@main
struct DictationAlphabetRegression {
    static let input =
        "Salomlar, men yangi alifboni bunday bo’ladi deb o’ylamagandim. Bizning chiroyli alifbomizga ko’z tegibdi."
    static let expected =
        "Salomlar, men yangi alifboni bunday böladi deb öylamagandim. Bizning çiroyli alifbomizga köz tegibdi."

    @MainActor
    static func main() async throws {
        _ = NSApplication.shared
        try await verify(
            name: "detected Uzbek uses modern alphabet", input: input, expected: expected,
            responseLanguage: "uz", expectedLanguage: .auto
        ) { $0.uzbekAlphabet = .modern }
        try await verify(
            name: "English-dominant mixed speech still converts only Uzbek",
            input: "I am switching. Hozir o‘zgartiryapti, chopayapti.",
            expected: "I am switching. Hozir özgartiryapti, çopayapti.",
            responseLanguage: "en", expectedLanguage: .auto
        ) { $0.uzbekAlphabet = .modern }
        try await verify(
            name: "detected German spelling is untouched",
            input: "Ich schreibe einen schönen Text.", expected: "Ich schreibe einen schönen Text.",
            responseLanguage: "de", expectedLanguage: .auto
        ) { $0.uzbekAlphabet = .modern }
        try await verify(
            name: "detected English remains English", input: "Show character",
            expected: "Show character", responseLanguage: "en", expectedLanguage: .auto
        ) { $0.uzbekAlphabet = .modern }
        try await verify(
            name: "mixed Uzbek and English preserves switching",
            input: "I am switching. Hozir o‘zgartiryapti, chopayapti.",
            expected: "I am switching. Hozir özgartiryapti, çopayapti.",
            responseLanguage: "uz", expectedLanguage: .auto
        ) { $0.uzbekAlphabet = .modern }
        try await verify(
            name: "detected Russian remains Russian", input: "Привет, как дела?",
            expected: "Привет, как дела?", responseLanguage: "ru", expectedLanguage: .auto
        ) { $0.uzbekAlphabet = .modern }
        try await verify(
            name: "current alphabet remains unchanged", input: input, expected: input,
            responseLanguage: "uz", expectedLanguage: .auto
        ) { $0.uzbekAlphabet = .current }
        try await verify(
            name: "legacy English preference cannot force recognition", input: input, expected: expected,
            responseLanguage: "uz", expectedLanguage: .auto, legacy: true
        ) { _ in }
        try await verify(
            name: "practice returns text without insertion or local history",
            input: "Practice stays in Echo.", expected: "Practice stays in Echo.",
            responseLanguage: "en", expectedLanguage: .auto, practice: true
        ) { $0.autoPaste = true }
        print("PASS: 8 automatic dictation scenarios and isolated practice output.")
        try await verifyInsertionFollowsFocus()
    }

    /// Switching windows while speaking must send the text to the window focused when
    /// the result arrives, not the one focused when recording started.
    @MainActor
    private static func verifyInsertionFollowsFocus() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("VoiceLab-FocusTest-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = LibraryStore(directory: directory, secrets: MemorySecrets())
        let library = LibraryModel(store: store)
        try await library.open(accountID: "focus-regression")
        let suite = "VoiceLab.FocusRegression.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = Preferences(defaults: defaults)

        // Each scenario: the app focused at start, the app focused when text arrives, the insert outcome.
        let scenarios: [(name: String, later: pid_t?, outcome: String, expectedTarget: pid_t, copied: Bool)] = [
            ("switching windows pastes into the newly focused app", 222, "Matn joylandi", 222, false),
            ("no focused app keeps the original target", nil, "Matn joylandi", 111, false),
            ("no text field reports a clipboard copy", 222, "Matn nusxalandi", 222, true),
        ]
        for scenario in scenarios {
            var captures = 0
            var insertedInto: pid_t?
            let model = DictationModel(
                api: StubAPI(input: "Salom", responseLanguage: "uz"), library: library, preferences: preferences,
                recorder: AudioRecorder(makeCapture: { StubCapture() }),
                captureTarget: {
                    captures += 1
                    if captures == 1 { return TextInsertion.Target(processID: 111) }
                    return scenario.later.map { TextInsertion.Target(processID: $0) }
                },
                insertText: { _, target, _ in
                    insertedInto = target?.processID
                    return scenario.outcome
                })
            model.toggle()
            try await eventually { model.phase == .recording || model.phase == .failed }
            precondition(model.phase == .recording, model.error ?? scenario.name)
            model.stop()
            try await eventually { model.phase == .idle || model.phase == .failed }
            precondition(model.phase == .idle, model.error ?? scenario.name)
            precondition(insertedInto == scenario.expectedTarget, scenario.name)
            precondition(model.copiedToClipboard == scenario.copied, scenario.name)
            model.discard()
            print("PASS: \(scenario.name)")
        }
        try await library.close()
    }

    @MainActor
    private static func verify(
        name: String, input: String, expected: String, responseLanguage: String,
        expectedLanguage: DictationLanguage, legacy: Bool = false, practice: Bool = false,
        configure: (Preferences) -> Void
    ) async throws {
        let suite = "VoiceLab.DictationAlphabetRegression.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        if legacy {
            defaults.set("modern", forKey: "uzbekAlphabet")
            defaults.set("en", forKey: "language")
        }
        let preferences = Preferences(defaults: defaults)
        configure(preferences)
        // Exercise the persisted values, not only in-memory bindings.
        let relaunched = Preferences(defaults: defaults)
        precondition(defaults.string(forKey: "language") == nil, name)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("VoiceLab-AlphabetTest-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = LibraryStore(directory: directory, secrets: MemorySecrets())
        let library = LibraryModel(store: store)
        try await library.open(accountID: "alphabet-regression")
        let editor = NSTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 300))
        editor.isRichText = false
        editor.string = "Oldingi qayd. ALMASHTIR Oxiri."
        editor.setSelectedRange((editor.string as NSString).range(of: "ALMASHTIR"))
        let binding = NoteBinding(library: library)
        editor.delegate = binding
        let api = StubAPI(input: input, responseLanguage: responseLanguage)
        let recorder = AudioRecorder(makeCapture: { StubCapture() })
        var insertedCount = 0
        let model = DictationModel(
            api: api, library: library, preferences: relaunched, recorder: recorder,
            captureTarget: { nil },
            insertText: { text, _, autoPaste in
                precondition(autoPaste)
                precondition(TextInsertion.replaceSelection(text, in: editor))
                insertedCount += 1
                return "Matn joylandi"
            })
        if practice { model.togglePractice() } else { model.toggle() }
        try await eventually { model.phase == .recording || model.phase == .failed }
        precondition(model.phase == .recording, model.error ?? name)
        precondition(model.isPracticeSession == practice)
        model.stop()
        try await eventually { model.phase == .idle || model.phase == .failed }
        precondition(model.phase == .idle, model.error ?? name)
        precondition(model.result == expected && insertedCount == (practice ? 0 : 1), name)
        let requestedLanguage = await api.requestedLanguage
        precondition(requestedLanguage == expectedLanguage, name)
        let expectedNote = practice ? "Oldingi qayd. ALMASHTIR Oxiri." : "Oldingi qayd. \(expected) Oxiri."
        precondition(editor.string == expectedNote, name)
        if !practice {
            precondition(binding.note.body == expectedNote, "Native edit must notify the note binding.")
        }
        try await library.flush()
        let saved = try await store.load(accountID: "alphabet-regression")
        if practice {
            precondition(saved.notes.isEmpty && saved.transcripts.isEmpty, name)
        } else {
            precondition(saved.notes.first?.body == expectedNote, name)
        }
        // Remote history must retain the server's canonical revision and text.
        if !practice { precondition(saved.transcripts.first?.text == input, name) }
        if input.contains("I am switching") {
            precondition(saved.transcripts.first?.languageCodeForDisplay == "mul", name)
        }
        model.discard()
        precondition(!model.isPracticeSession)
        try await library.close()
        print("PASS: \(name)")
    }

    @MainActor
    private static func eventually(_ condition: () -> Bool) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        fatalError("Timed out waiting for dictation.")
    }
}

@MainActor
private final class NoteBinding: NSObject, NSTextViewDelegate {
    let library: LibraryModel
    var note = Note()
    init(library: LibraryModel) { self.library = library }
    func textDidChange(_ notification: Notification) {
        guard let editor = notification.object as? NSTextView else { return }
        note.body = editor.string
        library.saveNote(note)
    }
}

private actor StubCapture: MicrophoneCapturing {
    func devices() async -> [MicrophoneDevice] { [] }
    func start(
        deviceID: String, recordingURL: URL?,
        onFrame: @escaping @Sendable (MicrophoneMeterFrame) -> Void,
        onFailure: @escaping @Sendable (MicrophoneCaptureError) -> Void
    ) async throws -> String {
        if let recordingURL { try Data("test audio".utf8).write(to: recordingURL) }
        return "test"
    }
    func stop() async {}
}

private actor StubAPI: DesktopServing {
    let input: String
    let responseLanguage: String
    private(set) var requestedLanguage: DictationLanguage?
    init(input: String, responseLanguage: String) {
        self.input = input
        self.responseLanguage = responseLanguage
    }
    func transcribe(file: URL, language: DictationLanguage) async throws -> Transcript {
        precondition(FileManager.default.fileExists(atPath: file.path))
        requestedLanguage = language
        return Transcript(
            id: "dst_regression", text: input, language: responseLanguage,
            durationMS: 1000, revision: 1)
    }
    func usage() async throws -> Usage { throw VoiceLabError.invalidResponse }
    func history(page: Int) async throws -> HistoryPage { throw VoiceLabError.invalidResponse }
    func update(_ transcript: Transcript, text: String) async throws -> Transcript {
        throw VoiceLabError.invalidResponse
    }
}

private final class MemorySecrets: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Data] = [:]
    func read(_ key: String) throws -> Data? { lock.withLock { values[key] } }
    func write(_ data: Data, key: String) throws { lock.withLock { values[key] = data } }
    func remove(_ key: String) throws { _ = lock.withLock { values.removeValue(forKey: key) } }
}
