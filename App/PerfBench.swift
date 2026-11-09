#if DEBUG && os(macOS)
import AppKit
import SwiftUI
import SrbCore

/// Debug-only perf run on a copy of the deck, to compare builds. The copy has to be under
/// Application Support/Srpski (the sandbox reaches nothing else), made fresh for every run:
/// `sqlite3 Srpski.store ".backup 'perf-bench/run/Srpski.store'"`, an empty `Inbox` beside it, then
/// `SRPSKI_DIR=<…/perf-bench/run> SRPSKI_KIND=typed Srpski -perfBench -autoSpeak NO -pushToTalk YES`
/// with a build that is optimized but keeps the Debug hooks
/// (`-configuration Release SWIFT_ACTIVE_COMPILATION_CONDITIONS=DEBUG`).
/// Never-shown windows, no focus taken; plays a review, the palette, Words, Progress and a
/// minute of idle, then quits. Timings and body counts go to `Documents/perf-bench.log`.
@MainActor
enum PerfBench {
    static var isOn: Bool { ProcessInfo.processInfo.arguments.contains("-perfBench") }

    static func runIfRequested(model: AppModel) {
        guard isOn else { return }
        guard SharedFiles.isTestCopy else { fatalError("-perfBench needs SRPSKI_DIR: it records answers") }
        NSApp.setActivationPolicy(.prohibited)
        let engine = model.engine

        // A dozen words due now, the same ones every run.
        let past = Date.now.addingTimeInterval(-86_400 * 20)
        let learned = engine.allNotes()
            .sorted { $0.answer < $1.answer }
            .compactMap { $0.card(.production) }
            .filter { $0.reps > 0 }
            .prefix(12)
        for card in learned { engine.record(card, grade: .easy, now: past) }
        model.didChange()

        // The main window and the menu bar popover, each with its own session as in the app.
        let session = ReviewSession(model: model)
        let main = window(ReviewView(compact: false, injected: session).environment(model), width: 1000, height: 720)
        let popover = ReviewSession(model: model)
        popover.opensWithWords = false
        let summary = window(MenuBarSummary(session: popover).environment(model), width: 380, height: 420)
        spin(2)
        mark("start")

        // Home: three forced refreshes (the half-minute tick), five popover opens.
        for _ in 0..<3 { session.reloadIfIdle(force: true); spin(0.2) }
        for _ in 0..<5 {
            popover.reloadIfIdle(force: true)
            model.didOpenQuickReview()
            summary.contentView?.needsLayout = true
            summary.contentView?.layoutSubtreeIfNeeded()
            spin(0.2)
        }
        mark("home done")

        // A review of typed cards, typed a letter at a time.
        session.startReview()
        spin(1)
        var answered = 0
        while session.screen == .card, session.card != nil, answered < 10 {
            guard let card = session.card else { break }
            if session.stage == .answering {
                if session.isClassic, card.direction == .production {
                    let answer = answered % 3 == 2 ? "pogrešno" : card.expected
                    mark("typing \(answer.count) letters")
                    for end in answer.indices.dropFirst() + [answer.endIndex] {
                        session.typed = String(answer[..<end])
                        spin(0.06)
                    }
                    mark("typed")
                    if answered == 0 {
                        // Voice: a second of the mic level moving.
                        model.speechInput.debugFake(listening: true, level: 0)
                        for i in 0..<45 {
                            model.speechInput.debugFake(listening: true, level: Float(i % 10) / 10)
                            spin(1.0 / 45)
                        }
                        model.speechInput.debugFake(listening: false, level: 0)
                        mark("voice done (45 levels)")
                    }
                    session.submit()
                } else if session.isClassic {
                    session.submit()
                } else {
                    session.giveUp()
                }
                spin(0.4)
            }
            if session.stage == .revealed {
                if session.showsGradeBar {
                    // The pointer over the grades.
                    mark("revealed")
                    for grade in Grade.allCases + Grade.allCases.reversed() {
                        session.highlight(grade)
                        spin(0.03)
                    }
                    mark("grades hovered (8)")
                    session.choose(.good)
                    spin(0.6)
                } else {
                    spin(1.2)
                    if session.stage == .revealed { session.confirm() }
                }
            }
            answered += 1
            spin(0.5)
        }
        mark("review done: \(answered) cards")
        session.goHome()
        spin(1)

        // The palette look of the same window (the setting is shared with the installed app, so it
        // goes back to what it was).
        let style = UserDefaults.standard.object(forKey: StudyStyle.key)
        UserDefaults.standard.set(StudyStyle.palette.rawValue, forKey: StudyStyle.key)
        spin(1)
        mark("palette home")
        for i in 0..<20 { session.paletteCursor = i % 4; spin(0.03) }
        mark("cursor moved (20)")
        UserDefaults.standard.set(style, forKey: StudyStyle.key)
        spin(0.5)
        mark("palette done")

        // Words and Progress, Progress resized like a window edge dragged.
        let words = window(WordsView().environment(model), width: 1000, height: 720)
        spin(1)
        model.didChange()
        spin(1)
        words.close()
        let progress = window(DashboardView().environment(model), width: 900, height: 720)
        spin(1)
        Perf.measure("bench: resize") {
            for step in 0..<30 {
                progress.setContentSize(NSSize(width: 900 + step * 12, height: 720))
                progress.contentView?.layoutSubtreeIfNeeded()
                spin(0.016)
            }
        }
        progress.close()
        mark("lists done")

        // What one more change to the deck costs with everything open (an answer on the phone).
        model.didChange()
        spin(1)
        mark("change done")
        // An iCloud import landing.
        model.refreshFromICloud()
        spin(1)
        mark("sync done")

        // Idle: the half-minute tick, the publish timer.
        spin(65)
        mark("idle done")
        _ = main
        exit(0)
    }

    private static func mark(_ name: String) {
        Perf.flushCounts()
        Perf.note("bench: \(name)")
    }

    private static func window(_ view: some View, width: CGFloat, height: CGFloat) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: view)
        window.contentView?.layoutSubtreeIfNeeded()
        return window
    }

    private static func spin(_ seconds: Double) {
        RunLoop.main.run(until: .now.addingTimeInterval(seconds))
    }
}
#endif
