import SwiftUI
import SrbCore

/// The first launch: what Kvačica is, then your level, which decides the built-in words that go in
/// and the level lessons start from. The look follows the App Store screenshots: big lowercase
/// headlines, orange on the first and last page, a light peach between.
struct OnboardingView: View {
    @Environment(AppModel.self) private var model
    @State private var step = Step.welcome
    /// Back or forward, for which way the pages push.
    @State private var forward = true
    @State private var choice: Choice?
    /// B2 and up: the built-in levels taken anyway; empty: words of your own only.
    @State private var extraLevels: Set<String> = []
    /// How much of the tour is showing: its features, then one more for Continue.
    @State private var tourShown = 0
    /// The memory page's curves, drawn once: without reviews, then with them; then Continue.
    @State private var memoryDrawn = (without: false, with: false, done: false)

    enum Step: Int, Comparable {
        case welcome, tour, memory, level, beyond, ready
        static func < (a: Step, b: Step) -> Bool { a.rawValue < b.rawValue }
        /// Orange pages; the others are light.
        var isBold: Bool { self == .welcome || self == .ready }
    }

    enum Choice: String, CaseIterable, Identifiable {
        case a1 = "A1", a2 = "A2", b1 = "B1", beyond = "B2+"
        var id: Self { self }

        var title: String {
            switch self {
            case .a1: String(localized: "Beginner")
            case .a2: String(localized: "Elementary")
            case .b1: String(localized: "Intermediate")
            case .beyond: String(localized: "Upper-intermediate and up")
            }
        }

        var detail: String {
            switch self {
            case .a1: String(localized: "My first words in Serbian")
            case .a2: String(localized: "I manage shops, cafés and small talk")
            case .b1: String(localized: "I get by in most everyday situations")
            case .beyond: String(localized: "I talk about almost anything")
            }
        }

        /// The built-in levels it brings in: its own and the ones below.
        var levels: [String] {
            switch self {
            case .a1: ["A1"]
            case .a2: ["A1", "A2"]
            case .b1, .beyond: ["A1", "A2", "B1"]
            }
        }
    }

