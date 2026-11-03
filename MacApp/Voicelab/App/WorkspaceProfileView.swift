import SwiftUI
import VoiceLabCore

struct WorkspaceProfileButton: View {
    let model: AppModel
    @State private var showsProfile = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var remainingFraction: Double? { model.usage?.remainingFraction }
    private var balanceDescription: String {
        guard let usage = model.usage else { return AppLocalization.text("Akkaunt") }
        return usage.enabled
            ? AppLocalization.text("%@ · %d min qoldi", usage.planName ?? "Echo", usage.remaining / 60)
            : AppLocalization.text("Faol tarif kerak")
    }

    var body: some View {
        Button {
            showsProfile.toggle()
        } label: {
            ZStack {
                Circle().strokeBorder(Design.accent.opacity(0.12), lineWidth: 2.5)
                if let remainingFraction {
                    Circle()
                        .trim(from: 0, to: remainingFraction)
                        .stroke(Design.tint, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .padding(1.25)
                }
                WorkspaceAvatar(name: model.account?.name ?? "Echo", size: 27)
            }
            .frame(width: 38, height: 38)
            .contentShape(Circle())
            .animation(reduceMotion ? nil : .smooth(duration: 0.25), value: remainingFraction)
        }
        .buttonStyle(.plain).foregroundStyle(Design.accent)
        .help((model.account?.name ?? "Echo") + " · " + balanceDescription)
        .accessibilityLabel(AppLocalization.text("Akkaunt") + ": " + (model.account?.name ?? "Echo"))
        .accessibilityValue(balanceDescription)
        .popover(isPresented: $showsProfile) { WorkspaceProfilePopover(model: model) }
    }
}

private struct WorkspaceAvatar: View {
    let name: String
    let size: CGFloat

    private var initials: String {
        let words = name.split(whereSeparator: \.isWhitespace)
        let letters = [words.first?.first, words.count > 1 ? words.last?.first : nil].compactMap { $0 }
        return letters.isEmpty ? "E" : String(letters).uppercased()
    }

    var body: some View {
        Text(initials)
            .font(.system(size: size * 0.34, weight: .semibold, design: .rounded))
            .foregroundStyle(Design.accent)
            .frame(width: size, height: size)
            .background {
                Circle().fill(Design.selection.gradient)
                Circle().strokeBorder(Design.accent.opacity(0.12), lineWidth: 1)
            }
            .accessibilityHidden(true)
    }
}

/// The profile at the bottom of the sidebar: avatar with the remaining-minutes ring,
/// name and plan. Opens the same profile popover as the toolbar button did.
struct WorkspaceProfileRow: View {
    let model: AppModel
    /// Collapsed sidebars show only the avatar and its ring.
    var isExpanded = true
    @State private var showsProfile = false
    @State private var hovering = false
    /// What the ring currently draws. Starts empty and sweeps up to the balance each
    /// time the window appears, so the remaining minutes catch the eye.
    @State private var shownFraction: Double = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var remainingFraction: Double? { model.usage?.remainingFraction }
    private var detail: String {
        guard let usage = model.usage else { return AppLocalization.text("Akkaunt") }
        return usage.enabled
            ? AppLocalization.text("%@ · %d min qoldi", usage.planName ?? "Echo", usage.remaining / 60)
            : AppLocalization.text("Faol tarif kerak")
    }

    private var name: String { model.account?.name ?? "Echo" }
    private var accessibilityName: String { AppLocalization.text("Akkaunt") + ": " + name }
    private var hoverAnimation: Animation? { reduceMotion ? nil : .easeOut(duration: 0.08) }

    private var button: some View {
        Button { showsProfile.toggle() } label: { label }
            .buttonStyle(.plain).foregroundStyle(Design.accent)
            .onHover { hovering = $0 }
            .animation(hoverAnimation, value: hovering)
            .help(name + " · " + detail)
            .accessibilityLabel(accessibilityName)
            .accessibilityValue(detail)
    }

    var body: some View {
        button
            // Open upward from the row so the popover stays inside the window.
            .popover(isPresented: $showsProfile, arrowEdge: .top) { WorkspaceProfilePopover(model: model) }
            .onAppear { sweepRing() }
            .onChange(of: remainingFraction) { _, _ in fillRing() }
    }

    private func sweepRing() {
        shownFraction = 0
        fillRing(delay: 0.35)
    }

    private func fillRing(delay: Double = 0) {
        let target = remainingFraction ?? 0
        guard !reduceMotion else { shownFraction = target; return }
        withAnimation(.easeOut(duration: 1.1).delay(delay)) { shownFraction = target }
    }

