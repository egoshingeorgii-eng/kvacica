import AppKit
import SwiftUI
import SrbCore

/// Mac: keyboard first, every action has a key. iPhone: touch, no key hints.
enum Platform {
    static let isTouch = false

    /// The compact card sizes, a little larger on the iPhone than in the Mac's menu bar popover.
    static func card(_ size: CGFloat) -> CGFloat { isTouch ? (size * 1.15).rounded() : size }
}

extension View {
    /// The main action on a screen: Liquid Glass on iOS 26 and later.
    @ViewBuilder
    func prominentButton() -> some View {
        buttonStyle(.borderedProminent)
    }

    /// A secondary action: Liquid Glass on iOS 26 and later.
    @ViewBuilder
    func secondaryButton() -> some View {
        buttonStyle(.bordered)
    }
}

struct ReviewView: View {
    var compact = false
    /// Debug snapshots hand in a session they drive; normally the view makes its own.
    var injected: ReviewSession?
    @Environment(AppModel.self) private var model
    /// Made on the first draw, not in onAppear: an empty first frame left the iPhone's large
    /// "Study" title without a scroll view to follow, so it stayed put on the first scroll.
    @State private var holder = SessionHolder()

    var body: some View {
        let session = injected ?? holder.session(for: model)
        ReviewCardView(session: session, compact: compact)
    }
}

/// Keeps the Study tab's session. A plain class in @State: creating the session on first use
/// doesn't count as a state change, so it can happen while the view is drawn.
@MainActor
final class SessionHolder {
    private var made: ReviewSession?

    func session(for model: AppModel) -> ReviewSession {
        if let made { return made }
        let session = ReviewSession(model: model)
        made = session
        return session
    }
}

private struct ReviewCardView: View {
    @Bindable var session: ReviewSession
    let compact: Bool
    @Environment(AppModel.self) private var model
    @State private var focusRequest = 0
    @Environment(\.showsKeyHints) private var showsKeyHints
    @State private var window = WindowBox()
    @State private var keyMonitor: Any?
    @AppStorage(CardMotion.key) private var motion: CardMotion = .slide
    @AppStorage(CardMotion.speedKey) private var speed: MotionSpeed = .standard
    @AppStorage(StudyStyle.key) private var style: StudyStyle = .cards
    @Environment(\.floatingPanel) private var floatingPanel
    /// The palette trial (Settings → Debug), main window only. The floating panel is always one.
    private var usesPalette: Bool { !compact && (style == .palette || floatingPanel) }
    /// Between home, a topic, the cards and the summary. On the Mac, the transition picked in
    /// Settings → Debug, the same as card to card, so the whole app moves one way.
    private var screenTransition: AnyTransition {
        motion.transition
    }

    private var screenAnimation: Animation {
        speed.animation
    }

