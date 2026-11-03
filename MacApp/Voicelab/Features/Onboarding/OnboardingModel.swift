import AVFoundation
import AppKit
import Observation
import VoiceLabCore

/// Coordinates onboarding without owning network credentials or embedding logic in views.
@MainActor @Observable
final class OnboardingModel {
    private(set) var progress = OnboardingProgress()
    private(set) var isPreparing = false
    private(set) var isFinishing = false
    private(set) var isCelebratingCompletion = false
    private(set) var isComplete = false
    private(set) var microphoneGranted = false
    private(set) var accessibilityGranted = false
    var heardMicrophone: Bool { microphone.speechDetected }
    private(set) var shortcutDetected = false
    private(set) var shortcutPressed = false
    var isTestingMicrophone: Bool { microphone.isRunning }
    private(set) var practiceWords: Int?
    private(set) var practiceSeconds: Double?
    private(set) var syncNotice: String?
    var error: String?
    let microphone: MicrophoneTestModel

    // Both values determine the visible step, including navigation before authentication.
    private var ownerID: String?
    private var beforeSignIn: OnboardingStep = .welcome

    @ObservationIgnored private let api: any OnboardingServing
    @ObservationIgnored private let completionAPI: (any OnboardingFinishing)?
    @ObservationIgnored private let library: LibraryModel
    @ObservationIgnored private let preferences: Preferences
    @ObservationIgnored private let dictation: DictationModel
    @ObservationIgnored private var isSyncing = false
    @ObservationIgnored private let readPermissions: () -> (microphone: Bool, accessibility: Bool)

    var step: OnboardingStep { ownerID == nil ? beforeSignIn : progress.step }
    var uzbekAlphabet: UzbekAlphabet {
        get { preferences.uzbekAlphabet }
        set { preferences.uzbekAlphabet = newValue }
    }
    var canContinue: Bool {
        !isPreparing && !isFinishing && !isCelebratingCompletion && !dictation.isBusy
            && OnboardingPolicy.canAdvance(
                step: step, signedIn: ownerID != nil && library.isReady,
                microphone: microphoneGranted, accessibility: accessibilityGranted,
                heardMicrophone: heardMicrophone, shortcutDetected: shortcutDetected,
                practiceComplete: progress.completedExercises.contains(step))
    }

    init(
        api: any OnboardingServing, library: LibraryModel,
        preferences: Preferences, dictation: DictationModel, completionAPI: (any OnboardingFinishing)? = nil,
        readPermissions: @escaping () -> (microphone: Bool, accessibility: Bool) = {
            (AVCaptureDevice.authorizationStatus(for: .audio) == .authorized, TextInsertion.hasAccessibility)
        }
    ) {
        self.api = api
        self.completionAPI = completionAPI
        self.readPermissions = readPermissions
        self.library = library
        self.preferences = preferences
        self.dictation = dictation
        microphone = MicrophoneTestModel(preferences: preferences)
    }

    func prepare(accountID: String) async {
        ownerID = accountID
        isPreparing = true
        isFinishing = false
        isCelebratingCompletion = false
        isComplete = false
        progress = library.snapshot.onboarding ?? OnboardingProgress()
        progress.answers.dictationLanguage = "auto"
        refreshPermissions()
        if progress.completedAt != nil {
            // Older clients queued an endpoint that never shipped. Do not fabricate
            // new questionnaire answers or repeatedly send that legacy acknowledgement.
            if completionAPI != nil && progress.completionVersion != 2 {
                progress.pendingSync = false
                persist()
            }
            isComplete = true
            isPreparing = false
            return
        }
        // A saved profile is a prefill, never proof of microphone/Accessibility permissions.
        if completionAPI == nil && !progress.profileLoaded {
            let localAnswers = progress.answers
            do {
                let profile = try await api.onboardingProfile()
                guard ownerID == accountID, library.accountID == accountID else { return }
                if let profile, localAnswers == OnboardingAnswers() {
                    progress.answers = profile.answers
                }
                progress.profileLoaded = true
            } catch {
                guard ownerID == accountID else { return }
                syncNotice = "Oldingi sozlamalar yuklanmadi. Onboardingni davom ettirishingiz mumkin."
            }
        }
        progress.answers.dictationLanguage = "auto"
        if progress.step.index < OnboardingStep.aboutYou.index { progress.step = .aboutYou }
        persist()
        applyPreferences()
        isPreparing = false
    }

    func next() {
        guard canContinue, step != .finish else { return }
        navigate(to: step.next)
    }

    func back() {
        guard !dictation.isBusy, !isPreparing, !isFinishing else { return }
        // Once signed in, back navigation never restarts authentication.
        guard ownerID == nil || step.index > OnboardingStep.aboutYou.index else { return }
        navigate(to: step.previous)
    }

    func skip() {
        guard step.skippable, !dictation.isBusy else { return }
        navigate(to: step.next)
    }

    private func navigate(to next: OnboardingStep) {
        stopMicrophoneTest()
        dictation.discard()
        dictation.clearResult()
        error = nil
        if ownerID == nil {
            beforeSignIn = next
        } else {
            progress.step = next
            persist()
        }
    }

