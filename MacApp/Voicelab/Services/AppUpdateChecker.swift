import AppKit
import Observation
import OSLog
@preconcurrency import Sparkle
import VoiceLabCore

/// Sparkle owns scheduling, verification and installation. Echo owns readiness and quiet status UI.
@MainActor @Observable
final class AppUpdateChecker: NSObject {
    static let shared = AppUpdateChecker()
    static var installedVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    }
    static var installedBuild: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
    }

    private(set) var phase: AppUpdatePhase = .unconfigured
    private(set) var availableVersion: String?
    private(set) var canCheck = false
    private(set) var lastCheckedAt: Date?
    private(set) var errorMessage: String?
    private(set) var hasPendingInstallation = false
    private(set) var isInstalling = false
    private(set) var channel = "stable"
    var automaticallyChecks = false {
        didSet {
            guard let updater = controller?.updater, updater.automaticallyChecksForUpdates != automaticallyChecks else { return }
            updater.automaticallyChecksForUpdates = automaticallyChecks
        }
    }
    var automaticallyInstalls = false {
        didSet {
            guard let updater = controller?.updater, updater.automaticallyDownloadsUpdates != automaticallyInstalls else { return }
            updater.automaticallyDownloadsUpdates = automaticallyInstalls
        }
    }

    @ObservationIgnored var onScheduledUpdate: ((UpdateNotification) -> Void)?
    @ObservationIgnored var onUpdateDismissed: (() -> Void)?
    @ObservationIgnored private var notificationRequestedPresentation = false
    @ObservationIgnored private var userInitiatedCheck = true
    @ObservationIgnored private weak var model: AppModel?
    @ObservationIgnored private var controller: SPUStandardUpdaterController?
    @ObservationIgnored private var observations: [NSKeyValueObservation] = []
    @ObservationIgnored private var preparation: Task<Void, Never>?
    @ObservationIgnored private var cleanup: Task<Void, Never>?
    @ObservationIgnored private var installationGeneration = UUID()
    @ObservationIgnored private var suspendedInstallHandler: (() -> Void)?
    @ObservationIgnored private var rejectedInstallHandlers: [() -> Void] = []
    @ObservationIgnored private var isDrainingInstallation = false
    @ObservationIgnored private var installationHandedOff = false
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var configuration: AppUpdateConfiguration?
    @ObservationIgnored private var didStartUpdater = false
    @ObservationIgnored private let startUpdater: @MainActor (SPUUpdater) throws -> Void
    @ObservationIgnored private let showUpdate: @MainActor (SPUStandardUpdaterController) -> Void
    @ObservationIgnored private let updateAvailability: @MainActor (SPUUpdater) -> Bool
    private static let deferralDomain = "Echo.UpdateDeferral"
    private enum Deferral: Int { case startup = 1, installation }
    private static let stagedKey = "Echo.updates.staged.v1"
    private struct StagedInstallation: Codable {
        let sourceBuild, targetBuild, displayVersion, feedURL, channel: String
    }
    @ObservationIgnored private let logger = Logger(subsystem: "uz.voicelab.desktop", category: "updates")

    var isConfigured: Bool { controller != nil }
    var hasUpdate: Bool { availableVersion != nil }
    var blockingMessage: String? { model?.updateBlockers.first?.message }
    var statusTitle: String {
        switch phase {
        case .unconfigured: AppLocalization.text("Updates are not configured for this build.")
        case .idle: AppLocalization.text("Echo %@", Self.installedVersion)
        case .checking: AppLocalization.text("Checking for updates…")
        case .available: AppLocalization.text("Echo %@ is available", availableVersion ?? "")
        case .downloading: AppLocalization.text("Downloading update…")
        case .verifying: AppLocalization.text("Verifying update…")
        case .ready: AppLocalization.text("Echo %@ is ready to install", availableVersion ?? "")
        case .installing: AppLocalization.text("Preparing to restart…")
        case .current: AppLocalization.text("Echo is up to date")
        case .failed: AppLocalization.text("Could not complete the update")
        }
    }
    var actionTitle: String {
        if hasPendingInstallation { return AppLocalization.text("Install update…") }
        if hasUpdate { return AppLocalization.text("View update…") }
        return AppLocalization.text("Yangilanishlarni tekshirish…")
    }

    init(defaults: UserDefaults = .standard,
         startUpdater: @escaping @MainActor (SPUUpdater) throws -> Void = { try $0.start() },
         showUpdate: @escaping @MainActor (SPUStandardUpdaterController) -> Void = { $0.checkForUpdates(nil) },
         updateAvailability: @escaping @MainActor (SPUUpdater) -> Bool = { $0.canCheckForUpdates }) {
        self.defaults = defaults
        self.startUpdater = startUpdater
        self.showUpdate = showUpdate
        self.updateAvailability = updateAvailability
        super.init()
    }

    func configure(model: AppModel, info: [String: Any] = Bundle.main.infoDictionary ?? [:]) {
        guard controller == nil else { return }
        self.model = model
        guard let config = AppUpdateConfiguration(
            feedURL: info["SUFeedURL"] as? String ?? "",
            publicKey: info["SUPublicEDKey"] as? String ?? "",
            channel: info["EchoUpdateChannel"] as? String ?? "") else { return }
        restorePendingInstallation(configuration: config)
        let controller = SPUStandardUpdaterController(
            startingUpdater: false, updaterDelegate: self, userDriverDelegate: self)
        self.controller = controller
        phase = hasPendingInstallation ? .ready : .idle
        startWhenReady()
    }

    private func startWhenReady() {
        guard !didStartUpdater, let controller, let model else { return }
        // Keychain restoration can wait on a system prompt. Subscribe once to its
        // completion instead of starting a doomed check or polling while it is open.
        let restoring = withObservationTracking { model.isRestoring } onChange: { [weak self] in
            Task { @MainActor in self?.startWhenReady() }
        }
        guard !restoring else { return }
        do {
            try startUpdater(controller.updater)
            didStartUpdater = true
            phase = hasPendingInstallation ? .ready : .idle
            observe(controller.updater)
        } catch {
            self.controller = nil
            phase = .unconfigured
            logger.error("Updater configuration rejected: \((error as NSError).code, privacy: .public)")
        }
    }

    func check() {
        guard canCheck, let controller, !isInstalling, !isDrainingInstallation else { return }
        errorMessage = nil
        userInitiatedCheck = true
        if !hasUpdate { phase = .checking }
        showUpdate(controller)
    }

    /// Notification actions only open the standard update UI. Startup may still be
    /// restoring Keychain state; defer this explicit action until Sparkle is ready.
    func showFromNotification() {
        notificationRequestedPresentation = true
        presentRequestedUpdate()
    }

    private func presentRequestedUpdate() {
        guard notificationRequestedPresentation, canCheck, !isInstalling, !isDrainingInstallation else { return }
        notificationRequestedPresentation = false
        check()
    }

    private func announceScheduledUpdate(_ item: SUAppcastItem, stage: UpdateNotification.Stage) {
        guard !userInitiatedCheck,
              let notice = UpdateNotification(channel: channel, build: item.versionString,
                version: item.displayVersionString, stage: stage) else { return }
        onScheduledUpdate?(notice)
    }

    /// Handles both canceled quit and failed preparation, without discarding user work.
    func installationWasCancelled() {
        guard !isDrainingInstallation else { return }
        installationGeneration = UUID()
        isDrainingInstallation = true
        isInstalling = false
        installationHandedOff = false
        let pendingPreparation = preparation
        let continuation = suspendedInstallHandler
        suspendedInstallHandler = nil
        pendingPreparation?.cancel()
        preparation = nil
        cleanup = Task { [weak self] in
            await pendingPreparation?.value
            guard let self else { return }
            await model?.cancelUpdateInstallation()
            // Drain the old Sparkle continuation while the synchronous delegate
            // still rejects installation. It cannot veto a later update cycle.
            continuation?()
            let rejected = rejectedInstallHandlers
            rejectedInstallHandlers.removeAll()
            rejected.forEach { $0() }
            isDrainingInstallation = false
            cleanup = nil
            if phase != .failed { phase = hasPendingInstallation ? .ready : (hasUpdate ? .available : .idle) }
            refreshPreferences()
        }
    }

    func waitForInstallationCancellation() async { await cleanup?.value }

    /// Non-sensitive hint only. Sparkle remains responsible for verifying artifacts.
    /// Retain the hint on the same build so natural Quit is safe before Sparkle probes
    /// an installer left running by a previous process.
    func restorePendingInstallation(configuration: AppUpdateConfiguration) {
        self.configuration = configuration
        channel = configuration.channel
        guard let data = defaults.data(forKey: Self.stagedKey) else { return }
        guard let staged = try? JSONDecoder().decode(StagedInstallation.self, from: data),
              staged.sourceBuild == Self.installedBuild, staged.targetBuild != Self.installedBuild,
              staged.feedURL == configuration.feedURL.absoluteString, staged.channel == configuration.channel else {
            clearPendingInstallation()
            return
        }
        hasPendingInstallation = true
        availableVersion = staged.displayVersion
        phase = .ready
    }

    private func stage(_ item: SUAppcastItem) {
        hasPendingInstallation = true
        availableVersion = item.displayVersionString
        guard let configuration else { return }
        let staged = StagedInstallation(sourceBuild: Self.installedBuild, targetBuild: item.versionString,
            displayVersion: item.displayVersionString, feedURL: configuration.feedURL.absoluteString,
            channel: configuration.channel)
        if let data = try? JSONEncoder().encode(staged) { defaults.set(data, forKey: Self.stagedKey) }
    }

    private func clearPendingInstallation() {
        defaults.removeObject(forKey: Self.stagedKey)
        hasPendingInstallation = false
    }

    private func observe(_ updater: SPUUpdater) {
        observations = [
            updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] _, _ in
                Task { @MainActor in self?.refreshPreferences() }
            },
            updater.observe(\.automaticallyChecksForUpdates, options: [.initial, .new]) { [weak self] _, _ in
                Task { @MainActor in self?.refreshPreferences() }
            },
            updater.observe(\.automaticallyDownloadsUpdates, options: [.initial, .new]) { [weak self] _, _ in
                Task { @MainActor in self?.refreshPreferences() }
            },
            updater.observe(\.lastUpdateCheckDate, options: [.initial, .new]) { [weak self] _, _ in
                Task { @MainActor in self?.refreshPreferences() }
            },
        ]
        refreshPreferences()
    }

    private func refreshPreferences() {
        guard let updater = controller?.updater else { return }
        canCheck = updateAvailability(updater)
        automaticallyChecks = updater.automaticallyChecksForUpdates
        automaticallyInstalls = updater.automaticallyDownloadsUpdates
        lastCheckedAt = updater.lastUpdateCheckDate
        presentRequestedUpdate()
    }

    private func report(_ error: any Error) {
        // No URL, account identifier, local path or underlying error is logged.
        logger.error("Update failed, code: \((error as NSError).code, privacy: .public)")
        let failure = error as NSError
        if failure.domain == SUSparkleErrorDomain &&
            [SUError.runningTranslocated, SUError.runningFromDiskImageError].contains(where: { Int($0.rawValue) == failure.code }) {
            errorMessage = AppLocalization.text("To update Echo, quit it, drag Echo to Applications in Finder, then open Echo from Applications.")
        } else {
            errorMessage = AppLocalization.text("The update could not finish. Your current version is still available. Please try again.")
        }
        phase = .failed
    }

    private static func isDeferral(_ error: any Error) -> Bool {
        let failure = error as NSError
        return failure.domain == deferralDomain && Deferral(rawValue: failure.code) != nil
    }
}

