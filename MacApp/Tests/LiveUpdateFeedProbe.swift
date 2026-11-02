import AppKit
@preconcurrency import Sparkle

/// A separate, disposable app probes the public signed feed. It never installs
/// an update, opens Echo's library, requests microphone access, or signs in.
@MainActor
final class LiveUpdateFeedProbe: NSObject, SPUUpdaterDelegate {
    private var updater: SPUUpdater?
    private var foundBuild: String?

    func start() {
        let updater = SPUUpdater(hostBundle: .main, applicationBundle: .main,
            userDriver: SPUStandardUserDriver(hostBundle: .main, delegate: nil), delegate: self)
        self.updater = updater
        do {
            try updater.start()
            updater.checkForUpdateInformation()
        } catch { finish("Updater could not start: \((error as NSError).code)", code: 1) }
        Task {
            try? await Task.sleep(for: .seconds(60))
            finish("Timed out waiting for the public update feed.", code: 1)
        }
    }

    func allowedChannels(for updater: SPUUpdater) -> Set<String> { ["test"] }

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        foundBuild = item.versionString
    }

    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: (any Error)?) {
        if let error {
            finish("Public feed check failed: \((error as NSError).code)", code: 1)
        }
        let expected = ProcessInfo.processInfo.environment["ECHO_EXPECTED_UPDATE_BUILD"]
        guard let foundBuild, foundBuild == expected else {
            finish("Expected update was not found.", code: 1)
        }
        finish("Sparkle verified the public test feed and found build \(foundBuild). No installation performed.", code: 0)
    }

    private func finish(_ message: String, code: Int32) -> Never {
        if let identifier = Bundle.main.bundleIdentifier {
            UserDefaults.standard.removePersistentDomain(forName: identifier)
        }
        print(message)
        exit(code)
    }
}

@main
enum LiveUpdateFeedProbeMain {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        let probe = LiveUpdateFeedProbe()
        probe.start()
        withExtendedLifetime(probe) { app.run() }
    }
}
