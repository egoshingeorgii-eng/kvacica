import Foundation
import SwiftData

/// Files the app shares with the MCP server, under ~/Library/Application Support/Srpski.
/// On iOS there's no MCP server; the same files live in the app's own Application Support.
///
/// - `Inbox/*.json`: decks queued by the MCP server; the app imports and removes them.
/// - `notes.json`: snapshot of every note and its learning status, written by the app.
/// - `tutor-report.md`: the same Markdown as "Copy for tutor", written by the app.
public enum SharedFiles {
    /// `SRPSKI_DIR` overrides the location (used for testing the MCP server). A test build
    /// (make-dmg.sh --test) names a folder of its own in Info.plist (`SrpskiDataFolder`), so it
    /// never opens the real deck.
    /// Built from the real passwd home: under App Sandbox, `homeDirectoryForCurrentUser`
    /// is the container and would open a second, empty deck.
    public static let folder = ProcessInfo.processInfo.environment["SRPSKI_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
        ?? realHome.appending(path: "Library/Application Support/" + dataFolderName, directoryHint: .isDirectory)
    private static var dataFolderName: String {
        Bundle.main.object(forInfoDictionaryKey: "SrpskiDataFolder") as? String ?? "Srpski"
    }
    /// A test copy of the deck (`SRPSKI_DIR`): it must never reach iCloud or the widgets.
    public static let isTestCopy = ProcessInfo.processInfo.environment["SRPSKI_DIR"] != nil

    private static var realHome: URL {
        if let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir {
            return URL(fileURLWithPath: String(cString: dir), isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }
    public static let inbox = folder.appending(path: "Inbox", directoryHint: .isDirectory)
    public static let notesSnapshot = folder.appending(path: "notes.json")
    public static let tutorReport = folder.appending(path: "tutor-report.md")
}

/// What the app publishes about its notes, so a chat can avoid duplicates and reuse clusters.
public struct NotesSnapshot: Codable, Sendable {
    public struct Entry: Codable, Sendable {
        public var note: DeckNote
        /// new, learning, review or relearning (production card).
        public var status: String
        public var lapses: Int
        public var leech: Bool
    }

    public var exportedAt: Date
    public var entries: [Entry]

    public static func load(from url: URL = SharedFiles.notesSnapshot) -> NotesSnapshot? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(NotesSnapshot.self, from: data)
    }

    public func write(to url: URL = SharedFiles.notesSnapshot) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(self).write(to: url, options: .atomic)
    }
}

extension StudyEngine {
    public func notesSnapshot(now: Date = .now) -> NotesSnapshot {
        let notes = allNotes()
        return NotesSnapshot(exportedAt: now, entries: notes.map { note in
            let production = note.card(.production)
            return NotesSnapshot.Entry(
                note: note.deckNote,
                status: String(describing: production?.phase ?? .new),
                lapses: note.lapses,
                leech: note.isLeech
            )
        })
    }
}

extension Note {
    var deckNote: DeckNote {
        DeckNote(
            id: noteID, kind: kind, cue: cue, answer: answer, accept: accept.isEmpty ? nil : accept,
            info: info, level: level, topic: topic, cluster: cluster, tags: tags,
            examples: examples.isEmpty ? nil : examples,
            forms: forms.isEmpty ? nil : forms
        )
    }
}

@MainActor
public enum Inbox {
    public struct Result: Sendable {
        public var summary = ImportSummary()
        public var failures: [String] = []
    }

    /// Imports every *.json deck in the inbox, oldest first, and deletes each one that imported.
    /// Broken files are renamed to *.failed so they aren't retried forever.
    public static func importPending(into context: ModelContext, folder: URL = SharedFiles.inbox) -> Result {
        var result = Result()
        let files = ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "json" && !$0.lastPathComponent.hasPrefix(".") }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        for file in files {
            do {
                let deck = try DeckFile.parse(String(contentsOf: file, encoding: .utf8))
                let summary = try DeckImporter.merge(deck, into: context)
                result.summary.added += summary.added
                result.summary.addedIDs += summary.addedIDs
                result.summary.updated += summary.updated
                result.summary.unchanged += summary.unchanged
                result.summary.deleted += summary.deleted
                result.summary.duplicateIDs += summary.duplicateIDs
                try? FileManager.default.removeItem(at: file)
            } catch {
                result.failures.append("\(file.lastPathComponent): \(error.localizedDescription)")
                try? FileManager.default.moveItem(at: file, to: file.appendingPathExtension("failed"))
            }
        }
        return result
    }
}
