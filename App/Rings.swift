import SwiftUI

/// The ring look's colors: orange is the app's own (actions, progress, the banner); every topic
/// gets a color of its own, none of them near orange.
enum Rings {
    static let accent = Color(red: 1.0, green: 0.48, blue: 0.10)
    static let accentLight = Color(red: 1.0, green: 0.63, blue: 0.27)
    /// Each side of a card's top bar: the close button left, the count and its ring right. Wide
    /// enough for «100/101» on one line; the same both sides keeps the title centred.
    static let topSlot: CGFloat = 104
    /// A white card on the grouped background (dark grey in dark mode).
    static let cardBackground = Color(nsColor: .textBackgroundColor)
    /// Between cards on home and in Progress, so both breathe the same.
    static let cardSpacing: CGFloat = 16
    /// The topic rings filling and the activity bars rising: the same move.
    static let rise = Animation.smooth(duration: 0.9).delay(0.1)

    static func color(for topic: String) -> Color {
        switch topic {
        case "Small words", "Basics": Color(red: 0.16, green: 0.38, blue: 0.92)
        case "Character & Feelings": Color(red: 0.80, green: 0.45, blue: 0.85)
        case "Clothes": Color(red: 0.70, green: 0.18, blue: 0.45)
        case "Nature & Weather": Color(red: 0.28, green: 0.58, blue: 0.22)
        case "Free time": Color(red: 0.90, green: 0.74, blue: 0.08)
        case "Language & Study": Color(red: 0.05, green: 0.45, blue: 0.60)
        case "Numbers & Colors": Color(red: 0.55, green: 0.40, blue: 0.28)
        case "Opinions & Ideas": Color(red: 0.33, green: 0.30, blue: 0.55)
        case "Phrases": Color(red: 0.62, green: 0.32, blue: 0.90)
        case "People & Jobs": Color(red: 0.36, green: 0.34, blue: 0.84)
        case "Family": Color(red: 0.85, green: 0.30, blue: 0.75)
        case "Body & Health": Color(red: 0.90, green: 0.16, blue: 0.30)
        case "Food & Drink": Color(red: 0.45, green: 0.72, blue: 0.10)
        case "Shopping": Color(red: 1.0, green: 0.38, blue: 0.62)
        case "Home": Color(red: 0.08, green: 0.62, blue: 0.62)
        case "City & Travel": Color(red: 0.18, green: 0.66, blue: 0.95)
        case "Time": Color(red: 0.38, green: 0.47, blue: 0.58)
        case "Verbs": Color(red: 0.10, green: 0.70, blue: 0.42)
        case "Grammar": Color(red: 0.52, green: 0.55, blue: 0.18)
        case "Sentences": Color(red: 0.56, green: 0.24, blue: 0.52)
        default: .gray
        }
    }
}
