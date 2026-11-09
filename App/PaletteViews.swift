import Foundation

import SwiftUI
import SwiftData
import SrbCore
import Carbon.HIToolbox

/// Settings → Debug: how the Study tab looks in the main window. The palette is a trial of the
/// "keyboard palette" concept: a two-tone headline over one list of commands, for home and cards.
enum StudyStyle: String, CaseIterable {
    case cards, palette

    static let key = "studyStyle"

    var title: String {
        switch self {
        case .cards: "Cards"
        case .palette: "Palette (trial)"
        }
    }
}

/// The pointer picks a row only once it has moved: a list, a card or the panel coming up under
/// a resting pointer picked whatever row happened to be under it.
@MainActor
enum PointerGate {
    /// Where the pointer rested when something new came up under it; nil once it has moved.
    private static var restingAt: NSPoint?

    /// Something new is on screen: the pointer has to move before it picks anything.
    static func reset() { restingAt = NSEvent.mouseLocation }

    static var hasMoved: Bool {
        guard let restingAt else { return true }
        guard NSEvent.mouseLocation != restingAt else { return false }
        self.restingAt = nil
        return true
    }
}

extension View {
    /// Hovering, through `PointerGate`: `inside` turns true only once the pointer has moved.
    func onPointerHover(_ inside: @escaping (Bool) -> Void) -> some View {
        onContinuousHover { phase in
            switch phase {
            case .active:
                if PointerGate.hasMoved { inside(true) }
            case .ended:
                inside(false)
            }
        }
    }
}

/// The big two-line title: what matters now, then the next thing, in a lighter shade.
/// Always exactly two lines at one size, so the panel below sits in the same place on every screen.
struct PaletteHeadline: View {
    let first: AttributedString
    let second: String?

    static let size: CGFloat = 30

    init(first: String, second: String?) {
        self.init(styled: AttributedString(first), second: second)
    }

    /// `first` with a part of it set apart, e.g. the word in its sentence.
    init(styled first: AttributedString, second: String?) {
        self.first = first
        self.second = second
    }

    var body: some View {
        // Centered, on one axis with the answer field and what appears under it.
        VStack(alignment: .center, spacing: 2) {
            Text(first).foregroundStyle(.primary)
            Text(second ?? " ").foregroundStyle(.secondary)
        }
        .font(.system(size: Self.size, weight: .semibold))
        .lineLimit(1)
        .minimumScaleFactor(0.5)
        .frame(maxWidth: .infinity)
    }
}

/// The headline of a right-or-wrong card, as on the iPhone: the word, "means", and the
/// translation to judge, large.
struct PaletteStatement: View {
    let serbian: String
    let russian: String

    var body: some View {
        VStack(spacing: 4) {
            Text(serbian)
                .font(.system(size: PaletteHeadline.size, weight: .semibold))
            Text("means")
                .font(.callout)
                .foregroundStyle(.secondary)
            Text(russian)
                .font(.system(size: 24, weight: .medium))
        }
        .lineLimit(1)
        .minimumScaleFactor(0.5)
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
    }
}

/// «ne» or «da» on a right-or-wrong card: the iPhone's side tile, with ← and → for the tilt.
struct YesNoTile: View {
    enum Look { case normal, selected, right, wrong }
    let title: String
    let subtitle: String
    let left: Bool
    let look: Look
    let onPick: () -> Void
    let action: () -> Void

    var body: some View {
        let color: Color = switch look {
        case .right: .green
        case .wrong: .red
        case .normal, .selected: .primary
        }
        let marked = look == .right || look == .wrong
        let toward: Double = look == .selected ? 1 : 0
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        Button(action: action) {
            VStack(spacing: 4) {
                Text(title).font(.system(size: 24, weight: .semibold))
                Text(subtitle).font(.callout).foregroundStyle(.secondary)
            }
            .foregroundStyle(color)
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity)
            .frame(height: 96)
            .background(shape.fill(marked ? color.opacity(0.14) : Color.primary.opacity(0.04)))
            .background(shape.fill(Color.accentColor.opacity(0.18 * toward)))
            .overlay(shape.strokeBorder(marked ? color.opacity(0.7) : Color.accentColor.opacity(0.12 + 0.7 * toward),
                                        lineWidth: marked ? 2 : 1 + 1.5 * toward))
            .overlay(alignment: left ? .leading : .trailing) {
                // The arrow key that answers it.
                if !marked {
                    Image(systemName: left ? "chevron.compact.left" : "chevron.compact.right")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(Color.accentColor.opacity(0.35 + 0.65 * toward))
                        .padding(.horizontal, 6)
                }
            }
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .onPointerHover { if $0 { onPick() } }
        .animation(.easeOut(duration: 0.12), value: look)
    }
}

/// The line above the headline: back, where you are, hints. Same height on every screen.
struct PaletteTopLine<Leading: View, Center: View, Trailing: View>: View {
    @ViewBuilder let leading: Leading
    @ViewBuilder let center: Center
    @ViewBuilder let trailing: Trailing