    var body: some View {
        ZStack {
            OnboardingBackground(bold: step.isBold)
            ZStack {
                switch step {
                case .welcome: welcome
                case .tour: tour
                case .memory: memory
                case .level: level
                case .beyond: beyond
                case .ready: ready
                }
            }
            .id(step)
            .transition(.push(from: forward ? .trailing : .leading))
        }
        .overlay(alignment: .topLeading) {
            if step != .welcome {
                // The same glass back button as the app's pushed pages (`ringsPageChrome`).
                Button { go(back) } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.primary)
                        .frame(width: 44, height: 44)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .modifier(GlassCircle())
                .padding(.leading, 16)
                .padding(.top, 2)
                .transition(.opacity)
                .accessibilityLabel("Back")
            }
        }
        .sensoryFeedback(.impact(weight: .light), trigger: step)
        .preferredColorScheme(step.isBold ? .light : nil)
        .task { await StarterLibrary.preload() }
    }

    // MARK: Pages

    private var welcome: some View {
        Page {
            Headline(lines: [String(localized: "Serbian 🇷🇸"), String(localized: "words that"), String(localized: "stick")], accentFrom: nil, onOrange: true)
            Text("Flashcards that start easy, come back when you're about to forget, and take your answer typed or spoken.")
                .font(.title3.weight(.medium))
                .foregroundStyle(.white.opacity(0.85))
        } button: {
            PillButton(title: String(localized: "Get started"), filled: false) { go(.tour) }
        }
    }

    private var tour: some View {
        Page {
            Headline(lines: [String(localized: "easy steps"), String(localized: "first")], accentFrom: 1)
            VStack(alignment: .leading, spacing: 22) {
                ForEach(Array(Self.features.enumerated()), id: \.offset) { index, feature in
                    feature
                        .opacity(index < tourShown ? 1 : 0)
                        .offset(y: index < tourShown ? 0 : 14)
                }
            }
            .padding(.top, 8)
        } button: {
            PillButton(title: String(localized: "Continue"), filled: true) { go(.memory) }
                .opacity(tourDone ? 1 : 0)
                .offset(y: tourDone ? 0 : 14)
                .disabled(!tourDone)
        }
        .task { await revealTour() }
    }

    private static var features: [Feature] { [
        Feature(symbol: "square.grid.2x2.fill", title: String(localized: "Choose, then type"),
                text: String(localized: "A new word starts as a choice of four and works up to writing it yourself.")),
        Feature(symbol: "waveform", title: String(localized: "Or just say it"),
                text: String(localized: "Answer in Serbian out loud, hands-free.")),
        Feature(symbol: "arrow.counterclockwise", title: String(localized: "Missed it? Try again"),
                text: String(localized: "A word you get wrong comes back until it sticks.")),
        Feature(symbol: "tablecells.fill", title: String(localized: "Every form"),
                text: String(localized: "Cases, plurals and verb forms, once you know the word.")),
    ] }

    /// The tour's features one at a time once the page is in, then Continue. Seen once, they stay.
    private var tourDone: Bool { tourShown > Self.features.count }

    private func revealTour() async {
        do {
            try await Task.sleep(for: .milliseconds(450))
            while !tourDone {
                withAnimation(.smooth(duration: 0.5)) { tourShown += 1 }
                try await Task.sleep(for: .milliseconds(tourDone ? 0 : 800))
            }
        } catch {}
    }

    private var memory: some View {
        Page {
            Headline(lines: [String(localized: "back just"), String(localized: "in time")], accentFrom: 1)
            Text("Kvačica asks each word again just before you'd forget it: the next day, in 3 days, in a week, in 3 weeks. Each time it stays longer, until it's learned for good.")
                .font(.body)
                .foregroundStyle(.secondary)
            MemoryChart(without: memoryDrawn.without, with: memoryDrawn.with)
                .padding(.top, 4)
        } button: {
            PillButton(title: String(localized: "Continue"), filled: true) { go(.level) }
                .opacity(memoryDrawn.done ? 1 : 0)
                .offset(y: memoryDrawn.done ? 0 : 14)
                .disabled(!memoryDrawn.done)
        }
        .task { await drawMemory() }
    }

    private func drawMemory() async {
        guard !memoryDrawn.done else { return }
        do {
            try await Task.sleep(for: .milliseconds(450))
            withAnimation(.easeOut(duration: MemoryChart.withoutDuration)) { memoryDrawn.without = true }
            try await Task.sleep(for: .seconds(MemoryChart.withoutDuration * 0.7))
            withAnimation(.easeInOut(duration: MemoryChart.withDuration)) { memoryDrawn.with = true }
            try await Task.sleep(for: .seconds(MemoryChart.withDuration))
            withAnimation(.smooth(duration: 0.5)) { memoryDrawn.done = true }
        } catch {}
    }

    private var level: some View {
        Page {
            Headline(lines: [String(localized: "what's your"), String(localized: "serbian?")], accentFrom: 1)
            VStack(spacing: 10) {
                ForEach(Choice.allCases) { option in
                    LevelCard(
                        badge: option.rawValue,
                        title: option.title,
                        detail: option.detail,
                        count: option == .beyond ? nil : option.levels.map(StarterLibrary.count).reduce(0, +),
                        selected: choice == option
                    ) {
                        withAnimation(.snappy) { choice = option }
                    }
                }
            }
            .sensoryFeedback(.selection, trigger: choice)
            Button("I already use Kvačica on another device") {
                model.finishOnboarding(levels: [], newLevel: nil)
            }
            .font(.subheadline.weight(.medium))
            .foregroundStyle(Rings.accent)
            .frame(maxWidth: .infinity)
            .padding(.top, 4)
        } button: {
            PillButton(title: String(localized: "Continue"), filled: true) {
                go(choice == .beyond ? .beyond : .ready)
            }
            .disabled(choice == nil)
            .opacity(choice == nil ? 0.4 : 1)
            .animation(.smooth, value: choice)
        }
    }

    private var beyond: some View {
        Page {
            Headline(lines: [String(localized: "past b1?"), String(localized: "bring your own")], accentFrom: 1)
            Text("The built-in words go up to B1. Add your own as you meet them, or take built-in ones to fill the gaps.")
                .font(.body)
                .foregroundStyle(.secondary)
            VStack(spacing: 10) {
                LevelCard(badge: nil, symbol: "square.and.pencil", title: String(localized: "Only my own words"),
                          detail: String(localized: "Start with an empty deck"), count: nil, selected: extraLevels.isEmpty) {
                    withAnimation(.snappy) { extraLevels = [] }
                }
                ForEach(StarterLibrary.levels.reversed(), id: \.self) { level in
                    LevelCard(badge: level, title: String(localized: "Built-in \(level) words"),
                              detail: String(localized: "To fill the gaps"), count: StarterLibrary.count(level),
                              selected: extraLevels.contains(level), multiple: true) {
                        withAnimation(.snappy) {
                            if extraLevels.contains(level) { extraLevels.remove(level) } else { extraLevels.insert(level) }
                        }
                    }
                }
            }
            .sensoryFeedback(.selection, trigger: extraLevels)
        } button: {
            PillButton(title: String(localized: "Continue"), filled: true) { go(.ready) }
        }
    }

    private var ready: some View {
        let levels = chosenLevels
        let count = levels.map(StarterLibrary.count).reduce(0, +)
        return Page {
            Headline(lines: [String(localized: "words for"), String(localized: "real life")], accentFrom: nil, onOrange: true)
            if count > 0 {
                CountUp(target: count)
                Text(String(localized: "words with all their forms and example sentences, \(levels.joined(separator: " · "))"))
                    .font(.title3.weight(.medium))
                    .foregroundStyle(.white.opacity(0.85))
            } else {
                Text("Your deck starts empty. Add words on the Words tab with +, as you meet them.")
                    .font(.title3.weight(.medium))
                    .foregroundStyle(.white.opacity(0.85))
            }
        } button: {
            PillButton(title: String(localized: "Start learning"), filled: false) {
                model.finishOnboarding(levels: levels, newLevel: newLevel)
            }
        }
    }

    // MARK: Choices

    private var chosenLevels: [String] {
        guard let choice else { return [] }
        if choice == .beyond { return StarterLibrary.levels.filter(extraLevels.contains) }
        return choice.levels
    }

    /// Lessons take the chosen level; above B1 the highest built-in level taken, if any.
    private var newLevel: String? {
        guard let choice else { return nil }
        if choice == .beyond { return chosenLevels.last }
        return choice.rawValue
    }

    private var back: Step {
        switch step {
        case .welcome, .tour: .welcome
        case .memory: .tour
        case .level: .memory
        case .beyond: .level
        case .ready: choice == .beyond ? .beyond : .level
        }
    }

    /// The direction goes in first, on its own: the page leaving takes its transition from the
    /// last update it was in.
    private func go(_ next: Step) {
        forward = next > step
        Task { @MainActor in
            withAnimation(.smooth(duration: 0.45)) { step = next }
        }
    }
}

