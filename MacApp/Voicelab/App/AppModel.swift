import AppKit
import OSLog
import Observation
import VoiceLabCore

enum Destination: String, CaseIterable, Identifiable {
    // Reachable workspace sections.
    case history, statistics, vocabulary, notes
    var id: Self { self }
    var title: String {
        switch self {
        case .history: "Bosh sahifa"
        case .statistics: "Statistika"
        case .vocabulary: "Lug‘at"
        case .notes: "Qaydlar"
        }
    }
    var symbol: String {
        switch self {
        case .history: "house"
        case .statistics: "chart.bar"
        case .vocabulary: "character.book.closed"
        case .notes: "note.text"
        }
    }
}

/// Composition root and session coordinator. Feature-specific state lives in its own model.
@MainActor @Observable
final class AppModel {
    /// Choosing a workspace section always leaves settings.
    var destination: Destination = .history { didSet { settingsPage = nil } }
    var isReviewingOnboarding = false
    /// The settings page shown in the main window's detail column, or nil for the workspace.
    private(set) var settingsPage: SettingsPage?
    var isShowingSettings: Bool { settingsPage != nil }
    private(set) var account: Account?
    private(set) var isRecordingShortcut = false
    private(set) var isUsingOnboardingShortcut = false
    private(set) var onboardingShortcutError: String?
    private(set) var isRestoring = true
    private(set) var didFinishBackgroundLaunch = false
    var isDictationShortcutRegistered: Bool { shortcut.isRegistered }
    private(set) var restorationError: String?
    private(set) var needsSignIn = false
    private(set) var isSigningIn = false
    private(set) var isCompletingSignIn = false
    private(set) var isSigningOut = false
    private(set) var isPreparingUpdate = false
    private(set) var isPastingTranscript = false
    private(set) var isOnboardingShortcutPending = false
    @ObservationIgnored private weak var updateTrial: TryItModel?
    @ObservationIgnored private weak var updateQuestionnaire: QuestionnaireModel?
    @ObservationIgnored private weak var updatePermissions: OnboardingPermissionsService?
    @ObservationIgnored private var updateTrialOwner: String?
    private var transcriptSaves = 0
    @ObservationIgnored private var updateInstallationPrepared = false
    @ObservationIgnored private var updateLease: UUID?
    @ObservationIgnored private var updatePreparationID: UUID?
    private(set) var signInRetryAt: Date?
    private(set) var isRefreshing = false
    private(set) var isLoadingHistory = false
    private(set) var hasMoreHistory = false
    private(set) var usage: Usage?
    private(set) var usageRefreshError: String?
    var error: String? {
        didSet {
            errorExpiryTask?.cancel()
            errorExpiryTask = nil
        }
    }
    let preferences: Preferences
    let library: LibraryModel
    let dictation: DictationModel
    let onboarding: OnboardingModel
    let mainWindow = MainWindowPresenter()
    /// When the current shortcut press started a recording; nil when the press did not.
    @ObservationIgnored private var heldShortcutSince: ContinuousClock.Instant?
    /// Automatic mode after a tap: recording continues until the next press.
    @ObservationIgnored private var isHandsFree = false
    let loginItem = LoginItemService()
    let updateNotifications = UpdateNotificationService(system: NativeUpdateNotificationEnvironment())
    let push: PushNotificationService?
    let inbox: NotificationInboxModel?
    let statistics: StatisticsModel
    @ObservationIgnored private let auth: Authentication
    @ObservationIgnored private let api: any DesktopServing
    @ObservationIgnored private let browser = BrowserAuthentication()
    @ObservationIgnored private let shortcut = GlobalShortcut()
    /// ⌃⌘V anywhere: types the latest transcript into the focused text field again.
    @ObservationIgnored private let pasteShortcut = GlobalShortcut()
    static let pasteLastTranscriptShortcut = DictationShortcut(
        keyCode: 9, modifiers: UInt64(NSEvent.ModifierFlags([.control, .command]).rawValue), keyLabel: "V")
    @ObservationIgnored private var dictationIsland: DictationIslandController?
    @ObservationIgnored private var historyPage = 0
    @ObservationIgnored private var started = false
    @ObservationIgnored private var signInTask: Task<Void, Error>?
    @ObservationIgnored private var pendingSignInCallback: URL?
    @ObservationIgnored private var backgroundRefreshTask: Task<Void, Never>?
    @ObservationIgnored private var usageRefreshTask: Task<Void, Never>?
    @ObservationIgnored private var usageRefreshID = UUID()
    @ObservationIgnored private var signInCooldownTask: Task<Void, Never>?
    @ObservationIgnored private var errorExpiryTask: Task<Void, Never>?
    @ObservationIgnored private var sessionObservationTask: Task<Void, Never>?
    @ObservationIgnored private var handledInvalidation: UUID?
    @ObservationIgnored private let presentSignIn: () -> Void
    private static var signInCooldownKey: String { RuntimeBackend.signInCooldownKey }
    private static let startupLog = Logger(subsystem: "uz.voicelab.desktop", category: "startup")

