import SwiftUI
import VoiceLabCore

struct OnboardingFlowView: View {
    let app: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var movingForward = true
    private var model: OnboardingModel { app.onboarding }
    private var sections: [String] {
        [
            AppLocalization.text("Boshlash"), AppLocalization.text("Ruxsatlar"),
            AppLocalization.text("Sozlash"), AppLocalization.text("O‘rganish"),
            AppLocalization.text("Shaxsiylashtirish"),
        ]
    }
    private var ownsCTA: Bool { [.welcome, .signIn, .tryIntro, .personalize].contains(model.step) }

    var body: some View {
        VStack(spacing: 0) {
            header
            journey
                .padding(.horizontal, 32).padding(.top, 4).padding(.bottom, 6)
            stepArea
            if model.step != .welcome { footer }
        }
        .background(OnboardingTheme.canvas)
        .foregroundStyle(OnboardingTheme.ink)
        .tint(OnboardingTheme.ink)
        .symbolRenderingMode(.hierarchical)
        .animation(reduceMotion ? nil : .smooth(duration: 0.3), value: model.step)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) {
            _ in
            model.refreshPermissions()
        }
        .onChange(of: model.accessibilityGranted) { _, _ in app.refreshShortcutRegistration() }
        .onChange(of: app.preferences.appearance) { _, appearance in
            let theme = appearance == "system" ? "auto" : appearance
            if model.progress.answers.theme != theme { model.setAnswer(\.theme, to: theme) }
        }
        .onChange(of: app.dictation.phase) { _, _ in model.recordPracticeResult() }
        .onChange(of: model.step) { old, next in movingForward = next.index >= old.index }
        .task(id: model.step) {
            guard model.step == .permissions else { return }
            while !Task.isCancelled {
                model.refreshPermissions()
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
            }
        }
        .onDisappear {
            model.stopMicrophoneTest()
            if !model.isComplete { app.dictation.discard() }
        }
    }

    private var header: some View {
        HStack(spacing: 18) {
            OnboardingWordmark(height: 30)
            Spacer(minLength: 12)
            languageMenu
            WorkspaceAppearanceButton(preferences: app.preferences)
        }
        .padding(.horizontal, 36).frame(height: 60)
    }

    private var journey: some View {
        VStack(spacing: 10) {
            HStack(spacing: 0) {
                ForEach(sections.indices, id: \.self) { index in
                    let current = index == model.step.section
                    let done = index < model.step.section
                    HStack(spacing: 7) {
                        ZStack {
                            Circle().fill(current ? OnboardingTheme.ink : OnboardingTheme.panel)
                            if done {
                                Image(systemName: "checkmark").font(.system(size: 12, weight: .semibold))
                            } else {
                                Text("\(index + 1)").font(.system(size: 12, weight: .semibold))
                            }
                        }
                        .foregroundStyle(current ? OnboardingTheme.surface : OnboardingTheme.muted)
                        .frame(width: 24, height: 24)
                        Text(sections[index])
                            .font(.system(size: 11, weight: current ? .semibold : .regular))
                            .foregroundStyle(current ? OnboardingTheme.ink : OnboardingTheme.muted)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity)
                    .accessibilityElement(children: .combine)
                    .accessibilityAddTraits(current ? .isSelected : [])
                }
            }
            ProgressView(value: Double(model.step.index + 1), total: Double(OnboardingStep.allCases.count))
                .progressViewStyle(.linear).tint(OnboardingTheme.glow)
                .frame(maxWidth: 240)
                .accessibilityLabel(AppLocalization.text("%d-qadam, jami 15", model.step.index + 1))
        }
        .frame(maxWidth: 700)
    }

    private var stepArea: some View {
        GeometryReader { viewport in
            ScrollView {
                VStack(spacing: 10) {
                    if let error = app.error { ErrorBanner(message: error) { app.error = nil } }
                    if let error = model.error { ErrorBanner(message: error) { model.error = nil } }
                    if let error = app.library.saveError { ErrorBanner(message: error) }
                    if model.isPreparing {
                        ProgressView(AppLocalization.text("Akkaunt sozlamalari yuklanmoqda…")).padding(40)
                    } else {
                        stepContent
                            .transition(
                                reduceMotion
                                    ? .opacity
                                    : .asymmetric(
                                        insertion: .opacity.combined(
                                            with: .offset(x: movingForward ? 16 : -16)),
                                        removal: .opacity))
                    }
                }
                .environment(\.onboardingCompact, viewport.size.height < 540)
                .padding(.horizontal, 24).padding(.vertical, viewport.size.height < 540 ? 8 : 16)
                .frame(maxWidth: .infinity)
                .frame(minHeight: viewport.size.height)
            }
            .scrollIndicators(.hidden)
            .scrollBounceBehavior(.basedOnSize)
            .id(model.step)
        }
    }

    private var languageMenu: some View {
        Menu {
            ForEach(InterfaceLanguage.allCases) { language in
                Button {
                    app.preferences.interfaceLanguage = language
                } label: {
                    if app.preferences.interfaceLanguage == language {
                        Label(language.title, systemImage: "checkmark")
                    } else {
                        Text(verbatim: language.title)
                    }
                }
            }
        } label: {
            AppLabel(app.preferences.interfaceLanguage.title, systemImage: "globe")
                .font(.system(size: 12)).foregroundStyle(OnboardingTheme.muted)
        }
        .menuStyle(.borderlessButton).fixedSize()
        .accessibilityLabel(AppLocalization.text("Ilova tili"))
    }

    private var footer: some View {
        HStack {
            if model.step != .welcome && model.step != .aboutYou {
                Button {
                    model.back()
                } label: {
                    AppLabel(AppLocalization.text("Orqaga"), systemImage: "arrow.left").frame(minWidth: 88)
                }.buttonStyle(OnboardingButtonStyle(variant: .ghost, height: 36))
                    .disabled(
                        app.isSigningIn || app.dictation.isBusy || model.isFinishing || model.isPreparing)
            }
            Spacer()
            if !ownsCTA {
                if model.step.skippable && !model.canContinue {
                    Button(AppLocalization.text("O‘tkazib yuborish")) { model.skip() }
                        .buttonStyle(OnboardingButtonStyle(variant: .ghost))
                        .disabled(app.dictation.isBusy)
                }
                Button {
                    if model.step == .finish { Task { await model.finish() } } else { model.next() }
                } label: {
                    HStack(spacing: 8) {
                        if model.isFinishing { ProgressView().controlSize(.small) }
                        Text(
                            model.step == .finish
                                ? AppLocalization.text("Yakunlash") : AppLocalization.text("Davom etish"))
                    }.frame(minWidth: 80)
                }
                .buttonStyle(OnboardingButtonStyle()).disabled(!model.canContinue)
                .keyboardShortcut(.defaultAction)
            }
        }
        .frame(maxWidth: 880).padding(.horizontal, 36)
        .frame(height: 56).padding(.bottom, 20)
    }

    @ViewBuilder private var stepContent: some View {
        switch model.step {
        case .welcome: OnboardingWelcome(onStart: model.next)
        case .signIn: OnboardingSignIn(app: app)
        case .aboutYou: OnboardingChoices(model: model, kind: .role)
        case .typingPlaces: OnboardingChoices(model: model, kind: .useCases)
        case .permissions: OnboardingPermissions(model: model)
        case .microphone: OnboardingMicrophone(model: model)
        case .shortcut: OnboardingShortcut(app: app)
        case .alphabet: OnboardingAlphabet(model: model)
        case .tryIntro: OnboardingPracticeIntro(onStart: model.next)
        case .tryMessage, .tryEmail, .tryList:
            OnboardingPractice(model: model, dictation: app.dictation, step: model.step)
        case .timeSavings: OnboardingTimeSavings(model: model)
        case .personalize: OnboardingPersonalize(model: model)
        case .finish: OnboardingFinish()
        }
    }
}
