import SwiftUI

/// Share the bundled brand artwork between the splash and background launch notice.
struct AppBrandIcon: View {
    var body: some View {
        Image("EchoLogo")
            .resizable().interpolation(.high).scaledToFit()
    }
}