    var body: some View {
        // A ZStack, not a VStack: while one screen fades into the next both are on screen, and
        // stacked vertically they'd squeeze each other and jump into place when the old one left.
        // Screens that scroll reach the window's edges and inset their content instead, so it
        // doesn't get clipped short of the edge.
        let inset: CGFloat = compact ? 18 : floatingPanel ? 20 : 36
        let _ = Perf.count(compact ? "popover card" : "card")
        ZStack(alignment: .top) {
            switch session.screen {
            case .home:
                if usesPalette {
                    // The floating panel's home is the panel itself, edge to edge.
                    PaletteHomeView(session: session)
                        .padding(floatingPanel ? 0 : inset)
                        .transition(screenTransition)
                } else {
                    HomeView(session: session, compact: compact, inset: inset)
                        .padding(compact ? inset : 0)
                        .transition(screenTransition)
                }
            case .topic:
                if let preview = session.preview {
                    TopicPreviewView(preview: preview, session: session, compact: compact, inset: inset)
                        .padding([.horizontal, .top], inset)
                        .transition(screenTransition)
                }
            case .picking:
                NewWordsPicker(session: session, compact: compact, inset: inset)
                    .padding([.horizontal, .top], inset)
                    .transition(screenTransition)
            case .lessonWords:
                if usesPalette {
                    PaletteLessonWordsView(session: session)
                        .padding(inset)
                        .transition(screenTransition)
                } else {
                    LessonWordsView(session: session, compact: compact, inset: inset)
                        .padding([.horizontal, .top], inset)
                        .transition(screenTransition)
                }
            case .summary:
                if usesPalette {
                    PaletteSummaryView(session: session)
                        .padding(inset)
                        .transition(screenTransition)
                } else {
                    SummaryView(session: session, compact: compact)
                        .frame(maxHeight: .infinity)
                        .padding(inset)
                        .transition(screenTransition)
                }
            case .caughtUp:
                PaletteCaughtUpView(session: session)
                    .padding(inset)
                    .transition(screenTransition)
            case .card where usesPalette:
                paletteCardScreen
                    .padding(inset)
                    .transition(screenTransition)
            case .card:
                VStack(spacing: compact ? 12 : 20) {
                    sessionHeader
                    // Pinned to the top, not centered: what appears after answering goes below and
                    // nothing above it moves.
                    cardView
                        .padding(.top, compact ? 8 : 40)
                }
                .onAppear { session.paletteCards = false }
                // The popover says nothing about Enter, so Continue is a button you can see.
                .safeAreaInset(edge: .bottom, spacing: 12) {
                    if !showsKeyHints, session.waitsForContinue {
                        Button(action: session.confirm) {
                            Text("Continue").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .keyboardShortcut(.defaultAction)
                    }
                }
                .padding(inset)
                .transition(screenTransition)
            }
        }
        .animation(screenAnimation, value: session.screen)
        .frame(width: compact ? 420 : nil)
        .frame(minHeight: compact ? 380 : nil)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(WindowReader(box: window))
        .onAppear {
            installKeyMonitor()
        }
        .onDisappear(perform: removeKeyMonitor)
        .onChange(of: session.cardToken) {
            focusAnswer()
            PointerGate.reset()
        }
        .onChange(of: session.screen) { PointerGate.reset() }
        .onChange(of: session.showingLessonWords) { _, showing in
            if !showing { focusAnswer() }
        }
        .onChange(of: model.quickOpenCount) {
            // The popover's own cards; the main window's home doesn't need redoing for it.
            guard compact else { return }
            session.reloadIfIdle(force: true)
            focusAnswer()
        }
        .onAppear(perform: takeLessonFromMenuBar)
        .onChange(of: model.windowRequest) { takeLessonFromMenuBar() }
        .onChange(of: model.revision) { session.reloadIfIdle() }
        .task { await refreshWhileOnScreen() }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didChangeOcclusionStateNotification)) { note in
            // Back on screen after a while away: catch up at once.
            if let shown = window.window, note.object as? NSWindow === shown, isOnScreen {
                session.reloadIfIdle(force: true)
            }
        }
    }

    /// Every half minute (learning cards come due), only while the window is on screen: the Mac's
    /// window lives all day behind other apps or put away, and home was worked out for nobody.
    private func refreshWhileOnScreen() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(30))
            if !Task.isCancelled, isOnScreen { session.reloadIfIdle(force: true) }
        }
    }

    private var isOnScreen: Bool {
        window.window?.occlusionState.contains(.visible) ?? false
    }

    /// A row in the menu bar: the window goes on with the open lesson, or starts the review.
    private func takeLessonFromMenuBar() {
        guard !compact, let request = model.windowRequest else { return }
        model.windowRequest = nil
        switch request {
        case .lesson:
            guard session.mode != .lesson else { return }
            if session.mode != .home { session.goHome() }
            session.continueLesson()
        case .review:
            guard session.mode != .review else { return }
            if session.mode != .home { session.goHome() }
            session.startReview()
        case .elsewhere(let device):
            if session.mode != .home { session.goHome() }
            guard let other = session.lessonsElsewhere.first(where: { $0.device == device }) else { return }
            session.continueLesson(other)
        case .chatWords:
            if session.mode != .home { session.goHome() }
            session.showNewWords(only: session.newWordsToLearn)
        }
    }

    // MARK: Parts

    /// Where you are and how far along: "Lesson · Shopping   7 of 10".
    private var sessionHeader: some View {
        HStack(spacing: 12) {
            Button(action: session.goHome) {
                HStack(spacing: 6) {
                    KeyCap(key: "esc")
                    if Platform.isTouch { Image(systemName: "chevron.left") }
                    Text(compact ? "Back" : "Back to home")
                }
            }
            .buttonStyle(.plain)
            .help(session.mode == .lesson ? "Leave this lesson (it stays open to continue later)" : "Leave this review")
            Spacer()
            Text(session.sessionTitle)
                .font(compact ? .callout.weight(.semibold) : .headline)
                .foregroundStyle(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Spacer()
            Button(action: session.showLessonWords) {
                if compact || Platform.isTouch {
                    Image(systemName: "list.bullet")
                } else {
                    Label("Words", systemImage: "list.bullet")
                }
            }
            .buttonStyle(.plain)
            .help(session.mode == .lesson ? "The words in this lesson" : "The words in this review")
            if session.sessionTotal > 0 {
                Text("\(session.sessionDone) of \(session.sessionTotal)")
                    .monospacedDigit()
                    .contentTransition(.numericText())
                ProgressView(value: Double(session.sessionDone), total: Double(session.sessionTotal))
                    .frame(width: compact ? 50 : 100)
            }
        }
        .font(compact ? .callout : .body)
        .foregroundStyle(.secondary)
        .animation(.snappy, value: session.sessionDone)
        .help(session.mode == .lesson
              ? "Words in this lesson that got through their quick repeats (after 1 and 10 minutes)."
              : "Words reviewed out of those that were due.")
    }

    /// Old card fades out quickly, the new one fades in: no jumping between exercise layouts.
    /// The card fills the space below the header from the top, so the feedback after an answer
    /// never moves what's above it. Cards slide in and out; a mistake shakes the card.
    /// iPhone: every card starts at the same height, so the prompt stays put from one exercise to
    /// the next and what appears after answering grows downward. That height is a typed card
    /// centered in the space the keyboard leaves free; it doesn't change while the keyboard is up
    /// or away, so nothing moves when it comes and goes.
    private var cardView: some View {
        ZStack(alignment: .top) {
            cardContent
                .id(session.cardToken)
                .transition(motion.transition)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(speed.animation, value: session.cardToken)
    }

    /// Keep the hidden field mounted after a right answer so the box keeps its height until the
    /// next card. The answer field releases focus as soon as it becomes read-only.
    private var keepsAnswerField: Bool {
        Platform.isTouch && session.result?.verdict == .correct
    }

    @ViewBuilder
    private var cardContent: some View {
        if let card = session.card {
            VStack(spacing: compact ? 12 : 18) {
                if session.isClassic {
                    // Same top as every exercise: instruction line, then the word, same size and place.
                    ExerciseInstruction(text: session.instruction(for: card.direction), compact: compact)
                    // iPhone: a recall card's prompt is the Serbian word, so the speaker sits beside it.
                    CardPrompt(text: card.prompt, sentence: session.exercise?.sentence, context: session.exercise?.context, revealed: session.stage == .revealed,
                               compact: compact, speak: promptSpeaker(for: card))

                    // The answer box and the line under it keep their size and place from answering
                    // to the result: the field turns into your answer, the hint into the verdict.
                    // Everything else appears below them, so nothing above ever moves.
                    answerBox(for: card)
                    statusLine(for: card)
                        .frame(height: 26)
                    if session.stage == .revealed {
                        details(card)
                    }
                } else if let face = session.exerciseFace {
                    ExerciseView(session: session, face: face, compact: compact)
                }
            }
            .frame(maxWidth: 560)
        }
    }

    private func promptSpeaker(for card: StudyCard) -> (() -> Void)? {
        guard Platform.isTouch, card.direction == .recognition, session.canSpeak else { return nil }
        return { session.speak() }
    }

    private var touchSpeaker: (() -> Void)? {
        Platform.isTouch && session.canSpeak ? { session.speak() } : nil
    }

    private var boxHeight: CGFloat { compact ? Platform.card(44) : 54 }

    /// While answering: the answer field (or "Enter to reveal"). After: what you typed, in green,
    /// orange or red, or the meaning for a recall card. Same box, same size.
    @ViewBuilder
    private func answerBox(for card: StudyCard) -> some View {
        let tint = boxTint
        let answering = session.stage == .answering
        Group {
            let shown = answering ? nil : shownInField(fontSize: compact ? Platform.card(20) : 26)
            if card.direction == .production, answering || keepsAnswerField || shown != nil {
                SessionAnswerField(
                    session: session,
                    placeholder: String(localized: "Say it out loud or type it"),
                    fontSize: compact ? Platform.card(20) : 26,
                    focusRequest: focusRequest,
                    readOnly: !answering,
                    shown: shown,
                    onSubmit: answering ? session.submit : session.confirm
                )
                .onAppear { focusAnswer() }
                .opacity(answering || shown != nil ? 1 : 0)
                .overlay {
                    if !answering, shown == nil { answerResult(for: card) }
                }
            } else if answering {
                // The whole box is the button: click where the meaning will appear.
                Text(Platform.isTouch ? "Tap to reveal" : showsKeyHints ? "Enter or click to reveal" : "Click to reveal")
                    .font(.system(size: compact ? Platform.card(17) : 20))
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(.horizontal, -44)
                    .contentShape(Rectangle())
                    .onTapGesture(perform: session.submit)
                    .linkCursor()
                    .background(KeyOnlyButton(title: String(localized: "Reveal"), action: session.submit))
            } else {
                answerResult(for: card)
            }
        }
        .lineLimit(1)
        .minimumScaleFactor(0.6)
        .padding(.horizontal, 44)
        .frame(maxWidth: .infinity)
        .frame(height: boxHeight)
        // The Mac's verdict looks like its ne / da tiles.
        .background(RoundedRectangle(cornerRadius: 10).fill(tint?.opacity(Platform.isTouch ? 0.1 : 0.14) ?? Color.primary.opacity(0.06)))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(tint ?? Color.accentColor, lineWidth: tint != nil && !Platform.isTouch ? 2 : 1.5)
                .opacity(tint != nil || session.isListening ? (tint != nil ? 0.7 : 0.5) : 0)
        )
        .overlay(alignment: .trailing) {
            if session.stage == .answering, card.direction == .production, session.canDictate {
                Button(action: session.toggleDictation) {
                    Group {
                        if session.isListening {
                            VoiceLevelBars(input: model.speechInput)
                        } else {
                            Image(systemName: "mic")
                                .font(.system(size: compact ? Platform.card(15) : 18))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .keyboardShortcut("d", modifiers: .command)
                .help(session.isListening ? "Check now (Tab)" : "Say it (Tab)")
                .padding(.trailing, 8)
            }
        }
        .animation(.easeOut(duration: 0.2), value: session.isListening)
        .animation(.easeOut(duration: 0.2), value: session.stage)
    }

    /// After answering: what you typed, colored by the verdict, or the meaning for a recall card.
    @ViewBuilder
    private func answerResult(for card: StudyCard) -> some View {
        if let result = session.result {
            let typed = session.typed.trimmingCharacters(in: .whitespaces)
            if result.verdict == .correct {
                // The field's weight: a bolder word got wider and looked like it jumped.
                // The letters fixed for you (diacritics) only change color: a line under a right
                // answer made it look marked wrong.
                DiffText(pieces: result.correct, color: .orange, font: .system(size: compact ? Platform.card(20) : 26), underlined: false)
                    .foregroundStyle(Color.green)
            } else if typed.isEmpty {
                Text("No answer")
                    .font(.system(size: compact ? Platform.card(17) : 20))
                    .foregroundStyle(.tertiary)
            } else if result.verdict == .wrong {
                // Nothing in common worth marking letter by letter: just cross it out.
                Text(typed)
                    .font(.system(size: compact ? Platform.card(20) : 26))
                    .foregroundStyle(.red)
                    .strikethrough(color: .red.opacity(0.5))
            } else {
                DiffText(pieces: result.typed, color: .red, font: .system(size: compact ? Platform.card(20) : 26))
            }
        } else {
            Text(card.expected)
                .font(.system(size: compact ? Platform.card(20) : 26, weight: .semibold))
        }
    }

    /// The Mac's answer field keeps showing your answer after Check, in the verdict's colors (the
    /// same as `answerResult`), so the word stays exactly where it was typed. Nil: no answer.
    private func shownInField(fontSize: CGFloat) -> NSAttributedString? {
        guard let result = session.result else { return nil }
        let typed = session.typed.trimmingCharacters(in: .whitespaces)
        guard !typed.isEmpty else { return nil }
        let center = NSMutableParagraphStyle()
        center.alignment = .center
        let base: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: fontSize), .paragraphStyle: center]
        func pieces(_ pieces: [DiffPiece], text: NSColor, marks: NSColor, underlined: Bool = true) -> NSAttributedString {
            let out = NSMutableAttributedString()
            for piece in pieces {
                var attributes = base
                attributes[.foregroundColor] = piece.kind == .wrong ? marks : text
                if piece.kind == .wrong, underlined {
                    attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
                    attributes[.underlineColor] = marks.withAlphaComponent(0.8)
                }
                out.append(NSAttributedString(string: piece.text, attributes: attributes))
            }
            return out
        }
        switch result.verdict {
        case .correct:
            return pieces(result.correct, text: .systemGreen, marks: .systemOrange, underlined: false)
        case .almost:
            return pieces(result.typed, text: .labelColor, marks: .systemRed)
        case .wrong:
            var attributes = base
            attributes[.foregroundColor] = NSColor.systemRed
            attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
            attributes[.strikethroughColor] = NSColor.systemRed.withAlphaComponent(0.5)
            return NSAttributedString(string: typed, attributes: attributes)
        }
    }

    private var boxTint: Color? {
        guard session.stage == .revealed, let verdict = session.result?.verdict else { return nil }
        return switch verdict {
        case .correct: .green
        case .almost: .orange
        case .wrong: .red
        }
    }

    /// Under the box: how to answer, then the verdict in the same spot.
    @ViewBuilder
    private func statusLine(for card: StudyCard) -> some View {
        if session.stage == .answering {
            Text(card.direction == .production ? answerHint : String(localized: "Recall the Russian meaning"))
                .font(.callout)
                .foregroundStyle(.secondary)
        } else if let result = session.result {
            VerdictBadge(verdict: result.verdict, forgaveDiacritics: result.forgaveDiacritics)
        } else {
            Color.clear
        }
    }

    private var answerHint: String {
        if session.isListening { return String(localized: "Listening… pause when you're done") }
        if Platform.isTouch {
            return session.canDictate ? String(localized: "Tap the mic and say it · or type it") : String(localized: "Type it and tap Return")
        }
        guard showsKeyHints else {
            return session.canDictate ? String(localized: "Type it · or click the mic and say it") : String(localized: "Type it")
        }
        guard session.canDictate else { return String(localized: "Type it · Enter to check") }
        return String(localized: "Tab to say it · or type it and press Enter")
    }

    /// After answering, below the verdict: the right answer when yours wasn't, notes, grades.
    @ViewBuilder
    private func details(_ card: StudyCard) -> some View {
        VStack(spacing: compact ? 8 : 12) {
            if let result = session.result, result.verdict != .correct {
                SpeakerBeside(speak: touchSpeaker) {
                    if result.verdict == .almost {
                        DiffText(pieces: result.correct, color: .orange, font: .system(size: compact ? Platform.card(24) : 32, weight: .semibold))
                    } else {
                        Text(result.expected)
                            .font(.system(size: compact ? Platform.card(24) : 32, weight: .semibold))
                            .multilineTextAlignment(.center)
                    }
                }
            }
            if let result = session.result, let note = card.note, result.expected != note.answer {
                Text("Main answer: \(note.answer)").font(.callout).foregroundStyle(.secondary)
            }
            if let note = card.note, card.direction == .production, !note.accept.isEmpty {
                Text("Also accepted: \(note.accept.joined(separator: ", "))")
                    .font(.callout).foregroundStyle(.secondary)
            }
            if let info = card.note?.info, !info.isEmpty {
                NoteInfoView(info: info, compact: compact)
            }
            // A form was asked: the whole table, that form in color.
            if let tag = session.exercise?.formTag, let note = card.note {
                if session.result?.verdict != .correct {
                    FormMistakeNote(note: note, tag: tag, given: session.typed,
                                    showsRule: session.exercise?.sentence?.rule == nil, compact: compact)
                }
                FormsTableView(note: note, highlight: tag, compact: compact)
            }
            if session.canSpeak, !Platform.isTouch {
                Button { session.speak() } label: {
                    Label(showsKeyHints ? "Listen  ␣" : "Listen", systemImage: "speaker.wave.2.fill")
                }
                .cardAction(mac: .borderless)
                .font(.callout)
            }

            if session.showsGradeBar {
                SessionGradeBar(session: session, compact: compact, showsKeyHints: showsKeyHints)
            }
            if !Platform.isTouch, session.result?.forgaveDiacritics == true {
                // Right but for the diacritics: it waits for you.
                ContinueButton(action: session.confirm)
            } else {
                KeyOnlyButton(title: String(localized: "Continue"), action: session.confirm)
            }
        }
        .transition(.opacity)
    }

    // MARK: Keyboard

    private func focusAnswer() {
        if session.stage == .answering { focusRequest += 1 }
    }

    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        let window = window
        let session = session
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { event in
            guard let target = window.window, event.window === target, target.isKeyWindow else { return event }
            return session.handleKey(event) ? nil : event
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }
}

// MARK: - Pieces

struct VerdictBadge: View {
    let verdict: Verdict
    let forgaveDiacritics: Bool

    var body: some View {
        let (title, color): (String, Color) = switch verdict {
        case .correct where forgaveDiacritics: (String(localized: "Correct · mind the diacritics"), .green)
        case .correct: (String(localized: "Correct"), .green)
        case .almost: (String(localized: "Almost — check the letters"), .orange)
        case .wrong: (String(localized: "Not quite"), .red)
        }
        HStack(spacing: 6) {
            Image(systemName: verdict == .correct ? "checkmark.circle.fill" : verdict == .almost ? "exclamationmark.circle.fill" : "xmark.circle.fill")
            Text(title)
        }
        .font(.callout.weight(.semibold))
        .foregroundStyle(color)
        .padding(.horizontal, 10)
        .padding(.vertical, 3)
        .background(Capsule().fill(color.opacity(0.14)))
        // One piece, one motion: the badge grows in from its middle. The capsule fading while
        // the icon popped on its own looked like two things arriving at different times.
        .badgeIn()
    }
}

/// Text with the mismatched letters in `color`. With `underlined`, a line under them too, drawn
/// whole: Text's own underline skipped the descenders and, with a tinted box behind each run,
/// looked torn and smudged under a right answer's fixed letters.
struct DiffText: View {
    let pieces: [DiffPiece]
    let color: Color
    let font: Font
    var underlined = true

    var body: some View {
        if #available(iOS 18, macOS 15, *), underlined {
            markedText
                .font(font)
                .multilineTextAlignment(.center)
                .textRenderer(DiffLine(color: color))
                .textSelection(.enabled)
        } else {
            Text(attributed)
                .font(font)
                .multilineTextAlignment(.center)
                .textSelection(.enabled)
        }
    }

    @available(iOS 18, macOS 15, *)
    private var markedText: Text {
        pieces.reduce(Text(verbatim: "")) { text, piece in
            let part = Text(verbatim: piece.text)
            return piece.kind == .wrong ? Text("\(text)\(part.foregroundStyle(color).customAttribute(DiffRun()))") : Text("\(text)\(part)")
        }
    }

    private var attributed: AttributedString {
        var result = AttributedString()
        for piece in pieces {
            var part = AttributedString(piece.text)
            if piece.kind == .wrong { part.foregroundColor = color }
            result += part
        }
        return result
    }
}

