import SwiftUI
import AppKit

/// The answer box. A plain NSTextField rather than SwiftUI's TextField: SwiftUI doesn't redraw a
/// focused field when its text is set from code, so dictated words stayed invisible until Enter.
struct AnswerField: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String
    let fontSize: CGFloat
    /// Bump to put the cursor in the field.
    let focusRequest: Int
    /// After answering, keep the field for layout but release keyboard focus.
    var readOnly = false
    /// After answering: the verdict (the answer in its colors), drawn by the field itself. A SwiftUI
    /// Text in its place sat half a point off and the word visibly twitched when it was checked.
    var shown: NSAttributedString? = nil
    let onSubmit: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.delegate = context.coordinator
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.alignment = .center
        field.cell?.isScrollable = true
        field.cell?.usesSingleLineMode = true
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.parent = self
        // Set on every update, the font restyled the field editor and laid the field out again.
        if field.font?.pointSize != fontSize { field.font = .systemFont(ofSize: fontSize) }
        if field.placeholderString != placeholder { field.placeholderString = placeholder }

        if let shown {
            if field.currentEditor() != nil { field.window?.makeFirstResponder(nil) }
            field.isEditable = false
            let fitted = Self.fitted(shown, in: field.bounds.width - 4)
            if !field.attributedStringValue.isEqual(to: fitted) { field.attributedStringValue = fitted }
            return
        }

        if field.stringValue != text {
            if let editor = field.currentEditor() as? NSTextView {
                editor.string = text
                editor.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
            } else {
                field.stringValue = text
            }
        }

        if context.coordinator.focusedRequest != focusRequest {
            context.coordinator.focusedRequest = focusRequest
            // The field may not be in its window yet on the first update.
            DispatchQueue.main.async {
                guard let window = field.window, field.currentEditor() == nil else { return }
                window.makeFirstResponder(field)
            }
        }
    }

    /// Smaller, down to 0.6 of the size, when the answer is wider than the field.
    private static func fitted(_ text: NSAttributedString, in width: CGFloat) -> NSAttributedString {
        let natural = text.size().width
        guard width > 0, natural > width else { return text }
        let scale = max(0.6, width / natural)
        let result = NSMutableAttributedString(attributedString: text)
        result.enumerateAttribute(.font, in: NSRange(location: 0, length: result.length)) { font, range, _ in
            guard let font = font as? NSFont else { return }
            result.addAttribute(.font, value: font.withSize(font.pointSize * scale), range: range)
        }
        return result
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: AnswerField
        var focusedRequest = -1

        init(_ parent: AnswerField) { self.parent = parent }

        func controlTextDidBeginEditing(_ notification: Notification) {
            guard let editor = (notification.object as? NSTextField)?.currentEditor() as? NSTextView else { return }
            editor.isAutomaticSpellingCorrectionEnabled = false
            editor.isAutomaticTextReplacementEnabled = false
            editor.isContinuousSpellCheckingEnabled = false
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            parent.text = field.stringValue
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            guard selector == #selector(NSResponder.insertNewline(_:)) else { return false }
            parent.text = textView.string
            parent.onSubmit()
            return true
        }
    }
}
