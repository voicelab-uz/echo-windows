import SwiftUI
import VoiceLabCore

struct WorkspaceNotificationsButton: View {
    let model: NotificationInboxModel
    let push: PushNotificationService?
    @State private var showsInbox = false
    var body: some View {
        Button { showsInbox.toggle() } label: {
            ZStack(alignment: .topTrailing) {
                AppIcon(systemName: "bell", size: 20)
                    .frame(width: 38, height: 38)
                if model.unread > 0 {
                    Circle().fill(Design.tint).frame(width: 6, height: 6)
                        .overlay(Circle().stroke(Design.sidebar, lineWidth: 2))
                        .offset(x: -6, y: 5)
                }
            }.contentShape(Circle())
        }
        .buttonStyle(.plain).foregroundStyle(Design.accent)
        .help(AppLocalization.text("Bildirishnomalar"))
        .accessibilityLabel(AppLocalization.text("Bildirishnomalar"))
        .accessibilityValue(AppLocalization.text("%d ta o‘qilmagan", model.unread))
        .popover(isPresented: $showsInbox, arrowEdge: .bottom) {
            NotificationInboxView(model: model, push: push)
        }
    }
}

struct NotificationInboxView: View {
    let model: NotificationInboxModel
    let push: PushNotificationService?
    var embedded = false
    var onOpen: (() -> Void)?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var pushIsOff: Bool {
        guard let push else { return false }
        return push.authorization != .authorized || !push.isEnabled || !push.preferences.hasEnabledCategory
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if model.items.isEmpty && model.isLoading {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity, minHeight: 160)
            } else if model.items.isEmpty && model.error == nil {
                emptyState
            } else if !model.items.isEmpty {
                if embedded {
                    notificationItems
                } else {
                    ScrollView { notificationItems }
                        .frame(height: min(400, CGFloat(model.items.count) * 96 + (model.nextCursor.isEmpty ? 8 : 48)))
                }
            }
            if let error = model.error {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                    Text(error).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    Button(AppLocalization.text("Qayta urinish")) { Task { await model.refresh(force: true) } }
                        .buttonStyle(.link).disabled(model.isLoading)
                }
                .font(.system(size: 12)).padding(.horizontal, 16).padding(.vertical, 12)
            }
            if !embedded, pushIsOff, let push { enablePrompt(push) }
        }
        .frame(width: embedded ? nil : 340)
        .frame(maxWidth: embedded ? .infinity : nil)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: model.unread)
        .task { await model.refresh(force: true) }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text(AppLocalization.text("Bildirishnomalar")).font(.system(size: 13, weight: .semibold))
            if model.unread > 0 {
                Text(model.unread > 99 ? "99+" : String(model.unread))
                    .font(.system(size: 10, weight: .semibold)).monospacedDigit()
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Design.tint.opacity(0.14), in: Capsule()).foregroundStyle(Design.tint)
            }
            Spacer()
            if model.unread > 0 {
                Button(AppLocalization.text("Barchasini o‘qilgan qilish")) { Task { await model.markRead() } }
                    .buttonStyle(.plain).font(.system(size: 11, weight: .medium)).foregroundStyle(Design.tint)
                    .disabled(model.isMarkingRead)
            }
        }
        .padding(.horizontal, 16).frame(height: 44)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            ZStack {
                Circle().fill(Color.primary.opacity(0.06)).frame(width: 44, height: 44)
                WorkspaceAssetIcon(name: .notifications, size: 20).foregroundStyle(.secondary)
            }
            .padding(.bottom, 2)
            Text(AppLocalization.text("Hozircha yangilik yo‘q")).font(.system(size: 13, weight: .semibold))
            Text(AppLocalization.text("Echo yangiliklari shu yerda ko‘rinadi."))
                .font(.system(size: 12)).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 32).padding(.horizontal, 24)
    }

    /// Settings owns its shared permission action; only the popover needs a footer.
    private func enablePrompt(_ push: PushNotificationService) -> some View {
        VStack(spacing: 0) {
            Divider()
            Button {
                if push.authorization == .denied {
                    push.openSystemSettings()
                } else {
                    Task { await push.setEnabled(true) }
                }
            } label: {
                Label(AppLocalization.text(push.authorization == .denied
                    ? "Bildirishnoma sozlamalarini ochish" : "Bildirishnomalarni yoqish"),
                    systemImage: "bell.badge")
                    .font(.system(size: 12))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16).frame(minHeight: 40)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain).foregroundStyle(Design.tint)
            .disabled(push.isUpdating)
        }
    }

    private var notificationItems: some View {
        LazyVStack(spacing: 0) {
            ForEach(model.items) { item in
                NotificationInboxRow(item: item) {
                    // Dismiss the embedded settings before routing: a notification
                    // targeting Settings must be able to open it again.
                    if let onOpen { onOpen() }
                    model.open(item)
                    if onOpen == nil { dismiss() }
                }
                if item.id != model.items.last?.id { Divider().padding(.leading, 56) }
            }
            if !model.nextCursor.isEmpty {
                Button(AppLocalization.text("Yana ko‘rsatish")) { Task { await model.loadMore() } }
                    .buttonStyle(.plain).font(.system(size: 12, weight: .medium)).foregroundStyle(Design.tint)
                    .padding(12).disabled(model.isLoading)
            }
        }
        .padding(.vertical, 4)
    }
}

private struct NotificationInboxRow: View {
    let item: InboxNotification
    let open: () -> Void
    @State private var hovered = false
    var body: some View {
        Button(action: open) {
            HStack(alignment: .top, spacing: 12) {
                ZStack {
                    Circle().fill(Color.primary.opacity(0.06)).frame(width: 28, height: 28)
                    WorkspaceAssetIcon(name: .notifications, size: 14).foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(item.title).font(.system(size: 13, weight: item.read ? .medium : .semibold))
                            .foregroundStyle(.primary).fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 6)
                        if let date = item.date {
                            Text(date, style: .relative).font(.system(size: 11)).foregroundStyle(.tertiary)
                                .lineLimit(1)
                        }
                    }
                    Text(item.body).font(.system(size: 12)).foregroundStyle(.secondary)
                        .lineSpacing(2).lineLimit(3).fixedSize(horizontal: false, vertical: true)
                }
                Circle().fill(Design.tint).frame(width: 6, height: 6).padding(.top, 5)
                    .opacity(item.read ? 0 : 1)
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(hovered ? Color.primary.opacity(0.05) : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).onHover { hovered = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityHint(AppLocalization.text("Ochish"))
    }
}