/// Marks the letters a `DiffText` points out.
private struct DiffRun: TextAttribute {}

/// Draws the text, and one even line under each run marked `DiffRun`, through the descenders.
@available(iOS 18, macOS 15, *)
private struct DiffLine: TextRenderer {
    let color: Color

    func draw(layout: Text.Layout, in context: inout GraphicsContext) {
        for line in layout {
            for run in line {
                context.draw(run)
                guard run[DiffRun.self] != nil else { continue }
                let bounds = run.typographicBounds
                let thickness = max(1.5, (bounds.ascent / 14).rounded())
                let rect = CGRect(x: bounds.rect.minX + 1, y: bounds.origin.y + bounds.descent * 0.45,
                                  width: max(0, bounds.width - 2), height: thickness)
                context.fill(Path(roundedRect: rect, cornerRadius: thickness / 2), with: .color(color.opacity(0.8)))
            }
        }
    }
}

struct GradeBar: View {
    let selected: Grade
    /// The 1–4 before each grade; off where key hints are.
    var showsKeys = true
    let choose: (Grade) -> Void

    var body: some View {
        HStack(spacing: 8) {
            ForEach(Grade.allCases, id: \.self) { grade in
                Button {
                    choose(grade)
                } label: {
                    HStack(spacing: 6) {
                        if !Platform.isTouch, showsKeys {
                            Text(verbatim: "\(grade.rawValue)").foregroundStyle(.secondary)
                        }
                        Text(grade.title)
                    }
                    .font(.callout)
                    .frame(width: 84, height: 32)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(selected == grade ? grade.color.opacity(0.22) : Color.primary.opacity(0.05))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(selected == grade ? grade.color : .clear, lineWidth: 1.5)
                    )
                }
                .buttonStyle(.plain)
                .help(grade.meaning)
                .keyboardShortcut(KeyEquivalent(Character("\(grade.rawValue)")), modifiers: [])
            }
        }
        .animation(.spring(duration: 0.22, bounce: 0.4), value: selected)
    }
}

