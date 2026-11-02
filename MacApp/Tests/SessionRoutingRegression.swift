import Foundation
import VoiceLabCore

/// Actual AppModel + Authentication + DesktopAPI, with isolated storage and transport.
/// No browser, window, microphone or production server is opened by this executable.
@main
struct SessionRoutingRegression {
    @MainActor static func main() async throws {
        for body in ["", "<html>401 Unauthorized</html>",
                     #"{"error":{"code":"invalid_refresh_token","message":"Expired refresh"}}"#] {
            for feature in ["history", "usage", "dictation", "notes", "onboarding"] {
                let fixture = try await Fixture(rejectionBody: body)
                try await fixture.prepare()
                var note = Note()
                note.title = "Unsynced"
                note.body = "Keep this draft"
                fixture.app.library.saveNote(note)
                do {
                    switch feature {
                    case "history": _ = try await fixture.api.history(page: 1)
                    case "usage": _ = try await fixture.api.usage()
                    case "dictation":
                        let file = fixture.directory.appendingPathComponent("sample.wav")
                        try Data(repeating: 0, count: 64).write(to: file)
                        _ = try await fixture.api.transcribe(file: file, language: .auto)
                    case "notes": _ = try await fixture.api.notes(cursor: "", accountID: "account-a")
                    default: _ = try await fixture.api.onboardingProfile()
                    }
                    preconditionFailure("Expected refresh rejection")
                } catch VoiceLabError.signedOut {}
                try await eventually { fixture.app.needsSignIn }
                precondition(!fixture.app.isRestoring && fixture.app.restorationError == nil)
                precondition(!fixture.app.isShowingSettings && !fixture.app.dictation.isBusy)
                precondition(!fixture.app.onboarding.isComplete)
                fixture.app.showSettings() // Must not cover the login screen or open a window.
                precondition(!fixture.app.isShowingSettings)
                try await fixture.app.library.flush()
                let saved = try await fixture.store.load(accountID: "account-a")
                precondition(saved.notes.contains { $0.id == note.id && $0.body == note.body })
                precondition(fixture.presentations.count == 1)
                for _ in 0..<100 {
                    do { _ = try await fixture.auth.token(forceRefresh: true) }
                    catch VoiceLabError.signedOut {}
                }
                let requests = await fixture.transport.calls
                precondition(requests == 1, "Invalid refresh continued sending requests")
                _ = await fixture.app.shutdown()
                print("PASS: \(feature) refresh rejection opens login and preserves unsynced notes")
            }
        }

        do {
            let fixture = try await Fixture(expired: true)
            await fixture.app.restoreSession()
            try await eventually { fixture.app.needsSignIn }
            precondition(fixture.app.account == nil && !fixture.app.isRestoring)
            // Repeating restore must not undo the login gate or reopen the window.
            await fixture.app.restoreSession()
            precondition(fixture.app.needsSignIn && fixture.presentations.count == 1)
            await fixture.transport.allowLogin()
            let attempt = try await fixture.auth.beginAuthorization()
            let nonce = await fixture.transport.state
            _ = try await fixture.auth.completeAuthorization(
                callback: URL(string: "\(attempt.redirectURI)?code=dac_test&state=\(nonce)")!)
            await fixture.app.restoreSession()
            precondition(!fixture.app.needsSignIn && fixture.app.account?.id == "account-a")
            precondition(fixture.app.onboarding.isComplete)
            _ = await fixture.app.shutdown()
            print("PASS: expired startup opens login; successful login restores the workspace")
        }

        do {
            let fixture = try await Fixture()
            try await fixture.prepare()
            fixture.secrets.failRemoval = true
            do { _ = try await fixture.api.usage() } catch {}
            try await eventually { fixture.app.needsSignIn }
            precondition(fixture.app.restorationError == nil)
            _ = await fixture.app.shutdown()
            print("PASS: failed credential cleanup cannot leave an invalid session in the workspace")
        }

        do {
            let fixture = try await Fixture(offline: true)
            try await fixture.prepare()
            do { _ = try await fixture.api.usage() } catch {}
            try await Task.sleep(for: .milliseconds(100))
            precondition(!fixture.app.needsSignIn && fixture.app.account != nil)
            precondition(fixture.presentations.count == 0)
            _ = await fixture.app.shutdown()
            print("PASS: network failure keeps the signed-in workspace")
        }

        do {
            let fixture = try await Fixture()
            try await fixture.prepare()
            let transcriptEditor = UUID(), vocabularyEditor = UUID(), renameEditor = UUID()
            fixture.app.library.setUnsavedEdit(transcriptEditor, isDirty: false)
            precondition(fixture.app.canInstallUpdate, "Opening an unchanged editor must not block restart")
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let snapshot = try encoder.encode(fixture.app.library.snapshot)
            for editor in [transcriptEditor, vocabularyEditor, renameEditor] {
                fixture.app.library.setUnsavedEdit(editor, isDirty: true)
            }
            precondition(!fixture.app.canInstallUpdate && fixture.app.updateBlockers.contains(.unsavedChanges))
            do {
                try await fixture.app.prepareForUpdateInstallation()
                preconditionFailure("Update discarded unsaved editor text")
            } catch UpdateRestartError.blocked(let blockers) {
                precondition(blockers.contains(.unsavedChanges))
            }
            let ordinaryQuit = await fixture.app.shutdown()
            let discardAudioQuit = await fixture.app.shutdown(allowDiscardingRecording: true)
            precondition(!ordinaryQuit && !discardAudioQuit && !fixture.app.isPreparingUpdate)
            let afterVeto = try encoder.encode(fixture.app.library.snapshot)
            precondition(afterVeto == snapshot, "Restart veto must not silently save or discard drafts")
            fixture.app.library.setUnsavedEdit(transcriptEditor, isDirty: false) // Save/cancel/dismiss.
            fixture.app.library.setUnsavedEdit(transcriptEditor, isDirty: false) // Idempotent disappearance.
            precondition(!fixture.app.canInstallUpdate, "Dismissing one editor cleared another editor's draft")
            fixture.app.library.setUnsavedEdit(vocabularyEditor, isDirty: false)
            fixture.app.library.setUnsavedEdit(renameEditor, isDirty: false)
            precondition(fixture.app.canInstallUpdate)
            fixture.app.library.setUnsavedEdit(transcriptEditor, isDirty: true) // A new edit after a prior save.
            precondition(!fixture.app.canInstallUpdate)
            fixture.app.library.setUnsavedEdit(transcriptEditor, isDirty: false) // Undo to the original value.
            precondition(fixture.app.canInstallUpdate)
            let quitAfterCancel = await fixture.app.shutdown()
            precondition(quitAfterCancel, "Explicitly canceled edits must release the restart gate")
            print("PASS: unsaved transcript/vocabulary/rename leases veto update and Quit without writing; independent cancel/undo releases safely")
        }

        do {
            let fixture = try await Fixture()
            try await fixture.prepare()
            let editor = UUID()
            fixture.app.library.setUnsavedEdit(editor, isDirty: true)
            do {
                try await fixture.app.saveTranscript(
                    Transcript(id: "dst_failed_edit", text: "Original", language: "en", durationMS: 1000), text: "Keep editing")
                preconditionFailure("Expected the isolated offline API to reject the save")
            } catch is URLError {}
            precondition(fixture.app.updateBlockers.contains(.unsavedChanges) && !fixture.app.updateBlockers.contains(.saving),
                         "A failed save must keep the unsaved draft gate after the request finishes")
            fixture.app.library.setUnsavedEdit(editor, isDirty: false)
            _ = await fixture.app.shutdown()
            print("PASS: a failed transcript save keeps its unsaved editor lease until explicit cancellation")
        }

        do {
            let updates = HeldTranscriptAPI()
            let fixture = try await Fixture(uiAPI: updates)
            try await fixture.prepare()
            let transcript = Transcript(id: "dst_pending_save", text: "Original", language: "en", durationMS: 1000)
            let editor = UUID()
            fixture.app.library.setUnsavedEdit(editor, isDirty: true)
            let saving = Task { try await fixture.app.saveTranscript(transcript, text: "Keep my edit") }
            try await eventually { fixture.app.updateBlockers.contains(.saving) }
            let ordinaryQuit = await fixture.app.shutdown()
            precondition(!ordinaryQuit, "Quit discarded a pending transcript edit")
            let discardQuit = await fixture.app.shutdown(allowDiscardingRecording: true)
            precondition(!discardQuit,
                         "Recording-discard consent must not discard a pending transcript edit")
            precondition(!fixture.app.isPreparingUpdate, "Canceled quit left the workspace gated")
            await updates.finish()
            try await saving.value
            precondition(!fixture.app.updateBlockers.contains(.saving))
            precondition(fixture.app.updateBlockers.contains(.unsavedChanges), "Only the editor can acknowledge its successful save")
            fixture.app.library.setUnsavedEdit(editor, isDirty: false)
            let idleQuit = await fixture.app.shutdown()
            precondition(idleQuit, "Idle quit should resume after the save finishes")
            let saved = try await fixture.store.load(accountID: "account-a")
            precondition(saved.transcripts.contains { $0.id == transcript.id && $0.text == "Keep my edit" })
            print("PASS: normal Quit preserves pending transcript edits; explicit audio discard cannot bypass saving")
        }
    }

