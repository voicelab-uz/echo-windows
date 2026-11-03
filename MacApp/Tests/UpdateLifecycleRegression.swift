import AppKit
import Foundation
import Observation
import Sparkle
import VoiceLabCore

/// Deterministic delegate test: Sparkle is constructed but never started; no
/// download, application replacement, microphone, Keychain or network is used.
@MainActor @Observable final class AppModel {
    var isRestoring = false
    var isPreparingUpdate = false
    var updateBlockers: [UpdateRestartBlocker] = []
    var canInstallUpdate: Bool { updateBlockers.isEmpty }
    var failPreparation = false
    var pausePreparation = false
    var preparations = 0
    var cancellations = 0
    var resume: CheckedContinuation<Void, Never>?

    func prepareForUpdateInstallation() async throws {
        preparations += 1
        isPreparingUpdate = true
        if pausePreparation { await withCheckedContinuation { resume = $0 } }
        try Task.checkCancellation()
        if failPreparation { throw UpdateRestartError.blocked([.saving]) }
    }
    func cancelUpdateInstallation() async {
        cancellations += 1
        isPreparingUpdate = false
    }
}

@MainActor enum AppLocalization {
    static func text(_ key: String, _ arguments: CVarArg...) -> String {
        String(format: key, arguments: arguments)
    }
    static func error(_ error: any Error) -> String { error.localizedDescription }
}

private final class UpdateStateDecoder: NSCoder {
    var userInitiated = true
    var stage: SPUUserUpdateStage = .installing
    override var allowsKeyedCoding: Bool { true }
    override func decodeInteger(forKey key: String) -> Int { stage.rawValue }
    override func decodeBool(forKey key: String) -> Bool { userInitiated }
}

