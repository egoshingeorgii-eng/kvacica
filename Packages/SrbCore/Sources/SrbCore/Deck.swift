import Foundation
import SwiftData

/// The JSON deck format (see README).
public struct DeckFile: Codable, Sendable {
    public var version: Int
    public var notes: [DeckNote]
    /// Ids of notes to remove, with their cards and answer history. Applied after `notes`.
    public var delete: [String]?
    /// Example sentences to add to notes that exist, by id, leaving everything else about them
    /// (content, progress, the examples they have) as it is. Applied after `notes`, before `delete`.
    public var examples: [String: [NoteExample]]?
    /// Forms to set on notes that exist, by id and tag; other tags and everything else stay.
    /// Applied with `examples`.
    public var forms: [String: [String: String]]?

    public init(
        version: Int = 1, notes: [DeckNote], delete: [String]? = nil,
        examples: [String: [NoteExample]]? = nil, forms: [String: [String: String]]? = nil
    ) {
        self.version = version
        self.notes = notes
        self.delete = delete
        self.examples = examples
        self.forms = forms
    }
}

/// CEFR level of a note.
public enum Level: String, CaseIterable, Sendable {
    case a1 = "A1", a2 = "A2", b1 = "B1", b2 = "B2", c1 = "C1", c2 = "C2"

    /// Accepts "a1", " A1 " and Cyrillic look-alikes ("А1", "В2").
    public init?(parsing text: String) {
        let latin = text.trimmingCharacters(in: .whitespaces).uppercased()
            .replacingOccurrences(of: "А", with: "A")
            .replacingOccurrences(of: "В", with: "B")
            .replacingOccurrences(of: "С", with: "C")
        self.init(rawValue: latin)
    }

    /// Sort key for a stored level; anything unknown sorts last.
    public static func rank(_ text: String) -> Int {
        Level(parsing: text).flatMap { allCases.firstIndex(of: $0) } ?? allCases.count
    }
}

public struct DeckNote: Equatable, Sendable {
    public var id: String
    public var kind: NoteKind
    public var cue: String
    public var answer: String
    public var accept: [String]?
    public var info: String?
    /// "A1"…"C2". JSON key `level`; older decks used free-form `lesson`, which counts as A1.
    public var level: String = Level.a1.rawValue
    /// Theme like "Shopping" or "Family"; new rounds can be started from one topic.
    public var topic: String?
    public var cluster: String?
    public var tags: [String]?
    /// Sentences using the word, the word marked with asterisks. nil: keep what the note has.
    public var examples: [NoteExample]?
    /// The word's forms by tag (see `WordForms`). nil: keep what the note has.
    public var forms: [String: String]?

    public init(
        id: String, kind: NoteKind, cue: String, answer: String, accept: [String]? = nil, info: String? = nil,
        level: String = Level.a1.rawValue, topic: String? = nil, cluster: String? = nil, tags: [String]? = nil,
        examples: [NoteExample]? = nil, forms: [String: String]? = nil
    ) {
        self.id = id
        self.kind = kind
        self.cue = cue
        self.answer = answer
        self.accept = accept
        self.info = info
        self.level = level
        self.topic = topic
        self.cluster = cluster
        self.tags = tags
        self.examples = examples
        self.forms = forms
    }
}