    var body: some View {
        ZStack {
            HStack(spacing: 12) {
                leading
                Spacer(minLength: 12)
                trailing
            }
            center
        }
        .frame(maxWidth: .infinity)
        .font(.callout)
        .foregroundStyle(.secondary)
        .frame(height: 28)
    }
}

/// Where every palette screen puts its parts: the same column, the same top.
enum PaletteLayout {
    static let width: CGFloat = 640
    static let top: CGFloat = 24
    static let gap: CGFloat = 20
}

/// The white panel everything you can do sits in. Bare: the floating window is the panel.
struct PalettePanel<Content: View>: View {
    var bare = false
    @ViewBuilder let content: Content

    var body: some View {
        if bare {
            VStack(spacing: 0) { content }
        } else {
            VStack(spacing: 0) { content }
                .background(RoundedRectangle(cornerRadius: 14).fill(Color(nsColor: .textBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.primary.opacity(0.1)))
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .shadow(color: .black.opacity(0.07), radius: 18, y: 8)
        }
    }
}

/// One command, option or grade. The selected one is what Return does.
struct PaletteRow: View {
    enum Look { case normal, selected, right, wrong, faded }

    var symbol: String?
    var tint: Color = .secondary
    let title: String
    var subtitle: String?
    var key: String?
    var look: Look = .normal
    /// Set on the home list: the key stays hidden until ⌘ is held, then it covers the subtitle.
    var keyOnHold: Bool?
    /// The only thing to do (Check, Continue): title and key together in the middle, no icon.
    var centered = false
    /// In a list with a picked row: the pointer picks the row instead of adding a second highlight.
    var onPick: (() -> Void)?
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Group {
                if centered { centeredContent } else { content }
            }
            .padding(.horizontal, 12)
            .frame(height: 42)
            .frame(maxWidth: .infinity)
            .background(RoundedRectangle(cornerRadius: 8).fill(fill))
            // A verdict looks like the ne / da tiles': tinted, with a colored edge.
            .overlay {
                if let verdict = verdictColor {
                    RoundedRectangle(cornerRadius: 8).strokeBorder(verdict.opacity(0.7), lineWidth: 2)
                }
            }
            .contentShape(Rectangle())
            .opacity(look == .faded ? 0.4 : 1)
        }
        .buttonStyle(.plain)
        .onPointerHover { inside in
            if hovering != inside { hovering = inside }
            if inside { onPick?() }
        }
        .animation(.easeOut(duration: 0.12), value: look)
    }

    private var centeredContent: some View {
        HStack(spacing: 10) {
            Text(title)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(verdictColor ?? Color.primary)
                .lineLimit(1)
            if let key {
                PaletteKey(key: key).padding(.leading, 4)
            }
        }
    }

    private var content: some View {
        HStack(spacing: 12) {
            // Always the same slot, so every row's text starts at the same place.
            Group {
                if let symbol {
                    Image(systemName: symbol)
                        .font(.system(size: 15))
                        .foregroundStyle(tint)
                }
            }
            .frame(width: 24)
            Text(title)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(verdictColor ?? Color.primary)
                .lineLimit(1)
            Spacer(minLength: 12)
            if let held = keyOnHold {
                ZStack(alignment: .trailing) {
                    if let subtitle {
                        Text(subtitle)
                            .font(.callout)
                            .foregroundStyle(Color.secondary)
                            .lineLimit(1)
                            .opacity(held && key != nil ? 0 : 1)
                    }
                    if let key {
                        PaletteKey(key: key).opacity(held ? 1 : 0)
                    }
                }
                .animation(.easeOut(duration: 0.1), value: held)
            } else {
                trailing
            }
        }
    }

    @ViewBuilder private var trailing: some View {
        if let subtitle {
            Text(subtitle)
                .font(.callout)
                .foregroundStyle(Color.secondary)
                .lineLimit(1)
        }
        if let key {
            PaletteKey(key: key)
        }
    }

    private var fill: Color {
        switch look {
        // The same quiet gray as hover: the pick should be clear, not loud.
        case .selected: Color.primary.opacity(0.07)
        case .right, .wrong: (verdictColor ?? .clear).opacity(0.14)
        case .normal, .faded: hovering && onPick == nil ? Color.primary.opacity(0.07) : .clear
        }
    }

    private var verdictColor: Color? {
        switch look {
        case .right: .green
        case .wrong: .red
        default: nil
        }
    }
}

/// A key cap that also reads on the accent-colored selected row.
struct PaletteKey: View {
    let key: String
    var onAccent = false

    var body: some View {
        if onAccent {
            Text(key)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Color.white)
                .frame(minWidth: 18, minHeight: 18)
                .padding(.horizontal, 2)
                .background(RoundedRectangle(cornerRadius: 4).fill(Color.white.opacity(0.22)))
        } else {
            Text(key).keyCapStyle()
        }
    }
}

/// The strip along a panel's bottom edge with what the keys do, right-aligned.
struct PaletteFooter<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        HStack(spacing: 16) {
            Spacer(minLength: 0)
            content
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14)
        .frame(height: 38)
        .background(Color.primary.opacity(0.025))
    }
}

