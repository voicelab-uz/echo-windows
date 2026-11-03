import Foundation

/// A short-lived coordination hint, never authorization to install or execute code.
/// Both the app and its existing login helper resolve the same per-user location.
enum UpdateInstallationLease {
    static let maximumDuration: TimeInterval = 600
    private struct Lease: Codable {
        let token: UUID
        let appPath: String
        let createdAt: Date
        let expiresAt: Date
    }

    static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("EchoUpdateState", isDirectory: true)
    }

    @discardableResult
    static func begin(for app: URL, directory: URL = defaultDirectory, now: Date = .now) throws -> UUID {
        let token = UUID()
        let lease = Lease(token: token, appPath: app.standardizedFileURL.path,
                          createdAt: now, expiresAt: now.addingTimeInterval(maximumDuration))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        let file = directory.appendingPathComponent("installation.json")
        try JSONEncoder().encode(lease).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        return token
    }

    static func isActive(for app: URL, directory: URL = defaultDirectory, now: Date = .now) -> Bool {
        guard let lease = read(directory), lease.appPath == app.standardizedFileURL.path,
              lease.createdAt <= now, lease.expiresAt > now,
              lease.expiresAt.timeIntervalSince(lease.createdAt) <= maximumDuration else { return false }
        return true
    }

    /// A canceled handoff only removes its own lease. A newly launched app clears the
    /// lease for its path, including one left behind by an interrupted installer.
    static func clear(for app: URL, token: UUID? = nil, directory: URL = defaultDirectory) {
        guard let lease = read(directory), lease.appPath == app.standardizedFileURL.path,
              token == nil || token == lease.token else { return }
        try? FileManager.default.removeItem(at: directory.appendingPathComponent("installation.json"))
    }

    private static func read(_ directory: URL) -> Lease? {
        let file = directory.appendingPathComponent("installation.json")
        guard let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size <= 4096, let data = try? Data(contentsOf: file) else { return nil }
        return try? JSONDecoder().decode(Lease.self, from: data)
    }
}
