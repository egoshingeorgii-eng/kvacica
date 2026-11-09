import SwiftUI
import SrbCore

/// The lesson's (or review's) words with translations, to look over before the first card (Start)
/// or in the middle (Continue).
struct LessonWordsView: View {
    let session: ReviewSession
    let compact: Bool
    var inset: CGFloat = 0

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 12 : 18) {
            Button(action: session.goHome) {
                HStack(spacing: 6) {
                    KeyCap(key: "esc")
                    if Platform.isTouch { Image(systemName: "chevron.left") }
                    Text("Home")
                }
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)

            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(session.sessionTitle)
                        .font(compact ? .title2.weight(.semibold) : .largeTitle.weight(.semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    Text(subtitle)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 12)
                if !compact { goButton }
            }
            if compact { goButton.frame(maxWidth: .infinity, alignment: .leading) }

            ScrollView {
                // One column on the iPhone and in the menu bar, a grid in the window.
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: compact || Platform.isTouch ? 280 : 300), spacing: 8, alignment: .top)],
                    alignment: .leading,
                    spacing: 8
                ) {
                    ForEach(session.lessonWords) { row($0) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .contentMargins(.bottom, inset, for: .scrollContent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var subtitle: String {
        let n = session.lessonWords.count
        return session.lessonWordsFirst ? String(localized: "\(n) words. Have a look before you start.") : String(localized: "\(n) words")
    }

    private var goButton: some View {
        Button(action: session.hideLessonWords) {
            Text(session.lessonWordsFirst ? "Start" : "Continue").frame(minWidth: 120)
        }
        .prominentButton()
        .controlSize(.large)
        .keyboardShortcut(.defaultAction)
    }

    private func row(_ word: ReviewSession.LessonWord) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(word.serbian)
                .font(.body.weight(.semibold))
            Text(word.russian)
                .foregroundStyle(.secondary)
            if let info = word.info, !info.isEmpty {
                Text(info)
                    .font(.callout)
                    .foregroundStyle(.tertiary)
                    .lineLimit(2)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, minHeight: 0, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.03)))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.05)))
    }
}