/// A key and what it does, in the footer.
struct PaletteFooterHint: View {
    let keys: [String]
    let label: String

    var body: some View {
        HStack(spacing: 6) {
            HStack(spacing: 2) {
                ForEach(keys, id: \.self) { KeyCap(key: $0) }
            }
            Text(label)
        }
    }
}

/// How far along the review or lesson is, in the top line.
struct PaletteProgress: View {
    let done: Int
    let total: Int
    var tint: Color = .accentColor

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.08))
                Capsule().fill(tint)
                    .frame(width: total > 0 ? geo.size.width * CGFloat(done) / CGFloat(total) : 0)
            }
        }
        .frame(height: 6)
        .animation(.snappy, value: done)
    }
}

// MARK: - Home

/// The Study home as a palette: a headline, then one list of everything you can start.
/// Typing filters it; ↑ ↓ move the pick, Return opens it. The keys are handled here, in the
/// search field, not by the session (see `ReviewSession.paletteHome`).
struct PaletteHomeView: View {
    let session: ReviewSession
    @Environment(AppModel.self) private var model
    @State private var query = ""
    @State private var picked: ItemID?
    /// Only the arrows scroll; the pointer picks what is already in view.
    @State private var scrollTarget: ItemID?
    @State private var wordIndex = WordIndex()
    /// A word picked from the results, open over the list; and the one being edited from it.
    @State private var openedNote: Note?
    @State private var editing: Note?
    @State private var editAfterClosing: Note?
    @State private var commandHeld = false
    @State private var flagsMonitor: Any?
    @State private var headlineCache = HeadlineCache()
    @FocusState private var searching: Bool
    @Environment(\.floatingPanel) private var floatingPanel
    @Environment(\.openPanelPage) private var openPanelPage

    /// The headline reads the answer log, so it is worked out once per change, not on every
    /// redraw (scrolling under the pointer redraws the list with every row it passes).
    private final class HeadlineCache {
        var key = ""
        var value: (first: String, second: String?) = ("", nil)
    }

    /// `commandHeld` is for the debug renders, which can't hold a real key.
    init(session: ReviewSession, commandHeld: Bool = false) {
        self.session = session
        _commandHeld = State(initialValue: commandHeld)
    }

    enum ItemID: Hashable {
        case home(ReviewSession.HomeItem)
        case word(PersistentIdentifier)
        case command(String)
    }

    struct Item: Identifiable {
        let id: ItemID
        let symbol: String
        let tint: Color
        let title: String
        let subtitle: String
        /// The heading over this row and the ones after it with the same heading.
        var section: String?
        let action: () -> Void
    }

    /// Words or Progress, in a window of its own over the panel.
    private func open(_ id: String) { MainWindow.showWindow(id) }

