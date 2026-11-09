import SwiftUI
import SrbCore

extension Exercise {
    /// The line above the card; "fill in the word" says so instead of naming the format.
    func title(for direction: Direction) -> String {
        if context != nil { return String(localized: "What does the word mean here?") }
        guard sentence != nil else { return kind.title(for: direction) }
        return kind == .choice ? String(localized: "Pick the word that fits") : String(localized: "Fill in the missing word")
    }
}

extension ExerciseKind {
    func title(for direction: Direction) -> String {
        switch self {
        case .typed: String(localized: "Type or say it in Serbian")
        case .reveal: String(localized: "What does it mean?")
        case .choice: direction == .production ? String(localized: "How do you say this in Serbian?") : String(localized: "What does this mean?")
        case .trueFalse: String(localized: "Is this translation right?")
        case .tiles: String(localized: "Spell it in Serbian")
        case .match: String(localized: "Match each Serbian word with its translation")
        }
    }
}

/// What an exercise card shows, copied out of the session when the card is drawn. The card that's
/// leaving keeps its own copy, so it doesn't turn into the next exercise while it animates out.
struct ExerciseFace {
    let card: StudyCard
    let exercise: Exercise
    let stage: ReviewSession.Stage
    let tiles: TileBoard?
    let match: MatchBoard?
    let pickedOption: Int?
    let exerciseCorrect: Bool?
    let canSpeak: Bool
}

/// The quick exercises (choice, yes/no, tiles, match), while answering and after.
/// Reads what to show from `face`; `session` only takes the answers.
struct ExerciseView: View {
    let session: ReviewSession
    let face: ExerciseFace
    let compact: Bool
    /// Off in the palette trial, whose headline already shows the instruction and the word.
    var showsPrompt = true
    /// Off on the iPhone's ring screens: Don't know is on the remote at the bottom.
    var showsGiveUp = true
    @Environment(\.showsKeyHints) private var showsKeyHints

    var body: some View {
        let exercise = face.exercise
        let card = face.card
        Group {
            VStack(spacing: compact ? 12 : 18) {
                if showsPrompt {
                    ExerciseInstruction(text: exercise.title(for: card.direction), compact: compact)
                }
                switch exercise.kind {
                case .choice:
                    ChoiceExercise(session: session, face: face, exercise: exercise, card: card, compact: compact)
                case .trueFalse:
                    TrueFalseExercise(session: session, face: face, exercise: exercise, compact: compact)
                case .tiles:
                    TilesExercise(session: session, face: face, exercise: exercise, compact: compact, showsPrompt: showsPrompt)
                case .match:
                    MatchExercise(session: session, face: face, compact: compact)
                case .typed, .reveal:
                    EmptyView()
                }
                // Below the exercise: help while answering, the correction after a miss.
                // A right answer adds nothing; the next card fades in.
                if face.stage == .answering, exercise.kind != .trueFalse, showsGiveUp {
                    HStack(spacing: 16) {
                        // Without key hints: just Don't know.
                        if exercise.kind == .tiles, !Platform.isTouch, showsKeyHints {
                            HStack(spacing: 6) {
                                Text("Type the letters")
                                KeyCap(key: "⌫")
                                Text("takes one back")
                            }
                            .foregroundStyle(.secondary)
                        } else if exercise.kind == .match, !Platform.isTouch, showsKeyHints, showsPrompt {
                            // The palette's headline already says it.
                            Text("Number of a word, then of its translation")
                                .foregroundStyle(.secondary)
                        }
                        Button(action: session.giveUp) {
                            HStack(spacing: 6) {
                                KeyCap(key: exercise.kind == .tiles ? "?" : "⌫")
                                Text("Don't know")
                            }
                        }
                        .cardAction(mac: .plain)
                        // The iPhone's is a real button: its label keeps the full color.
                        .foregroundStyle(Platform.isTouch ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                    }
                    .font(.callout)
                } else if face.stage == .revealed, face.exerciseCorrect == false {
                    ExerciseFeedback(session: session, face: face, exercise: exercise, card: card, compact: compact)
                        .popIn(from: 0.94)
                }
            }
        }
    }
}

// MARK: - Exercises

private struct ChoiceExercise: View {
    let session: ReviewSession
    let face: ExerciseFace
    let exercise: Exercise
    let card: StudyCard
    let compact: Bool