/// Invisible Return-key fallback in case the window's key monitor didn't take the event.
extension View {
    /// The pointing hand over something clickable that doesn't look like a button.
    @ViewBuilder func linkCursor() -> some View {
        if #available(macOS 15, *) { pointerStyle(.link) } else { self }
    }
}

struct KeyOnlyButton: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(title, action: action)
            .keyboardShortcut(.defaultAction)
            .opacity(0)
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
    }
}

/// After a missed exercise: Enter on the Mac ("Enter to continue"). The iPhone has its Continue
/// pinned at the bottom of the screen instead (see ReviewCardView), so nothing here.
struct ContinueButton: View {
    let action: () -> Void
    @Environment(\.showsKeyHints) private var showsKeyHints

    /// Without key hints, Continue is a button pinned at the bottom instead, like the iPhone's.
    var body: some View {
        if !Platform.isTouch, showsKeyHints {
            Text("Enter to continue")
                .font(.callout)
                .foregroundStyle(.tertiary)
            KeyOnlyButton(title: String(localized: "Continue"), action: action)
        }
    }
}

extension Grade {
    /// How to pick a grade, per FSRS: only Again counts as forgetting.
    var meaning: String {
        switch self {
        case .again: String(localized: "Again: didn't know it")
        case .hard: String(localized: "Hard: knew it, with real effort")
        case .good: String(localized: "Good: knew it")
        case .easy: String(localized: "Easy: knew it instantly")
        }
    }

