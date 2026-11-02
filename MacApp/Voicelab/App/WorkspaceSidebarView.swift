import SwiftUI
import VoiceLabCore

/// The workspace sidebar: Echo branding, the workspace sections, and at the bottom
/// Settings (which opens the floating settings panel) and the profile.
struct WorkspaceSidebarView: View {
    @Bindable var model: AppModel
    /// Collapsed, the sidebar is a narrow strip of icons (toggled from the toolbar).
    var isExpanded = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                AppBrandIcon().frame(width: 30, height: 30).layoutPriority(1)
                    .modifier(EchoLogoEndpoint(location: .workspace))
                if isExpanded {
                    Text("Echo").font(.system(size: 23, weight: .semibold)).tracking(-0.7).lineLimit(1)
                        .transition(.opacity)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 17).padding(.top, 26).padding(.bottom, 34)
            .accessibilityElement(children: .ignore).accessibilityLabel("Echo")

            ScrollView {
                VStack(spacing: 6) {
                    ForEach(Destination.allCases) { destination in
                        // Selection is instant: no page cross-fade and no pill sliding
                        // across the items in between.
                        Button { model.destination = destination } label: {
                            navigationLabel(destination.title, icon: destination.workspaceIcon,
                                            selected: model.destination == destination)
                                .foregroundStyle(model.destination == destination ? Design.accent : .secondary)
                                .background {
                                    if model.destination == destination {
                                        RoundedRectangle(cornerRadius: 10)
                                            .fill(Design.selection)
                                    }
                                }
                        }
                        .buttonStyle(SidebarItemStyle(selected: model.destination == destination))
                        .help(AppLocalization.text(destination.title))
                        .accessibilityLabel(AppLocalization.text(destination.title))
                        .accessibilityAddTraits(model.destination == destination ? .isSelected : [])
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 10)
            }
            .scrollIndicators(.hidden)

            VStack(spacing: 6) {
                Divider().padding(.horizontal, 6).padding(.bottom, 6)
                Button(action: model.showSettings) {
                    navigationLabel("Sozlamalar", icon: .settings, selected: model.isShowingSettings)
                        .foregroundStyle(model.isShowingSettings ? Design.accent : .secondary)
                        .background {
                            if model.isShowingSettings {
                                RoundedRectangle(cornerRadius: 10).fill(Design.selection)
                            }
                        }
                        .overlay(alignment: .trailing) {
                            if let unread = model.inbox?.unread, unread > 0 {
                                Circle().fill(Design.tint).frame(width: 6, height: 6)
                                    .padding(.trailing, 12)
                                    .accessibilityHidden(true)
                            }
                        }
                }
                .buttonStyle(SidebarItemStyle(selected: model.isShowingSettings))
                // The panel's open animation must not carry the highlight: it switches instantly.
                .transaction { $0.animation = nil }
                .help(AppLocalization.text("Sozlamalar"))
                .accessibilityLabel(AppLocalization.text("Sozlamalar"))
                WorkspaceProfileRow(model: model, isExpanded: isExpanded)
            }
            .padding(.horizontal, 10).padding(.bottom, 14)
        }
        .foregroundStyle(Design.accent)
        .frame(width: isExpanded ? 224 : 64, alignment: .leading)
        .background(Design.sidebar)
    }

    private func navigationLabel(_ title: String, icon: WorkspaceAssetIcon.Name, selected: Bool) -> some View {
        HStack(spacing: 12) {
            // The active item's icon takes the accent color, so it follows the chosen accent.
            WorkspaceAssetIcon(name: icon, size: 21).frame(width: 24).layoutPriority(1)
                .foregroundStyle(selected ? Design.tint : Color.secondary)
            if isExpanded {
                Text(AppLocalization.text(title))
                    .font(.system(size: 14, weight: .medium))
                    .lineLimit(1).transition(.opacity)
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: 44)
        .contentShape(RoundedRectangle(cornerRadius: 10))
    }
}

/// The hover highlight shared by every sidebar row, matching the profile row: a soft tint
/// behind unselected rows while the pointer is over them.
struct SidebarItemStyle: ButtonStyle {
    let selected: Bool
    func makeBody(configuration: Configuration) -> some View {
        SidebarItemBody(configuration: configuration, selected: selected)
    }
}

private struct SidebarItemBody: View {
    let configuration: ButtonStyleConfiguration
    let selected: Bool
    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        configuration.label
            .background {
                // A clearly visible accent tint under the pointer; quick in and out.
                if hovering && !selected {
                    RoundedRectangle(cornerRadius: 10).fill(Design.tint.opacity(0.12))
                }
            }
            .onHover { hovering = $0 }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.08), value: hovering)
    }
}
