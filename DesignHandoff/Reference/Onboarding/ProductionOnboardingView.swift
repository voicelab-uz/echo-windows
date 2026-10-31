import AVFoundation
import SwiftUI
import VoiceLabCore

/// Production composition for the same screens used in design review.
struct ProductionOnboardingView: View {
    let app: AppModel
    private var language: WelcomeLanguage {
        WelcomeLanguage(rawValue: app.preferences.interfaceLanguage.rawValue) ?? .uzbek
    }
    private var languageSelection: Binding<WelcomeLanguage> {
        Binding(get: { language }, set: { value in
            if let selection = InterfaceLanguage(rawValue: value.rawValue) {
                app.preferences.interfaceLanguage = selection
            }
        })
    }
    @State private var journey = OnboardingJourney()
    @State private var permissions = OnboardingPermissionsService()
    @State private var accessibilityGuide = AccessibilityPermissionGuide()
    @State private var trial: TryItModel
    @State private var questionnaire: QuestionnaireModel
    @State private var contextOwner: String?
    @State private var initialized = false
    @State private var finishing = false
    @State private var completionError: String?
    @State private var keyChoice: OnboardingKeyChoice
    @State private var applyKey: Task<Void, Never>?
    /// A chosen key not yet saved; the copy names it immediately instead of after the save.
    @State private var pendingShortcut: DictationShortcut?
    /// The shortcut onboarding should name right now.
    private var shownShortcut: DictationShortcut { pendingShortcut ?? app.preferences.shortcut }
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(app: AppModel) {
        self.app = app
        // Onboarding copy and key art name the user's real shortcut, not a fixed fn.
        OnboardingShortcutName.label = app.preferences.shortcut.displayName
        _keyChoice = State(initialValue: Self.choice(for: app.preferences.shortcut))
        _journey = State(initialValue: OnboardingJourney(persistsProgress: !app.isReviewingOnboarding))
        let session = AppOnboardingSession(app: app)
        _trial = State(initialValue: TryItModel(service: session))
        _questionnaire = State(initialValue: QuestionnaireModel(service: session,
            readDraft: { app.library.snapshot.questionnaireDraft },
            writeDraft: { app.library.saveQuestionnaireDraft($0) },
            flushDraft: { try await app.library.flush() }))
    }
    private var setupStep: Binding<SetupExperience.Step> {
        Binding(get: { SetupExperience.Step(rawValue: journey.route.rawValue) ?? .microphone },
                set: { navigate(OnboardingJourney.Route(rawValue: $0.rawValue) ?? .microphone) })
    }
    /// Choosing a key saves it as the real dictation shortcut, so the press-to-test on this
    /// step and the practice later use the same key. Re-registering touches the event tap and
    /// the system Fn preference, so it waits until the selection animation has settled and
    /// only the last of several quick clicks is applied.
    private var keyBinding: Binding<OnboardingKeyChoice> {
        Binding(get: { keyChoice }, set: { choice in
            keyChoice = choice
            let shortcut: DictationShortcut? = switch choice {
            case .fn: .fn
            case .rightCommand: DictationShortcut(keyCode: 54, modifiers: 0, keyLabel: "⌘")
            case .rightOption: DictationShortcut(keyCode: 61, modifiers: 0, keyLabel: "⌥")
            case .custom: nil
            }
            applyKey?.cancel()
            pendingShortcut = nil
            app.setOnboardingShortcutPending(false)
            guard let shortcut, shortcut != app.preferences.shortcut else { return }
            pendingShortcut = shortcut
            app.setOnboardingShortcutPending(true)
            applyKey = Task {
                try? await Task.sleep(for: .milliseconds(400))
                guard !Task.isCancelled, keyChoice == choice else { return }
                try? app.changeShortcut(shortcut)
                pendingShortcut = nil
                app.setOnboardingShortcutPending(false)
                updateShortcut()
            }
        })
    }
    /// The physical keys a shortcut uses: its key plus the (left) keys of its modifiers.
    private static func keyCodes(of shortcut: DictationShortcut) -> Set<UInt16> {
        var codes: Set<UInt16> = [shortcut.keyCode]
        let flags = NSEvent.ModifierFlags(rawValue: UInt(shortcut.modifiers))
        if flags.contains(.control) { codes.insert(59) }
        if flags.contains(.option) { codes.insert(58) }
        if flags.contains(.shift) { codes.insert(56) }
        if flags.contains(.command) { codes.insert(55) }
        return codes
    }
    private static func choice(for shortcut: DictationShortcut) -> OnboardingKeyChoice {
        switch (shortcut.keyCode, shortcut.modifiers) {
        case (63, 0): .fn
        case (54, 0): .rightCommand
        case (61, 0): .rightOption
        default: .custom
        }
    }
    private var device: Binding<String> {
        Binding(get: { app.preferences.microphoneID }, set: { app.preferences.microphoneID = $0 })
    }
    private var alphabet: Binding<Bool> {
        Binding(get: { app.preferences.uzbekAlphabet == .modern },
                set: { app.preferences.uzbekAlphabet = $0 ? .modern : .current })
    }
    private var stage: Int {
        journey.route.stage >= 3 && trial.requiresSignIn ? 3 : journey.route.stage
    }

