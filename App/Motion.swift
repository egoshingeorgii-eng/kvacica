import SwiftUI

// Motion used across the study screens.

extension Animation {
    /// Card to card and screen to screen: quick, settles without overshooting.
    static let card = Animation.smooth(duration: 0.38)
    /// Small confirmations: a check mark, a tile landing.
    static let pop = Animation.spring(response: 0.3, dampingFraction: 0.55)
    /// A letter gliding from its tile into the word: smooth, no overshoot.
    static let tileFlight = Animation.smooth(duration: 0.42)
    /// iPhone: the next card pushing the answered one off, like a navigation push.
    static let cardPush = Animation.spring(response: 0.42, dampingFraction: 1)
}

extension AnyTransition {
    /// The next card slides in from the right out of a blur; the old one leaves to the left.
    static var cardIn: AnyTransition {
        .modifier(active: SlideBlur(x: 44, blur: 8, opacity: 0, scale: 0.97), identity: SlideBlur())
    }

    static var cardOut: AnyTransition {
        .modifier(active: SlideBlur(x: -44, blur: 8, opacity: 0, scale: 0.97), identity: SlideBlur())
    }

    /// Between home, a topic, a session and the summary. Only fades and moves: blur and scale
    /// can't touch the AppKit answer field, which then snaps into place at the end.
    static var screen: AnyTransition {
        .modifier(active: SlideBlur(y: 10, opacity: 0), identity: SlideBlur())
    }

    /// iPhone: between home, the cards and the summary, a plain crossfade. The small rise of
    /// `screen` moved the top of both screens against each other, which read as a twitch.
    static var ringsScreen: AnyTransition { .opacity }

    /// iPhone: the next card comes in from the right edge as the answered one leaves to the left.
    /// The leaving card takes no taps: they'd answer the card coming in.
    static var nextCard: AnyTransition {
        .push(from: .trailing).combined(with: .modifier(active: HitTesting(enabled: false), identity: HitTesting(enabled: true)))
    }
}

// MARK: Card transitions to try (Settings → Debug)

/// How one exercise card gives way to the next. Picked in Settings → Debug to try them out.
enum CardMotion: String, CaseIterable, Identifiable {
    case slide, slideBlur, crossfade, fadeThrough, push, zoom, rise, blurReplace, sheet, flip, none

    var id: String { rawValue }

    static let key = "debugCardMotion"
    static let speedKey = "debugCardMotionSpeed"

    var title: String {
        switch self {
        case .slide: "Slide (default)"
        case .slideBlur: "Slide through a blur"
        case .crossfade: "Crossfade"
        case .fadeThrough: "Fade out, then in"
        case .push: "Push, like a navigation stack"
        case .zoom: "Zoom, like opening an app"
        case .rise: "Rise from below"
        case .blurReplace: "Blur replace (SF Symbols style)"
        case .sheet: "Sheet over the old card"
        case .flip: "3D turn"
        case .none: "None"
        }
    }

    var transition: AnyTransition {
        switch self {
        case .slide:
            .asymmetric(
                insertion: .modifier(active: SlideBlur(x: 28, opacity: 0), identity: SlideBlur()),
                removal: .modifier(active: SlideBlur(x: -28, opacity: 0), identity: SlideBlur())
            )
        case .slideBlur:
            .asymmetric(insertion: .cardIn, removal: .cardOut)
        case .crossfade:
            .opacity
        case .fadeThrough:
            // The old card is gone before the new one starts, so the two never overlap.
            .asymmetric(
                insertion: .modifier(active: SlideBlur(opacity: 0, scale: 0.98), identity: SlideBlur())
                    .animation(.smooth(duration: 0.28).delay(0.12)),
                removal: .opacity.animation(.easeOut(duration: 0.12))
            )
        case .push:
            .push(from: .trailing)
        case .zoom:
            .asymmetric(
                insertion: .modifier(active: SlideBlur(opacity: 0, scale: 0.9), identity: SlideBlur()),
                removal: .modifier(active: SlideBlur(blur: 4, opacity: 0, scale: 1.08), identity: SlideBlur())
            )
        case .rise:
            .asymmetric(
                insertion: .modifier(active: SlideBlur(y: 28, opacity: 0), identity: SlideBlur()),
                removal: .modifier(active: SlideBlur(y: -14, opacity: 0), identity: SlideBlur())
            )
        case .blurReplace:
            AnyTransition(BlurReplaceTransition(configuration: .downUp))
        case .sheet:
            .asymmetric(
                insertion: .move(edge: .bottom).combined(with: .opacity),
                removal: .modifier(active: SlideBlur(blur: 2, opacity: 0, scale: 0.92), identity: SlideBlur())
            )
        case .flip:
            .asymmetric(
                insertion: .modifier(active: Turn(angle: 75, anchor: .leading), identity: Turn(angle: 0, anchor: .leading)),
                removal: .modifier(active: Turn(angle: -75, anchor: .trailing), identity: Turn(angle: 0, anchor: .trailing))
            )
        case .none:
            .identity
        }
    }

