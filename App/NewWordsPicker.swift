import SwiftUI
import SrbCore

/// One word the learner can tick before a lesson of exactly the ones they picked.
struct PickableWord: Identifiable {
    let id: String
    let serbian: String
    let russian: String
    let topic: String
    let level: String
    /// Built-in and not in the deck yet: it comes in when a lesson of it starts.
    let fromLibrary: Bool
}

/// What the New words list offers: the built-in words the deck doesn't have, easiest level
/// first, by topic, to add. With `ids` (words just added from a chat): those, to learn.
struct NewWordsList {
    struct Section: Identifiable {
        let topic: String
        let words: [PickableWord]
        var id: String { topic }
    }

    let words: [PickableWord]
    /// The levels among them, easiest first. The filter shows once there are two.
    let levels: [String]

    /// `ids`: only those (the chat batch, no built-in words). `topic`: only that topic's.
    @MainActor
    init(engine: StudyEngine, only ids: [String]?, topic: String?) {
        let allowed = ids.map(Set.init)
        // Words already in the deck come in only for a chat's batch: the plain list adds words,
        // and adding doesn't start them (a lesson takes them later).
        var words = allowed == nil ? [] : engine.unstartedNewestFirst().compactMap { note -> PickableWord? in
            let name = note.topic ?? TopicSummary.other
            if let allowed, !allowed.contains(note.noteID) { return nil }
            if let topic, name != topic { return nil }
            return PickableWord(id: note.noteID, serbian: note.answer, russian: note.cue, topic: name, level: note.level, fromLibrary: false)
        }
        if allowed == nil {
            let library = StarterLibrary.missing(in: engine)
                .filter { topic == nil || ($0.topic ?? TopicSummary.other) == topic }
                .enumerated()
                .sorted { (Level.rank($0.element.level), $0.offset) < (Level.rank($1.element.level), $1.offset) }
            words += library.map { _, note in
                PickableWord(id: note.id, serbian: note.answer, russian: note.cue,
                             topic: note.topic ?? TopicSummary.other, level: note.level, fromLibrary: true)
            }
        }
        self.words = words
        let present = Set(words.map(\.level))
        levels = Level.allCases.map(\.rawValue).filter(present.contains)
    }

    /// The words of `level` (nil: every level), by topic: the suggested topics in their order,
    /// then the others by name, "Other" last.
    func sections(level: String?) -> [Section] {
        let shown = level.map { level in words.filter { $0.level == level } } ?? words
        let grouped = Dictionary(grouping: shown, by: \.topic)
        let place = { (topic: String) in
            (topic == TopicSummary.other ? 1 : 0, Topics.suggested.firstIndex(of: topic) ?? Topics.suggested.count, topic)
        }
        return grouped.keys.sorted { place($0) < place($1) }.map { Section(topic: $0, words: grouped[$0]!) }
    }
}

/// The level the New words list shows, kept between visits; empty: every level.
enum NewWordsLevel {
    static let key = "newWordsLevel"
}