    var body: some View {
        let _ = Perf.count("palette home")
        let items = filtered
        let selected = selection(in: items)
        VStack(alignment: .leading, spacing: PaletteLayout.gap) {
            // The floating panel is the command line alone, like Raycast.
            if !floatingPanel {
                PaletteTopLine {
                    EmptyView()
                } center: {
                    EmptyView()
                } trailing: {
                    EmptyView()
                }
                PaletteHeadline(first: headline.first, second: headline.second)
            }
            PalettePanel(bare: floatingPanel) {
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 15))
                        .foregroundStyle(.tertiary)
                    TextField("Type a topic or a command", text: $query)
                        .textFieldStyle(.plain)
                        .font(.system(size: 16))
                        .focused($searching)
                        .onSubmit { items.first { $0.id == selected }?.action() }
                        .onExitCommand {
                            // Like Raycast: Esc clears what you typed, then puts the window away.
                            if query.isEmpty {
                                MainWindow.putAway()
                            } else {
                                query = ""
                                picked = nil
                            }
                        }
                        .onKeyPress(.downArrow) { move(1, in: items); return .handled }
                        .onKeyPress(.upArrow) { move(-1, in: items); return .handled }
                }
                .padding(.horizontal, 18)
                .frame(height: 52)
                Divider()
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                                if let section = item.section, index == 0 || items[index - 1].section != section {
                                    Text(section)
                                        .font(.callout.weight(.semibold))
                                        .foregroundStyle(.secondary)
                                        .padding(.horizontal, 12)
                                        .padding(.top, 10)
                                        .padding(.bottom, 2)
                                }
                                PaletteRow(
                                    symbol: item.symbol,
                                    tint: item.tint,
                                    title: item.title,
                                    subtitle: item.subtitle,
                                    key: index < 9 ? "⌘\(index + 1)" : nil,
                                    look: item.id == selected ? .selected : .normal,
                                    keyOnHold: commandHeld,
                                    onPick: { if picked != item.id { picked = item.id } },
                                    action: item.action
                                )
                                .id(item.id)
                            }
                            if items.isEmpty {
                                Text("Nothing called “\(query)”")
                                    .foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity, minHeight: 42)
                            }
                        }
                        .padding(8)
                    }
                    // Down to the window's bottom whatever is listed: filtering never moves anything.
                    .frame(maxHeight: .infinity, alignment: .top)
                    .onChange(of: scrollTarget) {
                        if let scrollTarget { withAnimation(.snappy) { proxy.scrollTo(scrollTarget) } }
                    }
                }
                // Stays at the panel's bottom edge; the list scrolls above it.
                Divider()
                PaletteFooter {
                    PaletteFooterHint(keys: ["↑", "↓"], label: String(localized: "Choose"))
                    PaletteFooterHint(keys: ["↩"], label: String(localized: "Open"))
                    PaletteFooterHint(keys: ["⌘"], label: String(localized: "Hold for shortcuts"))
                }
            }
        }
        .frame(width: floatingPanel ? nil : PaletteLayout.width)
        .padding(.top, floatingPanel ? 0 : PaletteLayout.top)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background { shortcuts(items) }
        .onAppear {
            session.paletteHome = true
            searching = true
            guard flagsMonitor == nil else { return }
            flagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { event in
                // Shift or Option alone changed nothing here, but redrew all of home.
                let held = event.modifierFlags.contains(.command)
                if commandHeld != held { commandHeld = held }
                return event
            }
        }
        .onDisappear {
            session.paletteHome = false
            if let flagsMonitor { NSEvent.removeMonitor(flagsMonitor) }
            flagsMonitor = nil
            commandHeld = false
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { _ in
            commandHeld = false
        }
        .onChange(of: query) {
            picked = nil
            PointerGate.reset()
        }
        .sheet(item: $openedNote, onDismiss: {
            searching = true
            if let note = editAfterClosing {
                editAfterClosing = nil
                editing = note
            }
        }) { note in
            NoteDetailView(note: note) {
                editAfterClosing = note
                openedNote = nil
            }
            .environment(model)
            // Esc closes it, as everywhere else in the palette.
            .background {
                Button("") { openedNote = nil }
                    .keyboardShortcut(.cancelAction)
                    .opacity(0)
            }
        }
        .noteEditorSheet(item: $editing) { searching = true }
    }

    private func move(_ step: Int, in items: [Item]) {
        guard !items.isEmpty else { return }
        let current = items.firstIndex { $0.id == selection(in: items) } ?? 0
        picked = items[min(max(current + step, 0), items.count - 1)].id
        scrollTarget = picked
    }

    /// ⌘1–⌘9 run the rows on screen.
    private func shortcuts(_ items: [Item]) -> some View {
        ZStack {
            ForEach(Array(items.prefix(9).enumerated()), id: \.element.id) { index, item in
                Button("", action: item.action)
                    .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .command)
            }
        }
        .opacity(0)
        .accessibilityHidden(true)
    }

    /// What Return does: the row picked with the arrows, otherwise the first one.
    private func selection(in items: [Item]) -> ItemID? {
        if let picked, items.contains(where: { $0.id == picked }) { return picked }
        return items.first?.id
    }

    /// Not the numbers (the rows below have them): how far along you are, as what it buys you in
    /// Serbia. One line pair per day, so it doesn't change every time you come back to it.
    private var headline: (first: String, second: String?) {
        let calendar = Calendar.current
        let day = calendar.ordinality(of: .day, in: .era, for: .now) ?? 0
        let key = "\(model.revision)/\(day)/\(session.topics.reduce(0) { $0 + $1.learned })"
        if headlineCache.key != key {
            headlineCache.value = makeHeadline(day: day, calendar: calendar)
            headlineCache.key = key
        }
        return headlineCache.value
    }

    private func makeHeadline(day: Int, calendar: Calendar) -> (first: String, second: String?) {
        HomeHeadline.make(learned: session.topics.reduce(0) { $0 + $1.learned },
                          lastAnswer: model.engine.lastAnswerDate(), day: day, calendar: calendar)
    }

    private var reviewMinutes: Int {
        max(1, Int((Double(session.reviewCount) * 12 / 60).rounded(.up)))
    }

    private var allItems: [Item] {
        _ = model.revision
        var items: [Item] = []
        if session.reviewCount > 0 {
            let count = session.reviewCount
            items.append(Item(id: .home(.review), symbol: "clock.arrow.circlepath", tint: .blue, title: String(localized: "Start review"),
                              subtitle: String(localized: "\(count) words · about \(reviewMinutes) min")) { session.startReview() })
        }
        if session.hasOpenLesson, let progress = session.lessonProgress {
            let name = model.lesson.map(ReviewSession.name(of:)) ?? String(localized: "lesson")
            let icon = model.lesson?.topic.map(TopicIcon.name(for:)) ?? "book"
            items.append(Item(id: .home(.lesson), symbol: icon, tint: .green, title: String(localized: "Continue \(name)"),
                              subtitle: String(localized: "\(progress.learned) of \(progress.total) learned")) { session.continueLesson() })
        }
        for other in session.lessonsElsewhere {
            let name = ReviewSession.name(of: other.lesson)
            items.append(Item(id: .home(.elsewhere(other.device)), symbol: "iphone", tint: .green, title: String(localized: "Continue \(name) here"),
                              subtitle: String(localized: "open on your \(other.deviceName) · \(other.progress.learned) of \(other.progress.total)")) { session.continueLesson(other) })
        }
        if session.canLearnNewWords {
            let words = session.newWords.flatMap(\.words)
            items.append(Item(id: .home(.newWords), symbol: "tray.and.arrow.down", tint: .orange, title: String(localized: "Learn words from your chat"),
                              subtitle: words.prefix(3).map(\.serbian).joined(separator: ", ") + (words.count > 3 ? " +\(words.count - 3)" : "")) {
                session.showNewWords(only: session.newWordsToLearn)
            })
        }
        if session.canLearnNewest {
            items.append(Item(id: .home(.newest), symbol: "tray.and.arrow.down", tint: .orange, title: String(localized: "Choose new words"),
                              subtitle: String(localized: "\(session.libraryCount) to add")) { session.showNewWords() })
        }
        for topic in session.topics where topic.notStarted > 0 {
            items.append(Item(id: .home(.topic(topic.topic)), symbol: TopicIcon.name(for: topic.topic), tint: .accentColor, title: Topics.displayName(topic.topic),
                              subtitle: String(localized: "\(topic.notStarted) new · \(topic.learned) of \(topic.total) learned"),
                              section: String(localized: "New lesson · \(model.lessonSize) words")) {
                session.startLesson(topic: topic.topic)
            })
        }
        // The floating panel has no tabs: the rest of the app is a command away.
        if floatingPanel { items += commands }
        return items
    }

    private var commands: [Item] {
        let section = "Kvačica"
        return [
            Item(id: .command("words"), symbol: "list.bullet", tint: .secondary, title: String(localized: "Words"),
                 subtitle: String(localized: "All your words"), section: section) { openPanelPage?(.words) },
            Item(id: .command("progress"), symbol: "chart.bar", tint: .secondary, title: String(localized: "Progress"),
                 subtitle: String(localized: "Streak, recall, hardest words"), section: section) { openPanelPage?(.progress) },
            Item(id: .command("settings"), symbol: "gearshape", tint: .secondary, title: String(localized: "Settings"),
                 subtitle: "", section: section) { openPanelPage?(.settings) },
            Item(id: .command("chat"), symbol: "bubble.left.and.text.bubble.right", tint: .secondary, title: String(localized: "Words from chat"),
                 subtitle: String(localized: "Add words from Claude or ChatGPT"), section: section) { openPanelPage?(.chat) },
        ]
    }

    /// Typed text searches everything: what you can study, every word (Serbian, Russian, other
    /// spellings, topic, tags, note) and the commands. Case, diacritics and đ/dj don't matter;
    /// a match at the start of a word comes before one inside it.
    private var filtered: [Item] {
        let needle = PaletteSearch.fold(query.trimmingCharacters(in: .whitespaces))
        guard !needle.isEmpty else { return allItems }
        let tokens = needle.split(separator: " ").map(String.init)
        func ranked(_ items: [Item]) -> [Item] {
            items.compactMap { item in
                PaletteSearch.score(tokens, primary: [PaletteSearch.fold(item.title)],
                                    secondary: [PaletteSearch.fold(item.subtitle)]).map { (item, $0) }
            }
            .enumerated()
            .sorted { ($0.element.1, $0.offset) < ($1.element.1, $1.offset) }
            .map(\.element.0)
        }
        let all = allItems
        let study = ranked(all.filter { if case .command = $0.id { false } else { true } })
        let apps = ranked(all.filter { if case .command = $0.id { true } else { false } })
        return study + words(matching: tokens) + apps
    }

    /// The words that match, best first, as rows that open the word.
    private func words(matching tokens: [String]) -> [Item] {
        if wordIndex.revision != model.revision {
            Perf.measure("palette: word index") { wordIndex.rebuild(from: model.engine.allNotes(), revision: model.revision) }
        }
        let found = wordIndex.entries.compactMap { entry in
            PaletteSearch.score(tokens, primary: entry.primary, secondary: entry.secondary).map { (entry, $0) }
        }
        .sorted { ($0.1, $0.0.note.answer.count) < ($1.1, $1.0.note.answer.count) }
        return found.prefix(50).map { entry, _ in
            let note = entry.note
            let subtitle = switch note.progress {
            case .notStarted: String(localized: "\(note.cue) · new")
            case .learning: note.cue
            case .learned: String(localized: "\(note.cue) · learned")
            }
            return Item(id: .word(note.persistentModelID), symbol: TopicIcon.name(for: note.topic ?? ""), tint: .secondary,
                        title: note.answer, subtitle: subtitle, section: String(localized: "Words")) { openedNote = note }
        }
    }
}

