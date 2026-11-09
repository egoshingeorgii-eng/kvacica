import AppKit
import Carbon.HIToolbox
import SrbCore
import SwiftUI

/// Menu bar item with the due count. A click opens Kvačica (the floating panel, or the window);
/// a right click (or ⌃-click) has the menu: quick card, Settings, Quit.
/// Without the floating panel the quick-card shortcut opens a small popover instead: what's due,
/// the open lesson, the streak, and the cards right in it (no home screen, no word list first:
/// the home screen lagged there with long word lists).
/// Built on NSStatusItem rather than MenuBarExtra because the global hotkey has to open the popover.
@MainActor
final class StatusBarController: NSObject, NSPopoverDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let popover = NSPopover()
    private let model: AppModel
    /// The popover's own cards, apart from the main window's.
    private let session: ReviewSession
    private var timer: Timer?
    private let words = MenuBarWords()
    /// Settings changed what the item shows: draw it again now, not at the next minute.
    static var settingsChanged: (() -> Void)?
    /// Who had focus before the popover took it, so closing the popover can give it back.
    private var previousApp: NSRunningApplication?

    init(model: AppModel) {
        self.model = model
        session = ReviewSession(model: model)
        session.opensWithWords = false
        super.init()

        let host = NSHostingController(rootView: MenuBarPopover(session: session).environment(model))
        host.sizingOptions = .preferredContentSize
        popover.contentViewController = host
        popover.behavior = .transient
        popover.delegate = self

        if let button = item.button {
            button.target = self
            button.action = #selector(clicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        MainWindow.willShow = { [weak self] in
            // The window is about to take focus; nothing to give back.
            self?.previousApp = nil
            if self?.popover.isShown == true { self?.popover.performClose(nil) }
        }

        GlobalHotKey.shared.onPress[.quickReview] = { [weak self] in
            if MainWindow.floats { MainWindow.quickCard() } else { self?.toggle() }
        }
        GlobalHotKey.shared.onPress[.openApp] = { MainWindow.toggle() }
        model.applyHotKey()

        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        Self.settingsChanged = { [weak self] in
            self?.words.reset()
            self?.refresh()
        }
        observeModel()
    }

    private func observeModel() {
        withObservationTracking {
            refresh()
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.observeModel()
                // An answer on the phone while the popover is open: its figures too.
                if self?.popover.isShown == true { self?.session.reloadIfIdle() }
            }
        }
    }

    /// Just the book while nothing's due; once words are due, a filled book and how many.
    /// Or, if Settings say so, a word to glance at with the count after it.
    private func refresh() {
        Perf.measure("status item") { updateButton() }
    }

    private func updateButton() {
        _ = model.revision
        guard let button = item.button else { return }
        let engine = model.engine
        let count = model.dueCount()
        let shows = MenuBarShows.current
        // The word stays put while the popover is open.
        let word = shows == .icon ? nil : words.update(model: model, frozen: popover.isShown)
        if let word {
            let title = MenuBarShows.title(word, translation: shows == .wordAndTranslation, count: count)
            button.image = nil
            button.imagePosition = .noImage
            button.attributedTitle = title.text
            button.toolTip = title.toolTip
            return
        }
        let symbol = count > 0 ? "character.book.closed.fill" : "character.book.closed"
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Kvačica")
        if count > 0 {
            button.imagePosition = .imageLeading
            button.attributedTitle = NSAttributedString(
                string: " " + (count > 999 ? "999+" : "\(count)"),
                attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .semibold)]
            )
            button.toolTip = String(localized: "\(count) words to review")
        } else {
            button.imagePosition = .imageOnly
            button.title = ""
            button.toolTip = engine.nextDueDate().map {
                String(localized: "Nothing to review · next one \($0.formatted(.relative(presentation: .named)))")
            } ?? String(localized: "Nothing to review")
        }
    }

    @objc private func clicked() {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true {
            // Assigned only for this click, so a plain click still opens the app.
            item.menu = makeMenu()
            item.button?.performClick(nil)
            item.menu = nil
        } else {
            MainWindow.toggle()
        }
    }

    private func makeMenu() -> NSMenu {
        let menu = NSMenu()
        func add(_ title: String, _ action: Selector, shortcut: String? = nil) {
            let entry = NSMenuItem(title: title, action: action, keyEquivalent: "")
            entry.target = self
            // The global shortcut as Settings has it ("⌥⌘S"), shown the menu's own way.
            if let shortcut, let key = shortcut.last, !"⌃⌥⇧⌘".contains(key) {
                entry.keyEquivalent = String(key).lowercased()
                var mask: NSEvent.ModifierFlags = []
                if shortcut.contains("⌃") { mask.insert(.control) }
                if shortcut.contains("⌥") { mask.insert(.option) }
                if shortcut.contains("⇧") { mask.insert(.shift) }
                if shortcut.contains("⌘") { mask.insert(.command) }
                entry.keyEquivalentModifierMask = mask
            }
            menu.addItem(entry)
        }
        let defaults = UserDefaults.standard
        add(String(localized: "Open Kvačica"), #selector(openApp), shortcut: defaults.string(forKey: Pref.panelHotKeyLabel))
        add(MainWindow.floats ? String(localized: "Quick Card") : String(localized: "Quick Review"), #selector(quickCard), shortcut: defaults.string(forKey: Pref.hotKeyLabel))
        menu.addItem(.separator())
        add(String(localized: "Settings…"), #selector(openSettings), shortcut: "⌘,")
        if Updates.isOn {
            add(Updates.available ? String(localized: "Update Available…") : String(localized: "Check for Updates…"), #selector(checkForUpdates))
        }
        menu.addItem(.separator())
        add(String(localized: "Quit Kvačica"), #selector(quit), shortcut: "⌘Q")
        return menu
    }

    @objc private func openApp() { MainWindow.show() }
    @objc private func quickCard() { MainWindow.floats ? MainWindow.quickCard() : toggle() }
    @objc private func openSettings() { MainWindow.showSettingsPage() }
    @objc private func checkForUpdates() { Updates.check() }
    @objc private func quit() { NSApp.terminate(nil) }

    @objc func toggle() {
        if popover.isShown {
            popover.performClose(nil)
            return
        }
        guard let button = item.button else { return }
        // The app has to be active for the popover to take Return and to close on a click
        // elsewhere. Activating raises the app's windows, though: the main window popped up
        // with the popover. Remember what was on screen to put it back once activation lands.
        let wasActive = NSApp.isActive
        previousApp = wasActive ? nil : NSWorkspace.shared.frontmostApplication
        let shown = Set(NSApp.windows.filter { $0.isVisible && $0.canBecomeMain }.map(ObjectIdentifier.init))
        NSApp.activate(ignoringOtherApps: true)
        // Its home is only worked out as it opens, not after every answer while it's closed.
        session.reloadIfIdle(force: true)
        model.didOpenQuickReview()
        PointerGate.reset()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
        if !wasActive { keepWindowsWhereTheyWere(shown) }
    }

    /// Activation is asynchronous, so ordering windows right after `activate` came too early.
    /// Once the app is active: windows that were open go back behind the other apps, and any
    /// that came up from closed or hidden (unhiding, SwiftUI reopening its window) go away again.
    private func keepWindowsWhereTheyWere(_ shown: Set<ObjectIdentifier>) {
        let popoverWindow = popover.contentViewController?.view.window
        let settle = {
            for window in NSApp.windows where window.canBecomeMain && window !== popoverWindow && window.isVisible {
                if shown.contains(ObjectIdentifier(window)) { window.orderBack(nil) } else { window.orderOut(nil) }
            }
            popoverWindow?.makeKey()
        }
        if NSApp.isActive {
            DispatchQueue.main.async(execute: settle)
            return
        }
        var token: NSObjectProtocol?
        token = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            if let token { NotificationCenter.default.removeObserver(token) }
            // A beat later, so a window SwiftUI reopens on activation is there to put away.
            DispatchQueue.main.async { MainActor.assumeIsolated { settle() } }
        }
    }

    func popoverDidClose(_ notification: Notification) {
        model.speechInput.stop()
        // A finished review or lesson isn't worth coming back to; an unfinished one is.
        if session.mode != .home, session.stage == .done { session.goHome() }
        // The menu bar's word held still while it was open; an answer may have moved it on.
        refresh()
        // Give focus back to whatever you were doing, unless a Srpski window (or the panel) is open.
        if !NSApp.windows.contains(where: { $0.isVisible && $0.canBecomeMain }), !FloatingPanelController.shared.isVisible {
            NSApp.hide(nil)
        } else if NSApp.isActive, let previousApp {
            // A window left open behind other apps stays there; focus goes back to where it was.
            previousApp.activate()
        }
        previousApp = nil
    }
}

/// What the menu bar item shows. The word is only there to be looked at: a glance never counts
/// as a review, only an answer in the cards does.
enum MenuBarShows: String, CaseIterable {
    case icon, word, wordAndTranslation

    static var current: MenuBarShows {
        MenuBarShows(rawValue: UserDefaults.standard.string(forKey: Pref.menuBarShows) ?? "") ?? .word
    }

    /// How long a word stays, in minutes.
    static let intervals = [1, 5, 15, 60]

    var title: String {
        switch self {
        case .icon: String(localized: "Icon & count")
        case .word: String(localized: "Word")
        case .wordAndTranslation: String(localized: "Word + translation")
        }
    }

    /// "zdravo · 12", or "zdravo — привет · 12"; long words end in "…". The Russian is always
    /// in the tooltip.
    static func title(_ word: MenuBarWord, translation: Bool, count: Int) -> (text: NSAttributedString, toolTip: String) {
        let font = NSFont.menuBarFont(ofSize: 0)
        let text = NSMutableAttributedString(string: clip(word.serbian), attributes: [.font: font])
        if translation {
            text.append(NSAttributedString(string: " — " + clip(word.russian), attributes: [
                .font: font, .foregroundColor: NSColor.secondaryLabelColor,
            ]))
        }
        if count > 0 {
            text.append(NSAttributedString(string: " · " + (count > 999 ? "999+" : "\(count)"), attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: font.pointSize, weight: .semibold),
                .foregroundColor: NSColor.secondaryLabelColor,
            ]))
        }
        let due = count > 0 ? String(localized: "\(count) words to review") : String(localized: "Nothing to review")
        return (text, "\(word.serbian) — \(word.russian)\n\(due)")
    }

    private static func clip(_ text: String, to length: Int = 18) -> String {
        text.count > length ? String(text.prefix(length - 1)).trimmingCharacters(in: .whitespaces) + "…" : text
    }
}

/// A word as the menu bar shows it, kept as text so a word deleted meanwhile can't trip it up.
struct MenuBarWord: Equatable {
    var serbian: String
    var russian: String
    var shownAt: Date
}

/// Which word the menu bar shows: the desktop widget's words (Settings → Which words), one at a
/// time, the next one every few minutes.
@MainActor
final class MenuBarWords {
    private(set) var current: MenuBarWord?
    private var index = -1

    /// Which words changed: start again from the top of the new list.
    func reset() {
        current = nil
        index = -1
    }

    /// The word to show now. `frozen` (the popover is open) keeps the one that's up.
    func update(model: AppModel, now: Date = .now, frozen: Bool = false) -> MenuBarWord? {
        let minutes = max(1, UserDefaults.standard.integer(forKey: Pref.menuBarMinutes))
        if let current, frozen || now.timeIntervalSince(current.shownAt) < Double(minutes * 60) - 5 {
            return current
        }
        // Worked out only when the word changes, not on every answer.
        let words = model.widgetWords(now: now)
        guard !words.isEmpty else {
            current = nil
            return nil
        }
        index = (index + 1) % words.count
        current = MenuBarWord(serbian: words[index].answer, russian: words[index].cue, shownAt: now)
        return current
    }
}

/// One system-wide shortcut via Carbon's RegisterEventHotKey (no Accessibility permission needed).
@MainActor
final class GlobalHotKey {
    /// Each shortcut and the setting it's kept in.
    enum Slot: UInt32, CaseIterable {
        /// The menu bar popover.
        case quickReview = 1
        /// The floating panel (or the window, with the panel off).
        case openApp = 2

        var codeKey: String { self == .quickReview ? Pref.hotKeyCode : Pref.panelHotKeyCode }
        var modifiersKey: String { self == .quickReview ? Pref.hotKeyModifiers : Pref.panelHotKeyModifiers }
        var labelKey: String { self == .quickReview ? Pref.hotKeyLabel : Pref.panelHotKeyLabel }
    }

    static let shared = GlobalHotKey()
    var onPress: [Slot: () -> Void] = [:]
    private var refs: [Slot: EventHotKeyRef] = [:]
    private var handlerInstalled = false

    func register(_ slot: Slot, keyCode: UInt32, modifiers: UInt32) {
        installHandlerIfNeeded()
        if let ref = refs.removeValue(forKey: slot) { UnregisterEventHotKey(ref) }
        let id = EventHotKeyID(signature: OSType(0x5352_424B), id: slot.rawValue) // 'SRBK'
        var ref: EventHotKeyRef?
        RegisterEventHotKey(keyCode, modifiers, id, GetApplicationEventTarget(), 0, &ref)
        refs[slot] = ref
    }

    private func installHandlerIfNeeded() {
        guard !handlerInstalled else { return }
        handlerInstalled = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var id = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            let slot = Slot(rawValue: id.id)
            Task { @MainActor in
                if let slot { GlobalHotKey.shared.onPress[slot]?() }
            }
            return noErr
        }, 1, &spec, nil, nil)
    }
}

