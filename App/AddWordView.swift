import SwiftUI
import SrbCore

/// A word of your own, typed in: Words → +. It's studied like any other, without a forms table
/// (a chat can fill that in later).
struct AddWordView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var answer = ""
    @State private var cue = ""
    @State private var kind = NoteKind.word
    @State private var topic = ""
    @State private var level = Level.a1.rawValue
    @State private var info = ""
    @State private var saveError: String?
    /// After "Save and add another": the word just added, shown under the fields.
    @State private var added: String?
    @FocusState private var focused: Field?

    private enum Field { case answer, cue }

    /// The kinds you'd type in yourself; form drills come from the forms table.
    private static let kinds: [NoteKind] = [.word, .phrase, .sentence]
    /// Grammar holds the form drills, Sentences follows from the kind.
    private static let topics = Topics.suggested.filter { $0 != "Grammar" && $0 != "Sentences" }

    var body: some View {
        Form {
            Section {
                TextField("Serbian", text: $answer)
                    .autocorrectionDisabled()
                    .focused($focused, equals: .answer)
                    .submitLabel(.next)
                    .onSubmit { focused = .cue }
                TextField("Russian", text: $cue)
                    .focused($focused, equals: .cue)
                    .submitLabel(.done)
            } footer: {
                if let added {
                    Label("Added “\(added)”", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .transition(.opacity)
                } else {
                    Text("Serbian in Latin letters, with č ć š ž đ.")
                }
            }

            Section {
                Picker("Kind", selection: $kind) {
                    ForEach(Self.kinds, id: \.self) { Text(Self.title(of: $0)).tag($0) }
                }
                .pickerStyle(.segmented)
                if kind != .sentence {
                    Picker("Topic", selection: $topic) {
                        Text("None").tag("")
                        ForEach(Self.topics, id: \.self) { Text(Topics.displayName($0)).tag($0) }
                    }
                }
                Picker("Level", selection: $level) {
                    ForEach(Level.allCases, id: \.rawValue) { Text($0.rawValue).tag($0.rawValue) }
                }
            }

            Section("Note") {
                TextField("Shown after you answer, e.g. its gender or a pitfall", text: $info, axis: .vertical)
                    .lineLimit(2...5)
            }
        }
        .formStyle(.grouped)
        .frame(width: 440)
        .fixedSize(horizontal: false, vertical: true)
        .navigationTitle("New word")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Add") { if save() { dismiss() } }
                    .disabled(!canSave)
            }
            ToolbarItem(placement: .primaryAction) {
                Button("Add another") {
                    let word = answer.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard save() else { return }
                    withAnimation(.smooth) { added = word }
                    answer = ""
                    cue = ""
                    info = ""
                    focused = .answer
                }
                .disabled(!canSave)
            }
        }
        .onAppear {
            level = model.newLevel ?? Level.a1.rawValue
            focused = .answer
        }
        .alert("Couldn't add the word", isPresented: Binding(get: { saveError != nil }, set: { if !$0 { saveError = nil } })) {
            Button("OK") {}
        } message: {
            Text(saveError ?? "")
        }
    }

    private var canSave: Bool {
        !answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !cue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private static func title(of kind: NoteKind) -> String {
        switch kind {
        case .word: String(localized: "Word")
        case .phrase: String(localized: "Phrase")
        case .sentence: String(localized: "Sentence")
        case .form: String(localized: "Form")
        }
    }

    /// False when it didn't go in (the alert says why).
    private func save() -> Bool {
        let serbian = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        let russian = cue.trimmingCharacters(in: .whitespacesAndNewlines)
        let note = info.trimmingCharacters(in: .whitespacesAndNewlines)
        let engine = model.engine
        let notes = engine.allNotes()
        if notes.contains(where: { $0.answer.caseInsensitiveCompare(serbian) == .orderedSame && $0.cue == russian }) {
            saveError = String(localized: "“\(serbian)” is already in your words.")
            return false
        }
        let ids = Set(notes.map(\.noteID))
        let base = Self.slug(serbian)
        var id = base
        var suffix = 2
        while ids.contains(id) {
            id = "\(base)-\(suffix)"
            suffix += 1
        }
        let deckNote = DeckNote(
            id: id, kind: kind, cue: russian, answer: serbian, info: note.isEmpty ? nil : note,
            level: level, topic: kind == .sentence ? "Sentences" : (topic.isEmpty ? nil : topic), tags: []
        )
        do {
            _ = try DeckImporter.merge(DeckFile(notes: [deckNote]), into: model.container.mainContext)
            model.cache.invalidate()
            model.didChange()
            return true
        } catch {
            saveError = error.localizedDescription
            return false
        }
    }

    /// "laku noć" → "laku-noc", as the built-in words and the chat name them.
    static func slug(_ text: String) -> String {
        let latin = text.lowercased()
            .replacingOccurrences(of: "đ", with: "dj")
            .applyingTransform(.stripDiacritics, reverse: false) ?? text
        let parts = latin.split { !($0.isASCII && ($0.isLetter || $0.isNumber)) }
        let slug = parts.joined(separator: "-")
        return slug.isEmpty ? "word" : String(slug.prefix(40))
    }
}
