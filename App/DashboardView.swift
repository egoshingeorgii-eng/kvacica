import AppKit
import SwiftUI
import SrbCore

/// The Mac's Progress tab: streak, recall, words, time, hard words, what's coming and recent
/// answers. The iPhone has its own as a sheet (ProgressSheet).
struct DashboardView: View {
    /// The figures, kept by the window across tabs.
    var built = BuiltDashboard()
    @State private var width: CGFloat = 0

    var body: some View {
        ScrollView {
            DashboardGrid(width: width, built: built)
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

/// The last dashboard and what it was worked out for.
final class BuiltDashboard {
    private var made: (revision: Int, retention: Double, data: Dashboard)?

    func dashboard(revision: Int, retention: Double, make: () -> Dashboard) -> Dashboard {
        if let made, made.revision == revision, made.retention == retention { return made.data }
        let data = make()
        made = (revision, retention, data)
        return data
    }
}

/// The cards, without scrolling (also rendered on its own for UI snapshots).
struct DashboardGrid: View {
    /// Width of the area the cards fill; columns are fixed fractions of it so long text
    /// can't widen one column and push the grid off-screen.
    let width: CGFloat
    @Environment(AppModel.self) private var model
    @AppStorage(Pref.retention) private var retention = 0.9

    /// The figures, worked out once per change to the deck, not on every draw: opening the tab
    /// drew twice (the width comes in after the first), each going through every answer.
    var built = BuiltDashboard()

    private let spacing: CGFloat = 16
    private let padding: CGFloat = 24

    var body: some View {
        let _ = Perf.count("progress grid")
        let data = built.dashboard(revision: model.revision, retention: retention) {
            Perf.measure("dashboard") { model.engine.dashboard(targetRetention: retention) }
        }
        if width < 640 {
            narrow(data)
        } else {
            wide(data)
        }
    }

    /// iPhone: one card under another.
    private func narrow(_ data: Dashboard) -> some View {
        VStack(spacing: spacing) {
            StreakCard(data: data)
            RecallCard(data: data)
            ForecastCard(days: data.forecast)
            TimeCard(data: data)
            WordsCard(data: data)
            HardWordsCard(data: data, copyReport: copyReport)
            RecentCard(answers: data.recent)
        }
        .padding(16)
    }

    private func wide(_ data: Dashboard) -> some View {
        let column = max((width - 2 * padding - 2 * spacing) / 3, 200)
        let double = 2 * column + spacing
        return VStack(spacing: spacing) {
            row {
                StreakCard(data: data).frame(width: double)
                RecallCard(data: data).frame(width: column)
            }
            row {
                ForecastCard(days: data.forecast).frame(width: column)
                TimeCard(data: data).frame(width: column)
                WordsCard(data: data).frame(width: column)
            }
            row {
                RecentCard(answers: data.recent).frame(width: double)
                HardWordsCard(data: data, copyReport: copyReport).frame(width: column)
            }
        }
        .padding(padding)
    }

    /// Cards side by side, all as tall as the tallest.
    private func row(@ViewBuilder _ cards: () -> some View) -> some View {
        HStack(alignment: .top, spacing: spacing) { cards() }
            .fixedSize(horizontal: false, vertical: true)
    }

    private func copyReport() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(model.engine.tutorReport(), forType: .string)
    }
}

// MARK: - Cards

private struct StreakCard: View {
    let data: Dashboard

    var body: some View {
        Card(String(localized: "Streak")) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                BigNumber(value: "\(data.currentStreak)", unit: String(localized: "unit: \(data.currentStreak) days", table: "Units"))
                if data.longestStreak > 0 {
                    Label("Longest \(data.longestStreak) days", systemImage: "trophy")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(Capsule().strokeBorder(Color.primary.opacity(0.12)))
                }
            }
            StreakHeatmap(answersPerDay: data.answersPerDay)
            HStack(spacing: 4) {
                let active = data.answersPerDay.count
                Text(String(localized: "\(active) days studied") + " · " + String(localized: "\(data.answersPerDay.values.reduce(0, +)) answers"))
                Spacer()
                Text("Less")
                ForEach([0, 5, 20, 45, 60], id: \.self) { count in
                    RoundedRectangle(cornerRadius: 3).fill(StreakHeatmap.color(for: count)).frame(width: 12, height: 12)
                }
                Text("More")
            }
            .font(.callout)
            .foregroundStyle(.secondary)
        }
    }
}