/// Every word's searchable text, folded once per change to the deck.
private final class WordIndex {
    struct Entry {
        let note: Note
        /// The word and its meaning: a match here ranks first.
        let primary: [String]
        /// Topic, tags, level, the note.
        let secondary: [String]
    }

    private(set) var revision = -1
    private(set) var entries: [Entry] = []

    func rebuild(from notes: [Note], revision: Int) {
        self.revision = revision
        entries = notes.map { note in
            Entry(note: note,
                  primary: ([note.answer, note.cue] + note.accept).map(PaletteSearch.fold),
                  secondary: ([note.topic ?? "", note.level, note.info ?? ""] + note.tags).map(PaletteSearch.fold))
        }
    }
}

/// How the palette matches what you type.
enum PaletteSearch {
    /// Lowercased, without diacritics; đ as dj, so "kudja" finds "kuđa".
    static func fold(_ text: String) -> String {
        text.replacingOccurrences(of: "đ", with: "dj").replacingOccurrences(of: "Đ", with: "dj")
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
    }

    /// Lower is better; nil when a typed word matches nowhere. Every typed word has to match:
    /// the whole field, its start, the start of a word in it, or anywhere in it, in that order.
    /// The same in a secondary field (topic, note) counts for less.
    static func score(_ tokens: [String], primary: [String], secondary: [String]) -> Int? {
        var total = 0
        for token in tokens {
            let best = (primary.compactMap { match(token, in: $0) } + secondary.compactMap { match(token, in: $0).map { $0 + 4 } }).min()
            guard let best else { return nil }
            total += best
        }
        return total
    }

