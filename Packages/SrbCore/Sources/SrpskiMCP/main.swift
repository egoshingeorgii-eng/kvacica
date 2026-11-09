// srpski-mcp: a stdio MCP server that lets a chat add and delete vocabulary in the Srpski app.
//
// It never touches the app's database. Decks (and deletions) go into the app's inbox folder
// (the app imports them within a second, or on next launch); reads come from the
// notes.json / tutor-report.md files the app publishes. See SharedFiles.

import AppKit
import Foundation
import SrbCore

let appBundleID = "com.georgiiegoshin.srpski"

// MARK: - Tools

/// The suggested topics plus any the deck already uses.
func knownTopics() -> [String] {
    let used = (NotesSnapshot.load()?.entries ?? []).compactMap(\.note.topic)
    var topics = Topics.suggested
    for topic in used where !topics.contains(topic) { topics.append(topic) }
    return topics
}

func topicGuide(_ topics: [String]) -> String {
    topics.map { topic in Topics.hints[topic].map { "\(topic) (\($0))" } ?? topic }.joined(separator: "; ")
}

func noteSchema() -> [String: Any] { [
    "type": "object",
    "properties": [
        "id": ["type": "string", "description": "Stable unique id: lowercase ASCII kebab-case of the Serbian, e.g. \"novcanik\", \"zato-sto\". Forms: \"f-gledati-ja\"; sentences: \"s-…\". Reusing an existing id updates that note."],
        "kind": ["type": "string", "enum": ["word", "phrase", "form", "sentence"], "description": "word/phrase: drilled both ways (RU→SR typed, SR→RU recall). form: a conjugation/declension drill, cue like \"gledati → ja …\". sentence: translate a whole Russian sentence."],
        "cue": ["type": "string", "description": "The prompt, in Russian (for forms: the Serbian drill, e.g. \"moći → oni …\"). Add a disambiguating hint in parentheses when a Russian word has several Serbian translations."],
        "answer": ["type": "string", "description": "The Serbian answer, Latin script, with correct diacritics (č ć š ž đ). Ekavian."],
        "accept": ["type": "array", "items": ["type": "string"], "description": "Other answers that are also correct (synonyms, with/without pronoun)."],
        "info": ["type": "string", "description": "Short note in Russian shown after answering; any Serbian in it in Latin script (\"pržiti na tiganju\", never \"пржити\"). For verbs always start with the full present tense, ja to oni, e.g. \"pišem, pišeš, piše, pišemo, pišete, pišu\", then \" · \" and a short note if useful (\"I гр.\", \"без na нельзя\"). For nouns/adjectives: gender pair, plural, false-friend warning."],
        "level": ["type": "string", "enum": ["A1", "A2", "B1", "B2", "C1", "C2"], "description": "CEFR level of the word. New words are introduced A1 first. Defaults to A1."],
        "topic": ["type": "string", "description": "Required. The theme the learner picks lessons from and where the app shows the word. Pick the best fit, spelled exactly: \(topicGuide(knownTopics())). Only invent a new short English topic if several words clearly need one; never leave it out (it would land in \"Other\")."],
        "cluster": ["type": "string", "description": "Only for 2–6 words that are genuinely easy to mix up (lekar/lekarka, levo/desno, stric/ujak); the app never shows two of them back to back. Never a whole topic: that is what topic is for. Leave it out for most words."],
        "tags": ["type": "array", "items": ["type": "string"], "description": "Free tags, e.g. \"verb\", \"false-friend\"."],
        "examples": ["type": "array", "items": exampleSchema(), "maxItems": 5, "description": "1–3 short sentences using the word, for the app's \"fill in the word\". Replaces the note's examples; leave it out to keep them (add more with add_examples)."],
        "forms": formsSchema(description: formsGuide + " Replaces the note's table; leave it out to keep it (change single forms with add_forms)."),
    ],
    "required": ["id", "kind", "cue", "answer", "topic"],
] }