private struct RecallCard: View {
    let data: Dashboard

    var body: some View {
        // Until learned words come back, show first-try accuracy so the card is never empty.
        let value = data.recall30 ?? data.firstTry30
        Card(String(localized: "Recall")) {
            BigNumber(
                value: value.map(percent) ?? "—",
                unit: data.recall30 != nil ? String(localized: "remembered") : String(localized: "right first try")
            )
            RecallGauge(value: value, target: data.targetRetention)
                .frame(maxWidth: .infinity)
            Text(footer)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .help("Remembered: words you still knew when they came back after a few days (last 30 days). Until the first ones come back, this shows how often you were right first try.")
    }

    private var footer: String {
        if data.recall30 != nil { return String(localized: "\(data.recallSample) reviews · last 30 days") }
        guard let first = data.firstReturn else { return String(localized: "Words come back after a lesson") }
        let calendar = Calendar.current
        if calendar.isDateInToday(first.day) { return String(localized: "First words come back today") }
        if calendar.isDateInTomorrow(first.day) { return String(localized: "First words come back tomorrow") }
        return String(localized: "First words come back \(first.day.formatted(.dateTime.weekday(.wide)))")
    }

    private func percent(_ value: Double) -> String { value.formatted(.percent.precision(.fractionLength(0))) }
}

private struct WordsCard: View {
    let data: Dashboard

    var body: some View {
        Card(String(localized: "Words learned"), badge: data.startedThisWeek > 0 ? String(localized: "+\(data.startedThisWeek) this week") : nil) {
            BigNumber(value: "\(data.learned)", unit: String(localized: "of \(data.learned + data.learning + data.notStarted)"))
            VStack(spacing: 12) {
                ForEach(data.levels) { level in
                    BarRow(
                        label: level.level,
                        detail: "\(level.learned) / \(level.total)",
                        fraction: level.total > 0 ? Double(level.learned) / Double(level.total) : 0
                    )
                }
                BarRow(
                    label: String(localized: "Learning now"),
                    detail: "\(data.learning)",
                    fraction: Double(data.learning) / Double(max(data.learned + data.learning + data.notStarted, 1)),
                    color: .orange
                )
            }
        }
    }
}

private struct TimeCard: View {
    let data: Dashboard

    var body: some View {
        let peak = max(data.studyTimeWeek, 1)
        Card(String(localized: "Study time"), badge: data.studyTimeWeek >= 60 ? String(localized: "+\(Duration.short(data.studyTimeWeek)) this week") : nil) {
            DurationNumber(seconds: data.studyTimeTotal)
            VStack(spacing: 12) {
                BarRow(
                    label: String(localized: "Today"),
                    detail: String(localized: "\(Duration.short(data.studyTimeToday)) · \(data.answersToday) answers"),
                    fraction: data.studyTimeToday / peak
                )
                BarRow(label: String(localized: "Last 7 days"), detail: Duration.short(data.studyTimeWeek), fraction: 1, color: .secondary)
            }
        }
    }
}

private struct HardWordsCard: View {
    let data: Dashboard
    let copyReport: () -> Void
    @State private var copied = false

