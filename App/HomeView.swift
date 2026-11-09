import SwiftUI
import SrbCore

/// The Study tab when nothing's running: review what's due, continue the open lesson, or pick a
/// topic for a new one.
struct HomeView: View {
    let session: ReviewSession
    let compact: Bool
    /// Off only for headless UI snapshots (they can't draw inside a ScrollView).
    var scrolls = true
    /// Margin around the content; the scroll view itself reaches the window's edges.
    var inset: CGFloat = 0
    @Environment(AppModel.self) private var model
    /// Topic tiles per row, for moving up and down with the arrow keys.
    @State private var columns = 1

    var body: some View {
        let _ = Perf.count("home")
        Group {
            if compact {
                compactBody
            } else if scrolls {
                ScrollViewReader { proxy in
                    ScrollView {
                        fullBody
                    }
                    .contentMargins(inset, for: .scrollContent)
                    .onChange(of: session.homeFocus) {
                        if let focus = session.homeFocus {
                            withAnimation(.snappy) { proxy.scrollTo(focus) }
                        }
                    }
                }
            } else {
                fullBody
            }
        }
        .onChange(of: homeRows, initial: true) { session.homeRows = homeRows }
    }

    /// What the arrow keys move through, row by row as on screen.
    private var homeRows: [[ReviewSession.HomeItem]] {
        var cards: [ReviewSession.HomeItem] = []
        if session.reviewCount > 0 { cards.append(.review) }
        if session.hasOpenLesson { cards.append(.lesson) }
        let elsewhere = session.lessonsElsewhere.map { ReviewSession.HomeItem.elsewhere($0.device) }
        if session.canLearnNewest { cards.append(.newest) }
        if session.canLearnNewWords { cards.append(.newWords) }
        if compact {
            // Popover order: chat card, review, open lesson, then the newest-words row above topics.
            var rows: [[ReviewSession.HomeItem]] = []
            if session.canLearnNewWords { rows.append([.newWords]) }
            rows += cards.filter { $0 != .newWords && $0 != .newest }.map { [$0] }
            rows += elsewhere.map { [$0] }
            if session.canLearnNewest { rows.append([.newest]) }
            let topics = session.topics.filter { $0.notStarted > 0 }.prefix(3).map { ReviewSession.HomeItem.topic($0.topic) }
            return rows + topics.map { [$0] }
        }
        let topics = session.topics.map { ReviewSession.HomeItem.topic($0.topic) }
        return [cards] + elsewhere.map { [$0] } + stride(from: 0, to: topics.count, by: columns).map {
            Array(topics[$0..<min($0 + columns, topics.count)])
        }
    }

    // MARK: iPhone

    /// One column: review, the open lesson, new words, then the topics.
    private var touchBody: some View {
        VStack(alignment: .leading, spacing: 16) {
            reviewCard
            if let progress = session.lessonProgress, session.hasOpenLesson {
                lessonCard(progress)
            }
            ForEach(session.lessonsElsewhere) { elsewhereCard($0) }
            if session.canLearnNewest {
                newestCard
            }
            if !session.newWords.isEmpty {
                newWordsCard
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("New lesson").font(.title2.weight(.semibold))
                Text("Pick a topic and learn \(model.lessonSize) words you haven't seen yet.")
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 4)
            topicGrid(minimum: 150)
        }
    }

    private func focused(_ item: ReviewSession.HomeItem) -> Bool { session.homeFocus == item }

    // MARK: Main window

