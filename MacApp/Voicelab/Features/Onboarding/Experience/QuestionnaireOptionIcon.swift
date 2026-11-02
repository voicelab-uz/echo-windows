import SwiftUI

/// Brand artwork keeps its original colors; generic choices use quiet native symbols.
struct QuestionnaireOptionIcon: View {
    let option: String

    var body: some View {
        Group {
            if let asset = Self.brands[option] {
                Image("OnboardingBrand-\(asset)")
                    .renderingMode(.original)
                    .resizable()
                    .scaledToFit()
            } else {
                Image(systemName: symbol)
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(WelcomePalette.muted)
            }
        }
        .frame(width: 16, height: 16)
        .accessibilityHidden(true)
    }

    private static let brands = [
        "youtube": "youtube", "instagram": "instagram", "telegram": "telegram",
        "tiktok": "tiktok", "linkedin": "linkedin", "x": "x", "facebook": "facebook",
        "zoom": "zoom", "google_meet": "google-meet", "teams": "microsoft-office-teams",
        "slack": "slack", "facetime": "FaceTime", "discord": "discord"
    ]

    private var symbol: String {
        switch option {
        case "friend", "in_person": "person.2"
        case "search", "finding_notes": "magnifyingglass"
        case "article": "newspaper"
        case "podcast": "mic"
        case "newsletter", "emails": "envelope"
        case "ai_chat", "ai": "sparkles"
        case "dictation": "waveform"
        case "meeting_notes", "notes", "taking_notes": "note.text"
        case "accessibility": "accessibility"
        case "exploring": "safari"
        case "developer", "coding": "curlybraces"
        case "founder": "flag"
        case "product": "square.stack.3d.up"
        case "marketing": "megaphone"
        case "sales": "chart.line.uptrend.xyaxis"
        case "operations": "gearshape"
        case "student", "educator": "graduationcap"
        case "writer": "pencil"
        case "creator": "paintbrush.pointed"
        case "consultant": "briefcase"
        case "legal": "building.columns"
        case "healthcare": "cross.case"
        case "support": "headphones"
        case "recruiting": "person.crop.rectangle"
        case "data_analysis": "chart.bar"
        case "messages": "bubble.left"
        case "documents": "doc.text"
        case "posts": "text.bubble"
        case "preparation": "calendar"
        case "focus": "scope"
        case "action_items": "checklist"
        case "sharing": "square.and.arrow.up"
        case "language": "character.bubble"
        case "none": "minus.circle"
        default: "ellipsis"
        }
    }
}
