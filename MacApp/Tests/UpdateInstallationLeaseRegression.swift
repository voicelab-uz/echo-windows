import Foundation

@main struct UpdateInstallationLeaseRegression {
    static func main() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("echo-update-lease-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let app = URL(fileURLWithPath: "/Applications/Echo.app")
        let otherApp = URL(fileURLWithPath: "/Applications/Other.app")
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        precondition(!UpdateInstallationLease.isActive(for: app, directory: directory, now: now))
        let first = try UpdateInstallationLease.begin(for: app, directory: directory, now: now)
        precondition(UpdateInstallationLease.isActive(for: app, directory: directory, now: now))
        precondition(!UpdateInstallationLease.isActive(for: otherApp, directory: directory, now: now))
        precondition(!UpdateInstallationLease.isActive(for: app, directory: directory, now: now.addingTimeInterval(-1)))
        precondition(!UpdateInstallationLease.isActive(for: app, directory: directory,
                                                     now: now.addingTimeInterval(UpdateInstallationLease.maximumDuration)))
        let replacement = try UpdateInstallationLease.begin(for: app, directory: directory, now: now)
        UpdateInstallationLease.clear(for: app, token: first, directory: directory)
        precondition(UpdateInstallationLease.isActive(for: app, directory: directory, now: now),
                     "A canceled older installation must not clear a newer lease.")
        UpdateInstallationLease.clear(for: otherApp, token: replacement, directory: directory)
        precondition(UpdateInstallationLease.isActive(for: app, directory: directory, now: now))
        UpdateInstallationLease.clear(for: app, directory: directory)
        precondition(!UpdateInstallationLease.isActive(for: app, directory: directory, now: now))
        try Data("broken".utf8).write(to: directory.appendingPathComponent("installation.json"))
        precondition(!UpdateInstallationLease.isActive(for: app, directory: directory, now: now))
        print("PASS: updater helper lease isolation, cancellation, expiry, relaunch cleanup and corrupt-file recovery.")
    }
}
