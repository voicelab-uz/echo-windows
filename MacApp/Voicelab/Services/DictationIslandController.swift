import AppKit
import Observation
import SwiftUI
import VoiceLabCore

/// Owns the panel lifecycle. Audio frames are observed only by the waveform view.
@MainActor
final class DictationIslandController {
    private weak var app: AppModel?
    private let recording: IslandRecordingSession
    private var panel: DictationIslandPanel?
    private let presentation = IslandPresentation()
    private let notices = IslandNoticeCenter()
    private var observers: [NSObjectProtocol] = []
    private var workspaceObserver: NSObjectProtocol?
    private var pointerMonitors: [Any] = []
    private var revealTask: Task<Void, Never>?
    private var running = false
    private var generation = UUID()
    private var transitionID = UUID()
    private var lastPhase: DictationModel.Phase?
    private var lastError: String?
    private var lastWarning: String?
    private var lastCopied = false
    private var lastAccountID: String?
    private var hiddenForNow = false
    private var wantsVisible = false
    private var screenID: CGDirectDisplayID?
    private var handledLaunchAnnouncement = false
    private var sessionMonitor: SessionReturnMonitor?
    private var lastGreetingAt: TimeInterval?

    init(app: AppModel) {
        self.app = app
        recording = IslandRecordingSession(dictation: app.dictation)
    }

    func presentTrial(_ trial: TryItModel?) {
        guard recording.trial !== trial else { return }
        // Invalidate subscriptions to the old owner before observing the new one.
        generation = UUID()
        recording.trial = trial
        notices.dismiss()
        lastPhase = nil
        lastError = nil
        lastWarning = nil
        hiddenForNow = false
        if trial == nil { hideImmediately() }
        observe()
    }

