import AppKit
import Observation

struct IslandNotice: Identifiable {
    enum Kind { case error, warning, success, startup, upgrade }
    enum Action { case copyResult, openPlans }
    let id = UUID()
    let kind: Kind
    let title: String
    let message: String
    var action: Action? = nil
    var duration: TimeInterval = 8

    @MainActor var height: CGFloat {
        if kind == .startup {
            let messageBounds = (AppLocalization.text(message) as NSString).boundingRect(
                with: NSSize(width: 248, height: CGFloat.greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                attributes: [.font: NSFont.systemFont(ofSize: 12)])
            return max(72, 24 + 16 + 5 + ceil(messageBounds.height))
        }
        // Match the rendered stack: 12-point vertical padding, a 26-point
        // close control, 8-point spacing and the actual wrapped text height.
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 3
        let messageBounds = (AppLocalization.text(message) as NSString).boundingRect(
            with: NSSize(width: 336, height: CGFloat.greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: NSFont.systemFont(ofSize: 12), .paragraphStyle: paragraph])
        let titleBounds = (AppLocalization.text(title) as NSString).boundingRect(
            with: NSSize(width: kind == .upgrade ? 268 : 272, height: CGFloat.greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: NSFont.systemFont(ofSize: 13, weight: .semibold)])
        let header = max(26, ceil(titleBounds.height))
        let actionHeight: CGFloat = action == nil ? 0 : action == .openPlans ? 40 : 32
        return min(300, 24 + header + 8 + ceil(messageBounds.height) + actionHeight)
    }
}

/// Newest notice wins. Hover pauses both expiry and its close ring.
@MainActor @Observable
final class IslandNoticeCenter {
    private(set) var notice: IslandNotice?
    private(set) var hovered = false
    private(set) var remaining: TimeInterval = 0
    private(set) var deadline: Date?
    @ObservationIgnored private var expiry: Task<Void, Never>?

    func show(_ notice: IslandNotice) {
        expiry?.cancel()
        self.notice = notice
        remaining = notice.duration
        deadline = nil
        if !hovered { resume() }
    }
    func dismiss() {
        // Repeated lifecycle updates must not re-trigger observation when empty.
        guard notice != nil else { return }
        expiry?.cancel()
        expiry = nil
        notice = nil
        deadline = nil
        remaining = 0
    }
    func hover(_ inside: Bool) {
        hovered = inside
        if inside {
            if let deadline { remaining = max(0, deadline.timeIntervalSinceNow) }
            deadline = nil
            expiry?.cancel()
            expiry = nil
        } else {
            resume()
        }
    }
    func progress(at date: Date) -> Double {
        guard let notice, notice.duration > 0 else { return 0 }
        return min(1, max(0, (deadline?.timeIntervalSince(date) ?? remaining) / notice.duration))
    }
    private func resume() {
        guard let notice, deadline == nil else { return }
        deadline = .now.addingTimeInterval(remaining)
        let delay = remaining
        expiry = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            guard let self, self.notice?.id == notice.id else { return }
            self.dismiss()
        }
    }
}
