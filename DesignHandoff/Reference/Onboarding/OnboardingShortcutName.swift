import Foundation
import SwiftUI

/// The dictation shortcut as onboarding shows it. Production sets `label` to the user's
/// shortcut (e.g. "Right ⌥"); standalone previews keep the bundled "fn".
enum OnboardingShortcutName {
    nonisolated(unsafe) static var label = "fn"
    nonisolated(unsafe) private static var cache: [String: Any] = [:]

    /// Loads a bundled copy catalog with every standalone "fn" replaced by the current
    /// shortcut, cached per shortcut so views can read it on every render.
    static func catalog<T: Decodable>(_ resource: String, as type: T.Type) -> [String: T]? {
        let key = resource + "|" + label
        if let hit = cache[key] as? [String: T] { return hit }
        guard let url = Bundle.main.url(forResource: resource, withExtension: "json"),
              var text = try? String(contentsOf: url, encoding: .utf8)
        else { return nil }
        if label != "fn" {
            // The label lands inside JSON string values, so escape it for JSON first.
            let json = label.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            text = text.replacingOccurrences(
                of: #"\bfn\b"#, with: NSRegularExpression.escapedTemplate(for: json), options: .regularExpression)
        }
        guard let catalog = try? JSONDecoder().decode([String: T].self, from: Data(text.utf8)) else { return nil }
        cache[key] = catalog
        return catalog
    }
}

private struct OnboardingShortcutLabelKey: EnvironmentKey {
    static let defaultValue = "fn"
}

extension EnvironmentValues {
    /// Display name of the dictation shortcut for onboarding key illustrations.
    var onboardingShortcutLabel: String {
        get { self[OnboardingShortcutLabelKey.self] }
        set { self[OnboardingShortcutLabelKey.self] = newValue }
    }
}