    var body: some View {
        let peak = max(data.hardWords.first?.mistakes ?? 1, 1)
        Card(String(localized: "Hardest words")) {
            if data.hardWords.isEmpty {
                Text("No mistakes yet. Words you get wrong show up here.")
                    .foregroundStyle(.secondary)
                    .frame(maxHeight: .infinity, alignment: .top)
            } else {
                VStack(spacing: 12) {
                    ForEach(data.hardWords) { word in
                        BarRow(
                            label: word.answer,
                            sublabel: word.cue,
                            detail: "\(word.mistakes)×",
                            fraction: Double(word.mistakes) / Double(peak),
                            color: .red
                        )
                    }
                }
            }
            Spacer(minLength: 0)
            Button {
                copyReport()
                copied = true
                Task {
                    try? await Task.sleep(for: .seconds(2))
                    copied = false
                }
            } label: {
                Label(copied ? "Copied" : "Copy for tutor", systemImage: copied ? "checkmark" : "doc.on.doc")
            }
            .buttonStyle(.borderless)
            .keyboardShortcut("c", modifiers: [.command, .shift])
            .help("Hard words and this week's wrong answers as Markdown (⌘⇧C)")
        }
    }
}

private struct ForecastCard: View {
    let days: [StudyStats.Day]

    var body: some View {
        let peak = max(days.map(\.count).max() ?? 0, 1)
        Card(String(localized: "Coming up")) {
            BigNumber(value: "\(days.first?.count ?? 0)", unit: String(localized: "due today"))
            HStack(alignment: .bottom, spacing: 10) {
                ForEach(days) { day in
                    VStack(spacing: 4) {
                        Text(verbatim: day.count > 0 ? "\(day.count)" : "")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                        RoundedRectangle(cornerRadius: 3)
                            .fill(Color.accentColor.opacity(day.count > 0 ? 1 : 0.15))
                            .frame(height: max(4, 90 * CGFloat(day.count) / CGFloat(peak)))
                        Text(day.day.formatted(.dateTime.weekday(.abbreviated)))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .frame(height: 130, alignment: .bottom)
        }
    }
}

private struct RecentCard: View {
    let answers: [Dashboard.RecentAnswer]

    var body: some View {
        Card(String(localized: "Recent answers")) {
            if answers.isEmpty {
                Text("Nothing yet.").foregroundStyle(.secondary)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(answers.enumerated()), id: \.offset) { index, answer in
                        if index > 0 { Divider() }
                        HStack(spacing: 10) {
                            Circle().fill(answer.grade.color).frame(width: 8, height: 8)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(answer.serbian).fontWeight(.medium)
                                Text(answer.russian).font(.callout).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(answer.direction == .production ? "RU → SR" : "SR → RU")
                                .font(.callout)
                                .foregroundStyle(.tertiary)
                            if answer.grade == .again, !answer.typed.isEmpty {
                                Text(answer.typed)
                                    .font(.callout)
                                    .strikethrough(color: .red.opacity(0.6))
                                    .foregroundStyle(.secondary)
                            }
                            Text(answer.grade.title)
                                .font(.callout.weight(.semibold))
                                .foregroundStyle(answer.grade.color)
                                .frame(width: 64, alignment: .trailing)
                            Text(answer.at.formatted(.relative(presentation: .named)))
                                .font(.callout)
                                .foregroundStyle(.tertiary)
                                .frame(width: 90, alignment: .trailing)
                        }
                        .padding(.vertical, 7)
                    }
                }
            }
        }
    }
}

// MARK: - Building blocks

private struct Card<Content: View>: View {
    let title: String
    var badge: String?
    @ViewBuilder let content: Content

    init(_ title: String, badge: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.badge = badge
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(title).font(.headline)
                Spacer()
                if let badge {
                    Text(badge)
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.green)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(Color.green.opacity(0.13)))
                }
            }
            content
        }
        .padding(20)
        .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color.cardBackground))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.primary.opacity(0.08)))
    }
}

