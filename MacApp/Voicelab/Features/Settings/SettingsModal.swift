import SwiftUI

/// Settings float over the workspace in a panel with their own sidebar, like Wispr Flow.
/// Esc or a click on the dimmed workspace closes it.
struct SettingsModal: View {
    let model: AppModel
    let page: SettingsPage

    private var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color.black.opacity(0.22)
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture { model.dismissSettings() }
                    .accessibilityHidden(true)
                HStack(spacing: 0) {
                    sidebar
                    ColumnHairline()
                    VStack(alignment: .leading, spacing: 0) {
                        Text(AppLocalization.text(page.title))
                            .font(.system(size: 26, weight: .semibold)).tracking(-0.5)
                            .accessibilityAddTraits(.isHeader)
                            .padding(.horizontal, 32).padding(.top, 30).padding(.bottom, 10)
                        SettingsDetailView(model: model, page: page)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .background(Design.canvas)
                }
                // A little smaller than the workspace so it reads as a layer above it, with
                // the same rounded panel shape so it still feels like part of the app.
                .frame(width: max(0, geometry.size.width - 88), height: max(0, geometry.size.height - 64))
                .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 26, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1).allowsHitTesting(false)
                }
                .shadow(color: .black.opacity(0.18), radius: 30, y: 12)
                .accessibilityElement(children: .contain)
                .accessibilityAddTraits(.isModal)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background {
            Button(AppLocalization.text("Yopish")) { model.dismissSettings() }
                .keyboardShortcut(.cancelAction).hidden()
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 6) {
            ModalCloseButton { model.dismissSettings() }
                .padding(.leading, 6).padding(.bottom, 18)
            group("Sozlamalar")
            // The account (name, plan, sign out) lives in the sidebar's profile row.
            ForEach(SettingsPage.navigation) { row($0) }
            Spacer(minLength: 0)
            Text(verbatim: "Echo \(version)")
                .font(.system(size: 11)).foregroundStyle(.tertiary)
                .padding(.horizontal, 10).padding(.bottom, 4)
        }
        .padding(.horizontal, 10).padding(.top, 14).padding(.bottom, 16)
        .frame(width: 240)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Design.sidebar)
    }

    private func group(_ title: String) -> some View {
        Text(AppLocalization.text(title).uppercased(with: AppLocalization.shared.language.locale))
            .font(.system(size: 11, weight: .semibold)).tracking(0.6).foregroundStyle(.secondary)
            .padding(.horizontal, 10).padding(.bottom, 6)
            .accessibilityAddTraits(.isHeader)
    }

    private func row(_ destination: SettingsPage) -> some View {
        SettingsModalRow(isSelected: page == destination) {
            model.showSettings(page: destination)
        } label: {
            // Same metrics as the main sidebar's items, so both sidebars read as one app.
            HStack(spacing: 12) {
                WorkspaceAssetIcon(name: destination.workspaceIcon, size: 21)
                    .foregroundStyle(page == destination ? Design.tint : Color.secondary)
                    .frame(width: 24)
                Text(AppLocalization.text(destination.title)).font(.system(size: 14, weight: .medium)).lineLimit(1)
                    .foregroundStyle(page == destination ? Design.accent : Color.secondary)
                Spacer(minLength: 0)
                if destination == .notifications, let unread = model.inbox?.unread, unread > 0 {
                    Text(unread > 99 ? "99+" : String(unread))
                        .font(.system(size: 10, weight: .semibold)).monospacedDigit().foregroundStyle(.secondary)
                }
            }
            .frame(height: 44)
        }
    }
}

/// A settings sidebar row: soft accent pill when selected, faint highlight on hover.
private struct SettingsModalRow<Content: View>: View {
    let isSelected: Bool
    let action: () -> Void
    @ViewBuilder var label: Content
    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: action) {
            label
                .padding(.horizontal, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    isSelected ? Design.selection : hovering ? Design.tint.opacity(0.12) : .clear,
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.08), value: hovering)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// The red traffic light, closing the settings panel like a macOS window's close button.
private struct ModalCloseButton: View {
    let action: () -> Void
    @State private var hovering = false
    @Environment(\.controlActiveState) private var activeState

    var body: some View {
        Button(action: action) {
            Circle()
                .fill(activeState == .inactive && !hovering
                      ? Color.gray.opacity(0.35) : Color(red: 1.0, green: 0.37, blue: 0.34))
                .overlay(Circle().strokeBorder(.black.opacity(0.12), lineWidth: 0.5))
                .overlay {
                    Image(systemName: "xmark").font(.system(size: 8, weight: .heavy))
                        .foregroundStyle(.black.opacity(0.55)).opacity(hovering ? 1 : 0)
                }
                // Same size as the window's own close button (14 pt).
                .frame(width: 14, height: 14)
                .contentShape(Circle().inset(by: -6))
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .onHover { hovering = $0 }
        .help(AppLocalization.text("Yopish"))
        .accessibilityLabel(AppLocalization.text("Yopish"))
    }
}