extension AppUpdateChecker: SPUUpdaterDelegate {
    func allowedChannels(for updater: SPUUpdater) -> Set<String> {
        channel == "stable" ? [] : [channel]
    }

    func updater(_ updater: SPUUpdater, mayPerform updateCheck: SPUUpdateCheck) throws {
        guard !isDrainingInstallation, !isInstalling else {
            throw NSError(domain: Self.deferralDomain, code: Deferral.installation.rawValue,
                          userInfo: [NSLocalizedDescriptionKey: AppLocalization.text("Echo is preparing to restart.")])
        }
        if model?.isRestoring != false {
            throw NSError(domain: Self.deferralDomain, code: Deferral.startup.rawValue, userInfo: [
                NSLocalizedDescriptionKey: AppLocalization.text("Echo is starting. Please try again in a moment.")])
        }
        userInitiatedCheck = updateCheck != .updatesInBackground
        if !hasPendingInstallation { phase = .checking }
    }

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        availableVersion = item.displayVersionString
        if !hasPendingInstallation { phase = .available }
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater, error: any Error) {
        if !hasPendingInstallation { availableVersion = nil; phase = .current; onUpdateDismissed?() }
        errorMessage = nil
    }

    func updater(_ updater: SPUUpdater, willDownloadUpdate item: SUAppcastItem, with request: NSMutableURLRequest) {
        phase = .downloading
    }

    func updater(_ updater: SPUUpdater, didDownloadUpdate item: SUAppcastItem) { phase = .verifying }

    func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem,
                 immediateInstallationBlock immediateInstallHandler: @escaping () -> Void) -> Bool {
        stage(item)
        phase = .ready
        announceScheduledUpdate(item, stage: .ready)
        // Keep Sparkle's scheduler alive. Natural Quit goes through our termination barrier.
        return false
    }

    func updaterShouldRelaunchApplication(_ updater: SPUUpdater) -> Bool {
        guard !isDrainingInstallation else { return false }
        guard model?.canInstallUpdate == true else {
            errorMessage = blockingMessage ?? AppLocalization.text("Finish your current task before updating Echo.")
            return false
        }
        return true
    }

    func updater(_ updater: SPUUpdater, shouldPostponeRelaunchForUpdate item: SUAppcastItem,
                 untilInvokingBlock installHandler: @escaping () -> Void) -> Bool {
        guard let model, !isDrainingInstallation, preparation == nil else {
            rejectedInstallHandlers.append(installHandler)
            installationWasCancelled()
            return true
        }
        let generation = UUID()
        installationGeneration = generation
        suspendedInstallHandler = installHandler
        isInstalling = true
        phase = .installing
        preparation = Task { [weak self, weak model] in
            guard let self, let model else { return }
            do {
                try await model.prepareForUpdateInstallation()
                try Task.checkCancellation()
            } catch {
                guard installationGeneration == generation else { return }
                if case UpdateRestartError.blocked(let blockers) = error {
                    errorMessage = blockers.first?.message
                } else { errorMessage = AppLocalization.error(error) }
                installationWasCancelled()
                return
            }
            guard installationGeneration == generation else { return }
            preparation = nil
            suspendedInstallHandler = nil
            installHandler()
        }
        return true
    }

    func updater(_ updater: SPUUpdater, willInstallUpdate item: SUAppcastItem) {
        stage(item)
        isInstalling = true
        installationHandedOff = true
        phase = .installing
    }

    func updater(_ updater: SPUUpdater, didAbortWithError error: any Error) {
        // Sparkle reschedules a vetoed check using its normal interval. Our own
        // readiness veto is not a download/signature error and must not abort an
        // installation already in progress or leave a misleading failure banner.
        if Self.isDeferral(error) { return }
        let failure = error as NSError
        if failure.domain == SUSparkleErrorDomain && failure.code == Int(SUError.noUpdateError.rawValue) { return }
        if isInstalling || model?.isPreparingUpdate == true { installationWasCancelled() }
        if failure.domain == SUSparkleErrorDomain && failure.code == Int(SUError.installationCanceledError.rawValue) { return }
        report(error)
    }

    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: (any Error)?) {
        if let error, Self.isDeferral(error) { refreshPreferences(); return }
        // A successful installer may finish its update cycle before AppKit exits.
        // Only an explicit cancellation/error may reopen the app's restart gate.
        if isInstalling && (!installationHandedOff || error != nil) { installationWasCancelled() }
        refreshPreferences()
        if case .checking = phase { phase = .idle }
    }

    func updater(_ updater: SPUUpdater, userDidMake choice: SPUUserUpdateChoice,
                 forUpdate item: SUAppcastItem, state: SPUUserUpdateState) {
        if choice == .skip {
            onUpdateDismissed?()
            clearPendingInstallation()
            availableVersion = nil
            if isInstalling || model?.isPreparingUpdate == true { installationWasCancelled() }
            else { phase = .idle }
        }
    }
}

extension AppUpdateChecker: @MainActor SPUStandardUserDriverDelegate {
    var supportsGentleScheduledUpdateReminders: Bool { true }

    func standardUserDriverShouldHandleShowingScheduledUpdate(_ update: SUAppcastItem,
                                                              andInImmediateFocus immediateFocus: Bool) -> Bool {
        false // Scheduled updates appear quietly in Settings and the menu.
    }

    func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem,
                                                   state: SPUUserUpdateState) {
        availableVersion = update.displayVersionString
        userInitiatedCheck = state.userInitiated
        if state.stage == .installing { stage(update); phase = .ready }
        else if !hasPendingInstallation { phase = .available }
        if !handleShowingUpdate {
            announceScheduledUpdate(update, stage: state.stage == .installing ? .ready : .available)
        }
    }

    func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
        onUpdateDismissed?()
    }

    func standardUserDriverWillFinishUpdateSession() {
        // This is driver cleanup, not necessarily user attention. Keep quiet
        // background reminders until a click, explicit Skip, or no-update result.
        if !hasPendingInstallation && !isInstalling {
            availableVersion = nil
            if phase != .failed && phase != .current { phase = .idle }
        }
    }
}
