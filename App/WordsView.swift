import SwiftData
import SwiftUI
import SrbCore

/// Every note with its progress, filterable by status and searchable.
struct WordsView: View {
    /// iPhone: false while another tab is showing, so the list is not rebuilt on every answer.
    var live = true
    @Environment(AppModel.self) private var model
    @AppStorage(Pref.lessonSize) private var lessonSize = 10
    @State private var filter: NoteProgress?
    @State private var search = ""
    @State private var selection = Set<PersistentIdentifier>()
    /// Empty until a column heading is clicked. The table then fills this in.
    @State private var sortOrder = [KeyPathComparator<WordRow>]()
    /// Notes waiting for confirmation before their progress is wiped.
    @State private var pendingReset: [Note] = []
    /// A word waiting for confirmation before deletion.
    @State private var pendingDelete: Note?
    /// The word opened in full: its form table and sentences.
    @State private var detail: Note?
    /// The word currently being edited from the list.
    @State private var editing: Note?
    /// Edits requested from the detail sheet wait until that sheet finishes dismissing.
    @State private var pendingDetailEdit: Note?
    /// Return to the detail sheet after saving or cancelling an edit opened from it.
    @State private var returnToDetailAfterEdit: Note?
    /// iPhone: the new-word sheet (the Mac's is in the window's toolbar).
    @State private var adding = false
    /// Every word as a row, made once per change to the deck (kept by the Mac's window across tabs).
    @State var built = BuiltRows()

    var body: some View {
        shown
            .confirmationDialog(
                pendingReset.count == 1 ? "Reset progress for “\(pendingReset[0].answer)”?" : "Reset progress for \(pendingReset.count) words?",
                isPresented: Binding(get: { !pendingReset.isEmpty }, set: { if !$0 { pendingReset = [] } })
            ) {
                Button("Reset", role: .destructive) {
                    apply(.notStarted, to: pendingReset)
                    pendingReset = []
                }
            } message: {
                Text("They come back as new words. Your answer history is kept.")
            }
            .confirmationDialog(
                "Delete “\(pendingDelete?.answer ?? String(localized: "word"))”?",
                isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
                titleVisibility: .visible
            ) {
                Button("Delete word", systemImage: "trash", role: .destructive) {
                    if let pendingDelete { delete(pendingDelete) }
                    pendingDelete = nil
                }
            } message: {
                Text("This also deletes its learning progress and answer history.")
            }
            .sheet(item: $detail, onDismiss: presentPendingDetailEdit) { note in
                NoteDetailView(note: note) {
                    editFromDetail(note)
                }
            }
            .noteEditorSheet(
                item: $editing,
                onDismiss: restoreDetailAfterEdit
            )
    }

    @ViewBuilder
    private var shown: some View {
        content
    }

    @ViewBuilder
    private var content: some View {
        table
    }

    @ViewBuilder
    private var table: some View {
        let _ = Perf.count("words")
        // Every note as plain values, once per change to the deck: table cells then read them
        // instead of walking SwiftData relationships on every scroll, and a search letter, a
        // click on a row or a column heading only filters and sorts them (it built every row
        // again, 25-50 ms each time).
        let _ = rebuildIfChanged()
        let notes = built.notes
        let counts = built.counts
        let query = searchQuery
        let rows = Perf.measure("words: table") {
            built.rows
                .filter { (filter == nil || $0.progress == filter) && matches($0, query) }
                .sorted(using: sortOrder)
        }

        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                FilterTile(title: String(localized: "All words"), count: built.rows.count, isSelected: filter == nil) { filter = nil }
                ForEach(NoteProgress.allCases) { progress in
                    FilterTile(title: progress.title, count: counts[progress] ?? 0, isSelected: filter == progress) {
                        filter = filter == progress ? nil : progress
                    }
                }
            }
            HStack {
                if let notStarted = counts[.notStarted], notStarted > 0 {
                    let lessons = Int((Double(notStarted) / Double(lessonSize)).rounded(.up))
                    Text(String(localized: "\(notStarted) words to go") + ": " + String(localized: "about \(lessons) lessons of \(lessonSize)."))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if !selection.isEmpty {
                    let selected = selection.compactMap { notes[$0] }
                    Menu("Mark \(selected.count) as") { statusButtons(for: selected) }
                        .fixedSize()
                }
                TextField("Search", text: $search)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 200)
            }

