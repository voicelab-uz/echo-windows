import SwiftUI
import VoiceLabCore

struct RootView: View {
    @Bindable var model: AppModel
    @State private var splashIntroFinished = false
    @State private var completionInFlight = false
    /// Home's recording search lives in the window toolbar, so its text lives here.
    @State private var historyQuery = ""
    @State private var sidebarVisible = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var showsSplash: Bool { model.isRestoring || !splashIntroFinished }

    private var showsOnboarding: Bool {
        return model.account == nil || model.needsSignIn || !model.onboarding.isComplete || model.isReviewingOnboarding
    }

    var body: some View {
        ZStack {
            if showsSplash {
                LaunchSplashView { splashIntroFinished = true }
                    .transition(.opacity)
            } else if let error = model.restorationError {
                VStack(spacing: 16) {
                    AppIcon(systemName: "lock.circle", size: 36).foregroundStyle(.secondary)
                    Text(AppLocalization.text("Saqlangan sessiyani ochib bo‘lmadi")).font(.title2)
                    Text(AppLocalization.text(error)).foregroundStyle(.secondary).textSelection(.enabled)
                        .multilineTextAlignment(.center)
                    Text(AppLocalization.text("Saqlangan sessiyani qayta o‘qish uchun urinib ko‘ring."))
                        .font(.callout).foregroundStyle(.secondary)
                    Button(AppLocalization.text("Qayta urinish")) {
                        Task { await model.retrySessionRestore() }
                    }
                    .buttonStyle(.borderedProminent)
                }
                .padding(32).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if showsOnboarding {
                ProductionOnboardingView(app: model)
                    .transition(.opacity)
            } else {
                workspace
                    .transition(.opacity)
            }
        }
        .frame(minWidth: 760, minHeight: 560)
        .background(Design.canvas)
        .tint(Design.accent)
        .environment(\.echoLogoInFlight, completionInFlight)
        .allowsHitTesting(!completionInFlight)
        .overlayPreferenceValue(EchoLogoBounds.self) { anchors in
            GeometryReader { geometry in
                if completionInFlight {
                    OnboardingCompletionView(
                        source: anchors[.onboarding].map { geometry[$0] },
                        destination: anchors[.workspace].map { geometry[$0] },
                        canvasSize: geometry.size,
                        onRevealHome: model.onboarding.finishCelebration,
                        onFinished: { completionInFlight = false }
                    )
                    .transition(.identity)
                }
            }
        }
        .animation(.easeOut(duration: reduceMotion ? 0.15 : 0.32), value: showsSplash)
        .animation(
            .easeInOut(duration: reduceMotion ? 0.15 : 0.4), value: model.onboarding.isCelebratingCompletion
        )
        .onChange(of: model.onboarding.isCelebratingCompletion, initial: true) { _, celebrating in
            if celebrating {
                completionInFlight = true
            } else if !model.onboarding.isComplete {
                completionInFlight = false
            }
        }
        .onChange(of: model.account?.id) { _, accountID in
            completionInFlight = false
            if accountID == nil { model.dismissSettings() }
        }
        .onChange(of: model.needsSignIn) { _, required in
            if required {
                completionInFlight = false
                model.dismissSettings()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) {
            _ in
            Task { await model.onboarding.syncPending() }
            Task { await model.refreshUsage() }
        }
    }
    private var workspace: some View {
        // Keep both columns in one SwiftUI layout tree. A native navigation split
        // negotiates child hosting-view minimum sizes as account/usage data arrives;
        // that feedback can repeatedly invalidate the main window's constraints.
        HStack(spacing: 0) {
            WorkspaceSidebarView(model: model, isExpanded: sidebarVisible)
                .allowsHitTesting(!model.isShowingSettings)
                .frame(width: sidebarVisible ? 224 : 64, alignment: .leading)
                .frame(maxHeight: .infinity)
                .clipped()
            VStack(spacing: 0) {
                if let error = model.error {
                    ErrorBanner(message: error) { model.error = nil }.padding([.horizontal, .top], 20)
                }
                if let error = model.library.saveError {
                    ErrorBanner(
                        message: AppLocalization.text("Saqlash tugamadi: %@", AppLocalization.text(error))
                    ).padding([.horizontal, .top], 20)
                }
                if let notice = model.onboarding.syncNotice {
                    HStack {
                        Text(AppLocalization.text(notice)).font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button(AppLocalization.text("Qayta sinxronlash")) {
                            Task { await model.onboarding.syncPending() }
                        }
                    }.padding(.horizontal, 20).padding(.top, 10)
                }
                if !model.library.isReady {
                    EmptyContent(
                        symbol: "lock.trianglebadge.exclamationmark",
                        title: AppLocalization.text("Lokal ma’lumot ochilmadi"),
                        subtitle:
                            AppLocalization.text(
                                "Ma’lumotlar himoyalangan holda saqlab qolindi. Yuqoridagi xatoni tekshiring."
                            ))
                } else {
                    switch model.destination {
                    case .history:
                        HistoryView(model: model, query: historyQuery)
                            // Sidebar motion must not animate transcript reflow or scrolling.
                            .transaction { $0.animation = nil }
                    case .statistics: StatisticsView(app: model)
                    case .vocabulary: VocabularyView(library: model.library)
                    case .notes: NotesView(library: model.library)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // Keep scrollbars clear of the panel's rounded corners and edge: shorter, and
            // floating a few points inside instead of stuck to the border.
            .contentMargins(.vertical, 18, for: .scrollIndicators)
            .contentMargins(.trailing, 5, for: .scrollIndicators)
            .modifier(WorkspacePanel(radius: 26))
            // Selectable transcript text keeps its I-beam cursor rects even under the
            // Settings panel; the page takes no pointer input while Settings is open.
            .allowsHitTesting(!model.isShowingSettings)
            .padding(.top, 8)
            .padding(.trailing, 10)
            .padding(.bottom, 10)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Design.sidebar)
        .modifier(HiddenWorkspaceTitle())
        .toolbar {
            if #available(macOS 26.0, *) {
                ToolbarItem(placement: .navigation) { sidebarToggle }
                    .sharedBackgroundVisibility(.hidden)
                ToolbarSpacer(.flexible, placement: .primaryAction)
                ToolbarItemGroup(placement: .primaryAction) { toolbarControls }
                    .sharedBackgroundVisibility(.hidden)
            } else {
                ToolbarItem(placement: .navigation) { sidebarToggle }
                ToolbarItem(placement: .principal) {
                    Color.clear.frame(width: 1, height: 1).accessibilityHidden(true)
                }
                ToolbarItemGroup(placement: .primaryAction) { toolbarControls }
            }
        }
        .overlay {
            if let page = model.settingsPage {
                SettingsModal(model: model, page: page)
                    .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.98)))
            }
        }
        .animation(reduceMotion ? nil : .snappy(duration: 0.22), value: model.isShowingSettings)
    }

    private var sidebarToggle: some View {
        WorkspaceSidebarToggle(isExpanded: sidebarVisible) {
            withAnimation(reduceMotion ? nil : WorkspaceMotion.layout) { sidebarVisible.toggle() }
        }
    }

    /// Appearance and notifications stay in the toolbar; the profile lives in the sidebar.
    @ViewBuilder private var toolbarControls: some View {
        if model.destination == .history && model.library.isReady {
            ExpandingSearchField(prompt: AppLocalization.text("Yozuvlarni izlash"), text: $historyQuery)
        }
        WorkspaceAppearanceButton(preferences: model.preferences)
        if let inbox = model.inbox {
            WorkspaceNotificationsButton(model: inbox, push: model.push)
        }
    }
}

struct HiddenWorkspaceTitle: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 15.0, *) {
            content.toolbar(removing: .title)
        } else {
            content
        }
    }
}
