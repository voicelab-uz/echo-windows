import UIKit

/// Opaque keyboard surfaces keep contrast consistent with the host's keyboard
/// appearance. These are Echo's colors, rather than private system keyboard APIs.
@MainActor
enum KeyboardAppearance {
    // Transparent background - no custom color
    static var keyboardCanvas: UIColor {
        .clear
    }

    static var character: UIColor {
        UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(red: 0.278, green: 0.278, blue: 0.290, alpha: 1.0)  // Exact native iOS dark key
                : UIColor.white
        }
    }

    static var function: UIColor {
        UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(red: 0.220, green: 0.220, blue: 0.231, alpha: 1.0)  // Exact native iOS dark function
                : UIColor(red: 0.68, green: 0.70, blue: 0.74, alpha: 1.0)
        }
    }

    static var pressedCharacter: UIColor {
        UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(white: 0.56, alpha: 1.0)  // Lighter when pressed
                : UIColor(red: 0.85, green: 0.86, blue: 0.88, alpha: 1.0)
        }
    }

    static var pressedFunction: UIColor {
        UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(white: 0.48, alpha: 1.0)
                : UIColor(red: 0.77, green: 0.79, blue: 0.82, alpha: 1.0)
        }
    }

    static var popup: UIColor {
        UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(white: 0.52, alpha: 1.0)
                : UIColor.white
        }
    }

    static var foreground: UIColor {
        UIColor { traits in
            traits.userInterfaceStyle == .dark ? .white : .black
        }
    }

    static var secondaryForeground: UIColor {
        UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(white: 0.76, alpha: 1.0)
                : UIColor(white: 0.27, alpha: 1.0)
        }
    }

    static let separator = UIColor.separator
    static let keyShadow = UIColor.black

    /// Apply this to the input controller and hosting controller. `.default`
    /// inherits the host interface style; explicit text-field preferences win.
    static func interfaceStyle(for appearance: UIKeyboardAppearance) -> UIUserInterfaceStyle {
        switch appearance {
        case .dark: return .dark
        case .light: return .light
        case .default: return .unspecified
        @unknown default: return .unspecified
        }
    }

    // Keyboard glyphs use the regular SF face at native keycap sizes. They do
    // not scale with body text, which would overflow the fixed keyboard rows.
    static func characterFont(for title: String) -> UIFont {
        .systemFont(ofSize: title.count > 1 ? 21 : 24, weight: .regular)
    }

    static let functionFont = UIFont.systemFont(ofSize: 15, weight: .regular)

    static func popupFont(for title: String) -> UIFont {
        .systemFont(ofSize: title.count > 1 ? 32 : 40, weight: .light)
    }
}