    var color: Color {
        switch self {
        case .again: .red
        case .hard: .orange
        case .good: .green
        case .easy: .blue
        }
    }
}

/// Five bars that follow the microphone level, with a gentle ripple so they never look frozen.
/// The grades with the picked one, reading it themselves: picking one with the arrows redrew
/// the whole card.
private struct SessionGradeBar: View {
    let session: ReviewSession
    let compact: Bool
    let showsKeyHints: Bool

    var body: some View {
        GradeBar(selected: session.selectedGrade, showsKeys: showsKeyHints, choose: session.choose)
            .padding(.top, compact ? 4 : 10)
        if !Platform.isTouch, showsKeyHints {
            Text("1–4 to grade · Enter: \(session.selectedGrade.title)")
                .font(.callout)
                .foregroundStyle(.tertiary)
        }
    }
}

/// The card's rows, worked out in a view of their own: the pointer over a grade or an arrow key
/// redraws them, not the whole card.
private struct PaletteRowList: View {
    /// Between the answer field and the rows; the options alone need no line on top.
    let divider: Bool
    let rows: () -> [PaletteRow]

    var body: some View {
        let rows = rows()
        if !rows.isEmpty {
            VStack(spacing: 0) {
                if divider { Divider() }
                VStack(spacing: 2) {
                    // By title: a row that changes meaning (Check → a grade) is a new row,
                    // not the old one fading into the new text.
                    ForEach(rows, id: \.title) { $0 }
                }
                .padding(8)
            }
        }
    }
}

