import AppIntents
import SwiftUI
import WidgetKit

@main
struct SrpskiWidgets: WidgetBundle {
    var body: some Widget {
        DueWidget()
        WordWidget()
    }
}

// MARK: - Timeline

struct SnapshotEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot?
    /// Which word the word widget shows in this entry.
    let wordIndex: Int
}

struct SnapshotProvider: TimelineProvider {
    func placeholder(in context: Context) -> SnapshotEntry {
        SnapshotEntry(date: .now, snapshot: .preview, wordIndex: 0)
    }

    func getSnapshot(in context: Context, completion: @escaping (SnapshotEntry) -> Void) {
        completion(SnapshotEntry(date: .now, snapshot: WidgetSnapshot.load() ?? .preview, wordIndex: 0))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<SnapshotEntry>) -> Void) {
        let snapshot = WidgetSnapshot.load()
        // A new entry every 30 minutes for 12 hours: due counts tick up, the word rotates.
        let start = Date.now
        let offset = Int(start.timeIntervalSince1970 / 1800) + WordRotation.skipped
        let entries = (0..<24).map { i in
            SnapshotEntry(date: start.addingTimeInterval(Double(i) * 1800), snapshot: snapshot, wordIndex: offset + i)
        }
        completion(Timeline(entries: entries, policy: .atEnd))
    }
}

extension WidgetSnapshot {
    static let preview = WidgetSnapshot(
        updatedAt: .now, dueNow: 12, newLeft: 5, roundLearned: 7, roundIntroduced: 10,
        upcoming: [], words: [Word(cue: "кошелёк", answer: "novčanik", info: nil)]
    )
}

// MARK: - Next word button

/// How many words the next-word button has skipped, kept in the app group so every timeline sees it.
enum WordRotation {
    private static let defaults = UserDefaults(suiteName: WidgetSnapshot.appGroup)

    static var skipped: Int {
        get { defaults?.integer(forKey: "wordWidgetSkipped") ?? 0 }
        set { defaults?.set(newValue, forKey: "wordWidgetSkipped") }
    }
}

/// The word widget's arrow button. WidgetKit reloads the timeline after it runs.
struct NextWordIntent: AppIntent {
    static let title: LocalizedStringResource = "Next Word"
    static let isDiscoverable = false

    func perform() async throws -> some IntentResult {
        WordRotation.skipped += 1
        return .result()
    }
}

// MARK: - Due widget

struct DueWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "SrpskiDue", provider: SnapshotProvider()) { entry in
            DueWidgetView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Kvačica: to review")
        .description("Cards due now, new words left and today's round.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

struct DueWidgetView: View {
    let entry: SnapshotEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        if let snapshot = entry.snapshot {
            HStack(alignment: .top, spacing: 16) {
                summary(snapshot)
                if family == .systemMedium {
                    ForecastBars(days: snapshot.forecast(from: entry.date))
                }
            }
        } else {
            OpenAppHint()
        }
    }

    private func summary(_ snapshot: WidgetSnapshot) -> some View {
        let due = snapshot.due(at: entry.date)
        return VStack(alignment: .leading, spacing: 4) {
            Label { Text(verbatim: "Kvačica") } icon: { Image(systemName: "character.book.closed") }
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
            if due == 0 {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 30))
                    .foregroundStyle(.green)
                Text("All done").font(.headline)
            } else {
                Text("\(due)")
                    .font(.system(size: 40, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                Text(String(localized: "unit: \(due) cards to review", table: "Units"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            // The open lesson, if there is one.
            if snapshot.roundIntroduced > 0, snapshot.roundLearned < snapshot.roundIntroduced {
                ProgressView(value: Double(snapshot.roundLearned), total: Double(snapshot.roundIntroduced))
                    .tint(.green)
                Text("Lesson \(snapshot.roundLearned) of \(snapshot.roundIntroduced) learned")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct ForecastBars: View {
    let days: [(day: Date, count: Int)]

    var body: some View {
        let peak = max(days.map(\.count).max() ?? 0, 1)
        VStack(alignment: .leading, spacing: 4) {
            Text("Next 7 days")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            HStack(alignment: .bottom, spacing: 6) {
                ForEach(days, id: \.day) { day in
                    VStack(spacing: 3) {
                        Text(day.count > 0 ? "\(day.count)" : "")
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                        Capsule()
                            .fill(Color.accentColor.gradient)
                            .frame(width: 10, height: max(3, 60 * CGFloat(day.count) / CGFloat(peak)))
                        Text(day.day.formatted(.dateTime.weekday(.narrow)))
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .frame(maxHeight: .infinity, alignment: .bottom)
        }
    }
}

// MARK: - Word widget

struct WordWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "SrpskiWord", provider: SnapshotProvider()) { entry in
            WordWidgetView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Kvačica: word")
        .description("One of your recent words, changing every half hour or when you click the arrow.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

struct WordWidgetView: View {
    let entry: SnapshotEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        if let words = entry.snapshot?.words, !words.isEmpty {
            let word = words[entry.wordIndex % words.count]
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Label { Text(verbatim: "Kvačica") } icon: { Image(systemName: "character.book.closed") }
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    if words.count > 1 {
                        Button(intent: NextWordIntent()) {
                            Image(systemName: "arrow.clockwise.circle.fill")
                                .font(.title3)
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("Another word")
                    }
                }
                Spacer(minLength: 0)
                Text(word.answer)
                    .font(.system(size: family == .systemSmall ? 24 : 30, weight: .semibold))
                    .minimumScaleFactor(0.5)
                    .lineLimit(2)
                Text(word.cue)
                    .font(family == .systemSmall ? .callout : .body)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                if family == .systemMedium, let info = word.info, !info.isEmpty {
                    Text(info)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(2)
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            OpenAppHint()
        }
    }
}

private struct OpenAppHint: View {
    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: "character.book.closed").font(.title2)
            Text("Open Kvačica once to fill this widget")
                .font(.caption)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
        }
    }
}
