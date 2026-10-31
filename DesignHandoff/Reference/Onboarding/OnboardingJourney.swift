import Foundation
import Observation

/// Non-sensitive navigation only; questionnaire answers live in the encrypted account library.
@MainActor @Observable
final class OnboardingJourney {
    enum Route: String, Codable, CaseIterable {
        case welcome, permissions, microphone, shortcut, alphabet, signIn, aboutYou, practice
        var stage: Int {
            switch self {
            case .welcome: 0
            case .permissions: 1
            case .microphone, .shortcut, .alphabet: 2
            case .signIn: 3
            case .aboutYou: 4
            case .practice: 5
            }
        }
    }
    struct Checkpoint: Codable {
        var route: Route = .welcome
        var triedVoice = false
        var resumeAfterPermissions: Route?
    }
    private(set) var route = Route.welcome
    private(set) var triedVoice = false
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let persistsProgress: Bool
    @ObservationIgnored private var owner: String?
    private var resumeAfterPermissions: Route?
    private var key: String { "echo.onboarding.v2." + (owner ?? "guest") }

    init(defaults: UserDefaults = .standard, persistsProgress: Bool = true) {
        self.defaults = defaults
        self.persistsProgress = persistsProgress
    }

    func restore(owner: String?, permissionsReady: Bool) {
        self.owner = owner
        let checkpoint = persistsProgress
            ? defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(Checkpoint.self, from: $0) } ?? Checkpoint()
            : Checkpoint()
        route = checkpoint.route
        triedVoice = checkpoint.triedVoice
        resumeAfterPermissions = checkpoint.resumeAfterPermissions
        if route.stage > 1 && !permissionsReady { requirePermissions() }
        if route.stage >= 3 && owner == nil { route = .signIn; triedVoice = false }
    }
    func signedIn(owner: String) {
        self.owner = owner
        // A newly authenticated account must load its own context before voice practice.
        triedVoice = false
        resumeAfterPermissions = nil
        navigate(.aboutYou)
        if persistsProgress { defaults.removeObject(forKey: "echo.onboarding.v2.guest") }
    }
    func navigate(_ route: Route) {
        self.route = route
        save()
    }
    func requirePermissions() {
        if route.stage > 1 { resumeAfterPermissions = route }
        route = .permissions
        save()
    }
    func continueAfterPermissions() {
        let destination = resumeAfterPermissions ?? .microphone
        resumeAfterPermissions = nil
        navigate(destination)
    }
    func recordVoiceSuccess() { triedVoice = true; save() }
    private func save() {
        guard persistsProgress else { return }
        if let data = try? JSONEncoder().encode(Checkpoint(route: route, triedVoice: triedVoice, resumeAfterPermissions: resumeAfterPermissions)) {
            defaults.set(data, forKey: key)
        }
    }
}