/// The list of words not started yet, the built-in ones not in the deck included, by topic.
/// Nothing is picked until the learner says so.
struct NewWordsPicker: View {
    let session: ReviewSession
    let compact: Bool
    var inset: CGFloat = 0
    @Environment(AppModel.self) private var model
    @AppStorage(NewWordsLevel.key) private var levelChoice = ""
    @State private var list: NewWordsList?
    @State private var selected: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 12 : 18) {
            Button(action: session.closeNewWords) {
                HStack(spacing: 6) {
                    KeyCap(key: "esc")
                    if Platform.isTouch { Image(systemName: "chevron.left") }
                    if session.newWordPickerTopic == nil { Text("Home") } else { Text("Back") }
                }
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)

            HStack(alignment: .center, spacing: 12) {
                Image(systemName: session.newWordPickerTopic.map(TopicIcon.name(for:)) ?? "tray.and.arrow.down")
                    .font(compact ? .title2 : .largeTitle)
                    .foregroundStyle(Color.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(compact ? .title2.weight(.semibold) : .largeTitle.weight(.semibold))
                    Text(subtitle)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 12)
                if !compact { learnButton }
            }
            if compact { learnButton.frame(maxWidth: .infinity, alignment: .leading) }

            HStack(spacing: 16) {
                if let list, list.levels.count > 1 {
                    Picker("Level", selection: $levelChoice) {
                        Text("All levels").tag("")
                        ForEach(list.levels, id: \.self) { Text($0).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                }
                Button(allSelected ? "Clear" : "Select all") {
                    if allSelected { selected.subtract(shown.map(\.id)) } else { selected.formUnion(shown.map(\.id)) }
                }
                .buttonStyle(.borderless)
                Text("\(selected.count) selected")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .font(.callout)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6, pinnedViews: []) {
                    ForEach(sections) { section in
                        if showsTopics {
                            sectionHeader(section)
                        }
                        ForEach(section.words) { word in
                            row(word)
                        }
                    }
                    if list != nil, sections.isEmpty {
                        Text("No new words at this level.")
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .contentMargins(.bottom, inset, for: .scrollContent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear(perform: load)
    }

    private var title: String {
        if let topic = session.newWordPickerTopic { return Topics.displayName(topic) }
        return session.newWordPickerIDs == nil ? String(localized: "New words") : String(localized: "Words from chat")
    }

    /// The plain list adds built-in words to the deck; a chat's batch is already there and is learned.
    private var adding: Bool { session.newWordPickerIDs == nil }

    private var subtitle: String {
        adding
            ? String(localized: "Built-in words you don't have yet. Pick the ones to add; lessons take them later.")
            : String(localized: "Pick which ones to learn.")
    }

    /// The remembered level, if the list has words of it.
    private var level: String? { list?.levels.contains(levelChoice) == true ? levelChoice : nil }
    private var sections: [NewWordsList.Section] { list?.sections(level: level) ?? [] }
    private var shown: [PickableWord] { sections.flatMap(\.words) }
    /// One topic's list has no topic headers.
    private var showsTopics: Bool { session.newWordPickerTopic == nil }

    private var allSelected: Bool { !shown.isEmpty && shown.allSatisfy { selected.contains($0.id) } }

    private func sectionHeader(_ section: NewWordsList.Section) -> some View {
        let all = section.words.allSatisfy { selected.contains($0.id) }
        return HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(Topics.displayName(section.topic))
                .font(.title3.weight(.semibold))
            Text("\(section.words.count)")
                .foregroundStyle(.secondary)
                .monospacedDigit()
            Spacer(minLength: 8)
            Button(all ? "Clear" : "Select all") {
                let ids = section.words.map(\.id)
                if all { selected.subtract(ids) } else { selected.formUnion(ids) }
            }
            .buttonStyle(.borderless)
            .font(.callout)
        }
        .padding(.top, 12)
        .padding(.bottom, 2)
    }

    private var learnButton: some View {
        Button(action: learn) {
            Text(learnTitle).frame(minWidth: 120)
        }
        .prominentButton()
        .controlSize(.large)
        .keyboardShortcut(.defaultAction)
        .disabled(selected.isEmpty)
    }

    private var learnTitle: String {
        switch (adding, selected.count) {
        case (true, 0): String(localized: "Add")
        case (true, let count): String(localized: "Add \(count) words")
        case (false, 0): String(localized: "Learn")
        case (false, let count): String(localized: "Learn \(count) words")
        }
    }

    /// In the order the list shows them, whatever level is on.
    private func learn() {
        guard let list else { return }
        let ids = list.sections(level: nil).flatMap(\.words).map(\.id).filter { selected.contains($0) }
        if adding { session.addChosen(ids) } else { session.startChosen(ids) }
    }

    private func load() {
        list = NewWordsList(engine: model.engine, only: session.newWordPickerIDs, topic: session.newWordPickerTopic)
        selected = []
    }

    private func row(_ word: PickableWord) -> some View {
        let on = selected.contains(word.id)
        return Button {
            if on { selected.remove(word.id) } else { selected.insert(word.id) }
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: on ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(on ? Color.accentColor : Color.secondary)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text(word.serbian)
                        .font(.body.weight(.semibold))
                    Text(word.russian)
                        .foregroundStyle(.secondary)
                }
                .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Text(word.level)
                    .font(.callout)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(on ? 0.06 : 0.03)))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(on ? 0.12 : 0.05)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