    private var fullBody: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 14) {
                reviewCard
                if let progress = session.lessonProgress, session.hasOpenLesson {
                    lessonCard(progress)
                }
                if session.canLearnNewest {
                    newestCard
                }
                if !session.newWords.isEmpty {
                    newWordsCard
                }
            }
            .fixedSize(horizontal: false, vertical: true)

            // A row, not a fifth card: the top row has no room for one.
            ForEach(session.lessonsElsewhere) { compactElsewhere($0) }

            HStack(alignment: .lastTextBaseline) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("New lesson").font(.title2.weight(.semibold))
                    Text("Pick a topic and learn \(model.lessonSize) words you haven't seen yet.")
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 12)
                HStack(spacing: 6) {
                    Text("Arrow keys to choose ·")
                    KeyCap(key: "↩")
                    Text("to open")
                }
                .font(.callout)
                .foregroundStyle(.secondary)
            }
            .padding(.top, 8)

            topicGrid(minimum: 180)
        }
    }

    private func topicGrid(minimum: CGFloat) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: minimum), spacing: 10)], spacing: 10) {
            ForEach(session.topics) { item in
                TopicTile(
                    name: item.topic,
                    icon: TopicIcon.name(for: item.topic),
                    notStarted: item.notStarted,
                    learned: item.learned,
                    total: item.total,
                    focused: focused(.topic(item.topic))
                ) { session.showTopic(item.topic) }
                .id(ReviewSession.HomeItem.topic(item.topic))
            }
        }
        .onGeometryChange(for: Int.self) { max(1, Int(($0.size.width + 10) / (minimum + 10))) } action: { columns = $0 }
    }

    private var reviewCard: some View {
        HomeCard(focused: focused(.review)) {
            Label("Review", systemImage: "clock.arrow.circlepath")
                .font(.title2.weight(.semibold))
            if session.reviewCount > 0 {
                Text("\(session.reviewCount) words are due")
                    .font(.title3)
                Text("About \(reviewMinutes) min")
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Button { session.startReview() } label: {
                    Text("Start review").frame(minWidth: 120)
                }
                .prominentButton()
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
            } else {
                Text("Nothing to review right now")
                    .font(.title3)
                if let next = session.nextDue {
                    Text("Next one \(next.formatted(.relative(presentation: .named)))")
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    /// A lesson open on the other device: continuing it here replaces the one open here.
    private func elsewhereCard(_ other: ReviewSession.LessonElsewhere) -> some View {
        HomeCard(focused: focused(.elsewhere(other.device))) {
            Label(ReviewSession.title(of: other.lesson), systemImage: lessonIcon(other.lesson))
                .font(.title2.weight(.semibold))
                .lineLimit(1)
            Text("\(other.progress.learned) of \(other.progress.total) learned")
                .font(.title3)
            ProgressView(value: Double(other.progress.learned), total: Double(max(other.progress.total, 1)))
                .tint(.green)
            Text("Open on your \(other.deviceName)")
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Button { session.continueLesson(other) } label: {
                Text("Continue here").frame(minWidth: 120)
            }
            .secondaryButton()
            .controlSize(.large)
        }
    }

    private func lessonIcon(_ lesson: Lesson?, topicIcons: Bool = false) -> String {
        if lesson?.label == AppModel.newWordsLessonLabel { return "tray.and.arrow.down" }
        guard topicIcons else { return "book" }
        return lesson?.topic.map(TopicIcon.name(for:)) ?? "square.grid.2x2"
    }

    private func lessonCard(_ progress: LessonProgress) -> some View {
        HomeCard(focused: focused(.lesson)) {
            Label(session.lessonTitle, systemImage: lessonIcon(model.lesson))
                .font(.title2.weight(.semibold))
                .lineLimit(1)
            Text("\(progress.learned) of \(progress.total) learned")
                .font(.title3)
            ProgressView(value: Double(progress.learned), total: Double(max(progress.total, 1)))
                .tint(.green)
            Spacer(minLength: 8)
            Button { session.continueLesson() } label: {
                Text("Continue lesson").frame(minWidth: 120)
            }
            .secondaryButton()
            .controlSize(.large)
            // Enter continues the lesson when there's nothing to review.
            .keyboardShortcut(session.reviewCount == 0 ? .defaultAction : nil)
        }
    }

    private var newWordsCard: some View {
        NewWordsCard(
            groups: session.newWords,
            compact: compact && !Platform.isTouch,
            scrolls: scrolls,
            focused: focused(.newWords),
            learnTitle: session.canLearnNewWords ? learnNewWordsTitle : nil,
            isDefaultAction: session.reviewCount == 0 && !session.hasOpenLesson && !session.canLearnNewest,
            openTopic: { session.showTopic($0) },
            learn: { session.showNewWords(only: session.newWordsToLearn) },
            dismiss: { model.dismissRecentlyAdded() }
        )
        .id(ReviewSession.HomeItem.newWords)
    }

    /// Opens the list of the words just added, to pick which to learn.
    private var learnNewWordsTitle: String { String(localized: "Choose") }

    /// Opens the list of words not started yet, so you can tick which ones to learn.
    private var newestCard: some View {
        HomeCard(focused: focused(.newest)) {
            Label("New words", systemImage: "tray.and.arrow.down")
                .font(.title2.weight(.semibold))
            Text("\(session.libraryCount) to add")
                .font(.title3)
            Text("Pick which ones to learn, and how many.")
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Button { session.showNewWords() } label: {
                Text("Choose").frame(minWidth: 120)
            }
            .prominentButton()
            .controlSize(.large)
            .keyboardShortcut(session.reviewCount == 0 && !session.hasOpenLesson ? .defaultAction : nil)
        }
        .id(ReviewSession.HomeItem.newest)
    }

    // MARK: Menu bar popover

    /// What's due with a big Start, the open lesson, then a few topics for a new lesson.
    private var compactBody: some View {
        VStack(alignment: .leading, spacing: 12) {
            compactHeader
            if !session.newWords.isEmpty {
                newWordsCard
            }
            compactReview
            if let progress = session.lessonProgress, session.hasOpenLesson {
                compactLesson(progress)
            }
            ForEach(session.lessonsElsewhere) { compactElsewhere($0) }
            if session.canLearnNewest {
                compactNewest
            }
            compactTopics
            Spacer(minLength: 0)
            compactFooter
        }
        .font(.body)
    }

    private var compactHeader: some View {
        HStack(spacing: 8) {
            Text(verbatim: "Kvačica").font(.title3.weight(.semibold))
            Spacer()
            Button { MainWindow.show() } label: {
                Label("Open window", systemImage: "macwindow")
            }
            .buttonStyle(.borderless)
            .help("Open the Kvačica window")
            Button { MainWindow.showSettings() } label: {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.borderless)
            .help("Settings")
        }
    }

    private var compactReview: some View {
        HStack(spacing: 14) {
            if session.reviewCount > 0 {
                Text("\(session.reviewCount)")
                    .font(.system(size: 36, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                VStack(alignment: .leading, spacing: 2) {
                    Text(String(localized: "unit: \(session.reviewCount) words to review", table: "Units"))
                        .font(.body.weight(.medium))
                    Text("About \(reviewMinutes) min").font(.callout).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Button { session.startReview() } label: {
                    Text("Start").frame(minWidth: 64)
                }
                .prominentButton()
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
            } else {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 30))
                    .foregroundStyle(.green)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Nothing to review").font(.body.weight(.medium))
                    if let next = session.nextDue {
                        Text("Next one \(next.formatted(.relative(presentation: .named)))")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 72, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.04)))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.08)))
        .focusRing(focused(.review), cornerRadius: 12)
    }

    private func compactElsewhere(_ other: ReviewSession.LessonElsewhere) -> some View {
        Button { session.continueLesson(other) } label: {
            HStack(spacing: 12) {
                Image(systemName: lessonIcon(other.lesson, topicIcons: true))
                    .font(.title3)
                    .foregroundStyle(Color.secondary)
                    .frame(width: 26)
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(ReviewSession.name(of: other.lesson))
                            .font(.body.weight(.medium))
                            .lineLimit(1)
                        Spacer(minLength: 8)
                        Text("\(other.progress.learned) of \(other.progress.total)")
                            .font(.callout)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    ProgressView(value: Double(other.progress.learned), total: Double(max(other.progress.total, 1)))
                        .tint(.green)
                    Text("Open on your \(other.deviceName) · continue here")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Image(systemName: "chevron.right").foregroundStyle(.tertiary)
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.04)))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.08)))
            .focusRing(focused(.elsewhere(other.device)), cornerRadius: 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func compactLesson(_ progress: LessonProgress) -> some View {
        let icon = lessonIcon(model.lesson, topicIcons: true)
        return Button { session.continueLesson() } label: {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.title3)
                    .foregroundStyle(Color.secondary)
                    .frame(width: 26)
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(session.continueLabel)
                            .font(.body.weight(.medium))
                            .lineLimit(1)
                        Spacer(minLength: 8)
                        Text("\(progress.learned) of \(progress.total)")
                            .font(.callout)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    ProgressView(value: Double(progress.learned), total: Double(max(progress.total, 1)))
                        .tint(.green)
                }
                Image(systemName: "chevron.right").foregroundStyle(.tertiary)
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.04)))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.08)))
            .focusRing(focused(.lesson), cornerRadius: 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // Enter goes to the lesson when there's nothing to review.
        .keyboardShortcut(session.reviewCount == 0 ? .defaultAction : nil)
    }

    private var compactNewest: some View {
        Button { session.showNewWords() } label: {
            HStack(spacing: 10) {
                Image(systemName: "tray.and.arrow.down")
                    .foregroundStyle(Color.secondary)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 1) {
                    Text("New words").fontWeight(.medium)
                    Text("\(session.libraryCount) to add")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                Text("Choose")
                    .foregroundStyle(Color.secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.05)))
            .focusRing(focused(.newest), cornerRadius: 10)
        }
        .buttonStyle(.plain)
        .keyboardShortcut(session.reviewCount == 0 && !session.hasOpenLesson ? .defaultAction : nil)
        .id(ReviewSession.HomeItem.newest)
    }

    /// The first three topics with new words left, in the same order as the main window; the rest in a menu.
    private var compactTopics: some View {
        let open = session.topics.filter { $0.notStarted > 0 }
        let shown = open.prefix(3)
        let rest = open.dropFirst(3)
        return VStack(alignment: .leading, spacing: 4) {
            Text("New lesson")
                .font(.callout.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.leading, 4)
            ForEach(shown) { item in
                CompactTopicRow(name: item.topic, icon: TopicIcon.name(for: item.topic), notStarted: item.notStarted, focused: focused(.topic(item.topic))) {
                    session.showTopic(item.topic)
                }
            }
            if !rest.isEmpty {
                Menu {
                    ForEach(rest) { item in
                        Button("\(Topics.displayName(item.topic)) (\(item.notStarted) new)") { session.showTopic(item.topic) }
                    }
                } label: {
                    Text("\(rest.count) more topics")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .padding(.leading, 10)
                .padding(.top, 2)
            }
            if open.isEmpty {
                Text("Every word has been started. Add more from a chat.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 4)
            }
        }
    }

    private var compactFooter: some View {
        HStack(spacing: 8) {
            if let hotKey = UserDefaults.standard.string(forKey: Pref.hotKeyLabel) {
                Text("\(hotKey) opens this from anywhere")
            }
            Spacer(minLength: 8)
            Button { NSApp.terminate(nil) } label: {
                Image(systemName: "power")
            }
            .buttonStyle(.borderless)
            .help("Quit Kvačica")
        }
        .font(.callout)
        .foregroundStyle(.secondary)
    }

    private var reviewMinutes: Int {
        max(1, Int((Double(session.reviewCount) * 12 / 60).rounded(.up)))
    }
}

/// One topic in the menu bar popover: a click opens its page.
private struct CompactTopicRow: View {
    let name: String
    let icon: String
    let notStarted: Int
    let focused: Bool
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .foregroundStyle(Color.secondary)
                    .frame(width: 22)
                Text(Topics.displayName(name)).lineLimit(1)
                Spacer(minLength: 8)
                Text("\(notStarted) new")
                    .font(.callout)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                Image(systemName: "chevron.right").foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(hovering ? 0.06 : 0)))
            .focusRing(focused, cornerRadius: 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }

    @State private var hovering = false
}