// MARK: - Pieces

/// A page: content from the top, the button at the bottom, the content scrolling if it must.
private struct Page<Content: View, Button: View>: View {
    @ViewBuilder let content: Content
    @ViewBuilder let button: Button

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    content
                }
                .padding(.horizontal, 28)
                .padding(.top, 72)
                .padding(.bottom, 24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollBounceBehavior(.basedOnSize)
            button
                .padding(.horizontal, 24)
                .padding(.bottom, 12)
        }
    }
}

/// The screenshots' headline: heavy, lowercase, tight; from `accentFrom` on the lines are orange,
/// the others dark, or white on the orange pages.
private struct Headline: View {
    let lines: [String]
    let accentFrom: Int?
    /// White on the orange pages.
    var onOrange = false

    var body: some View {
        VStack(alignment: .leading, spacing: -6) {
            ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                Self.line(line)
                    .foregroundStyle(accentFrom.map { index >= $0 } == true
                                     ? AnyShapeStyle(LinearGradient(colors: [Rings.accent, Color(red: 1, green: 0.35, blue: 0.4)], startPoint: .leading, endPoint: .trailing))
                                     : AnyShapeStyle(onOrange ? Color.white : Color(white: 0.1)))
            }
        }
        .font(.system(size: 50, weight: .heavy))
        .lineLimit(1)
        .minimumScaleFactor(0.6)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    /// Tight letters. A 🇷🇸 at the end is its own Text without tracking: tracking splits the
    /// flag's two regional-indicator letters into two empty boxes.
    @ViewBuilder
    private static func line(_ line: String) -> some View {
        if line.hasSuffix("🇷🇸") {
            HStack(spacing: 12) {
                Text(line.dropLast(1).trimmingCharacters(in: .whitespaces)).tracking(-1.6)
                Text("🇷🇸")
                    .font(.system(size: 44))
                    .foregroundStyle(Color.black)
                    .accessibilityHidden(true)
            }
        } else {
            Text(line).tracking(-1.6)
        }
    }
}