    convenience init() {
        let http = HTTPClient(persistAuthenticationCooldown: true, environment: RuntimeBackend.environment)
        let auth = Authentication(http: http, secrets: RuntimeBackend.keychain)
        let api = DesktopAPI(http: http, auth: auth)
        let directory = RuntimeBackend.libraryDirectory
        let preferences = Preferences()
        let library = LibraryModel(store: LibraryStore(directory: directory, secrets: RuntimeBackend.keychain), notesAPI: api)
        self.init(auth: auth, api: api, preferences: preferences, library: library)
    }

    init(
        auth: Authentication, api: any DesktopServing & OnboardingServing,
        preferences: Preferences, library: LibraryModel, presentSignIn: (() -> Void)? = nil,
        dictation: DictationModel? = nil
    ) {
        self.auth = auth
        self.api = api
        self.preferences = preferences
        self.library = library
        let pushEnvironment = NativePushNotificationEnvironment()
        if let pushAPI = api as? any PushServing, pushEnvironment.environment != nil {
            push = PushNotificationService(api: pushAPI, system: pushEnvironment)
        } else {
            // Local builds omit APNs entitlements until provisioning is configured.
            // Keep the inbox available without registering for system notifications.
            push = nil
        }
        statistics = StatisticsModel(api: api as? any StatisticsServing)
        inbox = (api as? any NotificationInboxServing).map { NotificationInboxModel(api: $0) }
        self.presentSignIn = presentSignIn ?? { [mainWindow] in mainWindow.show() }
        let dictation = dictation ?? DictationModel(api: api, library: library, preferences: preferences)
        self.dictation = dictation
        onboarding = OnboardingModel(
            api: api, library: library, preferences: preferences, dictation: dictation,
            completionAPI: api as? any OnboardingFinishing)
        dictation.canStartWork = { [weak self] in self?.isPreparingUpdate == false }
        dictation.onUsageMayHaveChanged = { [weak self] owner in
            self?.reconcileUsageAfterDictation(owner: owner)
        }
        let openNotification: (PushRoute) -> Void = { [weak self] route in
            guard let self, !self.needsSignIn, self.account?.id == route.accountID else { return }
            switch route.destination {
            case .home: self.destination = .history
            case .notes: self.destination = .notes
            case .vocabulary: self.destination = .vocabulary
            case .settings: self.showSettings()
            }
            self.mainWindow.show()
        }
        push?.onOpen = openNotification
        inbox?.onOpen = openNotification
        push?.onReceive = { [weak self] in
            Task { await self?.inbox?.refresh(force: true) }
        }
        if let retryAt = UserDefaults.standard.object(forKey: Self.signInCooldownKey) as? Date,
            retryAt > .now
        {
            setSignInCooldown(until: retryAt)
        }
        sessionObservationTask = Task { [weak self, auth] in
            for await event in await auth.sessionInvalidations() {
                guard !Task.isCancelled else { return }
                await self?.requireSignIn(event)
            }
        }
    }

    deinit {
        sessionObservationTask?.cancel()
        usageRefreshTask?.cancel()
    }