/// End of a review or lesson: what you did and what's next.
struct SummaryView: View {
    let session: ReviewSession
    let compact: Bool

    var body: some View {
        let isLesson = session.mode == .lesson
        let cards = session.summary.cards
        let firstTry = session.summary.firstTry
        VStack(spacing: compact ? 10 : 16) {
            PopIcon(systemName: "checkmark.circle.fill", color: .green)
                .font(.system(size: compact ? 40 : 60, weight: .regular))
            Text(isLesson ? (session.finishedLesson ? "Lesson done" : "Lesson paused") : "Review done")
                .font(compact ? .title2.weight(.semibold) : .largeTitle.weight(.semibold))
            if cards > 0 {
                Text("\(cards) words · \(firstTry) right the first time")
                    .font(compact ? .body : .title3)
                    .foregroundStyle(.secondary)
            }
            if isLesson, session.finishedLesson {
                Text("These words come back for review in a day or so.")
                    .foregroundStyle(.secondary)
            }
            // Stacked on the iPhone: "Another lesson: People & Jobs" and Done don't fit side by side.
            let buttons = Platform.isTouch ? AnyLayout(VStackLayout(spacing: 10)) : AnyLayout(HStackLayout(spacing: 10))
            buttons {
                if isLesson, session.finishedLesson, session.moreNewWords {
                    Button("Choose more words") { session.showNewWords() }
                        .prominentButton()
                        .keyboardShortcut(.defaultAction)
                    Button("Done") { session.goHome() }
                } else if isLesson, session.finishedLesson, !session.finishedNewWords {
                    Button("Another lesson: \(session.finishedLessonTopic.map(Topics.displayName) ?? String(localized: "any topic"))") { session.anotherLesson() }
                        .prominentButton()
                        .keyboardShortcut(.defaultAction)
                    Button("Done") { session.goHome() }
                } else {
                    Button("Done") { session.goHome() }
                        .prominentButton()
                        .keyboardShortcut(.defaultAction)
                }
            }
            .controlSize(.large)
            .padding(.top, 6)
        }
        .multilineTextAlignment(.center)
    }
}

