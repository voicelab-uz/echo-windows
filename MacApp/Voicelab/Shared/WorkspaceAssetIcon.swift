import SwiftUI

/// Bundled vector artwork shared with the web frontend. Template rendering lets
/// the same asset follow selection, appearance, and accessibility colors.
struct WorkspaceAssetIcon: View {
    enum Name: String {
        case statistics, notifications, home, notes, knowledge, settings, search, copy, edit
        case mic, shield, keyboard, users, warning, info, history, slider, developer
        case conversation, doc, clipboard, upload, download, share, delete, plus, play, pause
        case translation, bookmark, folder, key, star, send, inbox
        case speechToText = "speech-to-text"
        case textToSpeech = "text-to-speech"
        case sidebarOpen = "sidebar-open"
        case sidebarClosed = "sidebar-closed"

        var assetName: String { "WorkspaceIcon-" + rawValue }
    }

    let name: Name
    var size: CGFloat = 20

    var body: some View {
        Group {
            if name == .statistics {
                Image(systemName: "chart.bar.xaxis")
                    .font(.system(size: size, weight: .regular))
            } else {
                Image(name.assetName)
                    .renderingMode(.template)
                    .resizable()
                    .scaledToFit()
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

extension Destination {
    var workspaceIcon: WorkspaceAssetIcon.Name {
        switch self {
        case .history: .home
        case .statistics: .statistics
        case .vocabulary: .knowledge
        case .notes: .notes
        }
    }
}