/// Liquid Glass circle, as `glassCircle()` on the iPhone's pages; this file builds for the Mac too.
private struct GlassCircle: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26, macOS 26, *) {
            content.glassEffect(.regular.interactive(), in: .circle)
        } else {
            content.background(.ultraThinMaterial, in: Circle())
        }
    }
}

private struct Feature: View {
    let symbol: String
    let title: String
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: symbol)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .background(LinearGradient(colors: [Rings.accentLight, Rings.accent], startPoint: .top, endPoint: .bottom), in: Circle())
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline)
                Text(text).font(.subheadline).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

private struct LevelCard: View {
    let badge: String?
    var symbol: String?
    let title: String
    let detail: String
    let count: Int?
    let selected: Bool
    var multiple = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Group {
                    if let badge {
                        Text(badge).font(.system(size: 15, weight: .heavy)).tracking(-0.3)
                    } else if let symbol {
                        Image(systemName: symbol).font(.system(size: 17, weight: .semibold))
                    }
                }
                .foregroundStyle(selected ? .white : Rings.accent)
                .frame(width: 46, height: 46)
                .background(selected ? AnyShapeStyle(Rings.accent) : AnyShapeStyle(Rings.accent.opacity(0.12)),
                            in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.headline).foregroundStyle(.primary)
                    Text(count.map { String(localized: "\(detail) · \($0) words") } ?? detail)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .multilineTextAlignment(.leading)
                Spacer(minLength: 8)
                // The empty mark stays and the filled one scales in over it: swapping the symbol blinked.
                Image(systemName: multiple ? "square" : "circle")
                    .foregroundStyle(Color.secondary.opacity(0.5))
                    .overlay {
                        Image(systemName: multiple ? "checkmark.square.fill" : "checkmark.circle.fill")
                            .foregroundStyle(Rings.accent)
                            .scaleEffect(selected ? 1 : 0.5)
                            .opacity(selected ? 1 : 0)
                    }
                    .font(.title3)
            }
            .padding(14)
            .background(Rings.cardBackground, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(selected ? Rings.accent : .clear, lineWidth: 2)
            }
            .scaleEffect(selected ? 1 : 0.985)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// How memory fades: without reviews a word is gone in days; with them each review lifts it back
/// up and it fades more slowly, so the reviews spread out. Each curve draws like a pen.
private struct MemoryChart: View {
    let without: Bool
    let with: Bool

    static let withoutDuration = 0.9
    static let withDuration = 3.0

    /// Review days, and the whole span shown. The days axis is squeezed (a power under 1) so the
    /// first few days get room.
    private static let reviews: [Double] = [0, 1, 3, 7, 21]
    private static let span = 45.0
    private static func x(_ day: Double) -> Double { pow(day / span, 0.4) }

    /// How much of a word is left `day` days after the review at `from`: about half by the next
    /// review (each one waits longer, so it fades more slowly), and only a little after the last.
    /// After the last review it stays: learned for good.
    private static func recall(_ day: Double, from index: Int) -> Double {
        guard index + 1 < reviews.count else { return 1 }
        return exp(-(day - reviews[index]) * 0.6 / (reviews[index + 1] - reviews[index]))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            chart
                .padding(16)
                .background(Rings.cardBackground, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            // A card of its own under the chart's: the chart keeps all its room.
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 14) {
                    legend(String(localized: "With Kvačica"), dashed: false)
                    legend(String(localized: "On your own"), dashed: true)
                }
                HStack(spacing: 6) {
                    Self.dot.frame(width: 18)
                    Text("Kvačica asks the word again")
                }
            }
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(Rings.cardBackground, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("On your own a word is forgotten in a few days. Kvačica asks it again after 1, 3, 7 and 21 days, and then it's learned for good.")
    }