private struct BigNumber: View {
    let value: String
    let unit: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(value)
                .font(.system(size: 40, weight: .semibold, design: .rounded))
                .monospacedDigit()
            Text(unit)
                .font(.title3)
                .foregroundStyle(.secondary)
        }
    }
}

private struct DurationNumber: View {
    let seconds: TimeInterval

    var body: some View {
        let minutes = Int(seconds / 60)
        HStack(alignment: .firstTextBaseline, spacing: 2) {
            if minutes >= 60 {
                part("\(minutes / 60)", String(localized: "h", comment: "hours, after a number"))
                part("\(minutes % 60)", String(localized: "m", comment: "minutes, after a number")).padding(.leading, 6)
            } else {
                part("\(minutes)", String(localized: "m", comment: "minutes, after a number"))
            }
        }
    }

    private func part(_ number: String, _ unit: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 1) {
            Text(number).font(.system(size: 40, weight: .semibold, design: .rounded)).monospacedDigit()
            Text(unit).font(.title3).foregroundStyle(.secondary)
        }
    }
}

private struct BarRow: View {
    let label: String
    var sublabel: String?
    let detail: String
    let fraction: Double
    var color: Color = .accentColor

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline) {
                Text(label).fontWeight(.medium)
                if let sublabel {
                    Text(sublabel).font(.callout).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 8)
                Text(detail).foregroundStyle(.secondary).monospacedDigit()
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.07))
                    Capsule().fill(color).frame(width: geo.size.width * min(max(fraction, 0), 1))
                }
            }
            .frame(height: 5)
        }
    }
}

/// GitHub-style grid: one column per week, as many weeks as fit, the current week on the right.
struct StreakHeatmap: View {
    let answersPerDay: [Date: Int]
    private let cell: CGFloat = 16
    private let gap: CGFloat = 4

    var body: some View {
        GeometryReader { geo in
            // Only the number of weeks that fit counts: dragging the window's edge redrew all
            // 371 days (each with its tooltip) on every pixel.
            let weeks = max(4, min(53, Int((geo.size.width + gap) / (cell + gap))))
            HeatmapWeeks(weeks: weeks, answersPerDay: answersPerDay).equatable()
        }
        .frame(height: 16 + 6 + 7 * cell + 6 * gap)
    }
}

extension StreakHeatmap {
    static func color(for count: Int) -> Color {
        switch count {
        case 0: Color.primary.opacity(0.07)
        case 1..<10: Color.accentColor.opacity(0.3)
        case 10..<30: Color.accentColor.opacity(0.55)
        case 30..<60: Color.accentColor.opacity(0.8)
        default: Color.accentColor
        }
    }
}

private struct HeatmapWeeks: View, Equatable {
    let weeks: Int
    let answersPerDay: [Date: Int]
    private let cell: CGFloat = 16
    private let gap: CGFloat = 4

    var body: some View {
        let columns = weekColumns(count: weeks)
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .topLeading) {
                ForEach(monthLabels(columns), id: \.column) { label in
                    Text(label.text)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize()
                        .offset(x: CGFloat(label.column) * (cell + gap))
                }
            }
            .frame(height: 16, alignment: .topLeading)
            HStack(spacing: gap) {
                ForEach(columns.indices, id: \.self) { c in
                    VStack(spacing: gap) {
                        ForEach(0..<7, id: \.self) { r in
                            if let day = columns[c][r] {
                                let count = answersPerDay[day] ?? 0
                                RoundedRectangle(cornerRadius: 3)
                                    .fill(StreakHeatmap.color(for: count))
                                    .frame(width: cell, height: cell)
                                    .help("\(day.formatted(date: .abbreviated, time: .omitted)): \(count) answers")
                            } else {
                                Color.clear.frame(width: cell, height: cell)
                            }
                        }
                    }
                }
            }
        }
    }

    /// Each column is a week (calendar's first weekday on top); days after today are nil.
    private func weekColumns(count: Int) -> [[Date?]] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: .now)
        let thisWeek = calendar.dateInterval(of: .weekOfYear, for: today)!.start
        return (0..<count).map { c in
            let start = calendar.date(byAdding: .weekOfYear, value: c - (count - 1), to: thisWeek)!
            return (0..<7).map { r in
                let day = calendar.date(byAdding: .day, value: r, to: start)!
                return day > today ? nil : day
            }
        }
    }

    private func monthLabels(_ columns: [[Date?]]) -> [(column: Int, text: String)] {
        let calendar = Calendar.current
        var labels: [(column: Int, text: String)] = []
        var lastMonth: Int?
        for (c, week) in columns.enumerated() {
            guard let first = week.compactMap({ $0 }).first else { continue }
            let month = calendar.component(.month, from: first)
            if month != lastMonth {
                // Skip a label squeezed against the previous one.
                if let previous = labels.last, c - previous.column < 3 { labels.removeLast() }
                labels.append((c, first.formatted(.dateTime.month(.abbreviated))))
                lastMonth = month
            }
        }
        return labels
    }
}

