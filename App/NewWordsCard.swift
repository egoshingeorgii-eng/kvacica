import SwiftUI
import SrbCore

/// Words that came in from a chat, under the topic each one went to.
struct NewWordsGroup: Identifiable, Equatable {
    struct Word: Identifiable, Equatable {
        let id: String
        let serbian: String
        let russian: String
    }

    let topic: String
    let words: [Word]
    var id: String { topic }

    /// Groups `ids` by topic, topics in the order their first word came in. Deleted notes drop out.
    static func groups(ids: [String], notes: [Note]) -> [NewWordsGroup] {
        guard !ids.isEmpty else { return [] }
        let byID = Dictionary(notes.map { ($0.noteID, $0) }, uniquingKeysWith: { first, _ in first })
        var order: [String] = []
        var words: [String: [Word]] = [:]
        for id in ids {
            guard let note = byID[id] else { continue }
            let topic = note.topic ?? TopicSummary.other
            if words[topic] == nil { order.append(topic) }
            words[topic, default: []].append(Word(id: id, serbian: note.answer, russian: note.cue))
        }
        return order.map { NewWordsGroup(topic: $0, words: words[$0]!) }
    }
}

/// Top of the Study home screen after words arrive from a chat: what came in, where it went,
/// and a lesson of those words. A topic opens its page; "Got it" hides the card until the next words arrive.
struct NewWordsCard: View {
    let groups: [NewWordsGroup]
    let compact: Bool
    /// Headless snapshots can't draw inside a ScrollView, so they lay every row out instead.
    var scrolls = true
    var focused = false
    /// Nil when there's nothing left to learn, or that lesson is already open.
    var learnTitle: String?
    /// Enter starts the lesson when nothing is due and no other lesson is open.
    var isDefaultAction = false
    let openTopic: (String) -> Void
    var learn: () -> Void = {}
    let dismiss: () -> Void

    @State private var rowHeight: CGFloat = 0
    @ScaledMetric(relativeTo: .body) private var estimatedRowHeight: CGFloat = 51

    /// Topic rows kept on screen. The rest scroll inside the card, not the page.
    private let visibleRows = 3
    private let rowSpacing: CGFloat = 6

    private var count: Int { groups.map(\.words.count).reduce(0, +) }
    private var title: String { String(localized: "\(count) new words from your chat") }
    private var measuredRow: CGFloat { rowHeight > 0 ? rowHeight : estimatedRowHeight }
    private var viewportHeight: CGFloat {
        measuredRow * CGFloat(visibleRows) + rowSpacing * CGFloat(visibleRows - 1)
    }

    var body: some View {
        if compact {
            HStack(spacing: 8) {
                Image(systemName: "tray.and.arrow.down.fill").foregroundStyle(Color.secondary)
                Text(title).lineLimit(1)
                Spacer(minLength: 0)
                if learnTitle != nil {
                    learnButton
                }
                Button("Got it", action: dismiss).buttonStyle(.borderless)
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.05)))
            .focusRing(focused, cornerRadius: 10)
        } else {
            // Same look as the Review and Lesson cards it sits next to.
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    Label("New words", systemImage: "tray.and.arrow.down")
                        .font(.title2.weight(.semibold))
                    Spacer()
                    Button("Got it", action: dismiss)
                }
                Text("\(count) from your chat, added here:")
                    .font(.title3)
                topicList
                    .padding(.top, 4)
                if learnTitle != nil {
                    Spacer(minLength: 8)
                    learnButton
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: 14).fill(Color.primary.opacity(0.04)))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.primary.opacity(0.08)))
            .focusRing(focused, cornerRadius: 14)
        }
    }

    @ViewBuilder
    private var learnButton: some View {
        if compact {
            Button(learnTitle ?? String(localized: "Choose"), action: learn)
                .buttonStyle(.borderless)
                .keyboardShortcut(isDefaultAction ? .defaultAction : nil)
        } else {
            Button(action: learn) {
                Text(learnTitle ?? String(localized: "Learn these")).frame(minWidth: 120)
            }
            .prominentButton()
            .controlSize(.large)
            .keyboardShortcut(isDefaultAction ? .defaultAction : nil)
        }
    }

    private var topicRows: some View {
        VStack(spacing: rowSpacing) {
            ForEach(groups) { group in
                GroupRow(group: group) { openTopic(group.topic) }
                    .background {
                        GeometryReader { proxy in
                            Color.clear.preference(key: RowHeightKey.self, value: proxy.size.height)
                        }
                    }
            }
        }
        .onPreferenceChange(RowHeightKey.self) { height in
            guard height > 0, abs(height - rowHeight) > 0.5 else { return }
            rowHeight = height
        }
    }

    /// Three rows set the height. More topics scroll in here, so the card doesn't stretch the page.
    @ViewBuilder
    private var topicList: some View {
        if scrolls, groups.count > visibleRows {
            ScrollView {
                topicRows
            }
            .scrollBounceBehavior(.basedOnSize, axes: .vertical)
            .frame(height: viewportHeight)
        } else {
            topicRows
        }
    }

    private struct GroupRow: View {
        let group: NewWordsGroup
        let open: () -> Void
        private let shown = 3

        var body: some View {
            Button(action: open) {
                HStack(spacing: 10) {
                    Image(systemName: TopicIcon.name(for: group.topic))
                        .foregroundStyle(Color.secondary)
                        .frame(width: 22)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(Topics.displayName(group.topic)).fontWeight(.medium)
                        Text(words)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.right")
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(RoundedRectangle(cornerRadius: 9).fill(Color.primary.opacity(0.04)))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }

        /// "kafa, čaj, sok +2"; the translations are on the topic page.
        private var words: String {
            let list = group.words.prefix(shown).map(\.serbian).joined(separator: ", ")
            return group.words.count > shown ? "\(list) +\(group.words.count - shown)" : list
        }
    }
}

private struct RowHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}
