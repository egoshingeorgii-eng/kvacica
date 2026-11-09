import Foundation
import SrbCore

/// The words the app comes with, A1 to B1, each with its forms and example sentences
/// (Resources/srpski-library.json), so nobody needs a chat to get started. The first-launch
/// screens add the levels you pick; an empty Words list offers A1.
@MainActor
enum StarterLibrary {
    /// The levels it has, easiest first. Above B1 you bring your own words.
    static let levels = [Level.a1, .a2, .b1].map(\.rawValue)

    nonisolated static let all: [DeckNote] = {
        guard let url = Bundle.main.url(forResource: "srpski-library", withExtension: "json"),
              let text = try? String(contentsOf: url, encoding: .utf8),
              let deck = try? DeckFile.parse(text)
        else { return [] }
        return deck.notes
    }()

    /// Every built-in word's id.
    nonisolated static let ids = Set(all.map(\.id))

    static func notes(levels: [String]) -> [DeckNote] {
        all.filter { levels.contains($0.level) }
    }

    /// Words per level, counted once: the onboarding pages ask on every redraw.
    nonisolated private static let counts = Dictionary(grouping: all, by: \.level).mapValues(\.count)

    static func count(_ level: String) -> Int {
        counts[level] ?? 0
    }

    /// Reads the library off the main thread, so the first page that counts its words doesn't
    /// parse it in the middle of a transition.
    static func preload() async {
        await Task.detached(priority: .userInitiated) { _ = counts }.value
    }

    /// Built-in words the deck doesn't have yet, by id or by the Serbian word, in library order:
    /// the New words list offers them next to your own, and they come in once picked.
    static func missing(in engine: StudyEngine) -> [DeckNote] {
        let notes = engine.allNotes()
        let ids = Set(notes.map(\.noteID))
        let answers = Set(notes.map { $0.answer.lowercased() })
        return all.filter { !ids.contains($0.id) && !answers.contains($0.answer.lowercased()) }
    }

    /// Words of `level` the deck doesn't have yet.
    static func missing(_ level: String, in engine: StudyEngine) -> [DeckNote] {
        missing(in: engine).filter { $0.level == level }
    }

    /// Adds what the deck doesn't have of `levels`, keeping every word already there as it is.
    /// Returns how many went in.
    @discardableResult
    static func add(levels: [String], to model: AppModel) -> Int {
        add(missing(in: model.engine).filter { levels.contains($0.level) }, to: model)
    }

    /// Adds the built-in words with these ids that the deck doesn't have yet, as words not started.
    @discardableResult
    static func add(ids: some Collection<String>, to model: AppModel) -> Int {
        let ids = Set(ids)
        return add(missing(in: model.engine).filter { ids.contains($0.id) }, to: model)
    }

    private static func add(_ notes: [DeckNote], to model: AppModel) -> Int {
        guard !notes.isEmpty,
              let summary = try? DeckImporter.merge(DeckFile(notes: notes), into: model.container.mainContext)
        else { return 0 }
        model.cache.invalidate()
        model.didChange()
        return summary.added
    }
}
