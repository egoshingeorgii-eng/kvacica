import SwiftUI
import SrbCore

/// What a topic page shows: the next lesson's words, then the rest of the topic.
struct TopicPreview {
    struct Word: Identifiable {
        let id: String
        let serbian: String
        let russian: String
        let progress: NoteProgress
    }

    /// nil: any topic.
    let topic: String?
    /// The words the next lesson starts with, in lesson order.
    let next: [Word]
    /// Not started, for a later lesson (only for a real topic).
    let later: [Word]
    /// Already started: learning first, then learned.
    let started: [Word]
    /// Words not started beyond this lesson; for "Any topic" only the count is shown.
    let laterCount: Int
    /// Built-in words of this topic the deck doesn't have yet: the New words list offers them.
    let libraryCount: Int

    var title: String { topic.map(Topics.displayName) ?? String(localized: "Any topic") }

    @MainActor
    init(topic: String?, engine: StudyEngine, lessonSize: Int) {
        func word(_ note: Note) -> Word {
            Word(id: note.noteID, serbian: note.answer, russian: note.cue, progress: note.progress)
        }
        self.topic = topic
        let nextNotes = engine.lessonWords(topic: topic, level: nil, size: lessonSize)
        next = nextNotes.map(word)
        let nextIDs = Set(nextNotes.map(\.noteID))
        let notes = engine.allNotes()
            .filter { topic == nil || ($0.topic ?? TopicSummary.other) == topic }
            .sorted { (Level.rank($0.level), $0.order) < (Level.rank($1.level), $1.order) }
        let notStarted = notes.filter { $0.progress == .notStarted && !nextIDs.contains($0.noteID) }
        laterCount = notStarted.count
        libraryCount = topic.map { topic in StarterLibrary.missing(in: engine).filter { $0.topic == topic }.count } ?? 0
        if topic == nil {
            later = []
            started = []
        } else {
            later = notStarted.map(word)
            started = notes
                .filter { $0.progress != .notStarted }
                .sorted { ($0.progress == .learning ? 0 : 1) < ($1.progress == .learning ? 0 : 1) }
                .map(word)
        }
    }
}

/// A topic before its lesson starts: the words you're about to learn, with translations.
/// Enter starts the lesson, Esc goes back.
struct TopicPreviewView: View {
    let preview: TopicPreview
    let session: ReviewSession
    let compact: Bool
    /// Space below the list; the list scrolls right to the window's bottom edge.
    var inset: CGFloat = 0

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 12 : 18) {
            Button(action: session.closeTopic) {
                HStack(spacing: 6) {
                    KeyCap(key: "esc")
                    if Platform.isTouch { Image(systemName: "chevron.left") }
                    Text("All topics")
                }
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)

            HStack(alignment: .center, spacing: 12) {
                Image(systemName: preview.topic.map(TopicIcon.name(for:)) ?? "square.grid.2x2")
                    .font(compact ? .title2 : .largeTitle)
                    .foregroundStyle(Color.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(preview.title)
                        .font(compact ? .title2.weight(.semibold) : .largeTitle.weight(.semibold))
                    Text(subtitle)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 12)
                if !compact { startButton }
            }
            if compact { startButton.frame(maxWidth: .infinity, alignment: .leading) }

            ScrollView {
                VStack(alignment: .leading, spacing: compact ? 16 : 24) {
                    if preview.libraryCount > 0 {
                        Button { session.showNewWords(topic: preview.topic) } label: {
                            Label("Choose more words for this topic (\(preview.libraryCount))", systemImage: "plus.circle")
                        }
                        .buttonStyle(.borderless)
                    }
                    if preview.next.isEmpty {
                        Text("Every word here is started. Review brings them back when they're due.")
                            .foregroundStyle(.secondary)
                    } else {
                        section(String(localized: "This lesson"), preview.next, style: .next)
                    }
                    if !preview.later.isEmpty {
                        section(String(localized: "Later lessons"), preview.later, style: .later)
                    } else if preview.topic == nil, preview.laterCount > 0 {
                        Text("\(preview.laterCount) more new words in other lessons.")
                            .foregroundStyle(.secondary)
                    }
                    if !preview.started.isEmpty {
                        section(String(localized: "Already started"), preview.started, style: .started)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .contentMargins(.bottom, inset, for: .scrollContent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var subtitle: String {
        let learned = preview.started.filter { $0.progress == .learned }.count
        var parts = [String(localized: "\(preview.next.count) new words in this lesson")]
        if preview.laterCount > 0 { parts.append(String(localized: "\(preview.laterCount) later")) }
        if learned > 0 { parts.append(String(localized: "\(learned) learned")) }
        return parts.joined(separator: " · ")
    }

    private var startButton: some View {
        Button { session.startLesson(topic: preview.topic) } label: {
            Text("Start lesson").frame(minWidth: 120)
        }
        .prominentButton()
        .controlSize(.large)
        .keyboardShortcut(.defaultAction)
        .disabled(preview.next.isEmpty)
    }

    private enum Style { case next, later, started }

    private func section(_ title: String, _ words: [TopicPreview.Word], style: Style) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.title3.weight(.semibold))
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: compact ? 300 : 260), spacing: 10, alignment: .top)],
                alignment: .leading,
                spacing: 8
            ) {
                ForEach(words) { word in
                    WordRow(word: word, style: style, compact: compact)
                }
            }
        }
    }

    private struct WordRow: View {
        let word: TopicPreview.Word
        let style: Style
        let compact: Bool

        var body: some View {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(word.serbian)
                        .font(style == .next ? (compact ? .body.weight(.semibold) : .title3.weight(.semibold)) : .body.weight(.medium))
                    Text(word.russian)
                        .foregroundStyle(.secondary)
                }
                .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                if style == .started {
                    Text(word.progress == .learned ? "Learned" : "Learning")
                        .font(.callout)
                        .foregroundStyle(word.progress == .learned ? Color.green : Color.orange)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, style == .next ? 10 : 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(style == .next ? 0.05 : 0.025)))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(style == .next ? 0.09 : 0.05)))
            .opacity(style == .later ? 0.8 : 1)
        }
    }
}