    func start() {
        guard !running else { return }
        running = true
        observers.append(
            NotificationCenter.default.addObserver(
                forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
            ) { @Sendable [weak self] _ in
                Task { @MainActor [weak self] in self?.screenChanged() }
            })
        workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main
        ) { @Sendable [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.running, self.wantsVisible, SessionReturnMonitor.desktopAvailable else { return }
                self.positionPanel()
                self.panel?.orderFrontRegardless()
                self.refreshPointer()
            }
        }
        let monitor = SessionReturnMonitor(onReturn: { [weak self] in
            guard let self, self.running else { return }
            self.app?.refreshShortcutRegistration(rebuild: true)
            self.showReturnGreeting()
            self.generation = UUID()
            self.observe()
        }, onUnavailable: { [weak self] in
            guard let self else { return }
            self.app?.suspendShortcutForSessionChange()
            if self.notices.notice?.kind == .startup { self.notices.dismiss() }
            self.hideImmediately()
        })
        sessionMonitor = monitor
        monitor.start()
        installPointerMonitors()
        observe()
    }

    func stop() {
        running = false
        sessionMonitor?.stop(); sessionMonitor = nil
        generation = UUID()
        recording.trial = nil
        hideImmediately()
        notices.dismiss()
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
        if let workspaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(workspaceObserver)
        }
        workspaceObserver = nil
        pointerMonitors.forEach(NSEvent.removeMonitor)
        pointerMonitors.removeAll()
        panel?.close()
        panel = nil
        lastPhase = nil
    }

    private func observe() {
        guard running, let app else { return }
        let id = generation
        let state = withObservationTracking {
            (
                eligible: app.library.isReady && !app.isSigningOut && !app.needsSignIn
                    && app.restorationError == nil
                    && (recording.isTrial || app.onboarding.isComplete || app.onboarding.step.isPractice),
                phase: recording.phase, busy: recording.isBusy,
                accountID: app.library.accountID, signingOut: app.isSigningOut,
                // Trial errors remain beside its editor; stale workspace notices
                // must not replace the onboarding recording controls.
                error: recording.isTrial ? nil : app.dictation.error ?? app.error,
                needsPlanUpgrade: !recording.isTrial && app.dictation.error != nil
                    && app.dictation.needsPlanUpgrade,
                heardNothing: !recording.isTrial && app.dictation.error != nil && app.dictation.heardNothing,
                copied: !recording.isTrial && app.dictation.copiedToClipboard,
                warning: recording.isTrial ? nil : app.dictation.warning ?? app.library.saveError,
                noticeID: notices.notice?.id, hovered: notices.hovered,
                backgroundLaunchFinished: app.didFinishBackgroundLaunch
            )
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.running, self.generation == id else { return }
                self.observe()
            }
        }
        if state.accountID != lastAccountID || state.signingOut {
            notices.dismiss()
            lastError = nil
            lastWarning = nil
            lastAccountID = state.accountID
            hideImmediately()
        }
        if state.backgroundLaunchFinished, !handledLaunchAnnouncement {
            handledLaunchAnnouncement = true
            showReturnGreeting()
        }
        // The login greeting can also offer a way back into unfinished onboarding.
        guard
            state.eligible || notices.notice?.kind == .startup
                || presentation.notice?.kind == .startup
        else {
            notices.dismiss()
            lastError = state.error
            lastWarning = state.warning
            lastPhase = state.phase
            hideImmediately()
            return
        }

        let wasBusy = lastPhase.map { [.preparing, .recording, .transcribing].contains($0) } ?? false
        if (state.phase == .preparing && lastPhase != .preparing) || (state.busy && !wasBusy) {
            notices.dismiss()
            hiddenForNow = false
            selectScreen()
        }
        if let error = state.error, error != lastError, state.heardNothing {
            // Silence is not a failure: a short, friendly nudge instead of an error.
            hiddenForNow = false
            notices.show(
                IslandNotice(
                    kind: .warning, title: "Sizni eshita olmadik",
                    message: "Biroz balandroq gapirib, qayta urinib ko‘ring.", duration: 5))
        } else if let error = state.error, error != lastError {
            hiddenForNow = false
            notices.show(
                IslandNotice(
                    kind: state.needsPlanUpgrade ? .upgrade : .error,
                    title: state.needsPlanUpgrade ? "Yozish limiti tugadi" : "Amalni bajarib bo‘lmadi",
                    message: state.needsPlanUpgrade ? "Joriy tarifingizdagi ovozli yozish vaqti tugadi. Ko‘proq vaqt olish uchun yuqoriroq tarifga o‘ting." : error,
                    action: state.needsPlanUpgrade ? .openPlans : nil,
                    duration: state.needsPlanUpgrade ? 20 : 8))
        } else if state.copied && !lastCopied {
            // Nothing could take the text: say where it went, not that something failed.
            hiddenForNow = false
            notices.show(
                IslandNotice(
                    kind: .success, title: "Buferga nusxalandi",
                    message: "Kerakli joyga ⌘V bilan joylang.", duration: 4))
        } else if let warning = state.warning, warning != lastWarning {
            hiddenForNow = false
            notices.show(
                IslandNotice(
                    kind: .warning, title: "E’tibor bering",
                    message: warning, action: app.dictation.result == nil ? nil : .copyResult,
                    duration: 7))
        }
        lastPhase = state.phase
        lastError = state.error
        lastWarning = state.warning
        lastCopied = state.copied
        let visible = (state.busy || notices.notice != nil) && !hiddenForNow && SessionReturnMonitor.desktopAvailable
        if visible {
            // Keep the outgoing content during retraction, so a dismissed notice
            // doesn't flash into a recording capsule on its way out.
            presentation.notice = notices.notice
        }
        setVisible(visible)
    }

    private func showReturnGreeting() {
        guard running, let app, SessionReturnMonitor.desktopAvailable,
              !app.isRestoring, !recording.isBusy, !app.isSigningOut,
              app.dictation.error == nil, app.error == nil,
              app.dictation.warning == nil, app.library.saveError == nil,
              notices.notice == nil else { return }
        let now = ProcessInfo.processInfo.systemUptime
        guard lastGreetingAt.map({ now - $0 >= 5 }) ?? true else { return }
        lastGreetingAt = now
        let ready = app.library.isReady && !app.needsSignIn && app.restorationError == nil
            && app.onboarding.isComplete && app.isDictationShortcutRegistered
        hiddenForNow = false
        selectScreen()
        notices.show(IslandNotice(
            kind: .startup, title: ready ? "Echo tayyor" : "Echo ishga tushdi",
            message: ready
                ? AppLocalization.text("%@ tugmasini bosib gapiring", app.preferences.shortcut.displayName)
                : "Davom etish uchun Echo’ni oching.",
            duration: 4))
    }

    private func setVisible(_ visible: Bool) {
        guard visible != wantsVisible else {
            if visible { refreshPointer() }
            return
        }
        wantsVisible = visible
        revealTask?.cancel()
        revealTask = nil
        if visible {
            if panel == nil { createPanel() }
            if screenID == nil { selectScreen() }
            positionPanel()
            guard let panel else { return }
            let alreadyVisible = panel.isVisible
            panel.ignoresMouseEvents = true
            panel.orderFrontRegardless()
            if alreadyVisible {
                animate(expanded: true)
            } else {
                // Commit the folded first frame before starting the spring.
                // The panel's frame never animates or drives SwiftUI layout.
                revealTask = Task { [weak self] in
                    do { try await Task.sleep(for: .milliseconds(20)) } catch { return }
                    guard let self, self.running, self.wantsVisible else { return }
                    self.animate(expanded: true)
                }
            }
        } else {
            panel?.ignoresMouseEvents = true
            if notices.hovered { notices.hover(false) }
            animate(expanded: false)
        }
    }

    private func animate(expanded: Bool) {
        let transition = UUID()
        transitionID = transition
        let animation: Animation =
            NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            ? .easeOut(duration: 0.15)
            : .smooth(duration: expanded ? 0.52 : 0.44)
        withAnimation(animation, completionCriteria: .removed) {
            presentation.expanded = expanded
        } completion: { [weak self] in
            guard let self, self.transitionID == transition else { return }
            if !expanded && !self.wantsVisible {
                self.panel?.orderOut(nil)
                self.presentation.notice = nil
            }
            self.refreshPointer()
        }
        refreshPointer()
    }

    private func createPanel() {
        guard let app else { return }
        let panel = DictationIslandPanel(
            contentRect: NSRect(origin: .zero, size: presentation.layout.panelSize),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = "Echo — yozuv boshqaruvi"
        panel.level = .statusBar
        panel.collectionBehavior = [
            .canJoinAllSpaces, .fullScreenAuxiliary, .canJoinAllApplications, .ignoresCycle,
        ]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isMovableByWindowBackground = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.isExcludedFromWindowsMenu = true
        panel.acceptsMouseMovedEvents = true
        panel.animationBehavior = .none
        let host = IslandHostingView(
            rootView: DictationIslandView(
                model: app.dictation, recording: recording, preferences: app.preferences, notices: notices,
                presentation: presentation,
                openMain: { [weak app] in app?.mainWindow.show() },
                hide: { [weak self] in self?.hideForNow() }))
        host.sizingOptions = []
        // Placement already accounts for the camera. Do not add another safe
        // area inset between the hardware edge and the SwiftUI surface.
        host.safeAreaRegions = []
        panel.contentView = host
        self.panel = panel
    }

    private func selectScreen() {
        // Keep the chosen display for the whole recording, even if the pointer
        // moves to another display while speaking.
        screenID = IslandGeometry.screen(nearest: NSEvent.mouseLocation).map(IslandGeometry.displayID)
    }

    private func positionPanel() {
        guard let panel else { return }
        let screen =
            NSScreen.screens.first { IslandGeometry.displayID($0) == screenID }
            ?? IslandGeometry.screen(nearest: NSEvent.mouseLocation)
        guard let screen else { return }
        screenID = IslandGeometry.displayID(screen)
        let layout = IslandGeometry.layout(on: screen)
        presentation.layout = layout
        let frame = IslandGeometry.frame(on: screen, layout: layout)
        if panel.frame != frame { panel.setFrame(frame, display: true) }
    }

    private func screenChanged() {
        guard running else { return }
        positionPanel()
        refreshPointer()
    }

    private func hideForNow() {
        hiddenForNow = true
        setVisible(false)
    }

    private func hideImmediately() {
        transitionID = UUID()
        wantsVisible = false
        revealTask?.cancel()
        revealTask = nil
        presentation.expanded = false
        presentation.notice = nil
        panel?.ignoresMouseEvents = true
        panel?.orderOut(nil)
        if notices.hovered { notices.hover(false) }
    }

    private func installPointerMonitors() {
        if let monitor = NSEvent.addGlobalMonitorForEvents(
            matching: .mouseMoved,
            handler: { [weak self] _ in
                Task { @MainActor [weak self] in self?.refreshPointer() }
            }
        ) {
            pointerMonitors.append(monitor)
        }
        if let monitor = NSEvent.addLocalMonitorForEvents(
            matching: .mouseMoved,
            handler: { [weak self] event in
                Task { @MainActor [weak self] in self?.refreshPointer() }
                return event
            }
        ) {
            pointerMonitors.append(monitor)
        }
    }

    private func refreshPointer() {
        guard let panel, panel.isVisible, wantsVisible, presentation.expanded else {
            panel?.ignoresMouseEvents = true
            return
        }
        let point = panel.convertPoint(fromScreen: NSEvent.mouseLocation)
        let layout = presentation.layout
        let size = layout.surfaceSize(notice: presentation.notice)
        let local = CGPoint(
            x: point.x - (panel.frame.width - size.width) / 2,
            y: panel.frame.height - point.y)
        let shape = CameraIslandShape(
            cameraWidth: layout.cameraWidth, cameraHeight: layout.cameraHeight,
            shoulder: 10, bottomRadius: 24, excludesCamera: true)
        let inside = shape.path(in: CGRect(origin: .zero, size: size)).contains(local)
        panel.ignoresMouseEvents = !inside
        if notices.hovered != inside { notices.hover(inside) }
    }
}

private final class IslandHostingView: NSHostingView<DictationIslandView> {
    override var acceptsFirstResponder: Bool { false }
    override var needsPanelToBecomeKey: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