    private var chart: some View {
        Plot(drawn: AnimatablePair(without ? 1 : 0, with ? 1 : 0))
            .frame(height: 170)
    }

    /// The plot, drawn like a pen along each line's length: a climb back up at a review takes as
    /// long as a fade of the same length, instead of the whole climb appearing in one frame. A
    /// review's dot and day come in as the pen reaches them.
    private struct Plot: View, Animatable {
        /// How much of the line without reviews, and of the one with them, is drawn (0…1).
        var drawn: AnimatablePair<Double, Double>
        var animatableData: AnimatablePair<Double, Double> {
            get { drawn }
            set { drawn = newValue }
        }

        var body: some View {
            GeometryReader { proxy in
                let plot = CGRect(x: 6, y: 8, width: proxy.size.width - 12, height: proxy.size.height - 30)
                let without = MemoryChart.line(in: plot, reviewed: false)
                let with = MemoryChart.line(in: plot, reviewed: true)
                ZStack(alignment: .topLeading) {
                    // The floor and the top: all of it, none of it.
                    Path { path in
                        for y in [plot.minY, plot.maxY] {
                            path.move(to: CGPoint(x: plot.minX, y: y))
                            path.addLine(to: CGPoint(x: plot.maxX, y: y))
                        }
                    }
                    .stroke(Color.primary.opacity(0.08), lineWidth: 1)
                    without.path.trimmedPath(from: 0, to: drawn.first)
                        .stroke(Color.secondary.opacity(0.6), style: StrokeStyle(lineWidth: 2, lineCap: .round, dash: [4, 5]))
                    Text("forgotten")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: plot.maxX, alignment: .trailing)
                        .position(x: plot.maxX / 2, y: plot.maxY - 12)
                        .opacity(Self.fade(drawn.first, from: 0.6, over: 0.4))
                    with.path.trimmedPath(from: 0, to: drawn.second)
                        .stroke(LinearGradient(colors: [Rings.accentLight, Rings.accent], startPoint: .leading, endPoint: .trailing),
                                style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
                    ForEach(Array(MemoryChart.reviews.enumerated()), id: \.offset) { index, day in
                        let shown = Self.fade(drawn.second, from: with.reached[index], over: 0.05)
                        if index > 0 {
                            MemoryChart.dot
                                .position(x: plot.minX + plot.width * MemoryChart.x(day), y: plot.minY)
                                .opacity(shown)
                        }
                        Text(verbatim: "\(Int(day))")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                            .position(x: plot.minX + plot.width * MemoryChart.x(day), y: plot.maxY + 14)
                            .opacity(shown)
                    }
                    // Under the line's end, narrow enough to stay right of the last review's drop.
                    Text("learned for good")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Rings.accent)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 84, alignment: .trailing)
                        .position(x: plot.maxX - 42, y: plot.minY + 26)
                        .opacity(Self.fade(drawn.second, from: with.reached.last ?? 0, over: 0.2))
                    Text("days")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .frame(width: plot.maxX, alignment: .trailing)
                        .position(x: plot.maxX / 2, y: plot.maxY + 14)
                }
            }
        }

        /// 0 until `progress` reaches `from`, then up to 1 over the next `over` of the line.
        private static func fade(_ progress: Double, from: Double, over: Double) -> Double {
            min(1, max(0, (progress - from) / over))
        }
    }

    /// A curve as a path, and how far along its length (0…1) the pen is at the top of each
    /// review's climb (day 0: the start).
    private static func line(in plot: CGRect, reviewed: Bool) -> (path: Path, reached: [Double]) {
        func point(_ day: Double, _ recall: Double) -> CGPoint {
            CGPoint(x: plot.minX + plot.width * x(day), y: plot.maxY - plot.height * recall)
        }
        var points = [point(0, 1)]
        var reachedAt = [0]
        // Without reviews one fade from the start; with them a fade after each review, then
        // straight back up at the next.
        let starts = reviewed ? Array(reviews.indices) : [0]
        for index in starts {
            let from = reviews[index]
            let to = reviewed && index + 1 < reviews.count ? reviews[index + 1] : span
            for step in 1...60 {
                let day = from + (to - from) * Double(step) / 60
                points.append(point(day, reviewed ? recall(day, from: index) : exp(-day / 1.7)))
            }
            if to < span {
                points.append(point(to, 1))
                reachedAt.append(points.count - 1)
            }
        }
        var lengths = [0.0]
        for (a, b) in zip(points, points.dropFirst()) {
            lengths.append(lengths[lengths.count - 1] + hypot(b.x - a.x, b.y - a.y))
        }
        let total = max(lengths[lengths.count - 1], 1)
        return (Path { $0.addLines(points) }, reachedAt.map { lengths[$0] / total })
    }

    /// A review: the app asking the word again.
    fileprivate static var dot: some View {
        Circle()
            .fill(Rings.accent)
            .overlay(Circle().strokeBorder(.white, lineWidth: 2))
            .frame(width: 12, height: 12)
    }

    private func legend(_ title: String, dashed: Bool) -> some View {
        HStack(spacing: 6) {
            Path { path in
                path.move(to: CGPoint(x: 0, y: 1.5))
                path.addLine(to: CGPoint(x: 18, y: 1.5))
            }
            .stroke(dashed ? AnyShapeStyle(Color.secondary.opacity(0.6)) : AnyShapeStyle(Rings.accent),
                    style: StrokeStyle(lineWidth: dashed ? 2 : 3, lineCap: .round, dash: dashed ? [4, 5] : []))
            .frame(width: 18, height: 3)
            Text(title)
        }
    }
}