    private func requireSignIn(_ event: Authentication.SessionInvalidation) async {
        guard await auth.sessionInvalidation == event, !isSigningOut
        else { return }
        let shouldPresent = handledInvalidation != event.id
        handledInvalidation = event.id
        // Gate the entire workspace before any local I/O can fail or suspend.
        needsSignIn = true
        push?.deactivate()
        inbox?.deactivate()
        statistics.reset()
        isRestoring = false
        restorationError = nil
        dismissSettings()
        backgroundRefreshTask?.cancel()
        cancelUsageRefresh()
        library.stopNotesSync()
        dictation.discard()
        dictation.clearResult()
        onboarding.reset()
        NotificationCenter.default.post(name: Notification.Name("Echo.stopOnboarding"), object: nil)
        useOnboardingShortcut(false)
        usage = nil
        usageRefreshError = nil
        error = AppLocalization.error(VoiceLabError.signedOut)
        if shouldPresent { presentSignIn() }
        // Keep the account-bound library and unsynced drafts for the next login.
        // Failure to save must never leave the authenticated workspace visible.
        try? await library.flush()
    }
    /// Reuse the app's Keychain session and account activation, including encrypted-library loading.
    func authenticateForOnboarding() async throws {
        guard !isPreparingUpdate else { throw UpdateRestartError.blocked([.installation]) }
        if account != nil, library.isReady, !needsSignIn, !isSigningIn,
            !isSigningOut, !isRestoring, restorationError == nil { return }
        guard !isSigningIn, !isSigningOut, !isRestoring, restorationError == nil else {
            throw VoiceLabError.signedOut
        }
        if let retryAt = signInRetryAt, retryAt > .now {
            throw VoiceLabError.rateLimited(retryAt: retryAt, requestID: nil)
        }
        let task = startSignIn()
        try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
        try Task.checkCancellation()
        guard account != nil, !needsSignIn, restorationError == nil else { throw VoiceLabError.signedOut }
    }

    func onboardingAPI() throws -> any OnboardingExperienceServing {
        guard let service = api as? any OnboardingExperienceServing else { throw VoiceLabError.invalidResponse }
        return service
    }

    func showSettings() {
        showSettings(page: settingsPage ?? .general)
    }

    /// Settings share the main window: the sidebar's settings section selects the page.
    func showSettings(page: SettingsPage) {
        guard !needsSignIn else { return }
        settingsPage = page
        mainWindow.show()
    }

    /// Returns the detail column to the current workspace section.
    func dismissSettings() {
        settingsPage = nil
    }

    func start(launchedAtLogin: Bool = false) async {
        guard !started else { return }
        started = true
        isRestoring = true
        restorationError = nil
        defer {
            isRestoring = false
            if launchedAtLogin, !Task.isCancelled {
                didFinishBackgroundLaunch = true
            }
        }
        Self.startupLog.notice("Startup: preparing local state")
        do {
            try await LocalInstallationReset.performIfRequested()
            try Task.checkCancellation()
            if LocalInstallationReset.didResetInThisProcess {
                preferences.reloadFromStorage()
                AppAccent.shared.reloadFromStorage()
                onboarding.microphone.select(preferences.microphoneID)
            }
        } catch is CancellationError {
            started = false
            return
        } catch {
            // Show a retryable error in the window instead of silently skipping startup.
            Self.startupLog.error(
                "Startup: local preparation failed: \(error.localizedDescription, privacy: .public)")
            restorationError = AppLocalization.error(error)
            started = false
            mainWindow.show()
            return
        }
        Self.startupLog.notice("Startup: local state ready")
        loginItem.configureDefaultIfNeeded()
        let island = DictationIslandController(app: self)
        dictationIsland = island
        island.start()
        refreshShortcutRegistration()
        // A requested clean launch always starts at welcome, even if another
        // old process writes a credential back while this process is starting.
        guard !LocalInstallationReset.didResetInThisProcess else { return }
        await restoreSession()
    }

    func retrySessionRestore() async {
        guard !isRestoring, !isSigningIn, !isSigningOut else { return }
        if !started {
            await start()
            return
        }
        isRestoring = true
        defer { isRestoring = false }
        await restoreSession()
    }

    func restoreSession() async {
        restorationError = nil
        do {
            if let account = try await auth.restore() {
                try await activateAccount(account)
            } else {
                try await library.close()
                account = nil
                needsSignIn = false
                onboarding.reset()
            }
            if let event = await auth.sessionInvalidation { await requireSignIn(event) }
        } catch {
            // A locked Keychain / unreadable library is not evidence of logout.
            if let event = await auth.sessionInvalidation {
                await requireSignIn(event)
            } else {
                restorationError = AppLocalization.error(error)
            }
        }
    }

