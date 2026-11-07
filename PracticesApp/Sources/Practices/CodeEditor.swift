import SwiftUI
import AppKit

/// A plain-text Python editor: monospaced, no smart quotes, dashes or spelling (each of them
/// silently breaks code), with light syntax colouring. The design's editor: code.bg, mono 12/19,
/// padding 10 14, a 40pt gutter of line numbers.
struct CodeEditor: NSViewRepresentable {
    @Binding var text: String

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        let view = scroll.documentView as! NSTextView
        view.delegate = context.coordinator
        _ = view.layoutManager  // the gutter reads line fragments: TextKit 1 from the start, not mid-draw
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
        view.textContainerInset = NSSize(width: 14, height: 10)
        view.textContainer?.lineFragmentPadding = 0
        view.backgroundColor = NSColor(Theme.Color.codeBg)
        view.insertionPointColor = NSColor(Theme.Color.textCode)
        view.typingAttributes = Highlighter.base
        scroll.backgroundColor = NSColor(Theme.Color.codeBg)
        scroll.drawsBackground = true
        view.string = text
        Highlighter.apply(to: view.textStorage!)

        let ruler = LineNumberRuler(textView: view)
        scroll.verticalRulerView = ruler
        scroll.hasVerticalRuler = true
        scroll.rulersVisible = true
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let view = scroll.documentView as! NSTextView
        if view.string != text {
            view.string = text
            Highlighter.apply(to: view.textStorage!)
            scroll.verticalRulerView?.needsDisplay = true
        }
    }

    static let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: CodeEditor
        init(_ parent: CodeEditor) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? NSTextView else { return }
            parent.text = view.string
            Highlighter.apply(to: view.textStorage!)
            view.enclosingScrollView?.verticalRulerView?.needsDisplay = true
        }
    }
}

/// The gutter: 40 wide, gutter.bg, numbers in text.gutter right-aligned, a border.soft line on the right.
final class LineNumberRuler: NSRulerView {
    init(textView: NSTextView) {
        super.init(scrollView: textView.enclosingScrollView, orientation: .verticalRuler)
        clientView = textView
        ruleThickness = 40
        if let clip = scrollView?.contentView {
            clip.postsBoundsChangedNotifications = true
            NotificationCenter.default.addObserver(self, selector: #selector(scrolled), name: NSView.boundsDidChangeNotification, object: clip)
        }
    }
    required init(coder: NSCoder) { fatalError() }

    @objc private func scrolled() { needsDisplay = true }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        NSColor(Theme.Color.gutterBg).setFill()
        bounds.fill()
        NSColor(Theme.Color.borderSoft).setFill()
        NSRect(x: bounds.maxX - 1, y: 0, width: 1, height: bounds.height).fill()
        guard let view = clientView as? NSTextView, let layout = view.layoutManager, let container = view.textContainer else { return }
        let text = view.string as NSString
        let glyphs = layout.glyphRange(forBoundingRect: view.visibleRect, in: container)
        let chars = layout.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        let attributes: [NSAttributedString.Key: Any] = [.font: CodeEditor.font, .foregroundColor: NSColor(Theme.Color.textGutter)]
        let offset = convert(NSPoint.zero, from: view).y + view.textContainerOrigin.y
        var line = text.substring(to: chars.location).reduce(1) { $1 == "\n" ? $0 + 1 : $0 }
        var index = chars.location
        repeat {
            let lineRange = text.lineRange(for: NSRange(location: index, length: 0))
            let glyph = layout.glyphIndexForCharacter(at: lineRange.location)
            let rect = glyph < layout.numberOfGlyphs ? layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil) : layout.extraLineFragmentRect
            let label = NSAttributedString(string: "\(line)", attributes: attributes)
            let size = label.size()
            label.draw(at: NSPoint(x: bounds.maxX - 1 - size.width, y: offset + rect.minY + (rect.height - size.height) / 2))
            line += 1
            index = NSMaxRange(lineRange)
        } while index < NSMaxRange(chars)
    }
}

/// Keywords, builtins, strings, comments and function names in the design's colours
/// (tokens.md «Подсветка кода»); enough to read code, not a parser.
@MainActor
enum Highlighter {
    static let keywords = ["def", "return", "import", "from", "as", "if", "elif", "else", "for", "while", "in",
                           "not", "and", "or", "with", "try", "except", "finally", "raise", "async", "await",
                           "class", "lambda", "None", "True", "False", "pass", "break", "continue", "yield", "is"]
    static let builtins = ["str", "int", "float", "bool", "dict", "list", "tuple", "set", "bytes", "zip", "len",
                           "range", "enumerate", "map", "filter", "sorted", "min", "max", "sum", "any", "all",
                           "print", "isinstance", "object", "type", "Exception", "ValueError", "KeyError"]
    static let keywordRegex = try! NSRegularExpression(pattern: "\\b(" + keywords.joined(separator: "|") + ")\\b")
    static let builtinRegex = try! NSRegularExpression(pattern: "\\b(" + builtins.joined(separator: "|") + ")\\b")
    static let stringRegex = try! NSRegularExpression(pattern: #"(f?\"\"\"[\s\S]*?\"\"\"|f?'''[\s\S]*?'''|f?\"(?:[^\"\\\n]|\\.)*\"|f?'(?:[^'\\\n]|\\.)*')"#)
    static let commentRegex = try! NSRegularExpression(pattern: "#[^\\n]*")
    static let defRegex = try! NSRegularExpression(pattern: "(?<=def )[A-Za-z_][A-Za-z0-9_]*")

    static let comment = NSColor(Theme.Color.textDisabled)       // #6E6E76
    static let keyword = NSColor(Color(hex: 0xC792EA))
    static let string = NSColor(Color(hex: 0xC3E88D))
    static let function = NSColor(Color(hex: 0x82AAFF))
    static let builtin = NSColor(Color(hex: 0x4FD1D9))

    /// Font, text.code, line height 19.
    static let base: [NSAttributedString.Key: Any] = {
        let paragraph = NSMutableParagraphStyle()
        paragraph.minimumLineHeight = 19
        paragraph.maximumLineHeight = 19
        return [.font: CodeEditor.font, .foregroundColor: NSColor(Theme.Color.textCode), .paragraphStyle: paragraph,
                // TextKit puts the extra leading above the glyphs; CSS splits it, so lift by half.
                .baselineOffset: (19 - CodeEditor.font.ascender + CodeEditor.font.descender) / 2]
    }()

    static func apply(to storage: NSTextStorage) {
        let text = storage.string
        let all = NSRange(location: 0, length: (text as NSString).length)
        storage.beginEditing()
        storage.setAttributes(base, range: all)
        func paint(_ regex: NSRegularExpression, _ color: NSColor) {
            for m in regex.matches(in: text, range: all) { storage.addAttribute(.foregroundColor, value: color, range: m.range) }
        }
        paint(keywordRegex, keyword)
        paint(builtinRegex, builtin)
        paint(defRegex, function)
        paint(stringRegex, string)
        paint(commentRegex, comment)
        storage.endEditing()
    }
}
