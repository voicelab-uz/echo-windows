import Foundation
import Testing

@testable import VoiceLabCore

private let profileJSON = """
    {"onboarding":{"role":"developer","use_cases":["coding","notes"],
    "dictation_language":"uz","writing_style":"formal","ui_language":"uz","theme":"dark",
    "revision":2,"completed_at":"2026-10-20T10:00:00Z"},"request_id":"req_profile"}
    """

@Test func onboardingMatchesDesktopStepOrderAndSections() {
    #expect(
        OnboardingStep.allCases.map(\.rawValue) == [
            "welcome", "signin", "about-you", "typing-places", "permissions", "mic-test",
            "shortcut", "language", "try-it-intro", "try-it-message", "try-it-email",
            "try-it-list", "time-savings", "personalize", "finish",
        ])
    #expect(OnboardingStep.welcome.previous == .welcome)
    #expect(OnboardingStep.finish.next == .finish)
    #expect(OnboardingStep.allCases.map(\.section) == [0, 0, 0, 0, 1, 2, 2, 2, 3, 3, 3, 3, 3, 4, 4])
    #expect(OnboardingStep.allCases.filter(\.skippable) == [.microphone, .tryMessage, .tryEmail, .tryList])
}

@Test func onboardingRequiresRealPermissionsShortcutAndPractice() {
    func ready(
        _ step: OnboardingStep, signedIn: Bool = true, mic: Bool = false,
        ax: Bool = false, heard: Bool = false, shortcut: Bool = false, practice: Bool = false
    ) -> Bool {
        OnboardingPolicy.canAdvance(
            step: step, signedIn: signedIn, microphone: mic, accessibility: ax,
            heardMicrophone: heard, shortcutDetected: shortcut, practiceComplete: practice)
    }
    #expect(ready(.welcome, signedIn: false))
    #expect(!ready(.signIn, signedIn: false))
    #expect(!ready(.permissions, mic: true))
    #expect(!ready(.permissions, ax: true))
    #expect(ready(.permissions, mic: true, ax: true))
    #expect(!ready(.microphone, mic: true))
    #expect(ready(.microphone, heard: true))
    #expect(!ready(.shortcut))
    #expect(ready(.shortcut, shortcut: true))
    for step in [OnboardingStep.tryMessage, .tryEmail, .tryList] {
        #expect(!ready(step))
        #expect(ready(step, practice: true))
        #expect(!ready(step, signedIn: false, practice: true))
    }
    #expect(!ready(.finish, signedIn: false))
}

@Test func oldLibraryWithoutOnboardingStillDecodes() throws {
    let data = Data(#"{"schemaVersion":1,"transcripts":[],"notes":[],"vocabulary":[]}"#.utf8)
    let snapshot = try JSONDecoder().decode(LibrarySnapshot.self, from: data)
    #expect(snapshot.onboarding == nil)
}

@Test func onboardingProgressAndPendingSyncSurviveRestartAndStayAccountScoped() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let secrets = MemorySecrets()
    let store = LibraryStore(directory: directory, secrets: secrets)
    var snapshot = LibrarySnapshot()
    var progress = OnboardingProgress()
    progress.step = .tryEmail
    progress.answers.role = "developer"
    progress.completedExercises = [.tryMessage]
    snapshot.onboarding = progress
    try await store.save(snapshot, accountID: "first")

    let restarted = LibraryStore(directory: directory, secrets: secrets)
    let restored = try await restarted.load(accountID: "first")
    #expect(restored.onboarding == progress)
    #expect(restored.onboarding?.completedAt == nil)
    #expect(try await restarted.load(accountID: "second").onboarding == nil)

    progress.complete(at: Date(timeIntervalSince1970: 1000))
    snapshot.onboarding = progress
    try await restarted.save(snapshot, accountID: "first")
    let completed = try await store.load(accountID: "first").onboarding
    #expect(completed?.pendingSync == true)
    #expect(completed?.completedAt == Date(timeIntervalSince1970: 1000))
    #expect(completed?.step == .finish)
}

@Test func onboardingGETPrefillsAnswersWithoutCompletingLocalSetup() async throws {
    let transport = StubTransport([(200, tokenJSON()), (200, profileJSON)])
    let http = HTTPClient(transport: transport)
    let auth = try await restoredAuth(http: http, secrets: MemorySecrets())
    let profile = try await DesktopAPI(http: http, auth: auth).onboardingProfile()
    var progress = OnboardingProgress()
    progress.answers = try #require(profile?.answers)
    #expect(progress.answers.role == "developer")
    #expect(progress.answers.theme == "dark")
    #expect(progress.completedAt == nil)
    #expect(progress.step == .aboutYou)
}

@Test func onboardingGETDistinguishesAbsentProfileFromNetworkFailure() async throws {
    let transport = StubTransport([
        (200, tokenJSON()), (404, #"{"error":{"message":"No profile"}}"#),
        (503, #"{"error":{"message":"Temporarily unavailable"}}"#),
    ])
    let http = HTTPClient(transport: transport)
    let auth = try await restoredAuth(http: http, secrets: MemorySecrets())
    let api = DesktopAPI(http: http, auth: auth)
    #expect(try await api.onboardingProfile() == nil)
    await #expect(throws: VoiceLabError.self) { try await api.onboardingProfile() }
}

@Test func onboardingPUTUsesExactBackendContractAndSkipsUnansweredQuestions() async throws {
    let transport = StubTransport([(200, tokenJSON()), (200, profileJSON)])
    let http = HTTPClient(transport: transport)
    let auth = try await restoredAuth(http: http, secrets: MemorySecrets())
    let api = DesktopAPI(http: http, auth: auth, appVersion: "1.0")
    var answers = OnboardingAnswers()
    answers.useCases = ["notes", "notes", "invalid-option"]
    answers.theme = "dark"
    _ = try await api.saveOnboarding(answers, completedAt: Date(timeIntervalSince1970: 0))
    let requests = await transport.requests
    let request = try #require(requests.last)
    let data = try #require(request.httpBody)
    let object = try JSONSerialization.jsonObject(with: data)
    let fields = try #require(object as? [String: Any])
    #expect(request.httpMethod == "PUT")
    #expect(request.url?.path == "/v1/desktop/onboarding")
    #expect(fields["role"] as? String == "")
    #expect(fields["writing_style"] as? String == "")
    #expect(fields["use_cases"] as? [String] == ["notes"])
    #expect(fields["dictation_language"] as? String == "auto")
    #expect(fields["platform"] as? String == "darwin")
    #expect(fields["completed_at"] as? String == "1970-01-01T00:00:00Z")
    #expect(
        Set(fields.keys)
            == Set([
                "role", "use_cases", "dictation_language", "writing_style", "ui_language",
                "theme", "app_version", "platform", "completed_at",
            ]))
}

@Test func legacyLanguageStepRestoresAsAlphabetWithoutLosingProgress() throws {
    let step = try JSONDecoder().decode(OnboardingStep.self, from: Data(#""language""#.utf8))
    #expect(step == .alphabet)
    #expect(step.previous == .shortcut)
    #expect(step.next == .tryIntro)
    #expect(OnboardingAnswers().dictationLanguage == "auto")
}
