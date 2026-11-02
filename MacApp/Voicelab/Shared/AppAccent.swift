import AppKit
import Observation
import SwiftUI

/// The interactive color used across Echo. Views read it through `Design.tint`, so
/// Observation redraws them as soon as the choice changes.
@MainActor @Observable
final class AppAccent {
    enum Choice: String, CaseIterable, Identifiable {
        /// Echo's own brand blue, tuned separately for light and dark.
        case voicelab
        /// Follows the accent color picked in macOS System Settings.
        case system
        /// The macOS System Settings palette, in the same order.
        case blue, purple, pink, red, orange, yellow, green, graphite

        var id: String { rawValue }

        var title: String {
            switch self {
            case .voicelab: "VoiceLab"
            case .system: "Tizimga mos"
            case .blue: "Ko‘k"
            case .purple: "Binafsha"
            case .pink: "Pushti"
            case .red: "Qizil"
            case .orange: "To‘q sariq"
            case .yellow: "Sariq"
            case .green: "Yashil"
            case .graphite: "Grafit"
            }
        }

        var color: Color {
            switch self {
            case .voicelab: Color("VoicelabAccent")
            case .system: Color(nsColor: .controlAccentColor)
            case .blue: Color(nsColor: .systemBlue)
            case .purple: Color(nsColor: .systemPurple)
            case .pink: Color(nsColor: .systemPink)
            case .red: Color(nsColor: .systemRed)
            case .orange: Color(nsColor: .systemOrange)
            case .yellow: Color(nsColor: .systemYellow)
            case .green: Color(nsColor: .systemGreen)
            case .graphite: Color(nsColor: .systemGray)
            }
        }
    }

    static let shared = AppAccent()
    static let defaultsKey = "accentColor"

    var choice: Choice {
        didSet { defaults.set(choice.rawValue, forKey: Self.defaultsKey) }
    }
    var color: Color { choice.color }

    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        choice = Choice(rawValue: defaults.string(forKey: Self.defaultsKey) ?? "") ?? .voicelab
    }

    /// Picks up a reset of stored preferences without relaunching.
    func reloadFromStorage() {
        choice = Choice(rawValue: defaults.string(forKey: Self.defaultsKey) ?? "") ?? .voicelab
    }
}
