import AppKit
import Combine
import SwiftUI
import VoiceLabCore
import UserNotifications

@main
struct VoicelabApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    private var model: AppModel { delegate.model }
    init() { WelcomeType.registerBundledFonts() }
    var body: some Scene {
        // A menu-bar-first scene keeps automatic launches quiet on macOS 14 and later.
        MenuBarExtra {
            MenuBarView(model: model)
                .disabled(model.isPreparingUpdate)
                .environment(\.locale, model.preferences.interfaceLanguage.locale)
                .environment(\.layoutDirection, model.preferences.interfaceLanguage.isRightToLeft ? .rightToLeft : .leftToRight)
                .environment(\.dictationShortcut, model.preferences.shortcut)
        } label: {
            MenuBarLaunchLabel(model: model)
        }
        .menuBarExtraStyle(.menu)
        mainWindow
    }

    private var mainWindow: some Scene {
        Window("Echo", id: "main") {
            ContentView(model: model)
                .disabled(model.isPreparingUpdate)
                .environment(\.locale, model.preferences.interfaceLanguage.locale)
                .environment(\.layoutDirection, model.preferences.interfaceLanguage.isRightToLeft ? .rightToLeft : .leftToRight)
                .environment(\.dictationShortcut, model.preferences.shortcut)
        }
        // A compact default size; people can still resize or go full screen.
        .defaultSize(width: 880, height: 720)
        .windowResizability(.contentMinSize)
        .windowToolbarStyle(.unified)
        .commands {
            #if DEBUG
                CommandMenu("Development") {
                    Button("Review onboarding") {
                        model.isReviewingOnboarding = true
                        model.mainWindow.show()
                    }
                    Button("End onboarding review") { model.isReviewingOnboarding = false }
                        .disabled(!model.isReviewingOnboarding)
                }
            #endif
            CommandGroup(replacing: .appSettings) {
                Button(AppLocalization.text("Sozlamalar") + "…", action: model.showSettings)
                    .keyboardShortcut(",", modifiers: .command)
            }
            CommandMenu(AppLocalization.text("Yozish")) {
                Button(
                    model.dictation.phase == .recording
                        ? AppLocalization.text("Yozishni tugatish")
                        : AppLocalization.text("Yozishni boshlash")
                ) {
                    model.toggleDictation()
                }
                .disabled(
                    !model.onboarding.isComplete
                        || [.preparing, .transcribing].contains(model.dictation.phase))
                Button(AppLocalization.text("Bekor qilish")) { model.dictation.discard() }.disabled(
                    !model.dictation.isBusy)
            }
            CommandGroup(replacing: .newItem) {
                Button(AppLocalization.text("Yangi qayd")) {
                    model.library.saveNote(.init())
                    model.destination = .notes
                }.keyboardShortcut("n").disabled(model.isPreparingUpdate || !model.library.isReady || !model.onboarding.isComplete)
            }
        }

    }
}

