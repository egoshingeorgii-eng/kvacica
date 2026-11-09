#if DEBUG
import AppKit
import Carbon.HIToolbox
import SrbCore
import SwiftUI

/// Debug-only UI check: `Srpski -uiSnapshots <dir>` uses an in-memory store, clicks through
/// a review, saves PNGs of its own windows and quits. Needs no screen-recording permission.
@MainActor
enum DebugSnapshots {
    static var directory: URL? {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "-uiSnapshots"), i + 1 < args.count else { return nil }
        return URL(fileURLWithPath: args[i + 1], isDirectory: true)
    }

    static func run(in dir: URL, toggleQuickReview: @escaping () -> Void) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        NSApp.activate(ignoringOtherApps: true)
        Task {
            try await Task.sleep(for: .seconds(1.5))
            guard let main = NSApp.windows.first(where: { $0.canBecomeMain && $0.isVisible }) else { return }
            main.makeKeyAndOrderFront(nil)
            capture(main, "1-answer", in: dir)

            (main.firstResponder as? NSTextView)?.insertText("novcanik", replacementRange: NSRange(location: NSNotFound, length: 0))
            try await Task.sleep(for: .seconds(0.3))
            capture(main, "2-typed", in: dir)
            press(kVK_Return, "\r", in: main)
            try await Task.sleep(for: .seconds(0.6))
            capture(main, "3-almost", in: dir)

            press(kVK_Return, "\r", in: main)
            try await Task.sleep(for: .seconds(0.6))
            (main.firstResponder as? NSTextView)?.insertText("gledim", replacementRange: NSRange(location: NSNotFound, length: 0))
            press(kVK_Return, "\r", in: main)
            try await Task.sleep(for: .seconds(0.6))
            capture(main, "4-wrong", in: dir)

            press(kVK_Return, "\r", in: main)
            try await Task.sleep(for: .seconds(0.6))
            toggleQuickReview()
            try await Task.sleep(for: .seconds(1))
            if let popover = NSApp.windows.first(where: { $0.className.contains("Popover") && $0.isVisible }) {
                capture(popover, "5-popover", in: dir)
            }
            toggleQuickReview()

            NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
            try await Task.sleep(for: .seconds(1))
            if let settings = NSApp.keyWindow, settings !== main {
                capture(settings, "6-settings", in: dir)
            }
            NSApp.terminate(nil)
        }
    }

    /// `Srpski -uiSnapshots <dir> -renderDashboard`: fills the in-memory store with a few weeks of
    /// simulated study, renders the Progress tab to <dir>/dashboard-{light,dark}.png and exits.
    /// No window, no Dock icon, no focus change.
    static func renderDashboardIfRequested(model: AppModel) {
        guard let dir = directory, ProcessInfo.processInfo.arguments.contains("-renderDashboard") else { return }
        NSApp.setActivationPolicy(.prohibited)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let engine = model.engine
        var seed: UInt64 = 42
        func random(_ range: ClosedRange<Int>) -> Int {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return range.lowerBound + Int((seed >> 33) % UInt64(range.count))
        }
        let calendar = Calendar.current
        for daysAgo in stride(from: 60, through: 0, by: -1) {
            if daysAgo > 12, random(0...3) == 0 { continue }
            var time = calendar.date(byAdding: .day, value: -daysAgo, to: calendar.startOfDay(for: .now))!
                .addingTimeInterval(Double(random(8...20)) * 3600)
            // A review of what's due, then (most days) a lesson.
            let lesson = random(0...2) == 0 ? nil : engine.startLesson(topic: nil, level: nil, size: random(4...8), now: time)
            var last: StudyCard?
            for _ in 0..<80 {
                let next = engine.nextReviewCard(now: time, after: last)
                    ?? lesson.flatMap { engine.nextLessonCard($0, now: time, after: last) }
                guard let card = next else { break }
                let grade = Grade(rawValue: [1, 2, 3, 3, 3, 3, 4][random(0...6)])!
                engine.record(card, grade: grade, typed: grade == .again ? "pogrešno" : card.expected, now: time)
                last = card
                time.addTimeInterval(Double(random(6...40)))
            }
        }

        for scheme in [ColorScheme.light, .dark] {
            let view = DashboardGrid(width: 1100)
                .environment(model)
                .environment(\.colorScheme, scheme)
                .frame(width: 1100)
                .background(Color(nsColor: .windowBackgroundColor))
            let renderer = ImageRenderer(content: view)
            renderer.scale = 1
            NSApp.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
            if let image = renderer.nsImage, let tiff = image.tiffRepresentation,
               let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                try? png.write(to: dir.appending(path: "dashboard-\(scheme == .dark ? "dark" : "light").png"))
            }
        }
        exit(0)
    }

    /// `Srpski -uiSnapshots <dir> -renderExercises`: renders every quick exercise before and after
    /// answering to <dir>/exercise-*.png and exits. No window, no Dock icon.
    static func renderExercisesIfRequested(model: AppModel) {
        guard let dir = directory, ProcessInfo.processInfo.arguments.contains("-renderExercises") else { return }
        NSApp.setActivationPolicy(.prohibited)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        for (name, info) in [("verb", "kupim, kupiš, kupi, kupimo, kupite, kupe · несов.: kupovati"), ("reflexive", "zovem se, zoveš se, zove se, zovemo se, zovete se, zovu se")] {
            let renderer = ImageRenderer(content: NoteInfoView(info: info, compact: false).padding(30).frame(width: 640)
                .background(Color(nsColor: .windowBackgroundColor)))
            renderer.scale = 1
            if let tiff = renderer.nsImage?.tiffRepresentation,
               let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                try? png.write(to: dir.appending(path: "info-\(name).png"))
            }
        }

        func render(_ name: String, _ session: ReviewSession) {
            guard let face = session.exerciseFace else { return }
            let view = ExerciseView(session: session, face: face, compact: false)
                .environment(model)
                .padding(30)
                .frame(width: 640)
                .background(Color(nsColor: .windowBackgroundColor))
            let renderer = ImageRenderer(content: view)
            renderer.scale = 1
            if let tiff = renderer.nsImage?.tiffRepresentation,
               let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                try? png.write(to: dir.appending(path: "exercise-\(name).png"))
            }
        }

        for kind in [ExerciseKind.choice, .trueFalse, .tiles, .match] {
            let session = ReviewSession(model: model)
            session.startLesson(topic: nil)
            session.debugShow(kind)
            render("\(kind.rawValue)-1", session)
            switch kind {
            case .choice:
                session.pick(option: ((session.exercise?.correctIndex ?? 0) + 1) % 4)
            case .trueFalse:
                session.answer(yes: !(session.exercise?.statementIsTrue ?? true))
            case .tiles:
                if let letters = session.tiles?.letters, letters.count > 2 {
                    // A wrong attempt (last two letters swapped), then the fix.
                    let wrong = letters.dropLast(2) + [letters[letters.count - 1], letters[letters.count - 2]]
                    for letter in wrong { session.tile(typed: letter) }
                    render("tiles-2-wrong", session)
                    session.removeTiles(fromSlot: letters.count - 2)
                    for letter in letters.suffix(2) { session.tile(typed: letter) }
                }
            case .match:
                if let board = session.match {
                    session.match(left: 0)
                    session.match(right: (0..<board.right.count).first { !board.isMatched(right: $0) && $0 != 0 } ?? 1)
                    render("match-2-progress", session)
                }
                session.giveUp()
            default: break
            }
            render("\(kind.rawValue)-3-after", session)
        }
        exit(0)
    }

    /// `Srpski -uiSnapshots <dir> -renderHome`: the Study home screen, a session header and the
    /// summary, to <dir>/home-*.png. No window, no Dock icon.
    static func renderHomeIfRequested(model: AppModel) {
        guard let dir = directory, ProcessInfo.processInfo.arguments.contains("-renderHome") else { return }
        NSApp.setActivationPolicy(.prohibited)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        func render(_ name: String, width: CGFloat, _ content: some View) {
            let renderer = ImageRenderer(content: content.environment(model).padding(30).frame(width: width)
                .background(Color(nsColor: .windowBackgroundColor)))
            renderer.scale = 1
            if let tiff = renderer.nsImage?.tiffRepresentation,
               let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                try? png.write(to: dir.appending(path: "home-\(name).png"))
            }
        }
        // Something learned yesterday is due now, and a lesson is half done.
        let engine = model.engine
        let yesterday = Date.now.addingTimeInterval(-86_400 * 2)
        for note in engine.lessonWords(topic: "Family", level: nil, size: 6) {
            if let card = note.card(.production) { engine.record(card, grade: .easy, now: yesterday) }
        }
        // As if a chat just added a few words.
        model.recentlyAdded = ["kafa", "caj", "sok", "hleb", "mleko", "kuca", "stan", "grad"].filter { id in
            engine.allNotes().contains { $0.noteID == id }
        }
        // A lesson open on the iPhone.
        if let basics = engine.startLesson(topic: "Small words", level: nil, size: 10) {
            try? SyncedLesson.publish(basics, device: "snapshot-iphone", name: "iPhone", in: model.container.mainContext)
        }
        let session = ReviewSession(model: model)
        session.startLesson(topic: "Shopping")
        if let card = session.card { model.engine.record(card, grade: .easy) }
        session.goHome()
        render("1-main", width: 1000, HomeView(session: session, compact: false, scrolls: false))
        render("2-popover", width: 420, HomeView(session: session, compact: true))
        session.continueLesson()
        while session.mode == .lesson, session.stage != .done, let card = session.card {
            model.engine.record(card, grade: .good, now: card.due)
            session.loadNext()
        }
        render("3-summary", width: 700, SummaryView(session: session, compact: false))
        exit(0)
    }

    /// `Srpski -uiSnapshots <dir> -renderReviewWindow`: a real (never shown) 1200×720 window with the
    /// Study tab in a review, captured with AppKit so buttons and fields draw too.
    static func renderReviewWindowIfRequested(model: AppModel) {
        guard let dir = directory, ProcessInfo.processInfo.arguments.contains("-renderReviewWindow") else { return }
        NSApp.setActivationPolicy(.prohibited)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // Words learned a while ago, now due, both directions.
        let engine = model.engine
        let past = Date.now.addingTimeInterval(-86_400 * 20)
        for note in engine.lessonWords(topic: nil, level: nil, size: 12) {
            guard let card = note.card(.production) else { continue }
            engine.record(card, grade: .easy, now: past) // due about a week later: overdue now
        }
        let session = ReviewSession(model: model)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 720), styleMask: [.titled], backing: .buffered, defer: false)
        let host = NSHostingView(rootView: ReviewView(compact: false, injected: session).environment(model))
        window.contentView = host
        func capture(_ name: String) {
            RunLoop.main.run(until: .now.addingTimeInterval(1.2))
            host.layoutSubtreeIfNeeded()
            guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
            host.cacheDisplay(in: host.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: dir.appending(path: "window-\(name).png"))
        }
        capture("1-home")
        session.showTopic(engine.allNotes().first?.topic)
        capture("1-topic")
        session.startLesson(topic: engine.allNotes().first?.topic)
        capture("1-lesson-words")
        session.hideLessonWords()
        capture("1-lesson-card")
        session.goHome()
        session.startReview()
        capture("2-card")
        if session.card == nil {
            session.goHome()
            session.startLesson(topic: nil)
        }
        session.debugShowRecognition()
        capture("2-reveal")
        session.submit()
        capture("2-revealed")
        session.loadNext()
        // Answer everything, the first one wrong so it comes back.
        var first = true
        while session.screen == .card, session.card != nil {
            if session.stage == .answering {
                session.typed = first ? "xyz" : (session.card?.expected ?? "")
                if session.isClassic { session.submit() } else { session.giveUp() }
                if first { capture("2-wrong") }
                first = false
            }
            if session.stage == .revealed { session.confirm() }
            if session.sessionDone >= session.sessionTotal - 1 { break }
        }
        capture("3-late")
        exit(0)
    }

    /// `Srpski -uiSnapshots <dir> -renderMenuBar`: the menu bar popover with a review due and a
    /// lesson open, in a real, never shown window.
    static func renderMenuBarIfRequested(model: AppModel) {
        guard let dir = directory, ProcessInfo.processInfo.arguments.contains("-renderMenuBar") else { return }
        NSApp.setActivationPolicy(.prohibited)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let engine = model.engine
        func capture(_ name: String) {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 380, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
            let host = NSHostingView(rootView: MenuBarSummary().environment(model))
            window.contentView = host
            window.setContentSize(host.fittingSize)
            RunLoop.main.run(until: .now.addingTimeInterval(1))
            host.layoutSubtreeIfNeeded()
            guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
            host.cacheDisplay(in: host.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: dir.appending(path: "menubar-\(name).png"))
        }
        // The item itself in "Word" and "Word + translation", on a light and a dark bar, and
        // which word it picked (MENUBAR lines on stdout).
        var words = MenuBarWords()
        func bar(_ name: String, now: Date = .now, frozen: Bool = false) {
            let word = words.update(model: model, now: now, frozen: frozen)
            print("MENUBAR \(name): \(word.map { "\($0.serbian) — \($0.russian)" } ?? "icon") · \(model.dueCount(now: now)) due")
            guard let word else { return }
            for shows in [MenuBarShows.word, .wordAndTranslation] {
                for dark in [false, true] {
                    let title = MenuBarShows.title(word, translation: shows == .wordAndTranslation, count: model.dueCount(now: now))
                    let label = NSTextField(labelWithAttributedString: title.text)
                    let size = label.fittingSize
                    let strip = MenuBarStrip(frame: NSRect(x: 0, y: 0, width: size.width + 24, height: 24))
                    strip.dark = dark
                    label.frame = NSRect(x: 12, y: (24 - size.height) / 2, width: size.width, height: size.height)
                    strip.addSubview(label)
                    let window = NSWindow(contentRect: strip.frame, styleMask: [.borderless], backing: .buffered, defer: false)
                    window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                    window.contentView = strip
                    guard let rep = strip.bitmapImageRepForCachingDisplay(in: strip.bounds) else { continue }
                    strip.cacheDisplay(in: strip.bounds, to: rep)
                    try? rep.representation(using: .png, properties: [:])?
                        .write(to: dir.appending(path: "menubar-item-\(name)-\(shows.rawValue)-\(dark ? "dark" : "light").png"))
                }
            }
        }
        capture("1-nothing")
        bar("1-nothing")
        _ = model.startLesson(topic: "Shopping")
        capture("2-lesson")
        // Learned just now: the widget's mix puts them up front.
        for note in engine.lessonWords(topic: "Family", level: nil, size: 3) {
            if let card = note.card(.production) { engine.record(card, grade: .easy) }
        }
        model.didChange()
        bar("2-recent")
        for note in engine.lessonWords(topic: "Food & Drink", level: nil, size: 12) {
            if let card = note.card(.production) { engine.record(card, grade: .again, now: .now.addingTimeInterval(-86_400 * 3)) }
        }
        model.didChange()
        capture("3-due")
        words = MenuBarWords()
        let now = Date.now
        bar("3-due", now: now)
        bar("3-due-1min", now: now.addingTimeInterval(60))
        bar("3-due-frozen", now: now.addingTimeInterval(400), frozen: true)
        bar("3-due-6min", now: now.addingTimeInterval(360))
        bar("3-due-12min", now: now.addingTimeInterval(720))
        // Settings → Which words: the open lesson's; the real settings put back after.
        let saved = UserDefaults.standard.persistentDomain(forName: Bundle.main.bundleIdentifier ?? "") ?? [:]
        UserDefaults.standard.set(WidgetWordSource.lesson.rawValue, forKey: Pref.widgetWords)
        words.reset()
        bar("4-lesson-words", now: now)
        // Settings → Window & shortcuts with a word in the menu bar.
        UserDefaults.standard.set(MenuBarShows.word.rawValue, forKey: Pref.menuBarShows)
        for part in [SettingsCategory.window, .widget] {
            let settings = NSHostingView(rootView: SettingsView(category: part).environment(model))
            let settingsWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
            settingsWindow.contentView = settings
            settingsWindow.setContentSize(settings.fittingSize)
            RunLoop.main.run(until: .now.addingTimeInterval(1))
            settings.layoutSubtreeIfNeeded()
            if let rep = settings.bitmapImageRepForCachingDisplay(in: settings.bounds) {
                settings.cacheDisplay(in: settings.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: dir.appending(path: "menubar-settings-\(part.rawValue).png"))
            }
        }
        for key in [Pref.menuBarShows, Pref.widgetWords] { UserDefaults.standard.set(saved[key], forKey: key) }
        model.recentlyAdded = Array(engine.unstartedNewestFirst().prefix(5).map(\.noteID))
        model.didChange()
        capture("4-chat")
        exit(0)
    }

    /// `Srpski -uiSnapshots <dir> -renderPalette`: the palette trial (Settings → Debug) in a real,
    /// never shown window: home with a review due and a lesson open, then each kind of card.
    static func renderPaletteIfRequested(model: AppModel) {
        guard let dir = directory, ProcessInfo.processInfo.arguments.contains("-renderPalette") else { return }
        NSApp.setActivationPolicy(.prohibited)
        UserDefaults.standard.set(StudyStyle.palette.rawValue, forKey: StudyStyle.key)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let engine = model.engine
        // Missed a few days ago: due now.
        for note in engine.lessonWords(topic: "Food & Drink", level: nil, size: 12) {
            if let card = note.card(.production) { engine.record(card, grade: .again, now: .now.addingTimeInterval(-86_400 * 3)) }
        }
        let session = ReviewSession(model: model)
        session.startLesson(topic: "Shopping")
        if let card = session.card { engine.record(card, grade: .easy) }
        session.goHome()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 760), styleMask: [.titled], backing: .buffered, defer: false)
        let host = NSHostingView(rootView: ReviewView(compact: false, injected: session).environment(model))
        window.contentView = host
        func capture(_ name: String, wait: Double = 1.0) {
            RunLoop.main.run(until: .now.addingTimeInterval(wait))
            host.layoutSubtreeIfNeeded()
            guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
            host.cacheDisplay(in: host.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: dir.appending(path: "palette-\(name).png"))
        }
        capture("01-home")
        // The same home with ⌘ held: the shortcuts cover the subtitles.
        let held = NSHostingView(rootView: PaletteHomeView(session: session, commandHeld: true).environment(model))
        window.contentView = held
        RunLoop.main.run(until: .now.addingTimeInterval(1.0))
        held.layoutSubtreeIfNeeded()
        if let rep = held.bitmapImageRepForCachingDisplay(in: held.bounds) {
            held.cacheDisplay(in: held.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: dir.appending(path: "palette-01-home-command.png"))
        }
        window.contentView = host
        session.startReview()
        session.debugShow(.typed)
        session.showLessonWords()
        capture("01-words")
        session.hideLessonWords()
        capture("02-typed")
        let expected = session.card?.expected ?? ""
        session.typed = String(expected.prefix(3))
        capture("03-typing")
        session.typed = expected
        session.submit()
        capture("04-correct", wait: 0.4)
        session.confirm()
        // Right but for the marks: the first due word that has any.
        for _ in 0..<12 {
            session.debugShow(.typed)
            let word = session.card?.expected ?? ""
            let bare = word.folding(options: .diacriticInsensitive, locale: nil)
            session.typed = bare
            session.submit()
            if bare != word, session.result?.forgaveDiacritics == true {
                capture("04b-diacritics", wait: 0.4)
                session.confirm()
                break
            }
            session.confirm()
        }
        session.debugShow(.typed)
        session.typed = "xyz"
        session.submit()
        capture("05-wrong")
        session.choose(.again)
        RunLoop.main.run(until: .now.addingTimeInterval(0.6))
        // The quick exercises come up in lessons.
        session.continueLesson()
        session.hideLessonWords()
        session.debugShow(.choice)
        capture("06-choice")
        session.pick(option: ((session.exercise?.correctIndex ?? 0) + 1) % 4)
        capture("07-choice-wrong")
        session.confirm()
        session.debugShow(.trueFalse)
        capture("08-true-false")
        session.debugShowRecognition()
        capture("09-reveal")
        session.submit()
        capture("10-revealed")
        session.confirm()
        session.debugShow(.tiles)
        capture("11-tiles")
        while session.screen == .card, session.card != nil {
            if session.stage == .answering {
                session.typed = session.card?.expected ?? ""
                if session.isClassic { session.submit() } else { session.giveUp() }
            }
            if session.stage == .revealed { session.confirm() }
        }
        capture("12-summary")
        // The quick-card shortcut: straight to the next card due, "esc Hide" in the top line.
        session.startQuick()
        capture("13-quick")
        exit(0)
    }

    /// `Srpski -checkAnswerField`: puts the cursor in an offscreen answer field, sets its text from
    /// code (like dictation does) and prints whether the field shows it. Exits 0 on success.
    static func checkAnswerFieldIfRequested() {
        guard ProcessInfo.processInfo.arguments.contains("-checkAnswerField") else { return }
        NSApp.setActivationPolicy(.prohibited)
        let box = TextBox()
        let host = NSHostingView(rootView: AnswerFieldProbe(box: box))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 80), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: .now.addingTimeInterval(0.3))
        guard let field = host.firstDescendant(ofType: NSTextField.self) else { print("CHECK no field"); exit(2) }
        window.makeFirstResponder(field)
        print("CHECK editing:", field.currentEditor() != nil)
        for word in ["novčanik", "kafa"] {
            box.text = word
            RunLoop.main.run(until: .now.addingTimeInterval(0.2))
            let shown = (field.currentEditor() as? NSTextView)?.string ?? field.stringValue
            print("CHECK set \(word) → shows \(shown)")
            if shown != word { exit(1) }
        }
        exit(0)
    }

    private static func press(_ keyCode: Int, _ characters: String, in window: NSWindow) {
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            if let event = NSEvent.keyEvent(
                with: type, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, characters: characters,
                charactersIgnoringModifiers: characters, isARepeat: false, keyCode: UInt16(keyCode)
            ) {
                NSApp.postEvent(event, atStart: false)
            }
        }
    }

    private static func capture(_ window: NSWindow, _ name: String, in dir: URL) {
        guard let view = window.contentView?.superview ?? window.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: dir.appending(path: "\(name).png"))
    }
}
/// A strip of menu bar for the `-renderMenuBar` item snapshots.
private final class MenuBarStrip: NSView {
    var dark = false

    override func draw(_ dirtyRect: NSRect) {
        NSColor(white: dark ? 0.16 : 0.93, alpha: 1).setFill()
        bounds.fill()
    }
}

@Observable
final class TextBox {
    var text = ""
}

private struct AnswerFieldProbe: View {
    let box: TextBox

    var body: some View {
        AnswerField(text: Binding(get: { box.text }, set: { box.text = $0 }), placeholder: "", fontSize: 20, focusRequest: 0, onSubmit: {})
    }
}

private extension NSView {
    func firstDescendant<T: NSView>(ofType type: T.Type) -> T? {
        for sub in subviews {
            if let match = sub as? T ?? sub.firstDescendant(ofType: type) { return match }
        }
        return nil
    }
}
#endif
