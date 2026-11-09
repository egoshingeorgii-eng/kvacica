import SrbCore
import SwiftUI

/// A note's info under the answer. Verbs whose info starts with the six present-tense forms
/// ("kupim, kupiš, kupi, kupimo, kupite, kupe · …") get them as a table, ja/ti/on on the left and
/// mi/vi/oni on the right; whatever follows the forms stays a line of text below.
struct NoteInfoView: View {
    let info: String
    let compact: Bool
    var alignment: TextAlignment = .center

    var body: some View {
        if let table = Conjugation(info) {
            VStack(spacing: 8) {
                Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 3) {
                    ForEach(0..<3, id: \.self) { row in
                        GridRow {
                            pronoun(Conjugation.pronouns[row])
                            form(table.forms[row])
                            Color.clear.frame(width: compact ? 12 : 20, height: 1)
                            pronoun(Conjugation.pronouns[row + 3])
                            form(table.forms[row + 3])
                        }
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.04)))
                if let rest = table.rest {
                    text(rest)
                }
            }
        } else {
            text(info)
        }
    }

    /// One size for all of it: the forms in the primary color, everything else secondary.
    private var font: Font { compact ? .callout : .body }

    private func pronoun(_ text: String) -> some View {
        Text(text)
            .font(font)
            .foregroundStyle(.secondary)
            .gridColumnAlignment(.trailing)
    }

    private func form(_ text: String) -> some View {
        Text(text)
            .font(font)
            .gridColumnAlignment(.leading)
    }

    private func text(_ text: String) -> some View {
        Text(text)
            .font(font)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(alignment)
            .fixedSize(horizontal: false, vertical: true)
    }
}
