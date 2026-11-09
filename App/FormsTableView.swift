import SwiftUI
import SrbCore

/// How a form is made (`CaseRules.rule`): what's asked on the first line, the ending for this
/// kind of word on the second.
struct CaseRuleBox: View {
    let rule: String
    var compact = false

    var body: some View {
        let lines = rule.split(separator: "\n", maxSplits: 1).map(String.init)
        VStack(spacing: 2) {
            Text(lines[0]).foregroundStyle(.secondary)
            if lines.count > 1 { Text(lines[1]).fontWeight(.medium) }
        }
        .font(.callout)
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, 12)
        .padding(.vertical, compact ? 6 : 8)
        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

/// After a missed form: what the answer was instead ("sobom is the instrumental, sg.") and,
/// unless the card showed it already, how the asked form is made.
struct FormMistakeNote: View {
    let note: Note
    let tag: String
    /// What was typed or picked.
    let given: String
    var showsRule = true
    var compact = false

    var body: some View {
        let forms = note.forms
        let mistake = CaseRules.mistake(given, tag: tag, forms: forms, answer: note.answer)
        let rule = showsRule ? CaseRules.rule(tag: tag, forms: forms, answer: note.answer) : nil
        if mistake != nil || rule != nil {
            VStack(spacing: 6) {
                if let mistake {
                    Text(mistake)
                        .font(.callout.weight(.medium))
                        .multilineTextAlignment(.center)
                }
                if let rule { CaseRuleBox(rule: rule, compact: compact) }
            }
        }
    }
}

/// A word's form table: cases by number for a noun, by gender for an adjective, persons and
/// tenses for a verb. The form just asked is in the accent color; on the word's page, forms
/// already answered right in a review have a check.
struct FormsTableView: View {
    let note: Note
    var highlight: String?
    var compact = false
    var known: Set<String> = []

    var body: some View {
        let forms = note.forms
        VStack(spacing: compact ? 10 : 14) {
            ForEach(Array(sections(forms).enumerated()), id: \.offset) { _, section in
                grid(section, forms: forms)
            }
        }
        .font(compact ? .callout : .body)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Layout

    private struct Row {
        let label: String
        /// The tag in each column.
        let tags: [String]

        init(_ label: String, _ tags: [String]) {
            self.label = label
            self.tags = tags
        }
    }

    private struct Section {
        var title: String?
        var columns: [String]
        var rows: [Row]
    }

    private func sections(_ forms: [String: String]) -> [Section] {
        let caseRows: [(String, String)] = [
            ("nom", String(localized: "nom.")), ("gen", String(localized: "gen.")), ("dat", String(localized: "dat.")),
            ("acc", String(localized: "acc.")), ("voc", String(localized: "voc.")), ("ins", String(localized: "ins.")),
            ("loc", String(localized: "loc.")),
        ]
        let singularPlural = [String(localized: "sg."), String(localized: "pl.")]
        let (masculine, feminine, neuter) = (String(localized: "m."), String(localized: "f."), String(localized: "n."))
        func keep(_ section: Section) -> Section? {
            let rows = section.rows.filter { row in row.tags.contains { forms[$0] != nil || $0 == "nom.sg" } }
            return rows.isEmpty ? nil : Section(title: section.title, columns: section.columns, rows: rows)
        }
        switch WordForms.part(of: forms) {
        case .noun:
            return [keep(Section(title: nil, columns: singularPlural, rows: caseRows.map { Row($0.1, ["\($0.0).sg", "\($0.0).pl"]) }))].compactMap { $0 }
        case .adjective:
            let cases = Section(title: nil, columns: [masculine, feminine, neuter], rows: caseRows.filter { $0.0 != "voc" }.map { row in
                Row(row.1, ["m", "f", "n"].map { "\($0).\(row.0)" })
            })
            let degrees = Section(title: nil, columns: [""], rows: [Row(String(localized: "comp."), ["comp"]), Row(String(localized: "superl."), ["sup"])])
            return [keep(cases), keep(degrees)].compactMap { $0 }
        case .verb:
            let persons = [("1", String(localized: "I / we")), ("2", String(localized: "you / you (pl.)")), ("3", String(localized: "he / they"))]
            let present = Section(title: String(localized: "Present"), columns: singularPlural, rows: persons.map { Row($0.1, ["pres.\($0.0)sg", "pres.\($0.0)pl"]) })
            let past = Section(title: String(localized: "Past"), columns: singularPlural, rows: [
                Row(masculine, ["past.m.sg", "past.m.pl"]), Row(feminine, ["past.f.sg", "past.f.pl"]), Row(neuter, ["past.n.sg", "past.n.pl"]),
            ])
            let imperative = Section(title: String(localized: "Imperative"), columns: [""], rows: [
                Row(String(localized: "you"), ["imp.2sg"]), Row(String(localized: "we"), ["imp.1pl"]), Row(String(localized: "you (pl.)"), ["imp.2pl"]),
            ])
            return [keep(present), keep(past), keep(imperative)].compactMap { $0 }
        }
    }

    private func grid(_ section: Section, forms: [String: String]) -> some View {
        VStack(spacing: 6) {
            if let title = section.title {
                Text(title).font((compact ? Font.callout : .body).weight(.semibold)).foregroundStyle(.secondary)
            }
            Grid(alignment: .leading, horizontalSpacing: compact ? 12 : 18, verticalSpacing: 4) {
                if section.columns.count > 1 {
                    GridRow {
                        Color.clear.frame(width: 1, height: 1)
                        ForEach(section.columns, id: \.self) { Text($0).foregroundStyle(.tertiary) }
                    }
                }
                ForEach(Array(section.rows.enumerated()), id: \.offset) { _, row in
                    GridRow {
                        Text(row.label).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
                        ForEach(Array(row.tags.enumerated()), id: \.offset) { _, tag in
                            cell(tag, forms: forms)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.04)))
        }
    }

    @ViewBuilder
    private func cell(_ tag: String, forms: [String: String]) -> some View {
        if let value = forms[tag] ?? (tag == "nom.sg" ? note.answer : nil) {
            HStack(spacing: 4) {
                Text(value)
                    .fontWeight(tag == highlight ? .semibold : .regular)
                    .foregroundStyle(tag == highlight ? Color.accentColor : Color.primary)
                if known.contains(tag) {
                    Image(systemName: "checkmark")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.green)
                        .accessibilityLabel("known")
                }
            }
        } else {
            Text(verbatim: "—").foregroundStyle(.quaternary)
        }
    }
}

/// Word actions for the Mac detail menu. The ••• is the menu's own label, not an item in it.
struct NoteActionsMenuContent: View {
    let note: Note
    let onEdit: () -> Void
    let onDelete: () -> Void
    @Environment(AppModel.self) private var model