    @MainActor static func eventually(_ condition: () -> Bool) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        preconditionFailure("Login routing did not update within two seconds")
    }
}

@MainActor private final class Presentations { var count = 0 }

@MainActor private final class Fixture {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Echo-Session-\(UUID())")
    let suite = "Echo.SessionTest.\(UUID())"
    let secrets = RoutingSecrets()
    let transport: RoutingTransport
    let auth: Authentication
    let api: DesktopAPI
    let store: LibraryStore
    let app: AppModel
    let presentations = Presentations()

    init(expired: Bool = false, offline: Bool = false,
         uiAPI: any DesktopServing & OnboardingServing = OfflineUIAPI(),
         rejectionBody: String = #"{"error":{"code":"invalid_refresh_token","message":"Expired refresh"}}"#) async throws {
        transport = RoutingTransport(offline: offline, rejectionBody: rejectionBody)
        let http = HTTPClient(transport: transport)
        auth = Authentication(http: http, secrets: secrets)
        api = DesktopAPI(http: http, auth: auth)
        store = LibraryStore(directory: directory, secrets: secrets)
        let defaults = UserDefaults(suiteName: suite)!
        let library = LibraryModel(store: store)
        app = AppModel(auth: auth, api: uiAPI, preferences: Preferences(defaults: defaults),
                       library: library, presentSignIn: { [presentations] in presentations.count += 1 })
        struct Session: Encodable {
            let refreshToken = "drt_saved_123456789"
            let refreshExpiresAt: Date
            let account = Account(id: "account-a", email: "test@example.com", name: "Test")
            let accessToken = "access_saved_123456789"
            let accessExpiresAt = Date.distantPast
        }
        try secrets.write(JSONEncoder().encode(Session(refreshExpiresAt: expired ? .distantPast : .now.addingTimeInterval(3600))), key: "session")
        try secrets.write(Data(UUID().uuidString.utf8), key: "installation")
        try await library.open(accountID: "account-a")
        var progress = OnboardingProgress()
        progress.completedAt = .now
        progress.profileLoaded = true
        library.saveOnboarding(progress)
        try await library.flush()
    }

