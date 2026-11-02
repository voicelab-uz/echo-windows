import Foundation
import VoiceLabCore

/// Local update routes contain no URL, account or installation action.
struct UpdateNotification: Equatable, Sendable {
    enum Stage: String, Sendable { case available, ready }
    static let identifierPrefix = "Echo.update.v1."
    let channel: String
    let build: String
    let version: String
    let stage: Stage
    var identifier: String { Self.identifierPrefix + channel + "." + build }
    func isObsolete(channel: String, installedBuild: String) -> Bool {
        self.channel != channel || build.compare(installedBuild, options: .numeric) != .orderedDescending
    }
    var userInfo: [AnyHashable: Any] {
        ["echo_local_route": "update.v1", "channel": channel, "build": build,
         "version": version, "stage": stage.rawValue]
    }

    init?(channel: String, build: String, version: String, stage: Stage) {
        guard ["stable", "beta", "test"].contains(channel),
              !build.isEmpty, build.count <= 20, build.allSatisfy({ $0.isASCII && $0.isNumber }),
              !version.isEmpty, version.count <= 80,
              !version.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { return nil }
        self.channel = channel
        self.build = build
        self.version = version
        self.stage = stage
    }

    init?(identifier: String, userInfo: [AnyHashable: Any]) {
        guard userInfo["echo_local_route"] as? String == "update.v1",
              let channel = userInfo["channel"] as? String,
              let build = userInfo["build"] as? String,
              let version = userInfo["version"] as? String,
              let rawStage = userInfo["stage"] as? String, let stage = Stage(rawValue: rawStage) else { return nil }
        self.init(channel: channel, build: build, version: version, stage: stage)
        guard self.identifier == identifier else { return nil }
    }
}

/// Transport identity is authoritative. Remote payloads cannot invoke local routes,
/// and a local notification cannot bypass remote account validation.
enum AppNotificationRoute: Equatable, Sendable {
    case update(UpdateNotification)
    case remote(PushRoute)

    static func resolve(identifier: String, userInfo: [AnyHashable: Any], isRemote: Bool) -> Self? {
        if isRemote { return PushRoute(userInfo: userInfo).map(Self.remote) }
        return UpdateNotification(identifier: identifier, userInfo: userInfo).map(Self.update)
    }
}