    func setAnswer(_ keyPath: WritableKeyPath<OnboardingAnswers, String>, to value: String) {
        progress.answers[keyPath: keyPath] = value
        persist()
        applyPreferences()
    }

    func toggleUseCase(_ value: String) {
        if progress.answers.useCases.contains(value) {
            progress.answers.useCases.removeAll { $0 == value }
        } else {
            progress.answers.useCases.append(value)
        }
        persist()
    }

    private func applyPreferences() {
        preferences.appearance = progress.answers.theme == "auto" ? "system" : progress.answers.theme
    }

    private func persist() {
        guard let ownerID, ownerID == library.accountID else { return }
        library.saveOnboarding(progress)
    }

    func refreshPermissions() {
        let current = readPermissions()
        microphoneGranted = current.microphone
        accessibilityGranted = current.accessibility
    }

    func requestMicrophone() async {
        if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
            _ = await AVCaptureDevice.requestAccess(for: .audio)
        } else if !microphoneGranted {
            openPrivacy("Microphone")
        }
        refreshPermissions()
    }

    func requestAccessibility() {
        TextInsertion.requestAccessibility()
        if !TextInsertion.hasAccessibility { openPrivacy("Accessibility") }
        refreshPermissions()
    }

    private func openPrivacy(_ pane: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_\(pane)") {
            NSWorkspace.shared.open(url)
        }
    }

    func startMicrophoneTest() {
        guard step == .microphone else { return }
        microphone.start()
    }

    func stopMicrophoneTest() { microphone.stop() }

    func setShortcutPressed(_ pressed: Bool) { shortcutPressed = pressed }

    func handleShortcut() {
        guard ownerID != nil, !isPreparing else { return }
        if step == .shortcut {
            shortcutDetected = true
        } else if step.isPractice {
            dictation.togglePractice()
        }
    }

    func recordPracticeResult() {
        guard step.isPractice, let text = dictation.result, dictation.phase == .idle else { return }
        if !progress.completedExercises.contains(step) { progress.completedExercises.append(step) }
        if practiceWords == nil, let duration = dictation.resultDurationMS, duration > 0 {
            practiceWords = text.split(whereSeparator: \.isWhitespace).count
            practiceSeconds = Double(duration) / 1000
        }
        persist()
    }

    func finish() async {
        guard step == .finish, canContinue, let ownerID else { return }
        isFinishing = true
        error = nil
        let previous = progress
        progress.complete()
        persist()
        do {
            try await library.flush()
            guard self.ownerID == ownerID else { return }
            isCelebratingCompletion = true
            isFinishing = false
            await syncPending()
        } catch {
            progress = previous
            persist()
            isFinishing = false
            self.error = AppLocalization.error(error)
        }
    }

    /// The new flow calls this only after server-saved context and a successful real voice trial.
    /// Flush before revealing the workspace; failure leaves the final screen available to retry.
    func finishExperience() async -> Bool {
        refreshPermissions()
        guard let ownerID, library.accountID == ownerID, microphoneGranted, accessibilityGranted,
              !isFinishing else { return false }
        isFinishing = true
        error = nil
        defer { isFinishing = false }
        let previous = progress
        progress.completionVersion = 2
        progress.complete()
        persist()
        do {
            try await library.flush()
            guard self.ownerID == ownerID, library.accountID == ownerID else { return false }
            isComplete = true
            Task { await syncPending() }
            return true
        } catch {
            guard self.ownerID == ownerID else { return false }
            progress = previous
            persist()
            self.error = AppLocalization.error(error)
            return false
        }
    }

    /// Presentation acknowledges the locally saved completion; no network wait.
    func finishCelebration() {
        guard isCelebratingCompletion, progress.completedAt != nil,
            let ownerID, ownerID == library.accountID
        else { return }
        isComplete = true
        isCelebratingCompletion = false
    }

    /// Completion is local-first. Retry the durable pending profile on startup/foreground.
    func syncPending() async {
        guard !isSyncing, let ownerID, progress.pendingSync, let date = progress.completedAt else { return }
        isSyncing = true
        let sent = progress
        defer { isSyncing = false }
        do {
            if let completionAPI { try await completionAPI.completeOnboarding(forAccount: ownerID) }
            else { _ = try await api.saveOnboarding(sent.answers, completedAt: date) }
            guard self.ownerID == ownerID, library.accountID == ownerID, progress == sent else { return }
            progress.pendingSync = false
            persist()
            try await library.flush()
            syncNotice = nil
        } catch {
            guard self.ownerID == ownerID else { return }
            progress.pendingSync = true
            persist()
            syncNotice =
                "Onboarding shu Mac’da saqlandi. Akkaunt bilan sinxronlash keyingi ochishda qayta uriniladi."
        }
    }

    func reset() {
        stopMicrophoneTest()
        dictation.clearResult()
        ownerID = nil
        beforeSignIn = .welcome
        progress = OnboardingProgress()
        isComplete = false
        isPreparing = false
        isFinishing = false
        isCelebratingCompletion = false
        shortcutDetected = false
        shortcutPressed = false
        practiceWords = nil
        practiceSeconds = nil
        error = nil
        syncNotice = nil
    }
}