/// White on the orange pages, orange on the light ones.
private struct PillButton: View {
    let title: String
    let filled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Text(title)
                Image(systemName: "arrow.right")
            }
            .font(.headline)
            .frame(maxWidth: .infinity)
            .frame(height: 56)
            .foregroundStyle(filled ? Color.white : Color(white: 0.1))
            .background(filled ? AnyShapeStyle(Rings.accent) : AnyShapeStyle(Color.white), in: Capsule())
            .shadow(color: .black.opacity(filled ? 0.15 : 0.08), radius: 12, y: 6)
        }
        .buttonStyle(.plain)
    }
}

/// The number of words, counting up when the page comes in.
/// Slow at first, then faster and faster to the end, in steps the system's digit roll animates
/// (an Animatable count redrew plain text every frame and didn't look like iOS).
private struct CountUp: View {
    let target: Int
    @State private var shown = 0

    var body: some View {
        Text(shown, format: .number)
            .font(.system(size: 72, weight: .heavy))
            .tracking(-2)
            .monospacedDigit()
            .foregroundStyle(.white)
            .contentTransition(.numericText(value: Double(shown)))
            .task {
                try? await Task.sleep(for: .milliseconds(350))
                let steps = 22
                for step in 1...steps {
                    // Ease in: small steps first, big ones at the end.
                    let progress = pow(Double(step) / Double(steps), 2.4)
                    withAnimation(.snappy(duration: 0.16)) { shown = Int((Double(target) * progress).rounded()) }
                    try? await Task.sleep(for: .milliseconds(85))
                }
            }
    }
}

/// Orange with a warm glow, or light peach to pink.
private struct OnboardingBackground: View {
    let bold: Bool

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 1, green: 0.96, blue: 0.92), Color(red: 1, green: 0.86, blue: 0.8), Color(red: 1, green: 0.78, blue: 0.84)],
                           startPoint: .top, endPoint: .bottom)
            LinearGradient(colors: [Color(red: 1, green: 0.62, blue: 0.2), Color(red: 1, green: 0.42, blue: 0.12)],
                           startPoint: .top, endPoint: .bottom)
                .overlay(alignment: .topTrailing) {
                    // A gradient, not a blurred circle: a blur this wide redraws on every frame of a fade.
                    RadialGradient(colors: [Color(red: 1, green: 0.85, blue: 0.4).opacity(0.7), .clear],
                                   center: .center, startRadius: 0, endRadius: 300)
                        .frame(width: 600, height: 600)
                        .offset(x: 230, y: -250)
                }
                .opacity(bold ? 1 : 0)
        }
        .ignoresSafeArea()
        .animation(.smooth(duration: 0.6), value: bold)
        .accessibilityHidden(true)
    }
}