    private static func match(_ token: String, in field: String) -> Int? {
        guard !field.isEmpty, let range = field.range(of: token) else { return nil }
        if field == token { return 0 }
        if range.lowerBound == field.startIndex { return 1 }
        // The start of a word inside the field: after a space, a comma, a bracket.
        var search = field.startIndex
        while let found = field.range(of: token, range: search..<field.endIndex) {
            if !field[field.index(before: found.lowerBound)].isLetter { return 2 }
            search = field.index(after: found.lowerBound)
        }
        return 3
    }
}

// MARK: - Summary

/// End of a review or lesson, in the palette's shape: the result as the headline, next steps as rows.
struct PaletteSummaryView: View {
    let session: ReviewSession
    @State private var cursor = 0

    var body: some View {
        let isLesson = session.mode == .lesson
        let cards = session.summary.cards
        let firstTry = session.summary.firstTry
        let title = isLesson
            ? (session.finishedLesson ? String(localized: "Lesson done.") : String(localized: "Lesson paused."))
            : String(localized: "Review done.")
        let detail = cards > 0 ? String(localized: "\(firstTry) of \(cards) right the first time.") : nil
        VStack(alignment: .leading, spacing: PaletteLayout.gap) {
            PaletteTopLine {
                EmptyView()
            } center: {
                // A review says so in the headline; a lesson names its topic here.
                if isLesson { Text(session.lessonTitle).fontWeight(.semibold).foregroundStyle(.primary) }
            } trailing: {
                EmptyView()
            }
            PaletteHeadline(first: title, second: detail)
            PalettePanel {
                VStack(spacing: 2) {
                    ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                        // The only way on: in the middle, no icon, like Check on a card.
                        PaletteRow(symbol: rows.count == 1 ? nil : row.symbol, tint: row.tint, title: row.title, subtitle: row.subtitle,
                                   key: index == 0 ? "↩" : "esc", look: index == cursor ? .selected : .normal,
                                   centered: rows.count == 1, onPick: { cursor = index }, action: row.action)
                    }
                }
                .padding(8)
            }
            if isLesson, session.finishedLesson {
                Text("These words come back for review in a day or so.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
            }
        }
        .frame(width: PaletteLayout.width)
        .padding(.top, PaletteLayout.top)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .paletteArrows(
            move: { cursor = min(max(cursor + $0, 0), rows.count - 1) },
            run: { rows[min(cursor, rows.count - 1)].action() }
        )
    }

    private struct Row {
        let symbol: String
        let tint: Color
        let title: String
        var subtitle: String?
        let action: () -> Void
    }

    private var rows: [Row] {
        let home = Row(symbol: "house", tint: .secondary, title: String(localized: "Back to start"), subtitle: nil) { session.goHome() }
        if session.mode == .lesson, session.finishedLesson, session.moreNewWords {
            return [Row(symbol: "tray.and.arrow.down", tint: .orange, title: String(localized: "Choose more words")) { session.showNewWords() }, home]
        }
        if session.mode == .lesson, session.finishedLesson, !session.finishedNewWords {
            return [Row(symbol: "book", tint: .green, title: String(localized: "Another lesson"),
                        subtitle: session.finishedLessonTopic.map(Topics.displayName) ?? String(localized: "any topic")) {
                // Straight into it, its words first: no topic page on the way.
                let topic = session.finishedLessonTopic
                session.goHome()
                session.startLesson(topic: topic)
            }, home]
        }
        if session.mode == .review, session.hasOpenLesson, let progress = session.lessonProgress {
            return [Row(symbol: "book", tint: .green, title: String(localized: "Continue the lesson"),
                        subtitle: String(localized: "\(progress.learned) of \(progress.total) learned")) { session.continueLesson() }, home]
        }
        return [Row(symbol: "house", tint: .secondary, title: String(localized: "Back to start")) { session.goHome() }]
    }
}
// MARK: - All caught up