/// The same text as the cloud's (cloud/src/index.js).
var exampleGuide: String { "A short everyday sentence (A1–A2) using the word in whatever form the sentence needs, that word marked with asterisks, plus its Russian translation: {\"sr\": \"Kupio sam *hleba* u pekari.\", \"ru\": \"Я купил хлеба в пекарне.\"}. Give each note sentences that need different forms: a noun in different cases (Nema *hleba*. / Jedem supu sa *hlebom*.), a verb in different persons or the past (*Pišem* pismo. / Oni *pišu* brzo. / *Pisala* sam pismo.), an adjective agreeing in gender and case (*Velika* kuća. / U *velikom* gradu.). Besides the word itself use only words the learner already has (list_words) or very common ones. Ekavian, Latin script, correct diacritics." }

/// The same text as the cloud's (cloud/src/index.js).
var formsGuide: String { "The word's forms by tag, for the app's form drills (it asks e.g. \"Nema ___.\" for gen.sg) and its form table. Nouns: nom.sg … loc.pl, the 7 cases in singular and plural (voc only for people and animals, never for things, places or ideas: no \"planino\"; leave out the plural of a word that has none). Adjectives: m./f./n. with nom gen dat acc ins loc, the long attributive forms (f.gen \"velike\", m.loc \"velikom\"), plus comp and sup. Verbs: pres.1sg … pres.3pl, past.m.sg past.f.sg past.n.sg past.m.pl past.f.pl past.n.pl (the participle alone, without je/su), imp.2sg imp.1pl imp.2pl; a reflexive verb's forms keep se (\"zovem se\"). Ekavian, Latin script, correct diacritics. One form per tag; another accepted spelling may follow a slash (\"pisao/pis'o\"). Leave out forms that don't exist." }

func formsSchema(description: String) -> [String: Any] { [
    "type": "object",
    "description": description,
    "propertyNames": ["enum": WordForms.tags],
    "additionalProperties": ["type": "string"],
] }

func exampleSchema() -> [String: Any] { [
    "type": "object",
    "description": exampleGuide,
    "properties": [
        "sr": ["type": "string", "description": "The Serbian sentence, exactly one word (or phrase) marked: *hleba*."],
        "ru": ["type": "string", "description": "Its Russian translation."],
    ],
    "required": ["sr", "ru"],
] }

func tools() -> [[String: Any]] { [
    [
        "name": "add_words",
        "description": "Add or update Serbian vocabulary in the Srpski flashcard app. Notes are merged by id: new ids are added, existing ids get their content updated while keeping their review history. Call list_words first to avoid duplicates and to reuse cluster names.",
        "inputSchema": [
            "type": "object",
            "properties": ["notes": ["type": "array", "items": noteSchema(), "minItems": 1]],
            "required": ["notes"],
        ],
    ],
    [
        "name": "delete_words",
        "description": "Permanently delete notes from Srpski by id, together with their cards and review history. Only do this when the user asked to remove these words; to fix a typo or translation, use add_words with the same id instead, which keeps the progress. Get ids from list_words.",
        "inputSchema": [
            "type": "object",
            "properties": ["ids": ["type": "array", "items": ["type": "string"], "minItems": 1, "description": "Note ids, exactly as list_words shows them."]],
            "required": ["ids"],
        ],
    ],
    [
        "name": "add_examples",
        "description": "Add example sentences to notes already in Srpski, by id. The app uses them for \"fill in the word\": the sentence with the marked word blanked out, to type or say in the right form. Nothing else about the note changes and its progress is kept; sentences a note already has are skipped. 1–3 per note.",
        "inputSchema": [
            "type": "object",
            "properties": ["notes": [
                "type": "array", "minItems": 1,
                "items": [
                    "type": "object",
                    "properties": [
                        "id": ["type": "string", "description": "Note id, exactly as list_words shows it."],
                        "examples": ["type": "array", "items": exampleSchema(), "minItems": 1, "maxItems": 5],
                    ],
                    "required": ["id", "examples"],
                ],
            ]],
            "required": ["notes"],
        ],
    ],
    [
        "name": "add_forms",
        "description": "Fill in the form tables of notes already in Srpski, by id: every case of a noun, an adjective's genders and cases, a verb's present, past and imperative. The app drills them (\"Nema ___.\" → hleba, \"mi → ___\" → pišemo) and shows the table after answering. The tags given are set, the note's other tags and everything else stay, progress included. list_words says which notes have no table yet.",
        "inputSchema": [
            "type": "object",
            "properties": ["notes": [
                "type": "array", "minItems": 1,
                "items": [
                    "type": "object",
                    "properties": [
                        "id": ["type": "string", "description": "Note id, exactly as list_words shows it."],
                        "forms": formsSchema(description: formsGuide),
                    ],
                    "required": ["id", "forms"],
                ],
            ]],
            "required": ["notes"],
        ],
    ],
    [
        "name": "list_words",
        "description": "List the notes already in Srpski with their learning status (new, learning, review, relearning), lapses and leech flag, plus how many words each level has and the existing clusters. Optionally filter by level or a search string.",
        "inputSchema": [
            "type": "object",
            "properties": [
                "level": ["type": "string", "enum": ["A1", "A2", "B1", "B2", "C1", "C2"], "description": "Only this level."],
                "topic": ["type": "string", "description": "Only this topic (\"Other\" for notes without one)."],
                "search": ["type": "string", "description": "Case-insensitive match on id, cue, answer, info or tags."],
            ],
        ],
    ],
    [
        "name": "get_mistakes",
        "description": "Get the learner's leeches (cards forgotten 4+ times) and every wrong answer from the last 7 days, as Markdown. Use it to explain mistakes or to make targeted practice notes.",
        "inputSchema": ["type": "object", "properties": [String: Any]()],
    ],
] }

