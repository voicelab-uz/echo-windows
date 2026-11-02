import AppKit
import SwiftUI

@main struct EchoAuthLayoutRegression {
    @MainActor static func size<V: View>(_ view: V, width: CGFloat) -> CGSize {
        let host = NSHostingView(rootView: view.frame(width: width))
        host.layoutSubtreeIfNeeded()
        return host.fittingSize
    }
    @MainActor static func main() {
        _ = NSApplication.shared
        for width: CGFloat in [260, 320, 390] {
            for type: DynamicTypeSize in [.large, .accessibility3] {
                let idle = size(EchoAuthStatusRegion(isBusy: false, error: nil, loadingText: "Signing in…").environment(\.dynamicTypeSize, type), width: width)
                let busy = size(EchoAuthStatusRegion(isBusy: true, error: nil, loadingText: "Signing in…").environment(\.dynamicTypeSize, type), width: width)
                let failed = size(EchoAuthStatusRegion(isBusy: false, error: String(repeating: "A readable retry message. ", count: 20), loadingText: "Signing in…").environment(\.dynamicTypeSize, type), width: width)
                precondition(idle.height > 0 && idle.height.isFinite)
                precondition(abs(idle.height - busy.height) < 0.5 && abs(idle.height - failed.height) < 0.5,
                             "Auth status/error changed stack height and recentered the welcome screen")
            }
            for title in ["Continue with Google", "Google bilan kirish va Apple’ni ulash"] {
                let idle = size(EchoGoogleSignInLabel(icon: Image(systemName: "g.circle"), title: title, isBusy: false, height: 56), width: width)
                let busy = size(EchoGoogleSignInLabel(icon: Image(systemName: "g.circle"), title: title, isBusy: true, height: 56), width: width)
                precondition(abs(idle.height - 56) < 0.5 && abs(busy.height - idle.height) < 0.5)
                precondition(abs(idle.width - busy.width) < 0.5, "Google spinner changed the button width")
            }
        }
        print("Auth layout regression passed: actual SwiftUI regions keep identical idle/loading/error and button geometry at narrow widths and accessibility sizes")
    }
}