    private var label: some View {
        HStack(spacing: 10) {
            avatar
            if isExpanded {
                VStack(alignment: .leading, spacing: 1) {
                    Text(model.account?.name ?? "Echo").font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    Text(detail).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                }
                .transition(.opacity)
                Spacer(minLength: 0)
            }
        }
        .padding(6)
        .background(highlight, in: RoundedRectangle(cornerRadius: 10))
        .contentShape(RoundedRectangle(cornerRadius: 10))
    }

    private var highlight: Color { hovering || showsProfile ? Design.tint.opacity(0.12) : .clear }

    private var avatar: some View {
        ZStack {
            Circle().strokeBorder(Design.accent.opacity(0.12), lineWidth: 1.75)
            if remainingFraction != nil {
                Circle()
                    .trim(from: 0, to: shownFraction)
                    .stroke(Design.tint, style: StrokeStyle(lineWidth: 1.75, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .padding(0.875)
            }
            WorkspaceAvatar(name: model.account?.name ?? "Echo", size: 27)
        }
        .frame(width: 36, height: 36)
    }
}

private struct WorkspaceProfilePopover: View {
    let model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var confirmSignOut = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                WorkspaceAvatar(name: model.account?.name ?? "Echo", size: 44)
                VStack(alignment: .leading, spacing: 5) {
                    Text(model.account?.name ?? "Echo").font(.system(size: 15, weight: .semibold))
                    if let email = model.account?.email {
                        Text(email).font(.system(size: 12)).foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let usage = model.usage {
                UsageBalanceView(usage: usage)
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Design.surface, in: RoundedRectangle(cornerRadius: 12))
            }
            if let error = model.usageRefreshError {
                VStack(alignment: .leading, spacing: 8) {
                    Text(error).font(.caption).foregroundStyle(.secondary)
                    Button(AppLocalization.text("Qayta urinish")) {
                        Task { await model.refreshUsage() }
                    }.disabled(model.isRefreshing)
                }
            }
            Divider()
            Button {
                dismiss()
                model.showSettings()
            } label: {
                AppLabel(AppLocalization.text("Sozlamalar"), systemImage: "gearshape")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            Link(destination: RuntimeBackend.environment.websiteOrigin.appendingPathComponent("app")) {
                AppLabel(AppLocalization.text("Echo akkauntini ochish"), systemImage: "arrow.up.right.square")
            }
            .foregroundStyle(.secondary)
            if model.account != nil {
                Button(role: .destructive) { confirmSignOut = true } label: {
                    AppLabel(AppLocalization.text("Akkauntdan chiqish"),
                             systemImage: "rectangle.portrait.and.arrow.right")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain).foregroundStyle(.red)
                .disabled(model.dictation.isBusy || model.isSigningOut)
            }
        }
        .padding(20).frame(width: 300)
        .task { await model.refreshUsage() }
        .confirmationDialog(AppLocalization.text("Akkauntdan chiqilsinmi?"), isPresented: $confirmSignOut) {
            Button(AppLocalization.text("Akkauntdan chiqish"), role: .destructive) {
                dismiss()
                Task { await model.signOut() }
            }
        } message: {
            Text(AppLocalization.text("Qaydlar va lug‘at shu akkaunt uchun shifrlangan holda qoladi."))
        }
    }
}

struct WorkspaceAppearanceButton: View {
    @Bindable var preferences: Preferences
    @State private var transition = AppearanceTransition()
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var target: String { colorScheme == .dark ? "light" : "dark" }
    private var label: String { AppLocalization.text(colorScheme == .dark ? "Yorug‘" : "Qorong‘i") }

    var body: some View {
        Button {
            let appearance = target
            transition.change(to: appearance, reduceMotion: reduceMotion) {
                preferences.appearance = appearance
            }
        } label: {
            AppIcon(systemName: colorScheme == .dark ? "sun.max" : "moon", size: 18)
                .contentTransition(reduceMotion ? .identity : .symbolEffect(.replace))
                .frame(width: 32, height: 32).contentShape(Circle())
        }
        .buttonStyle(.plain).foregroundStyle(Design.accent)
        .background(AppearanceTransitionAnchor(transition: transition))
        .help(label).accessibilityLabel(label)
        .onChange(of: preferences.appearance) { _, appearance in
            transition.cancelIfDestinationChanged(to: appearance)
        }
        .onChange(of: reduceMotion) { _, reduced in
            if reduced { transition.cancel() }
        }
        .contextMenu {
            ForEach(["system", "light", "dark"], id: \.self) { appearance in
                Button {
                    transition.cancel()
                    preferences.appearance = appearance
                } label: {
                    HStack {
                        Text(
                            AppLocalization.text(
                                appearance == "system"
                                    ? "Tizimga mos" : appearance == "light" ? "Yorug‘" : "Qorong‘i"))
                        if preferences.appearance == appearance { AppIcon(systemName: "checkmark") }
                    }
                }
            }
        }
    }
}