/// The quick-card shortcut with nothing due and no lesson open: when the next review is, and a
/// new lesson to start instead. Esc puts the panel away; nothing goes by itself.
struct PaletteCaughtUpView: View {
    let session: ReviewSession
    @Environment(AppModel.self) private var model
    @State private var cursor = 0

    var body: some View {
        let rows = rows
        VStack(alignment: .leading, spacing: PaletteLayout.gap) {
            PaletteTopLine {
                Button(action: session.putAway) {
                    HStack(spacing: 6) {
                        KeyCap(key: "esc")
                        Text("Hide")
                    }
                }
                .buttonStyle(.plain)
            } center: {
                EmptyView()
            } trailing: {
                EmptyView()
            }
            PaletteHeadline(first: String(localized: "All caught up."), second: nextReview)
            PalettePanel {
                VStack(spacing: 2) {
                    ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                        PaletteRow(symbol: row.symbol, tint: row.tint, title: row.title, subtitle: row.subtitle,
                                   key: index == 0 ? "↩" : nil, look: index == cursor ? .selected : .normal,
                                   onPick: { cursor = index }, action: row.action)
                    }
                }
                .padding(8)
            }
        }
        .frame(width: PaletteLayout.width)
        .padding(.top, PaletteLayout.top)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .paletteArrows(
            move: { cursor = min(max(cursor + $0, 0), rows.count - 1) },
            run: { rows[min(cursor, rows.count - 1)].action() }
        )
    }

    private var nextReview: String {
        guard let next = session.nextDue else { return String(localized: "Nothing to review.") }
        return String(localized: "Next review \(next.formatted(.relative(presentation: .named))).")
    }

    private struct Row {
        let symbol: String
        let tint: Color
        let title: String
        var subtitle: String?
        let action: () -> Void
    }

    private var rows: [Row] {
        var rows: [Row] = []
        if session.canLearnNewWords {
            let words = session.newWords.flatMap(\.words)
            rows.append(Row(symbol: "tray.and.arrow.down", tint: .orange, title: String(localized: "Learn words from your chat"),
                            subtitle: words.prefix(3).map(\.serbian).joined(separator: ", ") + (words.count > 3 ? " +\(words.count - 3)" : "")) {
                session.startQuickChosen(session.newWordsToLearn)
            })
        }
        // The topic you're in the middle of first, then the next one with new words.
        let open = session.topics.filter { $0.notStarted > 0 }
        if let topic = open.first(where: { $0.learned > 0 }) ?? open.first {
            rows.append(Row(symbol: TopicIcon.name(for: topic.topic), tint: .green, title: String(localized: "New lesson · \(Topics.displayName(topic.topic))"),
                            subtitle: String(localized: "\(min(model.lessonSize, topic.notStarted)) new words")) {
                session.startQuickLesson(topic: topic.topic)
            })
        }
        rows.append(Row(symbol: "house", tint: .secondary, title: String(localized: "Back to start")) { session.goHome() })
        return rows
    }
}

// MARK: - Keys

extension View {
    /// ↑ ↓ and Return for a palette list with nothing focused to take them. Esc stays with the
    /// session (back to start).
    func paletteArrows(move: @escaping (Int) -> Void, run: @escaping () -> Void) -> some View {
        modifier(PaletteArrows(move: move, run: run))
    }
}

private struct PaletteArrows: ViewModifier {
    let move: (Int) -> Void
    let run: () -> Void
    @State private var monitor: Any?

    func body(content: Content) -> some View {
        content
            .onAppear {
                guard monitor == nil else { return }
                monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                    guard event.window?.isKeyWindow == true,
                          event.modifierFlags.intersection([.command, .option, .control]).isEmpty
                    else { return event }
                    switch Int(event.keyCode) {
                    case kVK_UpArrow: move(-1)
                    case kVK_DownArrow: move(1)
                    case kVK_Return, kVK_ANSI_KeypadEnter:
                        if !event.isARepeat { run() }
                    default: return event
                    }
                    return nil
                }
            }
            .onDisappear {
                if let monitor { NSEvent.removeMonitor(monitor) }
                monitor = nil
            }
    }
}

// MARK: - Lesson words

/// The words before the first card of a new lesson (Start), or from ⌘L mid-way (Continue), in the
/// palette's shape: the panel opens with the row Return runs, the words below it.
struct PaletteLessonWordsView: View {
    let session: ReviewSession