    var body: some View {
        // Child copy reads this while rendering below, so set it before they do.
        let _ = OnboardingShortcutName.label = shownShortcut.displayName
        VStack(spacing: 0) {
            WelcomeProgress(stages: language.copy.stages, activeIndex: stage)
            if initialized { content } else { ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity) }
            if let error = completionError ?? app.library.saveError ?? app.error {
                HStack(spacing: 12) {
                    Text(error).font(WelcomeType.font(size: 12)).fixedSize(horizontal: false, vertical: true)
                    if completionError != nil {
                        Button(language.permissionsCopy.continueTitle) { finish() }
                    }
                }
                .foregroundStyle(WelcomePalette.coral).padding(16)
            }
        }
        .frame(minWidth: 860, minHeight: 640)
        .background(WelcomePalette.canvas).foregroundStyle(WelcomePalette.ink)
        .tint(WelcomePalette.ink)
        .modifier(HiddenWorkspaceTitle())
        .environment(\.onboardingShortcutLabel, shownShortcut.displayName)
        .environment(\.layoutDirection, language.isRightToLeft ? .rightToLeft : .leftToRight)
        .disabled(finishing)
        .onAppear {
            app.registerOnboardingUpdateState(trial: trial, questionnaire: questionnaire,
                                              permissions: permissions, owner: app.account?.id)
        }
        .overlay { if finishing { ProgressView().padding(20).background(.regularMaterial, in: .rect(cornerRadius: 12)) } }
        .overlay(alignment: .topTrailing) {
            if app.isReviewingOnboarding {
                Button {
                    app.isReviewingOnboarding = false
                    app.destination = .history
                } label: {
                    Label(AppLocalization.text("Yopish"), systemImage: "xmark")
                }
                .buttonStyle(.bordered).keyboardShortcut(.cancelAction).padding(16)
            }
        }
        .task {
            guard !initialized else { return }
            permissions.refresh()
            journey.restore(owner: app.account?.id, permissionsReady: permissions.ready)
            contextOwner = app.account?.id
            trial.restoreCompletedTrial(journey.triedVoice)
            if !app.isReviewingOnboarding { trial.text = app.library.snapshot.onboardingPracticeDraft ?? "" }
            trial.restore()
            initialized = true
        }
        .task(id: initialized) {
            guard initialized else { return }
            // Permission can be revoked while any step is visible, including
            // while Echo is in the background behind System Settings.
            while !Task.isCancelled {
                refreshPermissions()
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
            }
        }
        .onChange(of: trial.requiresSignIn) { _, needsSignIn in
            guard initialized, journey.route.stage >= 3 else { return }
            if needsSignIn { questionnaire.cancel() }
            else { prepareContext() }
            updateShortcut()
        }
        .onChange(of: journey.route) { _, route in
            if route != .permissions { accessibilityGuide.dismiss() }
            if route.stage >= 3 && !trial.requiresSignIn { prepareContext() }
            updateShortcut()
        }
        .onChange(of: permissions.ready) { _, _ in updateShortcut() }
        .onChange(of: permissions.accessibility) { _, granted in
            if granted { accessibilityGuide.dismiss() }
        }
        .onChange(of: initialized) { _, _ in updateShortcut() }
        .onChange(of: questionnaire.isFinished) { _, done in
            if done && journey.route.stage >= 3 { journey.navigate(.practice) }
            updateShortcut()
        }
        .onChange(of: questionnaire.failure) { _, failure in
            if failure == .authentication {
                // Keep the durable journal, then reload it after login instead of
                // leaving a previously loaded model stuck in its auth failure state.
                questionnaire.reset()
                trial.sessionExpired()
            }
        }
        .onChange(of: app.needsSignIn) { _, required in
            if required {
                trial.sessionExpired()
                questionnaire.reset()
                app.useOnboardingShortcut(false)
            }
        }
        .onChange(of: trial.successfulTrials) { old, count in
            if count > old { journey.recordVoiceSuccess(); OnboardingHaptics.play(.confirmation) }
        }
        .onChange(of: trial.text) { _, _ in app.checkpointOnboardingPractice() }
        .onChange(of: app.account?.id) { old, new in
            if old != nil && old != new {
                trial.sessionExpired(); questionnaire.reset()
                contextOwner = nil
                journey.restore(owner: new, permissionsReady: permissions.ready)
            }
            app.registerOnboardingUpdateState(trial: trial, questionnaire: questionnaire,
                                              permissions: permissions, owner: new)
            if new != nil && old != new && !app.isReviewingOnboarding {
                trial.text = app.library.snapshot.onboardingPracticeDraft ?? ""
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshPermissions()
            updateShortcut()
            if journey.route.stage >= 3 && !trial.requiresSignIn { prepareContext() }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willCloseNotification)) { event in
            if let window = event.object as? NSWindow, window.canBecomeMain {
                trial.cancel(); questionnaire.cancel(); accessibilityGuide.dismiss(); app.useOnboardingShortcut(false)
                app.presentOnboardingTrial(nil)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
            app.useOnboardingShortcut(false)
        }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("Echo.stopOnboarding"))) { _ in
            trial.cancel(); questionnaire.cancel(); accessibilityGuide.dismiss()
            app.presentOnboardingTrial(nil)
        }
        .onDisappear {
            app.checkpointOnboardingPractice()
            applyKey?.cancel()
            app.setOnboardingShortcutPending(false)
            trial.cancel(); questionnaire.cancel(); accessibilityGuide.dismiss(); app.useOnboardingShortcut(false)
            app.presentOnboardingTrial(nil)
        }
    }

    @ViewBuilder private var content: some View {
        switch journey.route {
        case .welcome:
            WelcomeLanding(language: languageSelection) { navigate(.permissions) }
        case .permissions:
            PermissionsConcept(language: languageSelection,
                allowed: Binding(get: { permissions.allowed }, set: { _ in }),
                onBack: { navigate(.welcome) }, onContinue: {
                    permissions.refresh()
                    if permissions.ready { journey.continueAfterPermissions() }
                }, onRequest: { kind in
                    Task {
                        await permissions.request(kind)
                        guard journey.route == .permissions else { return }
                        if kind == .accessibility && !permissions.accessibility {
                            accessibilityGuide.show(language: language)
                        }
                    }
                },
                microphoneNeedsSettings: permissions.microphone == .denied,
                accessibilityNeedsSettings: permissions.accessibilityRequested,
                requesting: permissions.requesting,
                notice: permissions.microphone == .restricted ? language.permissionsCopy.restricted :
                    permissions.settingsFailed ? language.permissionsCopy.settingsUnavailable :
                    (permissions.microphone == .denied || permissions.accessibilityRecheckFailed) ? language.permissionsCopy.recovery : nil,
                onRevealApp: { NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL]) },
                onRecheckAccessibility: permissions.recheckAccessibility,
                accessibilityRecheckFailed: permissions.accessibilityRecheckFailed)
        case .microphone, .shortcut, .alphabet:
            SetupExperience(language: languageSelection, onBack: { navigate(.permissions) }, step: setupStep,
                            usesNewAlphabet: alphabet, deviceID: device,
                            shortcutError: app.onboardingShortcutError,
                            onRetryShortcut: { refreshPermissions(); updateShortcut() },
                            onOpenShortcutSettings: { permissions.openSettings(.accessibility) },
                            keyChoice: keyBinding,
                            customRecorder: AnyView(ShortcutField(model: app) { _ in }),
                            customKeys: Self.keyCodes(of: app.preferences.shortcut)) {
                navigate(.signIn)
            }
        case .signIn, .aboutYou, .practice:
            sessionContent
        }
    }

    @ViewBuilder private var sessionContent: some View {
        if !trial.requiresSignIn && !questionnaire.isFinished {
            QuestionnaireConcept(language: languageSelection, model: questionnaire) {
                if questionnaire.index > 0 { questionnaire.back() }
                else { questionnaire.cancel(); navigate(.alphabet) }
            }
        } else {
            TryItExperience(language: languageSelection, model: trial, usesSystemIsland: true, isCompletingSignIn: app.isCompletingSignIn, signInRetryAt: app.signInRetryAt, onBack: {
                trial.cancel()
                if questionnaire.isFinished { questionnaire.review(); navigate(.aboutYou) }
                else { navigate(.alphabet) }
            }, onNext: finish)
            .background {
                if !trial.requiresSignIn && questionnaire.isFinished {
                    OnboardingFnInput { keyCode, pressed, focused in
                        trial.receive(keyCode: keyCode, functionDown: pressed, isFocused: focused,
                                      deviceID: app.preferences.microphoneID,
                                      usesNewAlphabet: app.preferences.uzbekAlphabet == .modern)
                    }.frame(width: 0, height: 0)
                }
            }
        }
    }

    private func prepareContext() {
        guard let owner = app.account?.id, !app.needsSignIn, app.library.isReady else { return }
        if contextOwner != owner {
            questionnaire.reset(); contextOwner = owner; journey.signedIn(owner: owner)
        }
        if journey.route == .signIn { journey.navigate(.aboutYou) }
        questionnaire.load()
        if questionnaire.isFinished && journey.route != .practice { journey.navigate(.practice) }
    }
    private func updateShortcut() {
        let practicing = journey.route == .practice && !trial.requiresSignIn && questionnaire.isFinished
        app.presentOnboardingTrial(practicing ? trial : nil)
        app.useOnboardingShortcut(NSApp.isActive && (journey.route == .shortcut ||
            practicing))
    }
    private func refreshPermissions() {
        permissions.refresh()
        guard initialized, journey.route.stage > 1, !permissions.ready else { return }
        trial.cancel(); questionnaire.cancel(); app.useOnboardingShortcut(false); journey.requirePermissions()
    }
    private func navigate(_ route: OnboardingJourney.Route) {
        OnboardingHaptics.play(.navigation)
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) { journey.navigate(route) }
    }
    private func finish() {
        guard !finishing, questionnaire.isFinished, trial.canContinue else { return }
        permissions.refresh()
        guard permissions.ready else { journey.requirePermissions(); return }
        if app.isReviewingOnboarding && app.onboarding.isComplete {
            app.isReviewingOnboarding = false
            app.destination = .history
            return
        }
        finishing = true; completionError = nil
        Task {
            let completed = await app.onboarding.finishExperience()
            finishing = false
            if completed {
                app.library.saveOnboardingPracticeDraft(nil)
                app.useOnboardingShortcut(false)
            }
            else { completionError = app.onboarding.error ?? language.setupCopy.permissionError }
        }
    }
}