func addWords(_ args: [String: Any]) -> (String, Bool) {
    guard let notes = args["notes"] as? [Any], !notes.isEmpty else {
        return ("Pass a non-empty `notes` array.", true)
    }
    var deck: DeckFile
    do {
        let data = try JSONSerialization.data(withJSONObject: ["version": 1, "notes": notes])
        deck = try DeckFile.parse(String(decoding: data, as: UTF8.self))
    } catch {
        return ("Nothing was added. \(error.localizedDescription)", true)
    }

    let known = Dictionary(
        (NotesSnapshot.load()?.entries ?? []).map { ($0.note.id, $0.note) },
        uniquingKeysWith: { first, _ in first }
    )

    // Every word needs a topic: that's where the app shows it. An update without one keeps the
    // old topic; a new word without one is sent back. Topics are matched to the existing spelling.
    let topics = knownTopics()
    var missingTopic: [String] = [], newTopics: Set<String> = []
    for i in deck.notes.indices {
        let given = deck.notes[i].topic?.trimmingCharacters(in: .whitespaces) ?? ""
        if given.isEmpty || given == TopicSummary.other {
            if let old = known[deck.notes[i].id]?.topic {
                deck.notes[i].topic = old
            } else {
                missingTopic.append(deck.notes[i].id)
            }
            continue
        }
        let topic = Topics.canonical(given, among: topics)
        deck.notes[i].topic = topic
        if !topics.contains(topic) { newTopics.insert(topic) }
    }
    guard missingTopic.isEmpty else {
        return ("Nothing was added: every word needs a topic, so the app can file it where the learner looks. Missing on: \(missingTopic.joined(separator: ", ")). Pick one per word and send them again: \(topicGuide(topics)).", true)
    }
    let badExamples = deck.notes.flatMap { note in
        (note.examples ?? []).compactMap { example in example.problem.map { "\(note.id): \(example.sr) (\($0))" } }
            + [note.forms.flatMap(WordForms.problem).map { "\(note.id) forms: \($0)" }].compactMap { $0 }
    }
    guard badExamples.isEmpty else {
        return ("Nothing was added: some examples can't be used.\n\(badExamples.joined(separator: "\n"))", true)
    }
    func canonical(_ note: DeckNote, keeping old: DeckNote? = nil) -> DeckNote {
        var n = note
        n.accept = (n.accept ?? []).isEmpty ? nil : n.accept
        n.tags = n.tags ?? []
        // Left out, the app keeps the note's examples and forms.
        if n.examples == nil { n.examples = old?.examples }
        if n.forms == nil { n.forms = old?.forms }
        return n
    }
    var added: [String] = [], updated: [String] = [], unchanged: [String] = []
    for note in deck.notes {
        if let old = known[note.id] {
            if canonical(old) == canonical(note, keeping: old) { unchanged.append(note.id) } else { updated.append(note.id) }
        } else {
            added.append(note.id)
        }
    }

    do {
        try enqueue(deck)
    } catch {
        return ("Couldn't queue the deck: \(error.localizedDescription)", true)
    }

    var text = "Queued \(deck.notes.count) notes for Srpski.\n"
    text += "New \(added.count)\(list(added))\n"
    text += "Updated \(updated.count)\(list(updated))\n"
    if !unchanged.isEmpty { text += "Unchanged \(unchanged.count)\n" }
    if !added.isEmpty { text += "The new words show up at the top of the app's Study tab, grouped by topic.\n" }
    if !newTopics.isEmpty {
        text += "New topic \(newTopics.sorted().joined(separator: ", ")) created. If an existing one fits better (\(topics.joined(separator: ", "))), send the same ids again with it.\n"
    }
    return (text + importNote(), false)
}