    var body: some View {
        let words = session.lessonWords
        let first = session.lessonWordsFirst
        VStack(alignment: .leading, spacing: PaletteLayout.gap) {
            PaletteTopLine {
                Button(action: session.goHome) {
                    HStack(spacing: 6) {
                        KeyCap(key: "esc")
                        Text("Back")
                    }
                }
                .buttonStyle(.plain)
            } center: {
                Text(session.sessionTitle).fontWeight(.semibold).foregroundStyle(.primary)
            } trailing: {
                EmptyView()
            }
            PaletteHeadline(
                first: first ? String(localized: "\(words.count) new words.") : String(localized: "\(words.count) words so far."),
                second: first ? String(localized: "Have a look, then start.") : String(localized: "Back to the cards when you’re ready.")
            )
            PalettePanel {
                VStack(spacing: 2) {
                    PaletteRow(symbol: nil, title: first ? String(localized: "Start the lesson") : String(localized: "Continue"),
                               key: "↩", look: .selected, centered: true, onPick: {}, action: session.hideLessonWords)
                }
                .padding(8)
                Divider()
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(words) { word in
                            VStack(alignment: .leading, spacing: 4) {
                                HStack(alignment: .firstTextBaseline, spacing: 12) {
                                    Text(word.serbian)
                                        .font(.system(size: 15, weight: .semibold))
                                    Spacer(minLength: 12)
                                    Text(word.russian)
                                        .font(.system(size: 15))
                                        .foregroundStyle(.secondary)
                                        .multilineTextAlignment(.trailing)
                                }
                                if let info = word.info, !info.isEmpty {
                                    Text(info)
                                        .font(.callout)
                                        .foregroundStyle(.tertiary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                            .padding(.horizontal, 20)
                            .padding(.vertical, 10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(.vertical, 6)
                }
                .frame(maxHeight: .infinity, alignment: .top)
            }
        }
        .frame(width: PaletteLayout.width)
        .padding(.top, PaletteLayout.top)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(KeyOnlyButton(title: first ? String(localized: "Start") : String(localized: "Continue"), action: session.hideLessonWords))
    }
}

/// The home screen's two-line headline: how many words you know, said with a wink; also over
/// the menu bar popover. A new pair each day; after 3 days away, a nudge instead.
enum HomeHeadline {
    static func make(learned n: Int, lastAnswer: Date?, day: Int, calendar: Calendar = .current) -> (first: String, second: String?) {
        func pick(_ lines: [(String, String)]) -> (String, String?) {
            let line = lines[day % lines.count]
            return (line.0, line.1)
        }
        if let last = lastAnswer,
           let away = calendar.dateComponents([.day], from: calendar.startOfDay(for: last), to: calendar.startOfDay(for: .now)).day,
           away >= 3 {
            return pick([
                (String(localized: "Gde si bre? \(away) days."), String(localized: "The words thought you moved to Croatia.")),
                (String(localized: "\(away) days away."), String(localized: "Some of your words forgot you back.")),
            ])
        }
        let words = String(localized: "\(n) words.")
        switch n {
        case 0:
            return (String(localized: "Zero words. A clean slate."), String(localized: "Every Serb started here. Most were babies."))
        case ..<30:
            return pick([
                (String(localized: "\(words) A toddler knows more."), String(localized: "A toddler can’t order burek, though.")),
                (String(localized: "\(words) Enough to say hello."), String(localized: "Not enough to survive the follow-up.")),
                (String(localized: "\(words) You can point and name things."), String(localized: "Everyone starts there. Progress.")),
            ])
        case ..<100:
            return pick([
                (String(localized: "\(words) You can order coffee."), String(localized: "You can’t yet refuse the second one.")),
                (String(localized: "\(words) The baker understands you."), String(localized: "The baker’s mother doesn’t.")),
                (String(localized: "\(words) Enough for a taxi."), String(localized: "Not enough to argue about the fare.")),
            ])
        case ..<250:
            return pick([
                (String(localized: "\(words) You’d survive a day in Belgrade."), String(localized: "Lunch might be a surprise.")),
                (String(localized: "\(words) Small talk: possible."), String(localized: "Escaping it: not yet.")),
                (String(localized: "\(words) You can read the menu."), String(localized: "The prices still hurt in any language.")),
            ])
        case ..<500:
            return pick([
                (String(localized: "\(words) Ready for the kafana."), String(localized: "Not ready for the third rakija.")),
                (String(localized: "\(words) You could fill in a form at MUP."), String(localized: "Emotionally, you’re not ready.")),
                (String(localized: "\(words) Careful, landlord."), String(localized: "Your tenant understands you now.")),
            ])
        default:
            return pick([
                (String(localized: "\(words) You understand the gossip."), String(localized: "Now you’re part of it.")),
                (String(localized: "\(words) Baba next door accepts you."), String(localized: "Mostly.")),
                (String(localized: "\(words) No more English replies."), String(localized: "From most Serbs.")),
            ])
        }
    }

    /// Today's, for views that don't keep the day themselves.
    static func today(learned: Int, lastAnswer: Date?) -> (first: String, second: String?) {
        let calendar = Calendar.current
        let day = calendar.ordinality(of: .day, in: .era, for: .now) ?? 0
        return make(learned: learned, lastAnswer: lastAnswer, day: day, calendar: calendar)
    }
}