    private func activateAccount(_ account: Account) async throws {
        cancelUsageRefresh()
        usage = nil
        usageRefreshError = nil
        self.account = account
        try await library.open(accountID: account.id)
        if LocalInstallationReset.needsOnboardingReplay {
            try await library.restartOnboarding()
            try LocalInstallationReset.completeOnboardingReplay()
        }
        await onboarding.prepare(accountID: account.id)
        if let event = await auth.sessionInvalidation {
            await requireSignIn(event)
            return
        }
        handledInvalidation = nil
        restorationError = nil
        needsSignIn = false
        error = nil
        isRestoring = false
        Task { await onboarding.syncPending() }
        push?.activate(accountID: account.id)
        inbox?.activate(accountID: account.id)
        // Local session readiness and the login-launch greeting do not depend
        // on profile/history network latency.
        backgroundRefreshTask?.cancel()
        backgroundRefreshTask = Task { [weak self] in await self?.refresh() }
    }
    func signIn() {
        guard !isPreparingUpdate else { return }
        guard !isSigningIn, !isSigningOut, !isRestoring, restorationError == nil else { return }
        guard signInRetryAt.map({ $0 <= .now }) ?? true else { return }
        _ = startSignIn()
    }

    private func startSignIn() -> Task<Void, Error> {
        isSigningIn = true
        isCompletingSignIn = false
        error = nil
        let task = Task { try await performSignIn() }
        signInTask = task
        return task
    }

    func cancelSignIn() {
        pendingSignInCallback = nil
        signInTask?.cancel()
    }

    private func performSignIn() async throws {
        defer {
            isSigningIn = false
            isCompletingSignIn = false
            signInTask = nil
        }
        do {
            let callback: URL
            if let pendingSignInCallback, await auth.canResumeAuthorization(callback: pendingSignInCallback) {
                callback = pendingSignInCallback
            } else {
                callback = try await browser.authenticate(using: auth)
                pendingSignInCallback = callback
            }
            try Task.checkCancellation()
            isCompletingSignIn = true
            mainWindow.returnFromBrowser()
            let account = try await auth.completeAuthorization(callback: callback)
            pendingSignInCallback = nil
            do {
                try await activateAccount(account)
            } catch {
                // Authentication succeeded; retry local loading without consuming
                // another authorization code or replacing the saved session.
                restorationError = AppLocalization.error(error)
                throw error
            }
        } catch {
            if case VoiceLabError.rateLimited = error, !Task.isCancelled {
                // Keep only this validated callback in memory for an explicit
                // retry. No new browser request or authorization code is needed.
            } else {
                pendingSignInCallback = nil
                await auth.cancelAuthorization()
            }
            if !Task.isCancelled {
                if case VoiceLabError.storage = error {
                    restorationError = AppLocalization.error(error)
                } else {
                    report(error)
                }
            }
            throw error
        }
    }