extension DeckNote: Codable {
    enum CodingKeys: String, CodingKey {
        case id, kind, cue, answer, accept, info, level, lesson, topic, cluster, tags, examples, forms
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        kind = try c.decode(NoteKind.self, forKey: .kind)
        cue = try c.decode(String.self, forKey: .cue)
        answer = try c.decode(String.self, forKey: .answer)
        accept = try c.decodeIfPresent([String].self, forKey: .accept)
        info = try c.decodeIfPresent(String.self, forKey: .info)
        topic = try c.decodeIfPresent(String.self, forKey: .topic)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .flatMap { $0.isEmpty ? nil : $0 }
        cluster = try c.decodeIfPresent(String.self, forKey: .cluster)
        tags = try c.decodeIfPresent([String].self, forKey: .tags)
        examples = try c.decodeIfPresent([NoteExample].self, forKey: .examples)
        forms = try c.decodeIfPresent([String: String].self, forKey: .forms)
        if let raw = try c.decodeIfPresent(String.self, forKey: .level) {
            guard let parsed = Level(parsing: raw) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .level, in: c, debugDescription: "level must be one of A1, A2, B1, B2, C1, C2, got \"\(raw)\""
                )
            }
            level = parsed.rawValue
        } else {
            let legacy = try c.decodeIfPresent(String.self, forKey: .lesson)
            level = legacy.flatMap(Level.init(parsing:))?.rawValue ?? Level.a1.rawValue
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(kind, forKey: .kind)
        try c.encode(cue, forKey: .cue)
        try c.encode(answer, forKey: .answer)
        try c.encodeIfPresent(accept, forKey: .accept)
        try c.encodeIfPresent(info, forKey: .info)
        try c.encode(level, forKey: .level)
        try c.encodeIfPresent(topic, forKey: .topic)
        try c.encodeIfPresent(cluster, forKey: .cluster)
        try c.encodeIfPresent(tags, forKey: .tags)
        try c.encodeIfPresent(examples, forKey: .examples)
        try c.encodeIfPresent(forms, forKey: .forms)
    }
}

public enum DeckError: LocalizedError, Equatable {
    case notJSON
    case unsupportedVersion(Int)
    case invalid(String)

    public var errorDescription: String? {
        switch self {
        case .notJSON: String(localized: "No JSON object found. A deck starts with { \"version\": 1, \"notes\": [ … ] }.")
        case .unsupportedVersion(let v): String(localized: "Deck version \(v) isn't supported (expected 1).")
        case .invalid(let reason): reason
        }
    }
}

extension DeckFile {
    /// Parses a deck file or text pasted from a chat: ```json fences and text around the JSON are ignored.
    public static func parse(_ text: String) throws -> DeckFile {
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start < end else {
            throw DeckError.notJSON
        }
        let deck: DeckFile
        do {
            deck = try JSONDecoder().decode(DeckFile.self, from: Data(text[start...end].utf8))
        } catch let error as DecodingError {
            throw DeckError.invalid(describe(error))
        } catch {
            throw DeckError.invalid(error.localizedDescription)
        }
        guard deck.version == 1 else { throw DeckError.unsupportedVersion(deck.version) }
        for note in deck.notes where [note.id, note.cue, note.answer].contains(where: { $0.trimmingCharacters(in: .whitespaces).isEmpty }) {
            throw DeckError.invalid(String(localized: "Note \"\(note.id)\" has an empty id, cue or answer."))
        }
        return deck
    }

    private static func describe(_ error: DecodingError) -> String {
        func path(_ context: DecodingError.Context) -> String {
            context.codingPath.map { $0.intValue.map { "[\($0)]" } ?? ".\($0.stringValue)" }
                .joined().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        }
        switch error {
        case .keyNotFound(let key, let context):
            return String(localized: "Missing \"\(key.stringValue)\" at \(path(context)).")
        case .typeMismatch(_, let context), .valueNotFound(_, let context), .dataCorrupted(let context):
            let at = path(context)
            return at.isEmpty ? String(localized: "Invalid JSON: \(context.debugDescription)") : String(localized: "Invalid value at \(at): \(context.debugDescription)")
        @unknown default:
            return error.localizedDescription
        }
    }
}

public struct ImportSummary: Equatable, Sendable {
    public var added = 0
    public var updated = 0
    public var unchanged = 0
    public var deleted = 0
    /// Ids of the notes that were new, in deck order.
    public var addedIDs: [String] = []
    /// IDs that appeared more than once in the deck; the last occurrence wins.
    public var duplicateIDs: [String] = []