func deleteWords(_ args: [String: Any]) -> (String, Bool) {
    let ids = (args["ids"] as? [Any] ?? []).compactMap { $0 as? String }
    guard !ids.isEmpty else { return ("Pass a non-empty `ids` array.", true) }
    guard let snapshot = NotesSnapshot.load() else {
        return ("Srpski hasn't published its notes yet. Open the app once, then try again.", true)
    }
    let known = Dictionary(snapshot.entries.map { ($0.note.id, $0.note) }, uniquingKeysWith: { first, _ in first })
    var found: [String] = [], missing: [String] = []
    for id in ids where !found.contains(id) && !missing.contains(id) {
        if known[id] != nil { found.append(id) } else { missing.append(id) }
    }
    guard !found.isEmpty else {
        return ("Nothing was deleted: no notes with ids \(missing.joined(separator: ", ")). Check them with list_words.", true)
    }

    do {
        try enqueue(DeckFile(version: 1, notes: [], delete: found))
    } catch {
        return ("Couldn't queue the deletion: \(error.localizedDescription)", true)
    }

    var text = "Queued deletion of \(found.count) notes: "
    text += found.map { "\($0) (\(known[$0]!.cue) → \(known[$0]!.answer))" }.joined(separator: ", ") + "\n"
    if !missing.isEmpty { text += "Not found\(list(missing))\n" }
    return (text + importNote(), false)
}

func addExamples(_ args: [String: Any]) -> (String, Bool) {
    let items = (args["notes"] as? [Any] ?? []).compactMap { $0 as? [String: Any] }
    guard !items.isEmpty else { return ("Pass a non-empty `notes` array of {id, examples}.", true) }
    guard let snapshot = NotesSnapshot.load() else {
        return ("Srpski hasn't published its notes yet. Open the app once, then try again.", true)
    }
    let known = Set(snapshot.entries.map(\.note.id))
    var byID: [String: [NoteExample]] = [:], missing: [String] = [], problems: [String] = []
    for item in items {
        guard let id = item["id"] as? String, !id.isEmpty else { continue }
        let examples = (item["examples"] as? [Any] ?? []).compactMap(NoteExample.init(json:))
        problems += examples.compactMap { example in example.problem.map { "\(id): \(example.sr) (\($0))" } }
        if known.contains(id) { byID[id, default: []] += examples } else if !missing.contains(id) { missing.append(id) }
    }
    guard problems.isEmpty else {
        return ("Nothing was added: some examples can't be used.\n\(problems.joined(separator: "\n"))", true)
    }
    byID = byID.filter { !$0.value.isEmpty }
    guard !byID.isEmpty else {
        return ("Nothing was added: no notes with ids \(missing.joined(separator: ", ")). Check them with list_words.", true)
    }
    do {
        try enqueue(DeckFile(version: 1, notes: [], examples: byID))
    } catch {
        return ("Couldn't queue the examples: \(error.localizedDescription)", true)
    }
    let count = byID.values.map(\.count).reduce(0, +)
    var text = "Queued \(count) example sentences for \(byID.count) notes\(list(byID.keys.sorted())). Ones a note already has are skipped.\n"
    if !missing.isEmpty { text += "Not found\(list(missing))\n" }
    return (text + importNote(), false)
}

