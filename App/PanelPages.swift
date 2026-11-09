import AppKit
import SwiftData
import SwiftUI
import SrbCore

/// What the floating panel shows: Study (the palette and its cards), or one of the pages its
/// commands open in place, in the iPhone's card look. Esc or Back returns to Study.
enum PanelPage: Hashable {
    case study, words, progress, settings, chat
}

extension EnvironmentValues {
    /// Opens a page in the floating panel; nil outside it.
    @Entry var openPanelPage: ((PanelPage) -> Void)?
}

// MARK: - Frame

/// A page's frame: Back on the left, the page's own line (a title, or the search field) in the
/// middle, an extra on the right; the content under a hairline. Same height as the palette's
/// search line, so nothing jumps between them.
struct PanelPageFrame<Center: View, Trailing: View, Content: View>: View {
    let back: () -> Void
    /// Esc. Back unless the page has something to clear first.
    var escape: (() -> Void)?
    @ViewBuilder let center: Center
    @ViewBuilder let trailing: Trailing
    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                Button(action: back) {
                    HStack(spacing: 6) {
                        KeyCap(key: "esc")
                        Text("Back")
                    }
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                center
                    .frame(maxWidth: .infinity)
                trailing
                    .foregroundStyle(.secondary)
            }
            .font(.callout)
            .padding(.horizontal, 18)
            .frame(height: 52)
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .background {
            Button("", action: escape ?? back)
                .keyboardShortcut(.cancelAction)
                .opacity(0)
                .accessibilityHidden(true)
        }
    }
}

/// A page's title in the middle of its top line.
private struct PanelTitle: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(.primary)
    }
}

/// The white card the iPhone puts everything on.
private struct PanelCardBackground: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(Color(nsColor: .textBackgroundColor))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.primary.opacity(0.07)))
    }
}

// MARK: - Words from chat

/// The iPhone's Words from chat page, in the panel: make a link, copy it, add it to the chat.
struct PanelChatPage: View {
    let back: () -> Void

    var body: some View {
        PanelPageFrame(back: back) {
            PanelTitle(title: String(localized: "Words from chat"))
        } trailing: {
            EmptyView()
        } content: {
            ChatConnectorPage()
                .scrollContentBackground(.hidden)
        }
    }
}

// MARK: - Words

/// Every word, as on the iPhone: one card of rows with the topic's icon, the word, its meaning
/// and where it stands. Typing searches like the palette; ↑ ↓ and Return open a word over the
/// list (its forms, sentences and the ••• menu). ⌘N adds a word, in a sheet over the panel.
struct PanelWordsPage: View {
    let back: () -> Void
    @Binding var adding: Bool
    @Environment(AppModel.self) private var model
    @State private var built = BuiltRows()
    @State private var folded = FoldedRows()
    @State private var search = ""
    @State private var filter: NoteProgress?
    @State private var picked: PersistentIdentifier?
    @State private var scrollTarget: PersistentIdentifier?
    @State private var opened: Note?
    @State private var editing: Note?
    @State private var editAfterClosing: Note?
    @FocusState private var searching: Bool

    /// Each row's text folded for search, once per change to the deck.
    private final class FoldedRows {
        var revision = -1
        var text: [PersistentIdentifier: (primary: [String], secondary: [String])] = [:]
    }