            Table(rows, selection: $selection, sortOrder: $sortOrder) {
                TableColumn("Serbian", sortUsing: WordSort.serbian) { Text($0.answer).fontWeight(.medium) }
                TableColumn("Russian", sortUsing: WordSort.russian) { Text($0.cue) }
                TableColumn("Topic", sortUsing: WordSort.topic) { row in
                    Label(Topics.displayName(row.topic), systemImage: row.topicIcon).foregroundStyle(.secondary)
                }
                .width(min: 90, ideal: 120)
                TableColumn("Level", sortUsing: WordSort.level) { Text($0.level).foregroundStyle(.secondary) }
                    .width(min: 50, ideal: 70)
                TableColumn("Status", sortUsing: WordSort.status) { StatusLabel(row: $0) }
                    .width(min: 110, ideal: 130)
                TableColumn("Next review", sortUsing: WordSort.nextReview) { row in
                    Text(row.nextReview).foregroundStyle(.secondary).monospacedDigit()
                }
                .width(min: 80, ideal: 100)
                TableColumn("Lapses", sortUsing: WordSort.lapses) { row in
                    Text(verbatim: row.lapses > 0 ? "\(row.lapses)" : "").monospacedDigit()
                }
                .width(50)
            }
            .contextMenu(forSelectionType: PersistentIdentifier.self) { ids in
                let selected = ids.compactMap { notes[$0] }
                if !selected.isEmpty {
                    if selected.count == 1 {
                        Button("Show forms and sentences") { detail = selected[0] }
                        Button("Edit word", systemImage: "pencil") { editing = selected[0] }
                    }
                    Menu(selected.count == 1 ? "Mark as" : "Mark \(selected.count) words as") {
                        statusButtons(for: selected)
                    }
                    if selected.count == 1 {
                        Button("Delete word", systemImage: "trash", role: .destructive) { pendingDelete = selected[0] }
                    }
                }
            } primaryAction: { ids in
                // Double-click: the word in full.
                detail = ids.lazy.compactMap { notes[$0] }.first
            }
        }
        .padding(20)
    }

    @ViewBuilder
    private func statusButtons(for notes: [Note]) -> some View {
        Button("Learned: I know it") { apply(.learned, to: notes) }
        Button("Learning: study it now") { apply(.learning, to: notes) }
        Divider()
        Button("Not started: reset progress") {
            let started = notes.filter { $0.progress != .notStarted }
            if started.isEmpty { return }
            pendingReset = started
        }
    }

    private func apply(_ progress: NoteProgress, to notes: [Note]) {
        model.engine.setProgress(progress, for: notes)
        model.cache.invalidate()
        model.didChange()
    }

    private func delete(_ note: Note) {
        do {
            try model.deleteWord(note)
        } catch {
            model.alert = AppAlert(title: String(localized: "Couldn't delete word"), message: error.localizedDescription)
        }
    }

    private func editFromDetail(_ note: Note) {
        pendingDetailEdit = note
        returnToDetailAfterEdit = note
        detail = nil
    }

    private func presentPendingDetailEdit() {
        guard let note = pendingDetailEdit else { return }
        pendingDetailEdit = nil
        editing = note
    }

    private func restoreDetailAfterEdit() {
        guard let note = returnToDetailAfterEdit else { return }
        returnToDetailAfterEdit = nil
        detail = note
    }

    private func rebuildIfChanged() {
        guard built.revision != model.revision else { return }
        Perf.measure("words: rows") { built.rebuild(from: model.engine.allNotes(), revision: model.revision, alphabetical: false) }
    }

    /// The search as rows are matched against it, worked out once per draw rather than per row.
    private var searchQuery: String {
        search.trimmingCharacters(in: .whitespaces).lowercased()
    }

    private func matches(_ row: WordRow, _ query: String) -> Bool {
        query.isEmpty || row.searchText.contains(query)
    }
}