func addForms(_ args: [String: Any]) -> (String, Bool) {
    let items = (args["notes"] as? [Any] ?? []).compactMap { $0 as? [String: Any] }
    guard !items.isEmpty else { return ("Pass a non-empty `notes` array of {id, forms}.", true) }
    guard let snapshot = NotesSnapshot.load() else {
        return ("Srpski hasn't published its notes yet. Open the app once, then try again.", true)
    }
    let known = Set(snapshot.entries.map(\.note.id))
    var byID: [String: [String: String]] = [:], missing: [String] = [], problems: [String] = []
    for item in items {
        guard let id = item["id"] as? String, !id.isEmpty else { continue }
        let raw = item["forms"] as? [String: Any] ?? [:]
        var table: [String: String] = [:]
        for (tag, value) in raw {
            if let form = value as? String { table[tag] = form.trimmingCharacters(in: .whitespaces) } else { table[tag] = "" }
        }
        if table.isEmpty { problems.append("\(id): no forms") }
        if let problem = WordForms.problem(table) { problems.append("\(id): \(problem)") }
        if known.contains(id) { byID[id, default: [:]].merge(table) { _, new in new } } else if !missing.contains(id) { missing.append(id) }
    }
    guard problems.isEmpty else {
        return ("Nothing was added.\n\(problems.joined(separator: "\n"))", true)
    }
    guard !byID.isEmpty else {
        return ("Nothing was added: no notes with ids \(missing.joined(separator: ", ")). Check them with list_words.", true)
    }
    do {
        try enqueue(DeckFile(version: 1, notes: [], forms: byID))
    } catch {
        return ("Couldn't queue the forms: \(error.localizedDescription)", true)
    }
    let count = byID.values.map(\.count).reduce(0, +)
    var text = "Queued \(count) forms for \(byID.count) notes\(list(byID.keys.sorted())).\n"
    if !missing.isEmpty { text += "Not found\(list(missing))\n" }
    return (text + importNote(), false)
}

/// Drops a deck into the app's inbox.
func enqueue(_ deck: DeckFile) throws {
    let fm = FileManager.default
    try fm.createDirectory(at: SharedFiles.inbox, withIntermediateDirectories: true)
    let stamp = ISO8601DateFormatter.string(from: .now, timeZone: .current, formatOptions: [.withFullDate, .withTime])
    let name = "\(stamp)-\(UUID().uuidString.prefix(8)).json"
    // Write under a hidden name first so the app never reads a half-written file.
    let temp = SharedFiles.inbox.appending(path: ".\(name).tmp")
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
    try encoder.encode(deck).write(to: temp)
    try fm.moveItem(at: temp, to: SharedFiles.inbox.appending(path: name))
}

func list(_ ids: [String]) -> String { ids.isEmpty ? "" : ": " + ids.joined(separator: ", ") }

func importNote() -> String {
    NSRunningApplication.runningApplications(withBundleIdentifier: appBundleID).isEmpty
        ? "Srpski isn't running; it applies this the next time it opens."
        : "Srpski is running and applies this right away."
}