@main struct UpdateLifecycleRegression {
    @MainActor static func main() async throws {
        let suite = "Echo.UpdateLifecycle.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let config = AppUpdateConfiguration(feedURL: "https://cdn.example.com/echo/test/appcast.xml",
            publicKey: Data(repeating: 1, count: 32).base64EncodedString(), channel: "test")!
        let model = AppModel()
        let checker = AppUpdateChecker(defaults: defaults)
        checker.configure(model: model) // Test bundle intentionally has no updater config.
        checker.restorePendingInstallation(configuration: config)
        let controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil)
        let updater = controller.updater
        let launchItem = SUAppcastItem(dictionary: ["title": "Echo 1.0.0", "enclosure": [
            "url": "https://cdn.example.com/echo/115/Echo.dmg", "sparkle:version": "115",
            "sparkle:shortVersionString": "1.0.0", "length": "1024", "type": "application/octet-stream"
        ]])!
        precondition(launchItem.displayVersionString == "1.0.0" && launchItem.versionString == "115")
        for installed in ["108", "112"] {
            precondition(SUStandardVersionComparator.default.compareVersion(launchItem.versionString, toVersion: installed) == .orderedDescending,
                         "The 1.0.0 launch must update older builds even when their marketing version was 2.0.0")
        }
        print("PASS: Sparkle compares numeric builds while displaying the 1.0.0 launch version.")
        let item = SUAppcastItem(dictionary: ["title": "Echo 2", "enclosure": [
            "url": "https://cdn.example.com/echo/2/Echo.dmg", "sparkle:version": "2",
            "sparkle:shortVersionString": "2.0", "length": "1024", "type": "application/octet-stream"
        ]])!
        let state = SPUUserUpdateState(coder: UpdateStateDecoder())!

        var notices: [UpdateNotification] = []
        var dismissals = 0
        checker.onScheduledUpdate = { notices.append($0) }
        checker.onUpdateDismissed = { dismissals += 1 }
        checker.standardUserDriverWillHandleShowingUpdate(true, forUpdate: item, state: state)
        precondition(notices.isEmpty, "User-initiated update UI must never emit a local reminder")
        let scheduledDecoder = UpdateStateDecoder()
        scheduledDecoder.userInitiated = false
        let scheduledState = SPUUserUpdateState(coder: scheduledDecoder)!
        checker.standardUserDriverWillHandleShowingUpdate(false, forUpdate: item, state: scheduledState)
        precondition(notices.count == 1 && notices[0].build == "2" && notices[0].stage == .ready)
        checker.standardUserDriverWillHandleShowingUpdate(true, forUpdate: item, state: state)
        _ = checker.updater(updater, willInstallUpdateOnQuit: item, immediateInstallationBlock: {})
        precondition(notices.count == 1, "A manual download must not send a ready reminder")
        try checker.updater(updater, mayPerform: .updatesInBackground)
        _ = checker.updater(updater, willInstallUpdateOnQuit: item, immediateInstallationBlock: {})
        checker.updater(updater, didFinishUpdateCycleFor: .updatesInBackground, error: nil)
        precondition(notices.count == 2 && notices.last?.stage == .ready && dismissals == 0,
                     "The automatic driver must leave its ready reminder after a successful cycle")
        checker.standardUserDriverWillFinishUpdateSession()
        precondition(dismissals == 0, "Generic Sparkle cleanup must not erase a background reminder")
        checker.standardUserDriverDidReceiveUserAttention(forUpdate: item)
        precondition(dismissals == 1)
        checker.updater(updater, userDidMake: .skip, forUpdate: item, state: state)
        print("PASS: only scheduled update callbacks emit reminders; user attention dismisses them.")

        let clickModel = AppModel()
        clickModel.isRestoring = true
        var clickReady = false
        var shownUpdates = 0
        let clickChecker = AppUpdateChecker(defaults: defaults,
            startUpdater: { _ in clickReady = true },
            showUpdate: { _ in shownUpdates += 1 }, updateAvailability: { _ in clickReady })
        clickChecker.configure(model: clickModel, info: ["SUFeedURL": config.feedURL.absoluteString,
            "SUPublicEDKey": config.publicKey, "EchoUpdateChannel": config.channel])
        clickChecker.showFromNotification()
        clickChecker.showFromNotification()
        precondition(shownUpdates == 0 && !clickChecker.canCheck)
        clickModel.isRestoring = false
        try await eventually { shownUpdates == 1 }
        for _ in 0..<10 { await Task.yield() }
        precondition(shownUpdates == 1 && clickModel.preparations == 0,
                     "A cold-launch click must open existing update UI once when ready, never prepare installation")

        let startupModel = AppModel()
        startupModel.isRestoring = true
        var starts = 0
        let startupChecker = AppUpdateChecker(defaults: defaults, startUpdater: { _ in starts += 1 })
        startupChecker.configure(model: startupModel, info: ["SUFeedURL": config.feedURL.absoluteString,
            "SUPublicEDKey": config.publicKey, "EchoUpdateChannel": config.channel])
        precondition(starts == 0 && startupChecker.phase == .idle && startupChecker.errorMessage == nil)
        await Task.yield()
        precondition(starts == 0, "A pending Keychain prompt must not start or retry the updater")
        startupModel.isRestoring = false
        try await eventually { starts == 1 }
        startupModel.isRestoring = true
        await Task.yield()
        precondition(starts == 1, "Later account restoration must not start Sparkle twice")
        do {
            try startupChecker.updater(updater, mayPerform: .updates)
            preconditionFailure("Expected a readiness deferral")
        } catch {
            startupChecker.updater(updater, didAbortWithError: error)
            startupChecker.updater(updater, didFinishUpdateCycleFor: .updates, error: error)
        }
        precondition(startupChecker.phase == .idle && startupChecker.errorMessage == nil)
        startupModel.isRestoring = false
        try startupChecker.updater(updater, mayPerform: .updates)
        let networkFailure = URLError(.notConnectedToInternet)
        startupChecker.updater(updater, didAbortWithError: networkFailure)
        precondition(startupChecker.phase == .failed && startupChecker.errorMessage != nil,
                     "Actual download/network failures must remain visible")
        for code in [SUError.runningTranslocated, SUError.runningFromDiskImageError] {
            startupChecker.updater(updater, didAbortWithError: NSError(domain: SUSparkleErrorDomain, code: Int(code.rawValue)))
            precondition(startupChecker.errorMessage?.contains("Applications") == true,
                         "Translocation and disk-image errors must explain how to install Echo")
        }
        startupChecker.updater(updater, didAbortWithError: NSError(domain: "Other", code: 1005))
        precondition(startupChecker.errorMessage?.contains("Applications") == false,
                     "Error codes from another domain must not be mistaken for Sparkle installation errors")
        print("PASS: updater waits for Keychain startup once; readiness deferral is quiet and genuine failures remain visible.")

        model.updateBlockers = [.dictation]
        precondition(!checker.updaterShouldRelaunchApplication(updater))
        model.updateBlockers = [.retryableRecording]
        precondition(!checker.updaterShouldRelaunchApplication(updater))
        model.updateBlockers = [.unsavedChanges]
        precondition(!checker.updaterShouldRelaunchApplication(updater), "Unsaved editor text must veto restart.")
        model.updateBlockers = []
        precondition(checker.updaterShouldRelaunchApplication(updater))

        precondition(!checker.updater(updater, willInstallUpdateOnQuit: item, immediateInstallationBlock: {
            preconditionFailure("Sparkle retains control of scheduled installation.")
        }))
        let reopened = AppUpdateChecker(defaults: defaults)
        reopened.configure(model: model)
        reopened.restorePendingInstallation(configuration: config)
        precondition(reopened.hasPendingInstallation && reopened.availableVersion == "2.0")
        reopened.updater(updater, userDidMake: .skip, forUpdate: item, state: state)
        let afterSkip = AppUpdateChecker(defaults: defaults)
        afterSkip.restorePendingInstallation(configuration: config)
        precondition(!afterSkip.hasPendingInstallation)
        _ = checker.updater(updater, willInstallUpdateOnQuit: item, immediateInstallationBlock: {})
        let otherFeed = AppUpdateConfiguration(feedURL: "https://cdn.example.com/echo/stable/appcast.xml",
            publicKey: config.publicKey, channel: "stable")!
        let changedFeed = AppUpdateChecker(defaults: defaults)
        changedFeed.restorePendingInstallation(configuration: otherFeed)
        precondition(!changedFeed.hasPendingInstallation, "A staged hint must not cross release channels.")
        _ = checker.updater(updater, willInstallUpdateOnQuit: item, immediateInstallationBlock: {})
        let stagedData = defaults.data(forKey: "Echo.updates.staged.v1")!
        var previousBuild = try JSONSerialization.jsonObject(with: stagedData) as! [String: String]
        previousBuild["sourceBuild"] = "0"
        defaults.set(try JSONSerialization.data(withJSONObject: previousBuild), forKey: "Echo.updates.staged.v1")
        let newBuild = AppUpdateChecker(defaults: defaults)
        newBuild.restorePendingInstallation(configuration: config)
        precondition(!newBuild.hasPendingInstallation, "An installed build must not inherit the old staged hint.")
        print("PASS: busy/retryable audio veto; staged update survives restart and Skip clears it.")

        var rejected = false
        model.failPreparation = true
        precondition(checker.updater(updater, shouldPostponeRelaunchForUpdate: item, untilInvokingBlock: {
            rejected = !checker.updaterShouldRelaunchApplication(updater)
        }))
        try await eventually { rejected }
        await checker.waitForInstallationCancellation()
        precondition(!model.isPreparingUpdate && model.cancellations == 1)
        model.failPreparation = false
        precondition(checker.updaterShouldRelaunchApplication(updater), "A failed preparation cannot veto the next attempt.")

        var canceledContinuations = 0
        model.pausePreparation = true
        _ = checker.updater(updater, shouldPostponeRelaunchForUpdate: item, untilInvokingBlock: {
            precondition(!checker.updaterShouldRelaunchApplication(updater))
            canceledContinuations += 1
        })
        try await eventually { model.resume != nil }
        checker.installationWasCancelled()
        precondition(!checker.updaterShouldRelaunchApplication(updater))
        // A late/reentrant callback must drain without changing a future attempt.
        _ = checker.updater(updater, shouldPostponeRelaunchForUpdate: item, untilInvokingBlock: {
            precondition(!checker.updaterShouldRelaunchApplication(updater))
            canceledContinuations += 1
        })
        model.resume?.resume(); model.resume = nil
        await checker.waitForInstallationCancellation()
        precondition(canceledContinuations == 2 && !model.isPreparingUpdate)
        print("PASS: failed/canceled preparation drains once and cannot reopen or veto a later installation.")

        model.pausePreparation = false
        var resumed = false
        _ = checker.updater(updater, shouldPostponeRelaunchForUpdate: item, untilInvokingBlock: {
            precondition(checker.updaterShouldRelaunchApplication(updater))
            resumed = true
        })
        try await eventually { resumed }
        checker.updater(updater, willInstallUpdate: item)
        do {
            try checker.updater(updater, mayPerform: .updates)
            preconditionFailure("A background check must defer during installation")
        } catch {
            checker.updater(updater, didAbortWithError: error)
            checker.updater(updater, didFinishUpdateCycleFor: .updates, error: error)
        }
        precondition(checker.isInstalling && model.isPreparingUpdate,
                     "A background readiness veto must not cancel the active installation")
        checker.updater(updater, didFinishUpdateCycleFor: .updates, error: nil)
        precondition(checker.isInstalling && model.isPreparingUpdate,
                     "A successful cycle must not unlock the app during installer handoff.")
        checker.installationWasCancelled()
        await checker.waitForInstallationCancellation()
        precondition(!checker.isInstalling && !model.isPreparingUpdate)
        print("PASS: installation handoff remains gated until explicit cancellation.")
    }

    @MainActor static func eventually(_ condition: () -> Bool) async throws {
        for _ in 0..<500 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(2))
        }
        preconditionFailure("Timed out waiting for update lifecycle.")
    }
}