    var body: some View {
        VStack(spacing: compact ? 12 : 18) {
            CardPrompt(
                text: card.direction == .production ? exercise.target.russian : exercise.target.serbian,
                sentence: exercise.sentence,
                revealed: face.stage == .revealed,
                compact: compact
            )
            // A plain Grid, not a lazy one: lazy cells stay behind when the card slides away.
            Grid(horizontalSpacing: 10, verticalSpacing: 10) {
                ForEach(Array(stride(from: 0, to: exercise.options.count, by: 2)), id: \.self) { row in
                    GridRow {
                        ForEach(row..<min(row + 2, exercise.options.count), id: \.self) { i in
                            OptionButton(label: "\(i + 1)", text: exercise.options[i], state: state(of: i), compact: compact, fillsHeight: true) {
                                session.pick(option: i)
                            }
                        }
                    }
                }
            }
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func state(of index: Int) -> OptionButton.State {
        guard face.stage == .revealed else { return .normal }
        if index == exercise.correctIndex { return .right }
        return index == face.pickedOption ? .wrong : .faded
    }
}

private struct TrueFalseExercise: View {
    let session: ReviewSession
    let face: ExerciseFace
    let exercise: Exercise
    let compact: Bool

    var body: some View {
        let statement = exercise.statement ?? exercise.target
        VStack(spacing: compact ? 12 : 18) {
            Prompt(text: statement.serbian, compact: compact)
            VStack(spacing: 4) {
                Text("means")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Text(statement.russian)
                    .font(.system(size: compact ? Platform.card(22) : 30, weight: .medium))
                    .multilineTextAlignment(.center)
            }
            HStack(spacing: 12) {
                OptionButton(label: "←", text: String(localized: "No, wrong"), state: state(yes: false), compact: compact) { session.answer(yes: false) }
                OptionButton(label: "→", text: String(localized: "Yes, right"), state: state(yes: true), compact: compact, keyOnTrailingEdge: true) { session.answer(yes: true) }
            }
            .frame(maxWidth: 460)
        }
    }

    private func state(yes: Bool) -> OptionButton.State {
        guard face.stage == .revealed else { return .normal }
        if yes == exercise.statementIsTrue { return .right }
        return face.pickedOption == (yes ? 1 : 0) ? .wrong : .faded
    }
}

private struct TilesExercise: View {
    let session: ReviewSession
    let face: ExerciseFace
    let exercise: Exercise
    let compact: Bool
    var showsPrompt = true
    /// A letter flies from its tile into the word and back.
    @Namespace private var flight
    /// Width the word row can use; long words get narrower slots instead of running off screen.
    @State private var rowWidth: CGFloat = 0
    @Environment(\.showsKeyHints) private var showsKeyHints

    /// Same on the tile and in the word, so a flying letter only moves, never changes size.
    private var letterFont: Font { .system(size: compact ? Platform.card(20) : 24, weight: .medium, design: .rounded) }

    var body: some View {
        if let board = face.tiles {
            let revealed = face.stage == .revealed
            let letters = Array(board.answer)
            let size: CGFloat = compact ? Platform.card(36) : 44
            let letterWidth = slotWidth(board)
            VStack(spacing: compact ? 12 : 18) {
                if showsPrompt {
                    Prompt(text: exercise.target.russian, compact: compact)
                }

                // The word being built. Click a letter to take it (and the ones after it) back.
                HStack(spacing: Self.slotSpacing) {
                    ForEach(Array(board.progress.enumerated()), id: \.offset) { index, item in
                        if let slot = item.slot {
                            // Missed: the right word, not what was placed with the rest tacked on
                            // (half a wrong word plus the leftover letters read as nonsense).
                            let missed = revealed && !board.isSolved
                            let shown = missed ? letters[index] : item.character
                            // Your letters that were right stay; the rest is the answer, in orange.
                            let filledIn = missed && item.character.map { $0.lowercased() != letters[index].lowercased() } ?? missed
                            let wrong = !missed && board.wrongSlots.contains(slot)
                            Button { session.removeTiles(fromSlot: slot) } label: {
                                Text(shown.map(String.init) ?? " ")
                                    .matchedGeometryEffect(id: slot < board.placed.count ? board.placed[slot] : -1 - slot, in: flight)
                                    .font(letterFont)
                                    .minimumScaleFactor(0.5)
                                    .foregroundStyle(wrong ? Color.red : filledIn || item.character == nil ? Color.orange : board.isSolved ? Color.green : Color.primary)
                                    .frame(width: letterWidth, height: compact ? 34 : 42)
                                    .background(
                                        RoundedRectangle(cornerRadius: 6)
                                            .fill(wrong ? Color.red.opacity(0.15) : board.isSolved ? Color.green.opacity(0.15) : Color.primary.opacity(filledIn || item.character == nil ? 0.04 : 0.09))
                                    )
                                    .overlay(alignment: .bottom) {
                                        if item.character == nil, !revealed {
                                            Capsule().fill(Color.secondary.opacity(0.5)).frame(height: 2).padding(.horizontal, 6).padding(.bottom, 5)
                                        }
                                    }
                            }
                            .buttonStyle(.plain)
                            // Not .disabled: that greys out the finished word.
                            .allowsHitTesting(item.character != nil && !revealed)
                        } else {
                            Color.clear.frame(width: Self.spaceWidth, height: 1)
                        }
                    }
                }
                // Both bounds: the frame takes the offered width even while a long word is wider.
                // With only maxWidth it took the word's width, so the slots never got narrower.
                .frame(minWidth: 0, maxWidth: .infinity)
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { rowWidth = $0 }

                // After answering the tiles stay where they were, dimmed, so nothing below moves.
                Group {
                    // Even rows, centered: up to 10 tiles a row (7 in the menu bar popover).
                    let perRow = min(board.tiles.count, compact ? 7 : 10)
                    Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 8) {
                        ForEach(Array(stride(from: 0, to: board.tiles.count, by: perRow)), id: \.self) { row in
                            GridRow {
                                ForEach(board.tiles[row..<min(row + perRow, board.tiles.count)]) { tile in
                                    let used = board.isUsed(tile.id)
                                    Button { session.tile(tile.id) } label: {
                                        ZStack {
                                            RoundedRectangle(cornerRadius: 8)
                                                .strokeBorder(Color.primary.opacity(used ? 0.06 : 0.12))
                                                .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(used ? 0.02 : 0.07)))
                                            if !used {
                                                Text(String(tile.letter))
                                                    .matchedGeometryEffect(id: tile.id, in: flight)
                                                    .font(letterFont)
                                            }
                                        }
                                        .frame(width: size, height: size)
                                    }
                                    .buttonStyle(.plain)
                                    .disabled(used)
                                }
                            }
                        }
                    }
                    .fixedSize()
                    .opacity(revealed ? 0.35 : 1)
                    .allowsHitTesting(!revealed)

                    // Which key types each letter with diacritics on these tiles.
                    let lettersHere = Set(board.tiles.map { Character($0.letter.lowercased()) })
                    let keys = SerbianKeys.diacriticKeys.filter { lettersHere.contains($0.letter) }
                    if !keys.isEmpty, showsKeyHints {
                        HStack(spacing: 16) {
                            ForEach(keys, id: \.letter) { item in
                                HStack(spacing: 6) {
                                    Text(String(item.letter)).font(.body.weight(.medium))
                                    KeyCap(key: item.key)
                                }
                            }
                        }
                        .foregroundStyle(.secondary)
                        .opacity(revealed ? 0.35 : 1)
                    }

                    // Always there, empty or not, so the line below never moves.
                    let left = TileBoard.maxAttempts - board.mistakes
                    Text(board.wrongSlots.isEmpty || revealed ? " " : String(localized: "Not quite: fix the red \(board.wrongSlots.count) letters", table: "Units") + " · " + String(localized: "\(left) tries left"))
                        .font(.callout)
                        .foregroundStyle(.red)
                }
            }
            .animation(.tileFlight, value: board.placed)
        }
    }