    private func setSignInCooldown(until date: Date) {
        signInCooldownTask?.cancel()
        signInRetryAt = date
        UserDefaults.standard.set(date, forKey: Self.signInCooldownKey)
        signInCooldownTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(max(0, date.timeIntervalSinceNow))) } catch { return }
            guard let self, self.signInRetryAt == date else { return }
            self.signInRetryAt = nil
            self.signInCooldownTask = nil
            UserDefaults.standard.removeObject(forKey: Self.signInCooldownKey)
            UserDefaults.standard.removeObject(forKey: "VoiceLab.auth.retryRequestID")
        }
    }
    func signOut() async {
        guard !isPreparingUpdate else { return }
        guard !isSigningIn, !isSigningOut, !dictation.isBusy else { return }
        isSigningOut = true
        defer { isSigningOut = false }
        do {
            try await library.flush()
            backgroundRefreshTask?.cancel()
            cancelUsageRefresh()
            dictation.discard()
            dictation.clearResult()
            onboarding.reset()
            try await library.close()
            push?.deactivate()
            inbox?.deactivate()
            statistics.reset()
            account = nil
            dismissSettings()
            needsSignIn = false
            restorationError = nil
            usage = nil
            usageRefreshError = nil
            historyPage = 0
            hasMoreHistory = false
            try await auth.logout()
        } catch { self.error = AppLocalization.error(error) }
    }
    func refresh() async {
        guard account != nil, !needsSignIn, !isSigningOut, !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        async let usageRefresh: Void = refreshUsage()
        if preferences.retainHistory { await loadHistory(reset: true) }
        await usageRefresh
    }
    /// Profile opening and foreground refreshes share a single read.
    func refreshUsage() async {
        guard account != nil, !needsSignIn, !isSigningOut, !isRestoring else { return }
        if let usageRefreshTask {
            await usageRefreshTask.value
            return
        }
        guard let owner = account?.id else { return }
        let requestID = UUID()
        usageRefreshID = requestID
        let task = Task<Void, Never> { [weak self] in
            guard let self else { return }
            await self.fetchUsage(owner: owner, requestID: requestID)
        }
        usageRefreshTask = task
        await task.value
        if usageRefreshID == requestID { usageRefreshTask = nil }
    }

    private func cancelUsageRefresh() {
        usageRefreshID = UUID()
        usageRefreshTask?.cancel()
        usageRefreshTask = nil
    }

    func reconcileUsageAfterDictation(owner: String) {
        guard owner == account?.id, !needsSignIn, !isSigningOut else { return }
        // An earlier GET may contain the balance from before STT committed.
        // Invalidate it even when its transport ignores cancellation.
        cancelUsageRefresh()
        Task { [weak self] in await self?.refreshUsage() }
    }

    private func fetchUsage(owner: String, requestID: UUID) async {
        do {
            let usage = try await api.usage()
            guard usageRefreshID == requestID, !Task.isCancelled, !needsSignIn, owner == account?.id else { return }
            self.usage = usage
            usageRefreshError = nil
        } catch {
            guard usageRefreshID == requestID, !Task.isCancelled, !needsSignIn, owner == account?.id else { return }
            if case VoiceLabError.signedOut = error {
                report(error)
            } else {
                // Preserve the last known balance. Optional profile metadata
                // must not become a recording failure in the notch.
                usageRefreshError = AppLocalization.text(
                    "Daqiqalar ma’lumotini yangilab bo‘lmadi. Qayta yangilang.")
            }
        }
    }
    func loadHistory(reset: Bool = false) async {
        guard let owner = account?.id, !needsSignIn, library.isReady, !isLoadingHistory, !isSigningOut else { return }
        isLoadingHistory = true
        defer { isLoadingHistory = false }
        let page = reset ? 1 : historyPage + 1
        do {
            let response = try await api.history(page: page)
            guard !Task.isCancelled, !needsSignIn, owner == account?.id else { return }
            library.merge(response.items)
            hasMoreHistory = response.hasMore
            historyPage = page
        } catch {
            if !Task.isCancelled, !needsSignIn, owner == account?.id { report(error) }
        }
    }
    private func report(_ error: Error) {
        if case VoiceLabError.rateLimited = error {
            // Only the HTTP authentication bucket can pause login. A usage or
            // history limit must not prevent the user from signing in.
            if let retryAt = UserDefaults.standard.object(forKey: Self.signInCooldownKey) as? Date,
                retryAt > .now
            {
                setSignInCooldown(until: retryAt)
            }
        } else if case VoiceLabError.signedOut = error {
            Task { [weak self, auth] in
                if let event = await auth.sessionInvalidation { await self?.requireSignIn(event) }
            }
        }
        self.error = AppLocalization.error(error)
        if case VoiceLabError.rateLimited(let retryAt, _) = error {
            errorExpiryTask = Task { [weak self] in
                do {
                    try await Task.sleep(for: .seconds(max(0, retryAt.timeIntervalSinceNow)))
                } catch { return }
                // Assigning any newer error (or dismissing this one) cancels this task.
                self?.error = nil
            }
        }
    }
    func saveTranscript(_ transcript: Transcript, text: String) async throws {
        guard !isPreparingUpdate else { throw UpdateRestartError.blocked([.installation]) }
        transcriptSaves += 1
        defer { transcriptSaves -= 1 }
        let owner = account?.id
        var updated = transcript
        if transcript.isRemote {
            updated = try await api.update(transcript, text: text)
        } else {
            updated.text = text
        }
        guard owner == account?.id else { throw VoiceLabError.sessionChanged }
        library.merge([updated])
    }
    /// A cheap synchronous snapshot for the updater UI and its delegate callbacks.
    /// The authentication actor performs an additional atomic check during preparation.
    var updateBlockers: [UpdateRestartBlocker] {
        var blockers: [UpdateRestartBlocker] = []
        if isRestoring { blockers.append(.startup) }
        if updateTrial?.canCancel == true || updateTrial?.phase == .restoring ||
            updateQuestionnaire?.busy == true || updatePermissions?.requesting == true || onboarding.isFinishing {
            blockers.append(.onboarding)
        }
        if dictation.isBusy { blockers.append(.dictation) }
        if dictation.canRetry { blockers.append(.retryableRecording) }
        if isSigningIn || isCompletingSignIn || isSigningOut { blockers.append(.authentication) }
        if isRecordingShortcut || isOnboardingShortcutPending { blockers.append(.shortcutEditing) }
        if isPastingTranscript { blockers.append(.textInsertion) }
        if library.hasUnsavedEdits { blockers.append(.unsavedChanges) }
        if transcriptSaves > 0 { blockers.append(.saving) }
        if isPreparingUpdate && !updateInstallationPrepared { blockers.append(.installation) }
        return blockers
    }

    var canInstallUpdate: Bool { updateBlockers.isEmpty }
    var hasUnfinishedRecording: Bool {
        dictation.isBusy || dictation.canRetry ||
            updateTrial.map { [.starting, .recording, .transcribing].contains($0.phase) } == true
    }

    func registerOnboardingUpdateState(trial: TryItModel, questionnaire: QuestionnaireModel,
                                       permissions: OnboardingPermissionsService, owner: String?) {
        updateTrial = trial
        updateQuestionnaire = questionnaire
        updatePermissions = permissions
        updateTrialOwner = owner
        trial.canStartWork = { [weak self] in self?.isPreparingUpdate == false }
        questionnaire.canStartWork = { [weak self] in self?.isPreparingUpdate == false }
        permissions.canStartWork = { [weak self] in self?.isPreparingUpdate == false }
    }

    func checkpointOnboardingPractice() {
        guard !isReviewingOnboarding, let trial = updateTrial,
              updateTrialOwner == account?.id, library.accountID == account?.id, library.isReady else { return }
        library.saveOnboardingPracticeDraft(onboarding.isComplete || trial.text.isEmpty ? nil : trial.text)
    }

    func setOnboardingShortcutPending(_ pending: Bool) { isOnboardingShortcutPending = pending }

    func prepareForUpdateInstallation() async throws {
        if updateInstallationPrepared {
            guard canInstallUpdate else { throw UpdateRestartError.blocked(updateBlockers) }
            return
        }
        guard canInstallUpdate else { throw UpdateRestartError.blocked(updateBlockers) }
        // Close the gate synchronously before yielding to either storage actor.
        let preparationID = UUID()
        updatePreparationID = preparationID
        isPreparingUpdate = true
        library.prepareForRelaunch()
        do {
            try await auth.prepareForRelaunch()
            try Task.checkCancellation()
            checkpointOnboardingPractice()
            try await library.flush()
            try Task.checkCancellation()
            guard updatePreparationID == preparationID else { throw CancellationError() }
            let blockers = updateBlockers.filter { $0 != .installation }
            guard blockers.isEmpty else { throw UpdateRestartError.blocked(blockers) }
            updateLease = try UpdateInstallationLease.begin(for: Bundle.main.bundleURL)
            updateInstallationPrepared = true
        } catch {
            if updatePreparationID == preparationID { await cancelUpdateInstallation() }
            throw error
        }
    }

    func cancelUpdateInstallation() async {
        updatePreparationID = nil
        if let updateLease { UpdateInstallationLease.clear(for: Bundle.main.bundleURL, token: updateLease) }
        updateLease = nil
        updateInstallationPrepared = false
        // Keep new work gated until the authentication actor has reopened.
        await auth.cancelRelaunch()
        isPreparingUpdate = false
        library.resumeAfterRelaunchCancellation()
        refreshShortcutRegistration()
    }

    func shutdown(allowDiscardingRecording: Bool = false) async -> Bool {
        do {
            var blockers = updateBlockers.filter { $0 != .installation }
            if allowDiscardingRecording {
                blockers.removeAll { $0 == .dictation || $0 == .retryableRecording }
                // Confirmation applies only to captured audio, not an unrelated
                // questionnaire save, permission prompt, or onboarding completion.
                if updateTrial.map({ [.starting, .recording, .transcribing].contains($0.phase) }) == true,
                   updateQuestionnaire?.busy != true, updatePermissions?.requesting != true,
                   !onboarding.isFinishing {
                    blockers.removeAll { $0 == .onboarding }
                }
            }
            guard blockers.isEmpty else { throw UpdateRestartError.blocked(blockers) }
            if isPreparingUpdate {
                guard updateInstallationPrepared, canInstallUpdate else {
                    throw UpdateRestartError.blocked(updateBlockers)
                }
            }
            isPreparingUpdate = true
            // All operations which can veto termination happen before cancellation
            // of recordings, browser authentication, or onboarding UI.
            library.prepareForRelaunch()
            try await auth.prepareForRelaunch()
            checkpointOnboardingPractice()
            try await library.flush()
            try shortcut.unregister()
            try pasteShortcut.unregister()
            NotificationCenter.default.post(name: Notification.Name("Echo.stopOnboarding"), object: nil)
            backgroundRefreshTask?.cancel()
            cancelUsageRefresh()
            cancelSignIn()
            dictation.discard()
            onboarding.stopMicrophoneTest()
            dictationIsland?.stop()
            sessionObservationTask?.cancel()
            return true
        } catch {
            if case UpdateRestartError.blocked(let blockers) = error { self.error = blockers.first?.message }
            else { self.error = AppLocalization.error(error) }
            await cancelUpdateInstallation()
            return false
        }
    }
    func toggleDictation() {
        guard !isPreparingUpdate else { return }
        guard !isUsingOnboardingShortcut, !isReviewingOnboarding else { return }
        guard !isRecordingShortcut, !isRestoring else { return }
        guard !needsSignIn, restorationError == nil, account != nil else {
            mainWindow.show()
            return
        }
        if onboarding.isComplete {
            dictation.toggle()
        } else {
            mainWindow.show()
            onboarding.handleShortcut()
        }
    }
    func beginShortcutRecording() throws {
        guard !isPreparingUpdate else { throw UpdateRestartError.blocked([.installation]) }
        guard !isRecordingShortcut else { return }
        guard !dictation.isBusy else { throw VoiceLabError.storage("Avval yozuvni tugating.") }
        try shortcut.unregister()
        try? pasteShortcut.unregister()
        isRecordingShortcut = true
        onboarding.setShortcutPressed(false)
    }
    func endShortcutRecording() {
        guard isRecordingShortcut else { return }
        isRecordingShortcut = false
        refreshShortcutRegistration()
    }
    func changeShortcut(_ selection: DictationShortcut) throws {
        guard !isPreparingUpdate else { throw UpdateRestartError.blocked([.installation]) }
        guard selection.isValid, !dictation.isBusy else {
            throw VoiceLabError.storage("Shortcutni hozir o‘zgartirib bo‘lmaydi.")
        }
        do {
            try shortcut.register(
                selection: selection,
                onPressedChange: { [weak self] pressed in self?.shortcutPressed(pressed) },
                action: { [weak self] in self?.shortcutDown() })
            preferences.shortcut = selection
        } catch {
            // Keep capture paused after a failed save. Dismissing the sheet restores
            // the previous binding, which has not been overwritten in preferences.
            if isRecordingShortcut {
                try? shortcut.unregister()
            } else {
                try? shortcut.register(
                    selection: preferences.shortcut,
                    onPressedChange: { [weak self] pressed in self?.shortcutPressed(pressed) },
                    action: { [weak self] in self?.shortcutDown() })
            }
            throw error
        }
    }
    func presentOnboardingTrial(_ trial: TryItModel?) {
        dictationIsland?.presentTrial(trial)
    }

    func useOnboardingShortcut(_ enabled: Bool) {
        isUsingOnboardingShortcut = enabled
        if !enabled { onboardingShortcutError = nil }
        refreshShortcutRegistration()
    }
    private func shortcutPressed(_ pressed: Bool) {
        guard !isPreparingUpdate else { return }
        if isUsingOnboardingShortcut {
            NotificationCenter.default.post(name: Notification.Name("Echo.onboardingFn"), object: nil,
                                            userInfo: ["pressed": pressed])
        } else {
            onboarding.setShortcutPressed(pressed)
            if !pressed { shortcutUp() }
        }
    }

    /// In automatic mode a press shorter than this is a tap, not push-to-talk.
    private static let automaticTapLimit: Duration = .milliseconds(300)
    /// In hold mode a release sooner than this is treated as an accidental tap.
    private static let accidentalHoldLimit: Duration = .milliseconds(250)

    /// Routes a shortcut press according to the activation mode. Toggle mode, onboarding,
    /// and every not-ready state keep the original toggleDictation() behavior.
    private func shortcutDown() {
        guard !isPreparingUpdate else { return }
        heldShortcutSince = nil
        let mode = preferences.activationMode
        guard mode != .toggle, !isUsingOnboardingShortcut, !isReviewingOnboarding, !isRecordingShortcut,
            !isRestoring, !needsSignIn, restorationError == nil, account != nil, onboarding.isComplete
        else { return toggleDictation() }
        if dictation.isBusy {
            guard mode == .automatic, [.preparing, .recording].contains(dictation.phase) else {
                // Hold mode ignores presses until the current recording is finished.
                return
            }
            // Any press during a hands-free recording ends it.
            isHandsFree = false
            dictation.stopWhenReady()
            return
        }
        isHandsFree = false
        dictation.toggle()
        if dictation.isBusy { heldShortcutSince = .now }
    }

    private func shortcutUp() {
        guard let start = heldShortcutSince else { return }
        heldShortcutSince = nil
        let held = ContinuousClock.now - start
        switch preferences.activationMode {
        case .toggle: return
        case .automatic where held < Self.automaticTapLimit:
            // A tap keeps recording hands-free; the next press stops it.
            isHandsFree = true
        case .hold where held < Self.accidentalHoldLimit: dictation.discard()
        case .hold, .automatic: dictation.stopWhenReady()
        }
    }
    /// The most recent transcript, from history or the last unsaved result.
    var lastTranscriptText: String? {
        library.snapshot.transcripts.max(by: { $0.createdAt < $1.createdAt })?.text ?? dictation.result
    }

    /// Writes the last transcript into whatever text field is focused, the same way a
    /// dictation does; without a text field it lands on the clipboard instead.
    func pasteLastTranscript() {
        guard !isPreparingUpdate, !isPastingTranscript,
              let text = lastTranscriptText, !text.isEmpty, !dictation.isBusy else { return }
        let target = TextInsertion.captureTarget()
        let method = preferences.textInsertionMethod
        isPastingTranscript = true
        Task {
            defer { isPastingTranscript = false }
            _ = await TextInsertion.insert(text, into: target, autoPaste: true, method: method)
        }
    }

    private func registerPasteShortcut() {
        // Only for the finished workspace, and never when it would shadow the dictation key.
        guard onboarding.isComplete, !isReviewingOnboarding, !isUsingOnboardingShortcut,
              preferences.shortcut != Self.pasteLastTranscriptShortcut else {
            try? pasteShortcut.unregister()
            return
        }
        try? pasteShortcut.register(
            selection: Self.pasteLastTranscriptShortcut, onPressedChange: { _ in },
            action: { [weak self] in self?.pasteLastTranscript() })
    }

    func suspendShortcutForSessionChange() {
        shortcut.invalidateEventTap()
        pasteShortcut.invalidateEventTap()
        shortcutPressed(false)
    }

    func refreshShortcutRegistration(rebuild: Bool = false) {
        if rebuild { suspendShortcutForSessionChange() }
        guard !isRecordingShortcut else { return }
        guard SessionReturnMonitor.desktopAvailable else {
            suspendShortcutForSessionChange()
            return
        }
        if ((onboarding.isComplete && !isReviewingOnboarding) || isUsingOnboardingShortcut) && TextInsertion.hasAccessibility {
            registerShortcut()
        } else {
            do { try shortcut.unregister() } catch { self.error = AppLocalization.error(error) }
            try? pasteShortcut.unregister()
            onboarding.setShortcutPressed(false)
        }
    }
    func registerShortcut() {
        guard !isRecordingShortcut else { return }
        guard SessionReturnMonitor.desktopAvailable else {
            suspendShortcutForSessionChange()
            return
        }
        do {
            try shortcut.register(
                selection: preferences.shortcut,
                onPressedChange: { [weak self] pressed in self?.shortcutPressed(pressed) },
                action: { [weak self] in self?.shortcutDown() })
            onboardingShortcutError = nil
            registerPasteShortcut()
        } catch {
            if isUsingOnboardingShortcut { onboardingShortcutError = AppLocalization.error(error) }
            else { self.error = AppLocalization.error(error) }
        }
    }
}