    var body: some View {
        Section("Learning status") {
            ForEach(NoteProgress.allCases) { progress in
                Button {
                    model.engine.setProgress(progress, for: [note])
                    model.cache.invalidate()
                    model.didChange()
                } label: {
                    if note.progress == progress {
                        Label(progress.title, systemImage: "checkmark")
                    } else {
                        Text(progress.title)
                    }
                }
            }
        }
        Button("Edit word", systemImage: "pencil", action: onEdit)
        Button(role: .destructive, action: onDelete) {
            Label("Delete word", systemImage: "trash")
        }
    }
}

/// One word in full: translation, note, form table and sentences. Opened from the Words tab.
struct NoteDetailView: View {
    let note: Note
    let onEdit: () -> Void
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var showingDeleteConfirmation = false
    @State private var saveError: String?

    /// The forms as the word's next level: open once it's known, and how many are known.
    private var formsLevel: FormsLevel? { model.engine.formsLevel(of: note) }

    static func caption(_ level: FormsLevel) -> String {
        guard level.isOpen else { return String(localized: "Reviews start asking these once you know the word.") }
        return String(localized: "Asked in reviews · \(level.known.count) of \(level.total) known")
    }

    var body: some View {
        Group {
            desktopLayout
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    NoteActionsMenuContent(
                        note: note,
                        onEdit: onEdit,
                        onDelete: { showingDeleteConfirmation = true }
                    )
                } label: {
                    Image(systemName: "ellipsis")
                }
                .accessibilityLabel("Word actions")
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { dismiss() }
            }
        }
        .confirmationDialog("Delete “\(note.answer)”?", isPresented: $showingDeleteConfirmation, titleVisibility: .visible) {
            Button("Delete word", systemImage: "trash", role: .destructive) { deleteWord() }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This also deletes its learning progress and answer history.")
        }
        .alert("Couldn't save changes", isPresented: Binding(
            get: { saveError != nil }, set: { if !$0 { saveError = nil } }
        )) {
            Button("OK") { saveError = nil }
        } message: {
            Text(saveError ?? String(localized: "Please try again."))
        }
        .frame(minWidth: 420, minHeight: 420)
    }