func listWords(_ args: [String: Any]) -> (String, Bool) {
    guard let snapshot = NotesSnapshot.load() else {
        return ("Srpski hasn't published its notes yet. Open the app once, then try again.", true)
    }
    let levelFilter = (args["level"] as? String).flatMap(Level.init(parsing:))?.rawValue
    let topicFilter = (args["topic"] as? String)?.trimmingCharacters(in: .whitespaces).lowercased()
    let search = (args["search"] as? String)?.lowercased() ?? ""
    let entries = snapshot.entries.filter { entry in
        let n = entry.note
        if let levelFilter, n.level != levelFilter { return false }
        if let topicFilter, (n.topic ?? "Other").lowercased() != topicFilter { return false }
        if search.isEmpty { return true }
        return ([n.id, n.cue, n.answer, n.info ?? ""] + (n.accept ?? []) + (n.tags ?? []))
            .contains { $0.lowercased().contains(search) }
    }

    let perLevel = Dictionary(grouping: snapshot.entries, by: \.note.level).mapValues(\.count)
    var clusters: [String] = []
    for entry in snapshot.entries {
        if let c = entry.note.cluster, !clusters.contains(c) { clusters.append(c) }
    }
    var text = "\(snapshot.entries.count) notes in Srpski (as of \(snapshot.exportedAt.formatted())).\n"
    text += "Levels: " + perLevel.keys.sorted { Level.rank($0) < Level.rank($1) }.map { "\($0) \(perLevel[$0]!)" }.joined(separator: ", ") + "\n"
    let perTopic = Dictionary(grouping: snapshot.entries, by: { $0.note.topic ?? "Other" }).mapValues(\.count)
    text += "Topics: " + perTopic.keys.sorted().map { "\($0) \(perTopic[$0]!)" }.joined(separator: ", ") + "\n"
    text += "Clusters: \(clusters.joined(separator: ", "))\n"
    let bare = snapshot.entries.filter { ($0.note.examples ?? []).isEmpty }.count
    text += "Without example sentences: \(bare) (add them with add_examples)\n"
    let tableless = snapshot.entries.filter { ($0.note.forms ?? [:]).isEmpty && ($0.note.kind == .word || $0.note.kind == .phrase) }.count
    text += "Without a form table: \(tableless) (fill them in with add_forms)\n\n"
    text += "Showing \(entries.count): id | cue → answer | level/topic/cluster | status\n"
    for entry in entries {
        let n = entry.note
        var status = entry.status
        if entry.lapses > 0 { status += ", \(entry.lapses) lapses" }
        if entry.leech { status += ", leech" }
        if let examples = n.examples, !examples.isEmpty { status += ", \(examples.count) examples" }
        if let forms = n.forms, !forms.isEmpty { status += ", \(forms.count) forms" }
        let group = ([n.level, n.topic ?? "Other"] + (n.cluster.map { [$0] } ?? [])).joined(separator: "/")
        text += "\(n.id) | \(n.cue) → \(n.answer) | \(group) | \(status)\n"
    }
    return (text, false)
}

func getMistakes() -> (String, Bool) {
    guard let report = try? String(contentsOf: SharedFiles.tutorReport, encoding: .utf8) else {
        return ("Srpski hasn't published a report yet. Open the app once, then try again.", true)
    }
    return (report, false)
}

// MARK: - JSON-RPC over stdio

func send(_ message: [String: Any]) {
    var object = message
    object["jsonrpc"] = "2.0"
    guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes]) else { return }
    FileHandle.standardOutput.write(data + Data("\n".utf8))
}

while let line = readLine() {
    guard let message = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any],
          let id = message["id"] // Notifications (no id) need no reply.
    else { continue }
    let params = message["params"] as? [String: Any] ?? [:]

    switch message["method"] as? String ?? "" {
    case "initialize":
        send(["id": id, "result": [
            "protocolVersion": params["protocolVersion"] as? String ?? "2025-06-18",
            "capabilities": ["tools": [String: Any]()],
            "serverInfo": ["name": "srpski", "version": "1.0"],
            "instructions": "Srpski is the user's Serbian (Latin script) flashcard app; the user is a Russian speaker. Use add_words to add vocabulary the user is learning, delete_words to remove notes the user asks to remove, add_examples to give notes example sentences, add_forms to fill in their form tables, list_words to see what's already there, get_mistakes to see what they get wrong.",
        ]])
    case "ping":
        send(["id": id, "result": [String: Any]()])
    case "tools/list":
        send(["id": id, "result": ["tools": tools()]])
    case "tools/call":
        let args = params["arguments"] as? [String: Any] ?? [:]
        let (text, isError): (String, Bool) = switch params["name"] as? String {
        case "add_words": addWords(args)
        case "delete_words": deleteWords(args)
        case "add_examples": addExamples(args)
        case "add_forms": addForms(args)
        case "list_words": listWords(args)
        case "get_mistakes": getMistakes()
        default: ("Unknown tool \(params["name"] ?? "")", true)
        }
        send(["id": id, "result": ["content": [["type": "text", "text": text]], "isError": isError]])
    default:
        send(["id": id, "error": ["code": -32601, "message": "Method not found"]])
    }
}