    public var description: String {
        var text = String(localized: "\(added) new, \(updated) updated, \(unchanged) unchanged.")
        if deleted > 0 { text += " " + String(localized: "\(deleted) deleted.") }
        if !duplicateIDs.isEmpty {
            text += "\n" + String(localized: "Duplicate ids (last one used): \(duplicateIDs.joined(separator: ", "))")
        }
        return text
    }
}

@MainActor
public enum DeckImporter {
    /// Merges by id: updates content, keeps scheduling state, adds new notes.
    /// Deletes only the notes listed in the deck's `delete`.
    public static func merge(_ deck: DeckFile, into context: ModelContext, now: Date = .now) throws -> ImportSummary {
        let existing = try context.fetch(FetchDescriptor<Note>())
        var byID = Dictionary(existing.map { ($0.noteID, $0) }, uniquingKeysWith: { first, _ in first })
        var nextOrder = (existing.map(\.order).max() ?? -1) + 1
        var seen = Set<String>()
        var summary = ImportSummary()

        for item in deck.notes {
            if !seen.insert(item.id).inserted { summary.duplicateIDs.append(item.id) }
            if let note = byID[item.id] {
                if note.apply(item) { summary.updated += 1 } else { summary.unchanged += 1 }
                ensureCards(for: note, in: context, now: now)
            } else {
                let note = Note(item, order: nextOrder)
                nextOrder += 1
                context.insert(note)
                byID[item.id] = note
                ensureCards(for: note, in: context, now: now)
                summary.added += 1
                summary.addedIDs.append(item.id)
            }
        }
        var touched = Set<String>()
        for (id, list) in deck.examples ?? [:] {
            guard let note = byID[id] else { continue }
            if note.addExamples(list) { touched.insert(id) }
        }
        for (id, table) in deck.forms ?? [:] {
            guard let note = byID[id] else { continue }
            if note.mergeForms(table) { touched.insert(id) }
        }
        summary.updated += touched.count
        for id in Set(deck.delete ?? []) {
            guard let note = byID.removeValue(forKey: id) else { continue }
            context.delete(note)
            summary.deleted += 1
        }
        try context.save()
        return summary
    }

    /// Notes from before levels existed had free-form lessons ("L3", "body"); they become A1.
    public static func migrateToLevels(in context: ModelContext) {
        let notes = (try? context.fetch(FetchDescriptor<Note>())) ?? []
        var changed = false
        for note in notes {
            let level = Level(parsing: note.level)?.rawValue ?? Level.a1.rawValue
            if note.level != level {
                note.level = level
                changed = true
            }
        }
        if changed { try? context.save() }
    }

    /// Moves notes to the topics of 2026-11 (`TopicMoves`). Runs on every launch, on each device:
    /// a note moves only while it still has its old topic, so running again changes nothing.
    public static func migrateTopics(in context: ModelContext) {
        let notes = (try? context.fetch(FetchDescriptor<Note>())) ?? []
        var changed = false
        for note in notes {
            guard let move = TopicMoves.november2026[note.noteID], note.topic == move.from else { continue }
            note.topic = move.to
            changed = true
        }
        if changed { try? context.save() }
    }

    private static func ensureCards(for note: Note, in context: ModelContext, now: Date) {
        let production = note.card(.production) ?? add(.production, unlocked: true, to: note, in: context, now: now)
        if note.kind.hasRecognition, note.card(.recognition) == nil {
            let reachedReview = production.phase == .review || production.phase == .relearning
            add(.recognition, unlocked: reachedReview, to: note, in: context, now: now)
        }
    }

    @discardableResult
    private static func add(_ direction: Direction, unlocked: Bool, to note: Note, in context: ModelContext, now: Date) -> StudyCard {
        let card = StudyCard(direction: direction, unlocked: unlocked, now: now)
        context.insert(card)
        note.cards = note.cardList + [card]
        return card
    }
}
