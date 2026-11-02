import SwiftUI

enum EchoLogoLocation: Hashable { case onboarding, workspace }

struct EchoLogoBounds: PreferenceKey {
    static let defaultValue: [EchoLogoLocation: Anchor<CGRect>] = [:]
    static func reduce(
        value: inout [EchoLogoLocation: Anchor<CGRect>], nextValue: () -> [EchoLogoLocation: Anchor<CGRect>]
    ) {
        value.merge(nextValue(), uniquingKeysWith: { _, next in next })
    }
}

private struct EchoLogoInFlightKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
    var echoLogoInFlight: Bool {
        get { self[EchoLogoInFlightKey.self] }
        set { self[EchoLogoInFlightKey.self] = newValue }
    }
}

/// Anchors remain in layout while one overlay owns the moving artwork.
struct EchoLogoEndpoint: ViewModifier {
    let location: EchoLogoLocation
    @Environment(\.echoLogoInFlight) private var inFlight
    func body(content: Content) -> some View {
        content
            .anchorPreference(key: EchoLogoBounds.self, value: .bounds) { [location: $0] }
            .opacity(inFlight ? 0 : 1)
            .animation(nil, value: inFlight)
    }
}