/// The answer field, reading what's typed itself: read by the card screen (through the field's
/// binding), every keystroke drew the whole screen again.
private struct SessionAnswerField: View {
    @Bindable var session: ReviewSession
    let placeholder: String
    let fontSize: CGFloat
    let focusRequest: Int
    let readOnly: Bool
    var shown: NSAttributedString? = nil
    let onSubmit: () -> Void

    var body: some View {
        AnswerField(text: $session.typed, placeholder: placeholder, fontSize: fontSize,
                    focusRequest: focusRequest, readOnly: readOnly, shown: shown, onSubmit: onSubmit)
    }
}

/// Reads the mic level itself: read by the card screen, the whole screen drew again for every
/// level, about 45 times a second while listening.
private struct VoiceLevelBars: View {
    let input: SpeechInput
    private let shape: [CGFloat] = [0.55, 0.8, 1, 0.8, 0.55]

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30)) { context in
            let time = context.date.timeIntervalSinceReferenceDate
            let level = input.level
            HStack(spacing: 2.5) {
                ForEach(shape.indices, id: \.self) { i in
                    let ripple = 0.5 + 0.5 * sin(time * 8 + Double(i) * 1.2)
                    Capsule()
                        .frame(width: 3, height: 4 + CGFloat(level) * 16 * shape[i] * (0.6 + 0.4 * ripple))
                }
            }
            .foregroundStyle(Color.accentColor)
        }
    }
}

// MARK: - Window lookup

/// Lets the key monitor react only to events in its own window.
final class WindowBox {
    weak var window: NSWindow?
}

struct WindowReader: NSViewRepresentable {
    let box: WindowBox

    func makeNSView(context: Context) -> NSView {
        let view = TrackingView()
        view.box = box
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class TrackingView: NSView {
        var box: WindowBox?
        /// Clicks go through, to the floating panel's backdrop (it moves the panel).
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            box?.window = window
        }
    }
}

// MARK: - Palette trial

extension ReviewCardView {
    /// A card in the palette's shape: the word as a two-tone headline, the answer field at the top
    /// of the panel, and everything you can do with the card as rows with their keys. Same top
    /// line, headline height and panel place as the palette home, so nothing jumps between them.
    var paletteCardScreen: some View {
        VStack(alignment: .leading, spacing: PaletteLayout.gap) {
            PaletteTopLine {
                // Quick cards: Esc puts the panel away and the card waits for the next shortcut.
                Button(action: session.quick ? session.putAway : session.goHome) {
                    HStack(spacing: 6) {
                        KeyCap(key: "esc")
                        Text(session.quick ? "Hide" : "Back")
                    }
                }
                .buttonStyle(.plain)
            } center: {
                // Where you are instead of what this is: the bar, and the count beside it.
                HStack(spacing: 10) {
                    PaletteProgress(done: session.sessionDone, total: session.sessionTotal,
                                    tint: session.mode == .lesson ? .green : .accentColor)
                        .frame(width: 200)
                    Text(verbatim: "\(session.sessionDone)/\(session.sessionTotal)")
                        .monospacedDigit()
                        .contentTransition(.numericText())
                        .frame(width: 44, alignment: .leading)
                }
                .help(session.sessionTitle)
                .animation(.snappy, value: session.sessionDone)
            } trailing: {
                Button(action: session.showLessonWords) {
                    HStack(spacing: 6) {
                        KeyCap(key: "⌘L")
                        Text("Words")
                    }
                }
                .buttonStyle(.plain)
                .keyboardShortcut("l", modifiers: .command)
                .help(session.mode == .lesson ? "The words in this lesson" : "The words in this review")
            }
            if floatingPanel {
                paletteCardScroller
            } else {
                paletteCardStack
                    .frame(maxHeight: .infinity, alignment: .top)
            }
        }
        .frame(width: PaletteLayout.width)
        .padding(.top, PaletteLayout.top)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        // Set on appearing only, by both card screens: an onDisappear (the panel put away, a screen
        // fading out after the next one came in) left it off under a palette card, and a right
        // answer with the diacritics off moved on before its hint could be read.
        .onAppear { session.paletteCards = true }
    }

