import SwiftUI

struct ContentView: View {
    let model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        RootView(model: model)
            .background(MainWindowAttachment(presenter: model.mainWindow).frame(width: 0, height: 0))
            .onAppear {
                model.mainWindow.openWindow = { [openWindow] in openWindow(id: "main") }
            }
    }
}

#Preview {
    OnboardingFlowView(app: AppModel())
        .frame(width: 1120, height: 760)
}