    private static let slotSpacing: CGFloat = 4
    private static let spaceWidth: CGFloat = 12

    /// The usual slot width, or less when the word wouldn't fit the row otherwise.
    private func slotWidth(_ board: TileBoard) -> CGFloat {
        let usual: CGFloat = compact ? 26 : 32
        guard rowWidth > 0 else { return usual }
        let items = board.progress
        let slots = CGFloat(items.filter { $0.slot != nil }.count)
        let spaces = CGFloat(items.count) - slots
        let room = rowWidth - Self.slotSpacing * CGFloat(max(items.count - 1, 0)) - Self.spaceWidth * spaces
        return slots > 0 ? max(12, min(usual, (room / slots).rounded(.down))) : usual
    }
}

private struct MatchExercise: View {
    let session: ReviewSession
    let face: ExerciseFace
    let compact: Bool

    var body: some View {
        if let board = face.match {
            // Both columns are numbered: the number keys pick a Serbian word, then its translation.
            // The column they act on now shows its numbers; the other one dims them.
            let pickingRight = board.selectedLeft != nil
            // Rows, not two columns: a long translation makes its whole row taller, so the two
            // sides stay level instead of the right column running further down than the left.
            Grid(horizontalSpacing: 14, verticalSpacing: 8) {
                ForEach(0..<max(board.left.count, board.right.count), id: \.self) { row in
                    GridRow {
                        if row < board.left.count {
                            OptionButton(label: "\(row + 1)", text: board.left[row], state: leftState(board, row), compact: compact, keyDimmed: pickingRight, fillsHeight: true) {
                                session.match(left: row)
                            }
                        } else {
                            Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                        }
                        if row < board.right.count {
                            OptionButton(label: "\(row + 1)", text: board.right[row], state: rightState(board, row), compact: compact, keyDimmed: !pickingRight, fillsHeight: true) {
                                session.match(right: row)
                            }
                        } else {
                            Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                        }
                    }
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            .animation(.easeOut(duration: 0.2), value: board.matchedLeft)
        }
    }

    private func leftState(_ board: MatchBoard, _ i: Int) -> OptionButton.State {
        if board.matchedLeft.contains(i) { return .right }
        if board.selectedLeft == i { return .selected }
        return board.lastWrong?.left == i ? .wrong : .normal
    }

    private func rightState(_ board: MatchBoard, _ j: Int) -> OptionButton.State {
        if board.isMatched(right: j) { return .right }
        if board.selectedRight == j { return .selected }
        return board.lastWrong?.right == j ? .wrong : .normal
    }
}

/// After an exercise: right or wrong, the word with its translation, and the grade.
struct ExerciseFeedback: View {
    let session: ReviewSession
    let face: ExerciseFace
    let exercise: Exercise
    let card: StudyCard
    let compact: Bool

    private var touchSpeaker: (() -> Void)? {
        Platform.isTouch && face.canSpeak ? { session.speak() } : nil
    }

    /// The sentence's word when it isn't the dictionary form; nil otherwise.
    private var sentenceForm: String? {
        guard let answer = exercise.sentence?.answer else { return nil }
        let fold = { (text: String) in text.lowercased().trimmingCharacters(in: .whitespaces) }
        return fold(answer) == fold(exercise.target.serbian) ? nil : answer
    }

    /// "genitive, pl. of novine", or "a form of novine" when the word has no table with it.
    private func formOf(_ form: String) -> String {
        let word = exercise.target.serbian
        guard let tag = exercise.formTag ?? card.note?.formTag(of: form) else {
            return String(localized: "a form of \(word)")
        }
        return String(localized: "\(WordForms.label(tag)) of \(word)")
    }

    var body: some View {
        VStack(spacing: compact ? 8 : 10) {
            // Tiles put right after a mistake or two: a win, just not a clean one.
            let fixed = face.tiles?.isSolved == true
            let tries = (face.tiles?.mistakes ?? 0) + 1
            HStack(spacing: 6) {
                if fixed { PopIcon(systemName: "checkmark.circle.fill", color: .orange) }
                Text(fixed ? "Right on try \(tries)" : "Not quite")
            }
            .font(.callout.weight(.semibold))
            .foregroundStyle(fixed ? Color.orange : Color.red)
            .padding(.horizontal, 10)
            .padding(.vertical, 3)
            .background(Capsule().fill((fixed ? Color.orange : Color.red).opacity(0.14)))
            // Tiles put right have the word up in the slots. Missed, the slots mix your letters
            // with the answer's, so the word is spelled out here too: without it Continue went by
            // before you'd seen what it was.
            if exercise.kind != .tiles || !fixed {
                // In a sentence the answer is the form the sentence needs. Headed by the dictionary
                // form, a miss read as if your pick had been right: "Ima li ___ u kafiću?",
                // novine picked, novina right, and under "Not quite" stood "novine — газета".
                let form = sentenceForm
                SpeakerBeside(speak: touchSpeaker) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(form ?? exercise.target.serbian).font(.system(size: compact ? Platform.card(20) : 26, weight: .semibold))
                        Text(verbatim: "—").foregroundStyle(.tertiary)
                        Text(exercise.target.russian).font(compact ? .body : .title3).foregroundStyle(.secondary)
                    }
                    .multilineTextAlignment(.center)
                }
                if let form {
                    Text(formOf(form))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
            }
            if let info = card.note?.info, !info.isEmpty {
                NoteInfoView(info: info, compact: compact)
            }
            if let tag = exercise.formTag, let note = card.note {
                if face.exerciseCorrect == false, let picked = face.pickedOption, exercise.options.indices.contains(picked) {
                    FormMistakeNote(note: note, tag: tag, given: exercise.options[picked],
                                    showsRule: exercise.sentence?.rule == nil, compact: compact)
                }
                FormsTableView(note: note, highlight: tag, compact: compact)
            }
            if face.canSpeak, Platform.isTouch, exercise.kind == .tiles, fixed {
                // The word is up in the tiles; the icon stands alone under it.
                SpeakerBeside(speak: { session.speak() }) { Color.clear.frame(width: 0, height: 0) }
            } else if face.canSpeak, !Platform.isTouch {
                Button { session.speak() } label: { Label(Platform.isTouch ? "Listen" : "Listen  ␣", systemImage: "speaker.wave.2.fill") }
                    .cardAction(mac: .borderless)
                    .font(.callout)
            }
            ContinueButton(action: session.confirm)
        }
    }
}

// MARK: - Pieces

/// The line above every card: what to do.
struct ExerciseInstruction: View {
    let text: String
    let compact: Bool
    @Environment(\.strongInstruction) private var strong