    private var paletteCardStack: some View {
        ZStack(alignment: .top) {
            paletteCard
                .id(session.cardToken)
                .transition(motion.transition)
        }
        .animation(speed.animation, value: session.cardToken)
    }

    /// The floating panel is shorter than a card with its details (a missed verb and its table):
    /// the card scrolls under the top line, back to the top for every new card. Wider than the
    /// column it sits in, so a card sliding in or out isn't cut at the column's edges.
    private var paletteCardScroller: some View {
        let overhang: CGFloat = 30
        return ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 0) {
                    Color.clear.frame(height: 0).id("card top")
                    paletteCardStack
                        // Room for the panel's shadow under the last line.
                        .padding(.bottom, 24)
                }
                .padding(.horizontal, overhang)
            }
            .padding(.horizontal, -overhang)
            .scrollIndicators(.automatic)
            .onChange(of: session.cardToken) { proxy.scrollTo("card top", anchor: .top) }
        }
    }

    @ViewBuilder
    private var paletteCard: some View {
        if let card = session.card {
            let face = session.exerciseFace
            let kind = session.exerciseKind
            VStack(alignment: .leading, spacing: PaletteLayout.gap) {
                if let face, kind == .trueFalse {
                    // Like the iPhone: the word, "means", and the translation to judge.
                    let statement = face.exercise.statement ?? face.exercise.target
                    PaletteStatement(serbian: statement.serbian, russian: statement.russian)
                } else if let context = session.exercise?.context {
                    // The word in its sentence; the sentence's meaning comes with the answer.
                    PaletteHeadline(styled: ContextPrompt.highlighted(context),
                                    second: session.stage == .revealed ? context.russian : String(localized: "What does the word mean here?"))
                } else {
                    let (first, second) = paletteHeadline(card, face: face)
                    PaletteHeadline(first: first, second: second)
                }
                PalettePanel {
                    if session.isClassic {
                        answerBox(for: card)
                            .padding(14)
                    } else if let face, kind == .trueFalse {
                        HStack(spacing: 10) {
                            YesNoTile(title: "ne", subtitle: String(localized: "No, wrong"), left: true, look: yesNoLook(false, face: face),
                                      onPick: pickRow(0, face: face)) { session.answer(yes: false) }
                            YesNoTile(title: "da", subtitle: String(localized: "Yes, right"), left: false, look: yesNoLook(true, face: face),
                                      onPick: pickRow(1, face: face)) { session.answer(yes: true) }
                        }
                        .padding([.horizontal, .top], 14)
                    } else if let face, kind == .tiles || kind == .match {
                        ExerciseView(session: session, face: face, compact: false, showsPrompt: false)
                            .padding(18)
                    }
                    PaletteRowList(divider: session.isClassic) { paletteRows(card, face: face) }
                    // After answering, below the rows so nothing above them moves, centered like
                    // the answer: the right answer when yours wasn't, other accepted forms, the note.
                    if session.stage == .revealed {
                        if session.isClassic {
                            paletteDetails(card)
                        } else if let face, face.exerciseCorrect == false, kind == .choice || kind == .trueFalse {
                            Divider()
                            ExerciseFeedback(session: session, face: face, exercise: face.exercise, card: card, compact: false)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 14)
                        }
                    }
                }
            }
        }
    }

    /// The headline never changes after answering: the verdict is in the field and the rows.
    private func paletteHeadline(_ card: StudyCard, face: ExerciseFace?) -> (String, String?) {
        let kind = session.exerciseKind
        // Fill in the word: the sentence with its gap, and what it means.
        if let sentence = (face?.exercise ?? session.exercise)?.sentence {
            return (sentence.blanked(), sentence.russian)
        }
        if let exercise = face?.exercise {
            switch kind {
            case .choice:
                return (card.direction == .production ? exercise.target.russian : exercise.target.serbian,
                        kind.title(for: card.direction))
            case .trueFalse:
                let statement = exercise.statement ?? exercise.target
                return (statement.serbian, String(localized: "means “\(statement.russian)”. Right?"))
            case .tiles:
                return (exercise.target.russian, String(localized: "Spell it in Serbian."))
            case .match:
                return (String(localized: "Match the pairs."), String(localized: "A word’s number, then its translation’s."))
            default: break
            }
        }
        let title = kind.title(for: card.direction)
        return (card.prompt, title.hasSuffix("?") ? title : title + ".")
    }

    /// What you can do with the card right now. The first row is what Return does.
    private func paletteRows(_ card: StudyCard, face: ExerciseFace?) -> [PaletteRow] {
        let answering = session.stage == .answering
        // No Back or Say-it rows: esc is in the top line, Tab and the mic are on the field.
        switch session.exerciseKind {
        case .typed, .reveal:
            if answering {
                if card.direction == .production {
                    return [PaletteRow(symbol: nil, title: session.isListening ? String(localized: "Check now") : String(localized: "Check"),
                                       key: "↩", look: .selected, centered: true, onPick: {}, action: session.submit)]
                }
                return [PaletteRow(symbol: nil, title: String(localized: "Show the meaning"), key: "↩", look: .selected, centered: true, onPick: {}, action: session.submit)]
            }
            if let result = session.result, result.verdict == .correct {
                // Only the diacritics off: it waits, so the fixed letters can be read.
                if result.forgaveDiacritics {
                    return [PaletteRow(symbol: nil, title: String(localized: "Continue"), key: "↩", look: .selected, centered: true, onPick: {}, action: session.confirm)]
                }
                // Right: the same row stays (it moves on by itself).
                return [PaletteRow(symbol: nil, title: String(localized: "Check"), key: "↩", look: .selected, centered: true, onPick: {}, action: session.confirm)]
            }
            if session.showsGradeBar {
                return Grade.allCases.map { grade in
                    PaletteRow(symbol: nil, title: grade.title, subtitle: grade.meaning.components(separatedBy: ": ").last,
                               key: "\(grade.rawValue)", look: session.selectedGrade == grade ? .selected : .normal,
                               onPick: { session.highlight(grade) }) {
                        session.choose(grade)
                    }
                }
            }
            return [PaletteRow(symbol: nil, title: String(localized: "Next card"), key: "↩", look: .selected, centered: true, onPick: {}, action: session.confirm)]
        case .choice:
            guard let face else { return [] }
            let exercise = face.exercise
            var rows = exercise.options.indices.map { i in
                PaletteRow(symbol: nil, title: exercise.options[i], key: "\(i + 1)", look: optionLook(i, face: face),
                           onPick: pickRow(i, face: face)) {
                    session.pick(option: i)
                }
            }
            rows.append(PaletteRow(symbol: "questionmark", tint: .secondary, title: String(localized: "Don’t know"), key: "⌫",
                                   look: cursorLook(exercise.options.count, face: face),
                                   onPick: pickRow(exercise.options.count, face: face), action: session.giveUp))
            return rows
        case .trueFalse:
            // ne and da are the tiles above; only Don't know is a row.
            guard let face else { return [] }
            return [PaletteRow(symbol: "questionmark", tint: .secondary, title: String(localized: "Don’t know"), key: "⌫",
                               look: cursorLook(2, face: face), onPick: pickRow(2, face: face), action: session.giveUp)]
        case .tiles, .match:
            return []
        }
    }

    /// While answering, the row under the arrows or the pointer is the picked one; after, nothing is.
    private func cursorLook(_ index: Int, face: ExerciseFace) -> PaletteRow.Look {
        face.stage == .answering && session.paletteCursor == index ? .selected : .normal
    }

    private func pickRow(_ index: Int, face: ExerciseFace) -> () -> Void {
        { if face.stage == .answering, session.paletteCursor != index { session.paletteCursor = index } }
    }

    private func optionLook(_ index: Int, face: ExerciseFace) -> PaletteRow.Look {
        guard face.stage == .revealed else { return cursorLook(index, face: face) }
        if index == face.exercise.correctIndex { return .right }
        return index == face.pickedOption ? .wrong : .normal
    }

    private func yesNoLook(_ yes: Bool, face: ExerciseFace) -> YesNoTile.Look {
        guard face.stage == .revealed else { return session.paletteCursor == (yes ? 1 : 0) ? .selected : .normal }
        if yes == face.exercise.statementIsTrue { return .right }
        // The other one keeps its look, like on the iPhone.
        return face.pickedOption == (yes ? 1 : 0) ? .wrong : .normal
    }

    /// Under the panel after answering: the right answer when yours wasn't, and the note.
    @ViewBuilder
    private func paletteDetails(_ card: StudyCard) -> some View {
        let fold = { (text: String) in
            text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let typed = fold(session.typed)
        let wrong = session.result.map { $0.verdict != .correct } ?? false
        let diacritics = session.result.map { $0.verdict == .correct && $0.forgaveDiacritics } ?? false
        // A clean right answer moves on by itself: nothing appears under it, nothing moves.
        let quiet = session.result?.verdict == .correct && !diacritics
        // What you typed is no news: only the other forms.
        let others = quiet ? [] : (card.direction == .production ? card.note?.accept ?? [] : [])
            .filter { fold($0) != typed }
        let info = quiet ? "" : card.note?.info ?? ""
        return VStack(spacing: 12) {
            if wrong || diacritics || !others.isEmpty || !info.isEmpty {
                Divider().padding(.horizontal, -14)
            }
            // Hints in Russian, like the notes under them.
            if diacritics, let result = session.result {
                Text(diacriticsHint(result))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            if let result = session.result, result.verdict != .correct {
                if result.verdict == .almost {
                    DiffText(pieces: result.correct, color: .orange, font: .system(size: 26, weight: .semibold))
                } else {
                    Text(result.expected).font(.system(size: 26, weight: .semibold))
                }
            }
            if !others.isEmpty {
                Text("Also accepted: \(others.joined(separator: ", "))")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            if !info.isEmpty {
                NoteInfoView(info: info, compact: false)
            }
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 14)
        // Nothing to add (a clean right answer): no padding either, so the panel keeps its height.
        .padding(.bottom, wrong || diacritics || !others.isEmpty || !info.isEmpty ? 14 : 0)
        .background(KeyOnlyButton(title: String(localized: "Continue"), action: session.confirm))
        .transition(.opacity)
    }
    /// Which letters needed their marks: "ć, а не c". Falls back to the marked letters when the
    /// typed word has another length (dj for đ).
    private func diacriticsHint(_ result: GradeResult) -> String {
        let want = Array(result.expected.lowercased())
        let got = Array(session.typed.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
        var pairs: [String] = []
        if want.count == got.count {
            for (w, g) in zip(want, got) where w != g {
                let pair = String(localized: "\(String(w)), not \(String(g))")
                if !pairs.contains(pair) { pairs.append(pair) }
            }
        }
        if pairs.isEmpty {
            pairs = result.correct.filter { $0.kind == .wrong }.map(\.text)
        }
        return String(localized: "Correct, but with diacritics: \(pairs.joined(separator: "; ")).")
    }
}