    var body: some View {
        if built.revision != model.revision {
            Perf.measure("panel words: rows") {
                built.rebuild(from: model.engine.allNotes(), revision: model.revision, alphabetical: true)
            }
        }
        let rows = shownRows
        let selected = picked.flatMap { id in rows.contains { $0.id == id } ? id : nil } ?? rows.first?.id
        return PanelPageFrame(back: back, escape: escape) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 15))
                    .foregroundStyle(.tertiary)
                TextField("Search words", text: $search)
                    .textFieldStyle(.plain)
                    .font(.system(size: 16))
                    .focused($searching)
                    .onSubmit { open(selected) }
                    .onKeyPress(.downArrow) { move(1, in: rows, from: selected); return .handled }
                    .onKeyPress(.upArrow) { move(-1, in: rows, from: selected); return .handled }
            }
        } trailing: {
            Text(verbatim: "\(rows.count)")
                .monospacedDigit()
        } content: {
            VStack(spacing: 0) {
                filters
                    .padding(.horizontal, 18)
                    .padding(.vertical, 10)
                ScrollViewReader { proxy in
                    ScrollView {
                        if rows.isEmpty {
                            Text(search.isEmpty ? "No words here yet" : "Nothing called “\(search)”")
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, minHeight: 80)
                        } else {
                            LazyVStack(spacing: 0) {
                                ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                                    if index > 0 { Divider().padding(.leading, 62) }
                                    PanelWordRow(row: row, selected: row.id == selected,
                                                 onPick: { if picked != row.id { picked = row.id } },
                                                 action: { open(row.id) })
                                        .id(row.id)
                                }
                            }
                            .padding(4)
                            .background(PanelCardBackground())
                            .padding([.horizontal, .bottom], 14)
                        }
                    }
                    .onChange(of: scrollTarget) {
                        if let scrollTarget { withAnimation(.snappy) { proxy.scrollTo(scrollTarget) } }
                    }
                }
                Divider()
                PaletteFooter {
                    PaletteFooterHint(keys: ["↑", "↓"], label: String(localized: "Choose"))
                    PaletteFooterHint(keys: ["↩"], label: String(localized: "Open"))
                    Button { adding = true } label: {
                        PaletteFooterHint(keys: ["⌘N"], label: String(localized: "Add word"))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .onAppear { searching = true }
        .onChange(of: search) {
            picked = nil
            PointerGate.reset()
        }
        .onChange(of: filter) {
            picked = nil
            PointerGate.reset()
        }
        .sheet(item: $opened, onDismiss: {
            searching = true
            if let note = editAfterClosing {
                editAfterClosing = nil
                editing = note
            }
        }) { note in
            NoteDetailView(note: note) {
                editAfterClosing = note
                opened = nil
            }
            .environment(model)
            .background {
                Button("") { opened = nil }
                    .keyboardShortcut(.cancelAction)
                    .opacity(0)
            }
        }
        .noteEditorSheet(item: $editing) { searching = true }
        .sheet(isPresented: $adding, onDismiss: { searching = true }) {
            NavigationStack { AddWordView() }
                .environment(model)
        }
    }

    /// All, New, Learning, Learned, with how many: the iPhone's filter, as chips.
    private var filters: some View {
        HStack(spacing: 6) {
            chip(String(localized: "All"), count: built.rows.count, value: nil)
            chip(String(localized: "New"), count: built.counts[.notStarted] ?? 0, value: .notStarted)
            chip(String(localized: "Learning"), count: built.counts[.learning] ?? 0, value: .learning)
            chip(String(localized: "Learned"), count: built.counts[.learned] ?? 0, value: .learned)
            Spacer(minLength: 0)
        }
    }

    private func chip(_ title: String, count: Int, value: NoteProgress?) -> some View {
        let on = filter == value
        return Button { filter = value } label: {
            HStack(spacing: 5) {
                Text(title)
                Text(verbatim: "\(count)")
                    .monospacedDigit()
                    .foregroundStyle(on ? Color.primary.opacity(0.6) : Color.secondary.opacity(0.7))
            }
            .font(.callout.weight(on ? .semibold : .regular))
            .foregroundStyle(on ? Color.primary : Color.secondary)
            .padding(.horizontal, 12)
            .frame(height: 28)
            .background(Capsule().fill(Color.primary.opacity(on ? 0.09 : 0.04)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    /// A to Z without a search; best match first with one.
    private var shownRows: [WordRow] {
        let rows = built.rows.filter { filter == nil || $0.progress == filter }
        let needle = PaletteSearch.fold(search.trimmingCharacters(in: .whitespaces))
        guard !needle.isEmpty else { return rows }
        if folded.revision != built.revision {
            folded.text = Dictionary(uniqueKeysWithValues: built.rows.map { row in
                (row.id, ([row.answer, row.cue].map(PaletteSearch.fold), [PaletteSearch.fold(row.searchText)]))
            })
            folded.revision = built.revision
        }
        let tokens = needle.split(separator: " ").map(String.init)
        return rows.compactMap { row -> (WordRow, Int)? in
            guard let text = folded.text[row.id],
                  let score = PaletteSearch.score(tokens, primary: text.primary, secondary: text.secondary) else { return nil }
            return (row, score)
        }
        .sorted { ($0.1, $0.0.answer.count) < ($1.1, $1.0.answer.count) }
        .map(\.0)
    }

    private func move(_ step: Int, in rows: [WordRow], from selected: PersistentIdentifier?) {
        guard !rows.isEmpty else { return }
        let current = rows.firstIndex { $0.id == selected } ?? 0
        picked = rows[min(max(current + step, 0), rows.count - 1)].id
        scrollTarget = picked
    }

    private func open(_ id: PersistentIdentifier?) {
        guard let id, let note = built.notes[id] else { return }
        opened = note
    }

    /// Esc clears the search first, then goes back.
    private func escape() {
        if search.isEmpty { back() } else { search = "" }
    }
}

/// A word as the iPhone lists it: the topic's icon on its tint, the word, its meaning, the topic,
/// and where it stands with when it's next.
private struct PanelWordRow: View {
    let row: WordRow
    let selected: Bool
    let onPick: () -> Void
    let action: () -> Void

    var body: some View {
        let tint = Rings.color(for: row.topic)
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: row.topicIcon)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(tint)
                    .frame(width: 34, height: 34)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(tint.opacity(0.12)))
                VStack(alignment: .leading, spacing: 1) {
                    Text(row.answer)
                        .font(.system(size: 15, weight: .semibold))
                    Text(row.cue)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .lineLimit(1)
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 2) {
                    PanelStatus(progress: row.progress, isLeech: row.isLeech)
                    if row.progress != .notStarted {
                        Text(row.nextReview)
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .monospacedDigit()
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(selected ? 0.06 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onPointerHover { if $0 { onPick() } }
    }
}

/// New, learning or learned, in its color; a word you keep missing says so.
private struct PanelStatus: View {
    let progress: NoteProgress
    let isLeech: Bool

    var body: some View {
        let (title, color): (String, Color) = switch progress {
        case .notStarted: (String(localized: "New"), .secondary)
        case .learning: (isLeech ? String(localized: "Tricky") : String(localized: "Learning"), isLeech ? .red : Rings.accent)
        case .learned: (String(localized: "Learned"), .green)
        }
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(color)
    }
}

// MARK: - Progress

/// The iPhone's Progress cards: streak with the week, recall, words, study time, the hardest
/// words and the last answers.
struct PanelProgressPage: View {
    let back: () -> Void
    @Environment(AppModel.self) private var model
    @AppStorage(Pref.retention) private var retention = 0.9
    @State private var data: Dashboard?
    @State private var copied = false

    var body: some View {
        PanelPageFrame(back: back) {
            PanelTitle(title: String(localized: "Progress"))
        } trailing: {
            // Keeps the title in the middle: as wide as Back.
            Color.clear.frame(width: 62, height: 1)
        } content: {
            if let data {
                ScrollView {
                    VStack(spacing: 14) {
                        HStack(alignment: .top, spacing: 14) {
                            streakCard(data)
                            recallCard(data)
                        }
                        wordsCard(data)
                        timeCard(data)
                        hardWordsCard(data)
                        recentCard(data.recent)
                    }
                    .padding(14)
                }
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear(perform: load)
        .onChange(of: model.revision, load)
    }

    private func load() {
        data = Perf.measure("panel progress") { model.engine.dashboard(targetRetention: retention) }
    }

    private func streakCard(_ data: Dashboard) -> some View {
        let week = PanelWeekStrip.days().reduce(0) { $0 + (data.answersPerDay[$1] ?? 0) }
        let streak = data.currentStreak
        return PanelBackedCard(String(localized: "Streak"), note: week > 0 ? String(localized: "\(week) answers this week") : nil) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 10) {
                    Image(systemName: streak > 0 ? "flame.fill" : "flame")
                        .font(.system(size: 26))
                        .foregroundStyle(streak > 0 ? AnyShapeStyle(Rings.accent) : AnyShapeStyle(.tertiary))
                    VStack(alignment: .leading, spacing: 1) {
                        Text(streak > 0 ? "\(streak) days" : "Start a streak")
                            .font(.system(.title2, design: .rounded).weight(.bold))
                        Text(streakDetail(data))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
                PanelWeekStrip(answersPerDay: data.answersPerDay)
            }
        }
    }

    private func streakDetail(_ data: Dashboard) -> String {
        let longest = data.longestStreak
        if data.currentStreak == 0 {
            return longest > 0 ? String(localized: "Your best was \(longest) days.") : String(localized: "Answer one card today.")
        }
        return longest > data.currentStreak ? String(localized: "Longest \(longest) days") : String(localized: "Your longest yet")
    }

    private func recallCard(_ data: Dashboard) -> some View {
        // Until learned words come back, first-try accuracy, so the card is never empty.
        let value = data.recall30 ?? data.firstTry30
        return PanelBackedCard(String(localized: "Recall")) {
            if let value {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(percent(value))
                            .font(.system(size: 30, weight: .bold, design: .rounded))
                            .monospacedDigit()
                        Text(data.recall30 != nil ? "remembered" : "right the first time")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    Gauge(value: value) {
                        Text("Recall")
                    } currentValueLabel: {
                        Image(systemName: "brain.head.profile")
                            .foregroundStyle(.green)
                    }
                    .gaugeStyle(.accessoryCircularCapacity)
                    .tint(.green)
                }
                .frame(maxHeight: .infinity)
            } else {
                PanelEmptyRow(symbol: "brain.head.profile", tint: .pink, title: String(localized: "Comes with practice"),
                              detail: String(localized: "Answer a few cards and see how much sticks."))
            }
        }
    }

    private func wordsCard(_ data: Dashboard) -> some View {
        let total = data.learned + data.learning + data.notStarted
        let fraction = total > 0 ? Double(data.learned) / Double(total) : 0
        return PanelBackedCard(String(localized: "Words")) {
            if data.learned == 0, data.learning == 0 {
                PanelEmptyRow(symbol: "book.closed.fill", tint: Rings.accent, title: String(localized: "No words learned yet"),
                              detail: String(localized: "Start a lesson and your first words land here."))
            } else {
                VStack(spacing: 14) {
                    HStack(spacing: 16) {
                        ZStack {
                            Circle().strokeBorder(Rings.accent.opacity(0.15), lineWidth: 8)
                            Circle()
                                .inset(by: 4)
                                .trim(from: 0, to: fraction)
                                .stroke(Rings.accent, style: StrokeStyle(lineWidth: 8, lineCap: .round))
                                .rotationEffect(.degrees(-90))
                            Text(percent(fraction))
                                .font(.system(.callout, design: .rounded).weight(.semibold))
                                .monospacedDigit()
                        }
                        .frame(width: 58, height: 58)
                        VStack(alignment: .leading, spacing: 1) {
                            HStack(alignment: .firstTextBaseline, spacing: 5) {
                                Text(verbatim: "\(data.learned)")
                                    .font(.system(size: 30, weight: .bold, design: .rounded))
                                    .monospacedDigit()
                                Text("of \(total)")
                                    .font(.title3)
                                    .foregroundStyle(.secondary)
                            }
                            Text(String(localized: "unit: \(total) words learned", table: "Units"))
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                        stat(String(localized: "Learning now"), value: "\(data.learning)")
                        Divider().frame(height: 36)
                        stat(String(localized: "New this week"), value: data.startedThisWeek > 0 ? "+\(data.startedThisWeek)" : "0")
                    }
                    // One level is the same bar as the ring; the bars only show once there are more.
                    if data.levels.count > 1 {
                        Divider()
                        VStack(spacing: 10) {
                            ForEach(data.levels) { level in
                                VStack(alignment: .leading, spacing: 5) {
                                    LabeledContent(level.level, value: "\(level.learned) / \(level.total)")
                                    ProgressView(value: level.total > 0 ? Double(level.learned) / Double(level.total) : 0)
                                        .tint(Rings.accent)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private func timeCard(_ data: Dashboard) -> some View {
        PanelBackedCard(String(localized: "Study time")) {
            if data.studyTimeTotal < 60 {
                PanelEmptyRow(symbol: "timer", tint: .teal, title: String(localized: "No study time yet"),
                              detail: String(localized: "Five minutes a day adds up quickly."))
            } else {
                HStack(alignment: .top, spacing: 0) {
                    stat(String(localized: "Today"), value: short(data.studyTimeToday))
                    Divider().frame(height: 44)
                    stat(String(localized: "7 days"), value: short(data.studyTimeWeek))
                    Divider().frame(height: 44)
                    stat(String(localized: "All time"), value: short(data.studyTimeTotal))
                }
            }
        }
    }

    /// A figure over its name, one of a row.
    private func stat(_ title: String, value: String) -> some View {
        VStack(spacing: 3) {
            Text(value)
                .font(.system(.title2, design: .rounded).weight(.bold))
                .monospacedDigit()
            Text(title)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private func hardWordsCard(_ data: Dashboard) -> some View {
        PanelBackedCard(String(localized: "Hardest words"), padding: data.hardWords.isEmpty ? 14 : 0) {
            if data.hardWords.isEmpty {
                PanelEmptyRow(symbol: "hand.thumbsup.fill", tint: .green, title: String(localized: "No mistakes yet"),
                              detail: String(localized: "Words you get wrong show up here."))
            } else {
                PanelRows(data.hardWords) { word in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(word.answer).fontWeight(.medium)
                            Text(word.cue).font(.callout).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                        Text("\(word.mistakes)×")
                            .font(.callout.weight(.semibold))
                            .foregroundStyle(.red)
                            .monospacedDigit()
                    }
                }
            }
        } trailing: {
            if !data.hardWords.isEmpty {
                // Hard words and this week's wrong answers, ready to paste into a chat.
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(model.engine.tutorReport(), forType: .string)
                    copied = true
                    Task {
                        try? await Task.sleep(for: .seconds(2))
                        copied = false
                    }
                } label: {
                    // Both labels always there, one faded out, so the button keeps its width.
                    ZStack(alignment: .trailing) {
                        Label("Copy for tutor", systemImage: "doc.on.doc")
                            .opacity(copied ? 0 : 1)
                        Label("Copied", systemImage: "checkmark")
                            .opacity(copied ? 1 : 0)
                    }
                    .font(.callout.weight(.semibold))
                    .animation(.easeInOut(duration: 0.2), value: copied)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func recentCard(_ answers: [Dashboard.RecentAnswer]) -> some View {
        PanelBackedCard(String(localized: "Recent answers"), padding: answers.isEmpty ? 14 : 0) {
            if answers.isEmpty {
                PanelEmptyRow(symbol: "clock.arrow.circlepath", tint: .indigo, title: String(localized: "No answers yet"),
                              detail: String(localized: "Your last answers show up here."))
            } else {
                PanelRows(answers) { answer in
                    HStack(spacing: 12) {
                        Circle().fill(answer.grade.color).frame(width: 8, height: 8)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(answer.serbian).fontWeight(.medium)
                            if answer.grade == .again, !answer.typed.isEmpty {
                                Text(answer.typed)
                                    .strikethrough(color: .red.opacity(0.6))
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                            } else {
                                Text(answer.russian).font(.callout).foregroundStyle(.secondary)
                            }
                        }
                        .lineLimit(1)
                        Spacer()
                        VStack(alignment: .trailing, spacing: 2) {
                            Text(answer.grade.title)
                                .font(.callout.weight(.semibold))
                                .foregroundStyle(answer.grade.color)
                            Text(answer.at.formatted(.relative(presentation: .named)))
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
            }
        }
    }

    private func percent(_ value: Double) -> String { value.formatted(.percent.precision(.fractionLength(0))) }

    private func short(_ seconds: TimeInterval) -> String {
        let minutes = Int(seconds / 60)
        let style = Duration.UnitsFormatStyle(allowedUnits: [.hours, .minutes], width: .narrow)
        if minutes < 1 { return seconds > 0 ? "<" + Duration.seconds(60).formatted(style) : Duration.seconds(0).formatted(style) }
        return Duration.seconds(minutes * 60).formatted(style)
    }
}

/// The iPhone's backed card: the title (and a control beside it) on a tinted backing, the
/// content on a white card inset into it, an optional note under it.
private struct PanelBackedCard<Content: View, Trailing: View>: View {
    let title: String
    var note: String?
    var padding: CGFloat
    @ViewBuilder let content: Content
    @ViewBuilder let trailing: Trailing

    init(_ title: String, note: String? = nil, padding: CGFloat = 14,
         @ViewBuilder content: () -> Content, @ViewBuilder trailing: () -> Trailing = { EmptyView() }) {
        self.title = title
        self.note = note
        self.padding = padding
        self.content = content()
        self.trailing = trailing()
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(title)
                    .font(.callout.weight(.semibold))
                Spacer()
                trailing
            }
            .padding(.horizontal, 12)
            .frame(minHeight: 34)
            content
                .padding(padding)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            if let note {
                Text(note)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
            }
        }
        .padding(4)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.primary.opacity(0.05)))
    }
}

/// Rows in a card, divided by inset hairlines.
private struct PanelRows<Item: Identifiable, Row: View>: View {
    let items: [Item]
    @ViewBuilder let row: (Item) -> Row

    init(_ items: [Item], @ViewBuilder row: @escaping (Item) -> Row) {
        self.items = items
        self.row = row
    }

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                if index > 0 { Divider().padding(.leading, 14) }
                row(item)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
            }
        }
    }
}

/// A card with nothing in it yet: a symbol on a tinted tile and what to do about it.
private struct PanelEmptyRow: View {
    let symbol: String
    let tint: Color
    let title: String
    let detail: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 40, height: 40)
                .background(tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body.weight(.semibold))
                Text(detail).font(.callout).foregroundStyle(.secondary)
            }
        }
    }
}

/// The last seven days, today on the right: a lit flame for each day you studied.
private struct PanelWeekStrip: View {
    let answersPerDay: [Date: Int]

    static func days(now: Date = .now) -> [Date] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        return (-6...0).map { calendar.date(byAdding: .day, value: $0, to: today)! }
    }

    var body: some View {
        let calendar = Calendar.current
        HStack(spacing: 0) {
            ForEach(Self.days(), id: \.self) { day in
                let studied = (answersPerDay[day] ?? 0) > 0
                let today = calendar.isDateInToday(day)
                VStack(spacing: 5) {
                    Text(day.formatted(.dateTime.weekday(.narrow)))
                        .font(.caption.weight(today ? .bold : .regular))
                        .foregroundStyle(today ? .primary : .secondary)
                    ZStack {
                        Circle()
                            .fill(studied ? Rings.accent.opacity(0.15) : Color.primary.opacity(0.06))
                        if studied {
                            Image(systemName: "flame.fill")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(Rings.accent)
                        } else if today {
                            Circle().strokeBorder(.secondary, style: StrokeStyle(lineWidth: 1.5, dash: [3, 3]))
                        }
                    }
                    .frame(width: 28, height: 28)
                }
                .frame(maxWidth: .infinity)
            }
        }
    }
}

// MARK: - Settings

/// Settings one part at a time, like Raycast's: the parts down the left, the picked one's
/// settings on the right. ↑ ↓ move between parts. ⌘, comes here too; the Settings window, with
/// them all on one page, is for the app without the panel.
struct PanelSettingsPage: View {
    let back: () -> Void
    @State private var category: SettingsCategory = .study
    @FocusState private var listFocused: Bool

    /// Room for the longest part, "Window & shortcuts", whole: at 200 it ended in "…".
    private static let listWidth: CGFloat = 236

    var body: some View {
        PanelPageFrame(back: back) {
            PanelTitle(title: String(localized: "Settings"))
        } trailing: {
            Color.clear.frame(width: 62, height: 1)
        } content: {
            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(SettingsCategory.allCases) { part in
                        PaletteRow(symbol: part.symbol, title: part.title,
                                   look: part == category ? .selected : .normal) {
                            category = part
                        }
                    }
                    Spacer(minLength: 0)
                }
                .padding(8)
                .frame(width: Self.listWidth)
                .focusable()
                .focusEffectDisabled()
                .focused($listFocused)
                .onKeyPress(.downArrow) { step(1); return .handled }
                .onKeyPress(.upArrow) { step(-1); return .handled }
                Divider()
                // On the panel's backdrop like the list: the form's own background only reached
                // as far down as its rows, a white block over the see-through rest.
                ScrollView {
                    SettingsView(formWidth: FloatingPanel.width - Self.listWidth - 1, category: category)
                        .scrollContentBackground(.hidden)
                        .id(category)
                }
            }
        }
        .onAppear { listFocused = true }
    }

    private func step(_ by: Int) {
        let all = SettingsCategory.allCases
        guard let index = all.firstIndex(of: category) else { return }
        category = all[min(max(index + by, 0), all.count - 1)]
    }
}