/// A 270° gauge with a tick at the target recall.
private struct RecallGauge: View {
    let value: Double?
    let target: Double
    private let lineWidth: CGFloat = 14

    var body: some View {
        GeometryReader { geo in
            let size = min(geo.size.width, geo.size.height)
            let radius = (size - lineWidth) / 2
            ZStack {
                arc(to: 1).stroke(Color.primary.opacity(0.08), style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                if let value {
                    arc(to: value).stroke(Color.accentColor, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    Circle()
                        .fill(Color.cardBackground)
                        .overlay(Circle().strokeBorder(Color.accentColor, lineWidth: 3))
                        .frame(width: lineWidth - 2, height: lineWidth - 2)
                        .offset(point(value, radius))
                }
                Rectangle()
                    .fill(Color.primary)
                    .frame(width: lineWidth + 10, height: 2.5)
                    .rotationEffect(angle(target))
                    .offset(point(target, radius))
                Text("Target")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .offset(point(target, radius - lineWidth - 18))
                Text(0.0.formatted(.percent)).font(.callout).foregroundStyle(.secondary)
                    .offset(x: -radius * 0.72, y: radius * 0.92)
                Text(1.0.formatted(.percent)).font(.callout).foregroundStyle(.secondary)
                    .offset(x: radius * 0.72, y: radius * 0.92)
            }
            .frame(width: size, height: size)
            .position(x: geo.size.width / 2, y: geo.size.height / 2)
        }
        .frame(height: 170)
    }

    private func arc(to fraction: Double) -> some Shape {
        Circle()
            .inset(by: lineWidth / 2)
            .trim(from: 0, to: 0.75 * min(max(fraction, 0), 1))
            .rotation(.degrees(135))
    }

    /// The arc starts bottom-left (135°) and sweeps 270° clockwise.
    private func angle(_ fraction: Double) -> Angle { .degrees(135 + 270 * min(max(fraction, 0), 1)) }

    private func point(_ fraction: Double, _ radius: CGFloat) -> CGSize {
        let a = angle(fraction).radians
        return CGSize(width: radius * CGFloat(Foundation.cos(a)), height: radius * CGFloat(Foundation.sin(a)))
    }
}

private enum Duration {
    private static let style = Swift.Duration.UnitsFormatStyle(allowedUnits: [.hours, .minutes], width: .narrow, zeroValueUnits: .hide)

    static func short(_ seconds: TimeInterval) -> String {
        let minutes = Int(seconds / 60)
        if minutes < 1, seconds > 0 { return "<" + Swift.Duration.seconds(60).formatted(style) }
        return Swift.Duration.seconds(minutes * 60).formatted(style)
    }
}

extension Color {
    /// Behind a dashboard card.
    static var cardBackground: Color {
        Color(nsColor: .controlBackgroundColor)
    }
}