    func prepare() async throws {
        await app.restoreSession()
        precondition(app.account != nil && app.onboarding.isComplete && !app.needsSignIn)
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
        UserDefaults.standard.removePersistentDomain(forName: suite)
    }
}

private final class RoutingSecrets: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Data] = [:]
    private var blocked = false
    var failRemoval: Bool {
        get { lock.withLock { blocked } }
        set { lock.withLock { blocked = newValue } }
    }
    func read(_ key: String) throws -> Data? { lock.withLock { values[key] } }
    func write(_ data: Data, key: String) throws { lock.withLock { values[key] = data } }
    func remove(_ key: String) throws {
        try lock.withLock {
            if blocked { throw VoiceLabError.storage("Keychain unavailable") }
            values[key] = nil
        }
    }
}

private actor RoutingTransport: HTTPTransport {
    let offline: Bool
    var loginAllowed = false
    private(set) var state = ""
    let rejectionBody: String
    private(set) var calls = 0
    init(offline: Bool, rejectionBody: String) {
        self.offline = offline
        self.rejectionBody = rejectionBody
    }
    func allowLogin() { loginAllowed = true }
    func send(_ request: URLRequest, uploadFile: URL?) async throws -> (Data, HTTPURLResponse) {
        calls += 1
        if offline { throw URLError(.notConnectedToInternet) }
        let status: Int
        let body: String
        if request.url!.path.hasSuffix("/authorizations") && loginAllowed {
            let fields = try JSONDecoder().decode([String: String].self, from: request.httpBody!)
            state = fields["state"]!
            status = 200
            body = #"{"authorization_url":"https://voicelab.uz/app/sign-in?desktop_auth_id=dau_test","authorization_request_id":"dau_test","expires_in":300}"#
        } else if loginAllowed {
            status = 200
            body = #"{"access_token":"access_new_123456789","refresh_token":"drt_new_123456789","token_type":"Bearer","expires_in":900,"refresh_expires_in":2592000,"user":{"id":"account-a","email":"test@example.com","name":"Test"}}"#
        } else {
            status = 401
            body = rejectionBody
        }
        return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
}

private struct OfflineUIAPI: DesktopServing, OnboardingServing {
    func usage() async throws -> Usage { throw URLError(.notConnectedToInternet) }
    func history(page: Int) async throws -> HistoryPage { throw URLError(.notConnectedToInternet) }
    func transcribe(file: URL, language: DictationLanguage) async throws -> Transcript { throw URLError(.notConnectedToInternet) }
    func update(_ transcript: Transcript, text: String) async throws -> Transcript { throw URLError(.notConnectedToInternet) }
    func onboardingProfile() async throws -> OnboardingProfile? { throw URLError(.notConnectedToInternet) }
    func saveOnboarding(_ answers: OnboardingAnswers, completedAt: Date) async throws -> OnboardingProfile { throw URLError(.notConnectedToInternet) }
}

private actor HeldTranscriptAPI: DesktopServing, OnboardingServing {
    private var continuation: CheckedContinuation<Void, Never>?
    private var finished = false
    func usage() async throws -> Usage { throw URLError(.notConnectedToInternet) }
    func history(page: Int) async throws -> HistoryPage { throw URLError(.notConnectedToInternet) }
    func transcribe(file: URL, language: DictationLanguage) async throws -> Transcript { throw URLError(.notConnectedToInternet) }
    func onboardingProfile() async throws -> OnboardingProfile? { throw URLError(.notConnectedToInternet) }
    func saveOnboarding(_ answers: OnboardingAnswers, completedAt: Date) async throws -> OnboardingProfile { throw URLError(.notConnectedToInternet) }
    func update(_ transcript: Transcript, text: String) async throws -> Transcript {
        if !finished { await withCheckedContinuation { continuation = $0 } }
        var updated = transcript
        updated.text = text
        return updated
    }
    func finish() { finished = true; continuation?.resume(); continuation = nil }
}