/// A note flattened into plain values for one table row.
struct WordRow: Identifiable {
    let id: PersistentIdentifier
    let answer: String
    let cue: String
    let topic: String
    let topicIcon: String
    let level: String
    let progress: NoteProgress
    let isLeech: Bool
    let nextReview: String
    /// Soonest due date. Words with no review sort after every real date.
    let nextDueSort: Date
    /// Not started, then learning, then learned.
    let progressRank: Int
    let lapses: Int
    /// Everything search looks at, lowercased.
    let searchText: String

    init(_ note: Note) {
        id = note.persistentModelID
        answer = note.answer
        cue = note.cue
        topic = note.topic ?? TopicSummary.other
        topicIcon = TopicIcon.name(for: note.topic ?? "")
        level = note.level
        progress = note.progress
        isLeech = note.isLeech
        lapses = note.lapses
        nextDueSort = note.nextDue ?? .distantFuture
        switch note.progress {
        case .notStarted: progressRank = 0
        case .learning: progressRank = 1
        case .learned: progressRank = 2
        }
        if let due = note.nextDue {
            nextReview = due <= .now ? String(localized: "now") : due.formatted(.relative(presentation: .named))
        } else {
            nextReview = "—"
        }
        searchText = ([note.answer, note.cue, note.level, note.topic ?? "", note.info ?? ""] + note.accept + note.tags)
            .joined(separator: "\n").lowercased()
    }
}

/// One comparator per column. Text uses the user's sort order, so č sits with c.
private enum WordSort {
    static let serbian = KeyPathComparator(\WordRow.answer, comparator: String.StandardComparator.localizedStandard)
    static let russian = KeyPathComparator(\WordRow.cue, comparator: String.StandardComparator.localizedStandard)
    static let topic = KeyPathComparator(\WordRow.topic, comparator: String.StandardComparator.localizedStandard)
    static let level = KeyPathComparator(\WordRow.level, comparator: String.StandardComparator.localizedStandard)
    static let status = KeyPathComparator(\WordRow.progressRank)
    static let nextReview = KeyPathComparator(\WordRow.nextDueSort)
    static let lapses = KeyPathComparator(\WordRow.lapses)
}

private struct FilterTile: View {
    let title: String
    let count: Int
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.callout).foregroundStyle(.secondary)
                Text("\(count)").font(.title2.weight(.semibold)).monospacedDigit()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 8).fill(isSelected ? Color.accentColor.opacity(0.15) : Color.primary.opacity(0.05)))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(isSelected ? Color.accentColor : .clear, lineWidth: 1.5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// The rows, kept between draws: typing in the search field built every row again from its note
/// (a relative date each) and sorted them all, letter by letter. The iPhone lists them A to Z;
/// the Mac's table keeps the deck's order until a column is clicked.
final class BuiltRows {
    private(set) var revision = -1
    private(set) var rows: [WordRow] = []
    private(set) var notes: [PersistentIdentifier: Note] = [:]
    private(set) var counts: [NoteProgress: Int] = [:]

    func rebuild(from notes: [Note], revision: Int, alphabetical: Bool) {
        self.revision = revision
        self.notes = Dictionary(notes.map { ($0.persistentModelID, $0) }, uniquingKeysWith: { first, _ in first })
        rows = notes.map(WordRow.init)
        if alphabetical {
            rows.sort { $0.answer.localizedStandardCompare($1.answer) == .orderedAscending }
        }
        counts = Dictionary(grouping: rows, by: \.progress).mapValues(\.count)
    }
}

private struct StatusLabel: View {
    let row: WordRow

    var body: some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(row.progress.title)
            if row.isLeech {
                Image(systemName: "ladybug.fill").foregroundStyle(.red).help("Leech: forgotten 4+ times")
            }
        }
    }

    private var color: Color {
        switch row.progress {
        case .notStarted: .secondary.opacity(0.4)
        case .learning: .orange
        case .learned: .green
        }
    }
}