    private var desktopLayout: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(note.answer).font(.largeTitle.weight(.semibold))
                    Text(note.cue).font(.title3).foregroundStyle(.secondary)
                }
                if let info = note.info, !info.isEmpty {
                    NoteInfoView(info: info, compact: false)
                }
                if note.forms.isEmpty {
                    Text("No form table yet.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    if let level = formsLevel {
                        Text(Self.caption(level)).font(.callout).foregroundStyle(.secondary)
                    }
                    FormsTableView(note: note, known: formsLevel?.known ?? [])
                }
                if !note.examples.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(Array(note.examples.enumerated()), id: \.offset) { _, example in
                            VStack(alignment: .leading, spacing: 2) {
                                if let cloze = example.cloze {
                                    ClozePrompt(sentence: cloze, revealed: true, compact: true, alignment: .leading)
                                } else {
                                    Text(example.plain)
                                        .multilineTextAlignment(.leading)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .fixedSize(horizontal: false, vertical: true)
                                    Text(example.ru)
                                        .foregroundStyle(.secondary)
                                        .multilineTextAlignment(.leading)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: 520, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
    }

    private func setStatus(_ progress: NoteProgress) {
        model.engine.setProgress(progress, for: [note])
        model.cache.invalidate()
        model.didChange()
    }

    private func deleteWord() {
        do {
            try model.deleteWord(note)
            dismiss()
        } catch {
            saveError = error.localizedDescription
        }
    }
}

private struct NoteEditorSheetContent: View {
    let note: Note

    var body: some View {
        NavigationStack {
            NoteEditorView(note: note)
        }
    }
}

extension View {
    func noteEditorSheet(
        item: Binding<Note?>,
        onDismiss: @escaping () -> Void = {}
    ) -> some View {
        sheet(item: item, onDismiss: onDismiss) { note in
            NoteEditorSheetContent(note: note)
        }
    }
}

struct NoteEditorView: View {
    let note: Note
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var answer: String
    @State private var cue: String
    @State private var progress: NoteProgress
    @State private var accept: String
    @State private var topic: String
    @State private var level: String
    @State private var info: String
    @State private var saveError: String?

    init(note: Note) {
        self.note = note
        _answer = State(initialValue: note.answer)
        _cue = State(initialValue: note.cue)
        _progress = State(initialValue: note.progress)
        _accept = State(initialValue: note.accept.joined(separator: "\n"))
        _topic = State(initialValue: note.topic ?? "")
        _level = State(initialValue: note.level)
        _info = State(initialValue: note.info ?? "")
    }

    var body: some View {
        Group {
            Form {
                Section("Word") {
                    TextField("Serbian", text: $answer)
                        .autocorrectionDisabled()
                    TextField("Russian", text: $cue)
                    TextField("Topic", text: $topic)
                    Picker("Level", selection: $level) {
                        ForEach(Level.allCases, id: \.rawValue) { level in
                            Text(level.rawValue).tag(level.rawValue)
                        }
                    }
                }

                Section {
                    TextEditor(text: $accept)
                        .scrollContentBackground(.hidden)
                        .frame(minHeight: 60)
                } header: {
                    Text("Accepted spellings")
                } footer: {
                    Text("One alternative spelling per line.")
                }

                Section("Note") {
                    TextEditor(text: $info)
                        .scrollContentBackground(.hidden)
                        .frame(minHeight: 80)
                }
            }
            // The default (columns) style puts section titles in the label column and squeezes
            // the labels against the edge.
            .formStyle(.grouped)
            .frame(width: 460)
            .fixedSize(horizontal: false, vertical: true)
        }
        .navigationTitle("Edit word")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save", action: save)
                    .disabled(answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                              cue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .alert("Couldn't save changes", isPresented: Binding(
            get: { saveError != nil }, set: { if !$0 { saveError = nil } }
        )) {
            Button("OK") { saveError = nil }
        } message: {
            Text(saveError ?? String(localized: "Please try again."))
        }
    }

    private func save() {
        let oldAnswer = note.answer
        let newAnswer = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        let newCue = cue.trimmingCharacters(in: .whitespacesAndNewlines)
        let variants = accept
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let newTopic = topic.trimmingCharacters(in: .whitespacesAndNewlines)
        let newInfo = info.trimmingCharacters(in: .whitespacesAndNewlines)
        var forms = note.forms
        if forms["nom.sg"] == oldAnswer { forms["nom.sg"] = newAnswer }

        let context = model.container.mainContext
        do {
            try context.transaction {
                note.answer = newAnswer
                note.cue = newCue
                note.accept = variants
                note.topic = newTopic.isEmpty ? nil : newTopic
                note.level = level
                note.info = newInfo.isEmpty ? nil : newInfo
                note.forms = forms
            }
            if progress != note.progress {
                model.engine.setProgress(progress, for: [note])
            }
            model.cache.invalidate()
            model.didChange()
            dismiss()
        } catch {
            context.rollback()
            saveError = error.localizedDescription
        }
    }
}