    /// The motion picked in Settings → Debug.
    static var current: CardMotion {
        UserDefaults.standard.string(forKey: key).flatMap(CardMotion.init(rawValue:)) ?? .slide
    }
}

/// How quickly cards change, picked next to `CardMotion`.
enum MotionSpeed: String, CaseIterable, Identifiable {
    case standard, smooth, snappy, bouncy, slow

    var id: String { rawValue }

    var title: String {
        switch self {
        case .standard: "Standard (default)"
        case .smooth: "Smooth"
        case .snappy: "Snappy"
        case .bouncy: "Bouncy"
        case .slow: "Slow motion (to look closely)"
        }
    }

    var animation: Animation {
        switch self {
        case .standard: .card
        case .smooth: .smooth(duration: 0.4)
        case .snappy: .snappy(duration: 0.28)
        case .bouncy: .bouncy(duration: 0.5, extraBounce: 0.1)
        case .slow: .smooth(duration: 1.6)
        }
    }

    static var current: MotionSpeed {
        UserDefaults.standard.string(forKey: CardMotion.speedKey).flatMap(MotionSpeed.init(rawValue:)) ?? .standard
    }
}

/// Turns around the vertical axis, fading as it goes edge-on.
private struct Turn: ViewModifier {
    let angle: Double
    let anchor: UnitPoint

    func body(content: Content) -> some View {
        content
            .rotation3DEffect(.degrees(angle), axis: (x: 0, y: 1, z: 0), anchor: anchor, perspective: 0.5)
            .opacity(1 - abs(angle) / 90)
    }
}

private struct HitTesting: ViewModifier {
    let enabled: Bool

    func body(content: Content) -> some View {
        content.allowsHitTesting(enabled)
    }
}

private struct SlideBlur: ViewModifier {
    var x: CGFloat = 0
    var y: CGFloat = 0
    var blur: CGFloat = 0
    var opacity: Double = 1
    var scale: CGFloat = 1

    func body(content: Content) -> some View {
        content
            .scaleEffect(scale)
            .offset(x: x, y: y)
            .blur(radius: blur)
            .opacity(opacity)
    }
}

extension View {
    /// Springs in from `scale` the moment it appears.
    func popIn(from scale: CGFloat = 0.4) -> some View { modifier(PopIn(from: scale)) }

    /// A verdict badge arriving: grows from its middle with a small spring as it fades in.
    func badgeIn() -> some View { modifier(BadgeIn()) }
}

private struct BadgeIn: ViewModifier {
    @State private var shown = false

    func body(content: Content) -> some View {
        content
            // The size springs, the fade doesn't: a spring on opacity overshoots and flickers.
            .animation(.spring(duration: 0.4, bounce: 0.3)) { $0.scaleEffect(shown ? 1 : 0.6) }
            .animation(.easeOut(duration: 0.15)) { $0.opacity(shown ? 1 : 0) }
            .onAppear { shown = true }
    }
}

private struct PopIn: ViewModifier {
    let from: CGFloat
    @State private var shown = false

    func body(content: Content) -> some View {
        content
            .scaleEffect(shown ? 1 : from)
            .opacity(shown ? 1 : 0)
            .onAppear {
                withAnimation(.pop) { shown = true }
            }
    }
}

/// An SF Symbol that grows in on the spot when it appears, from its own center. One motion
/// only: a spring with a little overshoot (a bounce on top of it read as a jolt).
struct PopIcon: View {
    let systemName: String
    let color: Color

    var body: some View {
        Image(systemName: systemName)
            .foregroundStyle(color)
            .popIn()
    }
}
