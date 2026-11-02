import SwiftUI

/// A single semantic bridge for app artwork. System-only controls retain their
/// familiar SF Symbol when the frontend has no equivalent vector.
struct AppIcon: View {
    let systemName: String
    var size: CGFloat = 16

    var body: some View {
        if let asset = Self.assets[systemName] {
            WorkspaceAssetIcon(name: asset, size: size)
        } else {
            Image(systemName: systemName)
                .font(.system(size: size, weight: .regular))
                .frame(width: size, height: size)
                .accessibilityHidden(true)
        }
    }

    private static let assets: [String: WorkspaceAssetIcon.Name] = [
        "chart.bar": .statistics,
        "bell": .notifications, "bell.fill": .notifications,
        "mic": .mic, "mic.fill": .mic,
        "checkmark.shield": .shield, "checkmark.shield.fill": .shield,
        "keyboard": .keyboard, "keyboard.fill": .keyboard,
        "person.2": .users, "person.2.fill": .users,
        "exclamationmark.triangle": .warning, "exclamationmark.triangle.fill": .warning,
        "exclamationmark.circle": .warning, "exclamationmark.circle.fill": .warning,
        "info.circle": .info, "info.circle.fill": .info,
        "clock.arrow.circlepath": .history,
        "slider.horizontal.3": .slider,
        "chevron.left.forwardslash.chevron.right": .developer, "curlybraces": .developer,
        "message": .conversation, "text.bubble": .conversation,
        "doc.text": .doc, "doc": .doc, "doc.on.clipboard": .clipboard,
        "square.and.arrow.up": .share, "square.and.arrow.down": .download,
        "arrow.up.doc": .upload, "trash": .delete, "trash.fill": .delete,
        "plus": .plus, "play": .play, "play.fill": .play, "pause.fill": .pause,
        "character.bubble": .translation, "waveform": .speechToText,
        "bookmark": .bookmark, "folder": .folder, "key": .key, "star": .star,
        "paperplane": .send, "tray": .inbox,
        "house": .home, "house.fill": .home,
        "note.text": .notes, "list.bullet": .notes,
        "book": .knowledge, "character.book.closed": .knowledge,
        "textformat.abc": .knowledge, "text.quote": .conversation,
        "gearshape": .settings, "magnifyingglass": .search,
        "doc.on.doc": .copy, "pencil": .edit, "pencil.line": .edit, "square.and.pencil": .edit,
        "sidebar.left": .sidebarOpen,
    ]
}

struct AppLabel: View {
    let title: String
    let systemImage: String

    init(_ title: String, systemImage: String) {
        self.title = title
        self.systemImage = systemImage
    }

    var body: some View {
        Label {
            Text(title)
        } icon: {
            AppIcon(systemName: systemImage, size: 15)
        }
    }
}