extension NSEvent.ModifierFlags {
    var carbonFlags: Int {
        var flags = 0
        if contains(.command) { flags |= cmdKey }
        if contains(.option) { flags |= optionKey }
        if contains(.control) { flags |= controlKey }
        if contains(.shift) { flags |= shiftKey }
        return flags
    }

    var symbols: String {
        (contains(.control) ? "⌃" : "") + (contains(.option) ? "⌥" : "")
            + (contains(.shift) ? "⇧" : "") + (contains(.command) ? "⌘" : "")
    }
}

/// The popover: the summary, or the cards once a review or lesson starts from it. Leaving them
/// (Esc, Done) comes back to the summary.
private struct MenuBarPopover: View {
    let session: ReviewSession
    /// Settings → Debug: the summary and the cards give way to each other like the cards do.
    @AppStorage(CardMotion.key) private var motion: CardMotion = .slide
    @AppStorage(CardMotion.speedKey) private var speed: MotionSpeed = .standard

    var body: some View {
        ZStack {
            if session.screen == .home {
                MenuBarSummary(session: session)
                    .transition(motion.transition)
            } else {
                // Key hints like the main window's: the keys work here too.
                ReviewView(compact: true, injected: session)
                    .transition(motion.transition)
            }
        }
        .animation(speed.animation, value: session.screen == .home)
    }
}

