import Foundation

/// What the app hands to the desktop widgets, via the shared app group container.
struct WidgetSnapshot: Codable, Equatable {
    struct Word: Codable, Hashable {
        var cue: String
        var answer: String
        var info: String?
    }

    var updatedAt: Date
    var dueNow: Int
    /// The open lesson: words not shown yet, learned, and in total (all 0 without a lesson).
    var newLeft: Int
    var roundLearned: Int
    var roundIntroduced: Int
    /// Due times of already-seen cards over the next week, so the widget can count as time passes.
    var upcoming: [Date]
    /// Words to show on the word widget, most recently started first.
    var words: [Word]

    /// iOS only takes app groups named group.*. The Mac's is team-prefixed and named in Info.plist
    /// (`SrpskiAppGroup`: project.yml, a test build's own from make-dmg.sh --test). A build signed
    /// without a team (the public repo's default install) has none, and the widget gets no data.
    static let appGroup = Bundle.main.object(forInfoDictionaryKey: "SrpskiAppGroup") as? String

    static var url: URL? {
        guard let appGroup else { return nil }
        return FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)?
            .appending(path: "widget.json")
    }

    static func load() -> WidgetSnapshot? {
        guard let url, let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(WidgetSnapshot.self, from: data)
    }

    func save() throws {
        guard let url = Self.url else { return }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(self).write(to: url, options: .atomic)
    }

    /// Cards due at `date`, counting the ones that came due since the snapshot.
    func due(at date: Date) -> Int {
        dueNow + upcoming.filter { $0 > updatedAt && $0 <= date }.count
    }

    /// Cards due on each of the 7 days starting with `date`'s day; today includes what's due now.
    func forecast(from date: Date, calendar: Calendar = .current) -> [(day: Date, count: Int)] {
        let today = calendar.startOfDay(for: date)
        return (0..<7).map { offset in
            let start = calendar.date(byAdding: .day, value: offset, to: today)!
            let end = calendar.date(byAdding: .day, value: 1, to: start)!
            let later = upcoming.filter { $0 > updatedAt && $0 >= start && $0 < end }.count
            return (start, offset == 0 ? dueNow + later : later)
        }
    }
}