    var body: some View {
        Text(text)
            .font(compact && !Platform.isTouch ? .body : .title3)
            .foregroundStyle(strong ? AnyShapeStyle(Color.primary.opacity(0.68)) : AnyShapeStyle(.secondary))
            .lineLimit(1)
    }
}

extension EnvironmentValues {
    /// The iPhone's ring screens: the instruction above the word a little darker than secondary.
    @Entry var strongInstruction = false
}

/// The word or phrase being asked, same size and place on every card.
struct Prompt: View {
    let text: String
    let compact: Bool
    /// iPhone: a speaker icon beside the word, when the word is the Serbian one.
    var speak: (() -> Void)?

    var body: some View {
        SpeakerBeside(speak: speak) {
            Text(text)
                .font(.system(size: compact ? Platform.card(26) : 38, weight: .semibold))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// What the card asks: the word, in "fill in the word" its sentence, or the word inside an
/// example sentence (`context`).
struct CardPrompt: View {
    let text: String
    let sentence: ClozeSentence?
    var context: ClozeSentence?
    /// Answered: the gap shows the word.
    let revealed: Bool
    let compact: Bool
    var speak: (() -> Void)?

    var body: some View {
        if let sentence {
            ClozePrompt(sentence: sentence, revealed: revealed, compact: compact)
        } else if let context {
            ContextPrompt(sentence: context, revealed: revealed, compact: compact)
        } else {
            Prompt(text: text, compact: compact, speak: speak)
        }
    }
}

/// "Kupio sam ____ u pekari." with its translation under it. Once answered the gap holds the
/// word, in the accent color, so the whole sentence can be read.
struct ClozePrompt: View {
    let sentence: ClozeSentence
    let revealed: Bool
    let compact: Bool
    var alignment: TextAlignment = .center

    var body: some View {
        VStack(alignment: stackAlignment, spacing: compact ? 6 : 8) {
            serbianText
                .font(.system(size: compact ? Platform.card(22) : 30, weight: .semibold))
                .multilineTextAlignment(alignment)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityLabel(revealed ? sentence.full : sentence.blanked())
            Text(sentence.russian)
                .font(compact ? .body : .title3)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(alignment)
                .fixedSize(horizontal: false, vertical: true)
            if let hint = sentence.hint {
                // Which word is meant: "тётя" alone could be tetka or strina.
                Text(hint)
                    .font(compact ? .subheadline.weight(.medium) : .body.weight(.medium))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(alignment)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Color.primary.opacity(0.06), in: Capsule())
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let rule = sentence.rule {
                // A case met for the first times: its ending, from the start so nothing moves.
                CaseRuleBox(rule: rule, compact: compact)
            }
        }
        .frame(maxWidth: .infinity, alignment: Alignment(horizontal: stackAlignment, vertical: .center))
        .animation(.easeOut(duration: 0.2), value: revealed)
    }

    /// The lines sit where their text is aligned: centered on a card, leading on a word's page.
    /// A short line is only as wide as its text, so a leading stack moved it off the card's center.
    private var stackAlignment: HorizontalAlignment {
        switch alignment {
        case .leading: .leading
        case .center: .center
        case .trailing: .trailing
        }
    }

    /// The gap is the word itself in clear letters, so it keeps the word's width and revealing it
    /// can't rewrap the sentence. Its line is drawn by `GapLine`: an underline skips the clear
    /// letters' descenders, and "zgrada" showed as "_ ____" with a hole under the g.
    @ViewBuilder private var serbianText: some View {
        if #available(iOS 18, macOS 15, *) {
            let gap = Text(verbatim: sentence.answer).foregroundStyle(revealed ? Color.accentColor : .clear)
            Text("\(Text(verbatim: sentence.before))\(revealed ? gap : gap.customAttribute(GapRun()))\(Text(verbatim: sentence.after))")
                .textRenderer(GapLine())
        } else {
            Text(serbian)
        }
    }

    private var serbian: AttributedString {
        var gap: AttributedString
        if revealed {
            gap = AttributedString(sentence.answer)
            gap.foregroundColor = Color.accentColor
        } else {
            // Keep the actual word's width while hiding its letters. Counting underscores only
            // approximates that width, so revealing a wider or narrower word could rewrap the
            // sentence and push the translation below it.
            // The line carries its own color: Text ignores UIKit's and AppKit's underline color,
            // and without one it takes the clear letters' color and the gap disappears.
            gap = AttributedString(sentence.answer)
            gap.foregroundColor = .clear
            gap.underlineStyle = Text.LineStyle(pattern: .solid, color: .secondary)
        }
        return AttributedString(sentence.before) + gap + AttributedString(sentence.after)
    }
}

/// Marks the gap in a `ClozePrompt` sentence for `GapLine`.
private struct GapRun: TextAttribute {}

/// Draws the text, and a line under the runs marked `GapRun`, through the descenders too.
@available(iOS 18, macOS 15, *)
private struct GapLine: TextRenderer {
    func draw(layout: Text.Layout, in context: inout GraphicsContext) {
        for line in layout {
            for run in line {
                context.draw(run)
                guard run[GapRun.self] != nil else { continue }
                let bounds = run.typographicBounds
                let thickness = max(1, (bounds.ascent / 18).rounded())
                let line = CGRect(x: bounds.rect.minX, y: bounds.origin.y + bounds.descent * 0.35,
                                  width: bounds.width, height: thickness)
                context.fill(Path(line), with: .color(.secondary))
            }
        }
    }
}

/// "Kupio sam **hleb** u pekari.": the word to recall in one of its sentences, in the accent
/// color. The translation's place is kept from the start and filled in with the answer, so
/// nothing moves.
struct ContextPrompt: View {
    let sentence: ClozeSentence
    let revealed: Bool
    let compact: Bool

    var body: some View {
        VStack(spacing: compact ? 6 : 8) {
            Text(serbian)
                .font(.system(size: compact ? Platform.card(22) : 30, weight: .semibold))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityLabel(sentence.full)
            Text(sentence.russian)
                .font(compact ? .body : .title3)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .opacity(revealed ? 1 : 0)
                .accessibilityHidden(!revealed)
        }
        .frame(maxWidth: .infinity)
        .animation(.easeOut(duration: 0.2), value: revealed)
    }

    private var serbian: AttributedString { Self.highlighted(sentence) }

    static func highlighted(_ sentence: ClozeSentence) -> AttributedString {
        var word = AttributedString(sentence.answer)
        word.foregroundColor = Color.accentColor
        return AttributedString(sentence.before) + word + AttributedString(sentence.after)
    }
}

/// A word with a bare speaker icon after it, like the mic in the answer field. The same space
/// on the other side keeps the word centered. Without `speak` it's just the word.
struct SpeakerBeside<Content: View>: View {
    let speak: (() -> Void)?
    @ViewBuilder let content: Content

    var body: some View {
        if let speak {
            HStack(spacing: 0) {
                Color.clear.frame(width: 32, height: 32)
                content
                Button(action: speak) {
                    Image(systemName: "speaker.wave.2")
                        .font(.system(size: 18))
                        .foregroundStyle(.secondary)
                        .frame(width: 32, height: 32)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Listen")
            }
        } else {
            content
        }
    }
}

/// A big answer button with its keyboard key on the left.
private struct OptionButton: View {
    enum State { case normal, selected, right, wrong, faded }

    let label: String
    let text: String
    let state: State
    let compact: Bool
    var keyOnTrailingEdge = false
    /// The number key doesn't act on this button right now (match: the other column's turn).
    var keyDimmed = false
    /// In a grid row: as tall as the tallest button in the row (the grid needs a fixed height).
    var fillsHeight = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                if keyOnTrailingEdge {
                    Spacer(minLength: 0)
                } else {
                    KeyCap(key: label).opacity(keyDimmed ? 0.3 : 1)
                }
                Text(text)
                    .font(compact && !Platform.isTouch ? .body : .title3)
                    .foregroundStyle(macVerdict ?? .primary)
                    .multilineTextAlignment(keyOnTrailingEdge ? .trailing : .leading)
                    .fixedSize(horizontal: false, vertical: true)
                if keyOnTrailingEdge {
                    KeyCap(key: label)
                } else {
                    Spacer(minLength: 0)
                }
                // A fixed slot for the check mark, so the text never shifts when it shows up.
                // The Mac marks a verdict like its ne / da tiles instead: the colors alone.
                ZStack {
                    if Platform.isTouch, state == .right {
                        PopIcon(systemName: "checkmark.circle.fill", color: .green)
                    } else if Platform.isTouch, state == .wrong {
                        PopIcon(systemName: "xmark.circle.fill", color: .red)
                    }
                }
                .frame(width: Platform.isTouch ? 20 : 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, compact && !Platform.isTouch ? 8 : 12)
            .frame(maxWidth: .infinity, minHeight: compact && !Platform.isTouch ? 38 : 48, maxHeight: fillsHeight ? .infinity : nil)
            // Only the colors fade, and without a spring (one overshoots them, so the green
            // flickers). An .animation(value:) on the whole button also caught the card swap, and
            // the next card snapped in instead of pushing. The check mark has its own pop.
            .animation(.easeOut(duration: 0.2)) { button in
                button
                    .background(RoundedRectangle(cornerRadius: 10).fill(fill))
                    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(border.opacity(macVerdict == nil ? 1 : 0.7),
                                                                             lineWidth: state == .normal || state == .faded ? 1 : 2))
                    .opacity(state == .faded ? 0.45 : 1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var fill: Color {
        switch state {
        case .normal, .faded: Color.primary.opacity(0.05)
        case .selected: Color.accentColor.opacity(0.15)
        case .right: Color.green.opacity(Platform.isTouch ? 0.18 : 0.14)
        case .wrong: Color.red.opacity(Platform.isTouch ? 0.18 : 0.14)
        }
    }

    /// The Mac colors a verdict's text too, like the ne / da tiles.
    private var macVerdict: Color? {
        guard !Platform.isTouch else { return nil }
        return switch state {
        case .right: .green
        case .wrong: .red
        default: nil
        }
    }

    private var border: Color {
        switch state {
        case .normal, .faded: Color.primary.opacity(0.08)
        case .selected: Color.accentColor
        case .right: Color.green
        case .wrong: Color.red
        }
    }
}

extension View {
    /// The smaller actions on a card (Don't know, Listen): text on the Mac, where keys do the
    /// work, and real buttons on the iPhone, where they're tapped.
    @ViewBuilder
    func cardAction(mac: some PrimitiveButtonStyle) -> some View {
        if Platform.isTouch {
            secondaryButton().controlSize(.large)
        } else {
            buttonStyle(mac)
        }
    }
}

/// A keyboard key, so it's obvious which key does what.
struct KeyCap: View {
    let key: String
    @Environment(\.showsKeyHints) private var showsKeyHints

    /// Nothing on the iPhone (there's no keyboard to point at) or where key hints are off.
    var body: some View {
        if !Platform.isTouch, showsKeyHints {
            Text(key).keyCapStyle()
        }
    }
}

extension EnvironmentValues {
    /// Off: no key caps or "press Enter" lines, just the cards (Continue becomes a button).
    @Entry var showsKeyHints = true
}

extension View {
    /// Every key cap's look: a small, quiet cap with a dark, light-weight glyph.
    func keyCapStyle() -> some View {
        font(.system(size: 11, weight: .medium))
            .foregroundStyle(Color.primary.opacity(0.85))
            .frame(minWidth: 18, minHeight: 18)
            .padding(.horizontal, 2)
            .background(RoundedRectangle(cornerRadius: 4).fill(Color.primary.opacity(0.04)))
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color.primary.opacity(0.1)))
    }
}