/// The menu bar popover: the day at a glance in the home screen's look (headline, then a panel
/// of command rows), each row opening the main window.
struct MenuBarSummary: View {
    /// Where review and the lesson run; without one (debug snapshots) they open the main window.
    var session: ReviewSession?
    @Environment(AppModel.self) private var model
    /// Debug snapshots: a session only for the figures.
    @State private var holder = SessionHolder()

    var body: some View {
        Perf.measure("menu bar summary") { summary }
    }

    /// The figures are the ones the session's home has worked out (refreshed as the popover
    /// opens), not counted again here: this ran through the deck about ten times per draw.
    @ViewBuilder private var summary: some View {
        let home = session ?? holder.session(for: model)
        let due = home.reviewCount
        let lesson = model.lesson
        let progress = home.lessonProgress
        let openLesson = home.hasOpenLesson
        let engine = model.engine
        let streak = engine.currentStreak()

        VStack(alignment: .leading, spacing: 12) {
            // The home screen's headline, a size smaller.
            let headline = HomeHeadline.today(learned: home.topics.reduce(0) { $0 + $1.learned },
                                              lastAnswer: engine.lastAnswerDate())
            VStack(alignment: .leading, spacing: 1) {
                Text(headline.first).foregroundStyle(.primary)
                if let second = headline.second { Text(second).foregroundStyle(.secondary) }
            }
            .font(.system(size: 17, weight: .semibold))
            .fixedSize(horizontal: false, vertical: true)

            HStack(alignment: .firstTextBaseline) {
                Text(status(due: due, next: home.nextDue, openLesson: openLesson))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                HStack(spacing: 4) {
                    Image(systemName: "flame.fill").foregroundStyle(.orange)
                    Text("\(streak) days").monospacedDigit()
                }
                .fontWeight(.semibold)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(Capsule().fill(Color.primary.opacity(0.06)))
            }
            .font(.callout)

            PalettePanel {
                VStack(spacing: 2) {
                    let rows = rows(home, due: due, lesson: openLesson ? lesson : nil, progress: progress)
                    ForEach(rows.indices, id: \.self) { i in
                        MenuBarRow(row: rows[i])
                    }
                }
                .padding(6)
            }

            HStack {
                Button("Settings…") { MainWindow.showSettings() }
                Spacer()
                Button("Quit Kvačica") { NSApp.terminate(nil) }
            }
            .buttonStyle(.borderless)
            .font(.callout)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 4)
        }
        .padding(16)
        .frame(width: 380)
    }

    fileprivate struct Row {
        var symbol: String
        var tint: Color
        var title: String
        var subtitle: String?
        var action: () -> Void
    }

    private func rows(_ home: ReviewSession, due: Int, lesson: Lesson?, progress: LessonProgress?) -> [Row] {
        var rows: [Row] = []
        if let lesson, let progress {
            let name = ReviewSession.name(of: lesson)
            rows.append(Row(symbol: lesson.topic.map(TopicIcon.name(for:)) ?? "book", tint: .green,
                            title: String(localized: "Continue \(name)"), subtitle: String(localized: "\(progress.learned) of \(progress.total) learned")) {
                study(.lesson) { $0.continueLesson() }
            })
        }
        if due > 0 {
            let minutes = max(1, Int((Double(due) * 12 / 60).rounded(.up)))
            rows.append(Row(symbol: "clock.arrow.circlepath", tint: .blue, title: String(localized: "Review"),
                            subtitle: String(localized: "\(due) words · about \(minutes) min")) {
                study(.review) { $0.startReview() }
            })
        }
        for other in home.lessonsElsewhere {
            let name = ReviewSession.name(of: other.lesson)
            let progress = other.progress
            rows.append(Row(symbol: "iphone", tint: .green, title: String(localized: "Continue \(name) here"),
                            subtitle: String(localized: "open on your \(other.deviceName) · \(progress.learned) of \(progress.total)")) {
                study(.elsewhere(other.device)) { session in
                    session.refreshHome()
                    if let lesson = session.lessonsElsewhere.first(where: { $0.device == other.device }) {
                        session.continueLesson(lesson)
                    }
                }
            })
        }
        let chatIDs = home.newWordsToLearn
        if !chatIDs.isEmpty, model.lesson?.label != AppModel.newWordsLessonLabel {
            let waiting = Set(chatIDs)
            let words = home.newWords.flatMap(\.words).filter { waiting.contains($0.id) }
            rows.append(Row(symbol: "tray.and.arrow.down", tint: .orange, title: String(localized: "Learn words from your chat"),
                            subtitle: words.prefix(3).map(\.serbian).joined(separator: ", ") + (words.count > 3 ? " +\(words.count - 3)" : "")) {
                // All of them, without the list to tick them in first.
                study(.chatWords) { $0.startChosen(chatIDs) }
            })
        }
        rows.append(Row(symbol: "macwindow", tint: .secondary, title: String(localized: "Open Kvačica"), subtitle: nil) {
            MainWindow.show()
        })
        return rows
    }

    /// Starts it in the popover, or in the main window when there's no popover session.
    private func study(_ request: AppModel.WindowRequest, _ start: (ReviewSession) -> Void) {
        guard let session else {
            model.windowRequest = request
            MainWindow.show()
            return
        }
        start(session)
    }

    private func status(due: Int, next: Date?, openLesson: Bool) -> String {
        if due > 0 { return String(localized: "\(due) words are waiting for you.") }
        if openLesson { return String(localized: "Nothing to review. Your lesson is waiting.") }
        guard let next else { return String(localized: "Nothing to review.") }
        return String(localized: "Nothing to review · next one \(next.formatted(.relative(presentation: .named))).")
    }
}

/// A command row in the menu bar popover: icon, the title with its detail under it. The row
/// keeps its own hover: held in the summary, every hover redrew it and recounted the words.
private struct MenuBarRow: View {
    let row: MenuBarSummary.Row
    @State private var isSelected = false

    var body: some View {
        Button(action: row.action) {
            HStack(spacing: 12) {
                Image(systemName: row.symbol)
                    .font(.system(size: 17))
                    .foregroundStyle(row.tint)
                    .frame(width: 26)
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.title)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(Color.primary)
                    if let subtitle = row.subtitle {
                        Text(subtitle)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
                .lineLimit(1)
                Spacer(minLength: 8)
            }
            .padding(.horizontal, 12)
            .frame(height: row.subtitle == nil ? 44 : 56)
            .frame(maxWidth: .infinity)
            .background(RoundedRectangle(cornerRadius: 8).fill(isSelected ? Color.primary.opacity(0.07) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onPointerHover { if isSelected != $0 { isSelected = $0 } }
    }
}
