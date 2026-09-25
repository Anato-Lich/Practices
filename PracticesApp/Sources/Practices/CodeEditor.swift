import SwiftUI
import AppKit

/// A plain-text Python editor: monospaced, no smart quotes, dashes or spelling (each of them
/// silently breaks code), with light syntax colouring.
struct CodeEditor: NSViewRepresentable {
    @Binding var text: String

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        let view = scroll.documentView as! NSTextView
        view.delegate = context.coordinator
        view.isRichText = false
        view.allowsUndo = true
        view.usesFindBar = true
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.isAutomaticTextReplacementEnabled = false
        view.isAutomaticSpellingCorrectionEnabled = false
        view.isContinuousSpellCheckingEnabled = false
        view.isGrammarCheckingEnabled = false
        view.smartInsertDeleteEnabled = false
        view.font = Self.font
        view.textContainerInset = NSSize(width: 8, height: 10)
        view.backgroundColor = .textBackgroundColor
        view.string = text
        Highlighter.apply(to: view.textStorage!)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let view = scroll.documentView as! NSTextView
        if view.string != text {
            view.string = text
            Highlighter.apply(to: view.textStorage!)
        }
    }

    static let font = NSFont.monospacedSystemFont(ofSize: 12.5, weight: .regular)

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: CodeEditor
        init(_ parent: CodeEditor) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? NSTextView else { return }
            parent.text = view.string
            Highlighter.apply(to: view.textStorage!)
        }
    }
}

/// Keywords, strings, comments and numbers; enough to read code, not a parser.
enum Highlighter {
    static let keywords = ["def", "return", "import", "from", "as", "if", "elif", "else", "for", "while", "in",
                           "not", "and", "or", "with", "try", "except", "finally", "raise", "async", "await",
                           "class", "lambda", "None", "True", "False", "pass", "break", "continue", "yield", "is"]
    static let keywordRegex = try! NSRegularExpression(pattern: "\\b(" + keywords.joined(separator: "|") + ")\\b")
    static let numberRegex = try! NSRegularExpression(pattern: "\\b\\d+(\\.\\d+)?\\b")
    static let stringRegex = try! NSRegularExpression(pattern: #"(\"\"\"[\s\S]*?\"\"\"|'''[\s\S]*?'''|f?\"(?:[^\"\\\n]|\\.)*\"|f?'(?:[^'\\\n]|\\.)*')"#)
    static let commentRegex = try! NSRegularExpression(pattern: "#[^\\n]*")
    static let defRegex = try! NSRegularExpression(pattern: "(?<=def )[A-Za-z_][A-Za-z0-9_]*")

    static func apply(to storage: NSTextStorage) {
        let text = storage.string
        let all = NSRange(location: 0, length: (text as NSString).length)
        storage.beginEditing()
        storage.setAttributes([.font: CodeEditor.font, .foregroundColor: NSColor.textColor], range: all)
        func paint(_ regex: NSRegularExpression, _ color: NSColor) {
            for m in regex.matches(in: text, range: all) { storage.addAttribute(.foregroundColor, value: color, range: m.range) }
        }
        paint(keywordRegex, .systemPink)
        paint(numberRegex, .systemYellow)
        paint(defRegex, .systemTeal)
        paint(stringRegex, .systemRed)
        paint(commentRegex, .secondaryLabelColor)
        storage.endEditing()
    }
}