private struct HomeCard<Content: View>: View {
    var focused = false
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) { content }
            .padding(20)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: 14).fill(Color.primary.opacity(0.04)))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.primary.opacity(0.08)))
            .focusRing(focused, cornerRadius: 14)
    }
}

extension View {
    /// The ring around the home item picked with the arrow keys.
    func focusRing(_ focused: Bool, cornerRadius: CGFloat) -> some View {
        overlay(
            RoundedRectangle(cornerRadius: cornerRadius)
                .strokeBorder(Color.accentColor, lineWidth: 2)
                .opacity(focused ? 1 : 0)
        )
        .animation(.easeOut(duration: 0.12), value: focused)
    }
}

/// A topic you can start a lesson from: one click starts it.
private struct TopicTile: View {
    let name: String
    let icon: String
    let notStarted: Int
    let learned: Int
    let total: Int
    let focused: Bool
    let start: () -> Void

    var body: some View {
        Button(action: start) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: icon)
                        .foregroundStyle(Color.secondary)
                        .frame(width: 22)
                    Text(Topics.displayName(name)).lineLimit(1)
                    Spacer(minLength: 0)
                }
                .font(.body.weight(.medium))
                ProgressView(value: Double(learned), total: Double(max(total, 1)))
                    .tint(.green)
                Text(notStarted == 0 ? "All started · \(learned)/\(total)" : "\(notStarted) new · \(learned)/\(total) learned")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.035)))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.07)))
            .focusRing(focused, cornerRadius: 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(notStarted == 0)
        .opacity(notStarted > 0 ? 1 : 0.5)
    }
}

enum TopicIcon {
    static func name(for topic: String) -> String {
        switch topic {
        case "Small words", "Basics": "textformat.abc"
        case "Phrases": "bubble.left.and.bubble.right"
        case "People & Jobs": "person.2"
        case "Character & Feelings": "face.smiling"
        case "Clothes": "tshirt"
        case "Nature & Weather": "cloud.sun"
        case "Free time": "guitars"
        case "Language & Study": "book"
        case "Numbers & Colors": "number"
        case "Opinions & Ideas": "lightbulb"
        case "Family": "figure.2.and.child.holdinghands"
        case "Body & Health": "heart"
        case "Food & Drink": "fork.knife"
        case "Shopping": "cart"
        case "Home": "house"
        case "City & Travel": "map"
        case "Time": "clock"
        case "Verbs": "figure.walk"
        case "Grammar": "text.book.closed"
        case "Sentences": "text.quote"
        default: "tag"
        }
    }
}