/// The status label is mounted even while its menu is closed. Resolve openWindow
/// in a live view environment, not in App before SwiftUI has installed its scenes.
private struct MenuBarLaunchLabel: View {
    let model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Image(nsImage: model.dictation.phase == .recording ? MenuBarIcon.recording : MenuBarIcon.mark)
            .accessibilityLabel("Echo")
            .onAppear {
                model.mainWindow.openWindow = { [openWindow] in openWindow(id: "main") }
            }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, ObservableObject {
    @Published private(set) var didFinishLaunching = false
    let model = AppModel()
    private var startupTask: Task<Void, Never>?
    private var launchedAtLogin = false
    private var notificationCoordinator: AppNotificationCoordinator?

    func applicationWillFinishLaunching(_ notification: Notification) {
        model.mainWindow.configureDockVisibility(preferences: model.preferences)
        observeAppearance()
        let coordinator = AppNotificationCoordinator(push: model.push, updates: model.updateNotifications)
        notificationCoordinator = coordinator
        UNUserNotificationCenter.current().delegate = coordinator
        model.updateNotifications.canDeliver = { [weak model] in
            guard let model else { return false }
            return !NSApp.isActive && model.onboarding.isComplete && !model.isReviewingOnboarding &&
                model.canInstallUpdate && !model.isPreparingUpdate
        }
        model.updateNotifications.onOpen = { [weak model] in
            model?.mainWindow.show()
            AppUpdateChecker.shared.showFromNotification()
        }
        launchedAtLogin = ApplicationLaunch.isLoginItem
        if launchedAtLogin { model.mainWindow.prepareForBackgroundLaunch() }
    }

    /// Applies the appearance preference app-wide through AppKit. SwiftUI's
    /// preferredColorScheme(nil) leaves a previously forced NSWindow appearance behind,
    /// so window borders and separators kept drawing dark after switching to System.
    private func observeAppearance() {
        withObservationTracking {
            NSApp.appearance = switch model.preferences.appearance {
            case "dark": NSAppearance(named: .darkAqua)
            case "light": NSAppearance(named: .aqua)
            default: nil
            }
        } onChange: { [weak self] in
            Task { @MainActor in self?.observeAppearance() }
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        UpdateInstallationLease.clear(for: Bundle.main.bundleURL)
        let updates = AppUpdateChecker.shared
        updates.onScheduledUpdate = { [weak model] update in
            model?.updateNotifications.schedule(update)
        }
        updates.onUpdateDismissed = { [weak model] in model?.updateNotifications.clearDelivered() }
        updates.configure(model: model)
        model.updateNotifications.configure(channel: updates.channel, installedBuild: AppUpdateChecker.installedBuild)
        // Some launches expose the Apple event only in didFinishLaunching.
        launchedAtLogin = launchedAtLogin || ApplicationLaunch.isLoginItem
        if launchedAtLogin {
            model.mainWindow.prepareForBackgroundLaunch()
        } else {
            model.mainWindow.show()
        }
        // Application lifetime owns restoration and the event tap, never a window's task.
        startupTask = Task { await model.start(launchedAtLogin: launchedAtLogin) }
        didFinishLaunching = true
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        // Startup owns service setup until local cleanup/session restoration finishes.
        guard !model.isRestoring else { return }
        model.refreshShortcutRegistration()
        model.loginItem.refresh()
        model.library.requestNotesSync()
        Task { await model.push?.refresh() }
        Task { await model.updateNotifications.refresh() }
        Task { await model.inbox?.refresh() }
    }
    func application(_ application: NSApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        model.push?.receivedToken(deviceToken)
    }
    func application(_ application: NSApplication, didFailToRegisterForRemoteNotificationsWithError error: any Error) {
        model.push?.registrationFailed()
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        model.mainWindow.show()
        return false
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let updater = AppUpdateChecker.shared
        let installingUpdate = updater.hasPendingInstallation || updater.isInstalling || model.isPreparingUpdate
        if model.updateBlockers.contains(.unsavedChanges) {
            let alert = NSAlert()
            alert.messageText = UpdateRestartBlocker.unsavedChanges.message
            alert.addButton(withTitle: AppLocalization.text("Davom etish"))
            _ = alert.runModal()
            return .terminateCancel
        }
        var allowDiscardingRecording = false
        if !installingUpdate && model.hasUnfinishedRecording {
            let alert = NSAlert()
            alert.messageText = AppLocalization.text("Yozuv davom etmoqda")
            alert.informativeText = AppLocalization.text("Chiqsangiz, tugallanmagan yozuv bekor qilinadi.")
            alert.addButton(withTitle: AppLocalization.text("Davom etish"))
            alert.addButton(withTitle: AppLocalization.text("Chiqish"))
            guard alert.runModal() == .alertSecondButtonReturn else { return .terminateCancel }
            allowDiscardingRecording = true
        }
        Task {
            do {
                await updater.waitForInstallationCancellation()
                if installingUpdate { try await model.prepareForUpdateInstallation() }
                let shouldTerminate = await model.shutdown(allowDiscardingRecording: allowDiscardingRecording && !installingUpdate)
                if shouldTerminate { startupTask?.cancel() }
                else { updater.installationWasCancelled() }
                sender.reply(toApplicationShouldTerminate: shouldTerminate)
            } catch {
                if case UpdateRestartError.blocked(let blockers) = error {
                    model.error = blockers.first?.message
                } else {
                    model.error = AppLocalization.error(error)
                }
                await model.cancelUpdateInstallation()
                updater.installationWasCancelled()
                sender.reply(toApplicationShouldTerminate: false)
            }
        }
        return .terminateLater
    }
}
