import SwiftUI
import AppKit
import PracticesCore

/// Markdown laid out natively: headings, lists, paragraphs with inline code and emphasis
/// (`AttributedString(markdown:)`), fenced code and tables as code blocks. `size` is the body's.
struct MarkdownView: View {
    let text: String
    var size: CGFloat = 13

    var body: some View {
        VStack(alignment: .leading, spacing: size * 0.75) {
            ForEach(Array(MarkdownBlock.parse(text).enumerated()), id: \.offset) { _, block in self.block(block) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
    }

    @ViewBuilder private func block(_ block: MarkdownBlock) -> some View {
        switch block {
        case .heading(let level, let text):
            let heading = level == 1 ? size + 9 : level == 2 ? size + 3 : size + 1
            Self.inline(text, heading).font(Theme.ui(heading, .semibold)).foregroundStyle(Theme.Color.text)
                .padding(.top, level == 1 ? 0 : size)
        case .paragraph(let text):
            Self.inline(text, size).font(Theme.ui(size)).foregroundStyle(Theme.Color.textCode).lineSpacing(3)
        case .item(let indent, let marker, let text):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(verbatim: marker).foregroundStyle(Theme.Color.textMuted).frame(minWidth: 12, alignment: .trailing)
                Self.inline(text, size).foregroundStyle(Theme.Color.textCode).lineSpacing(3)
            }
            .font(Theme.ui(size))
            .padding(.leading, CGFloat(indent) * 18)
        case .code(_, let text), .table(let text):
            CodeBlock(text: text)
        }
    }

    private static func inline(_ text: String, _ size: CGFloat) -> some View {
        var attributed = (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
        // Inline code in the chip colour, a size smaller: SF Mono runs wider than the text around it.
        for run in attributed.runs where run.inlinePresentationIntent?.contains(.code) == true {
            attributed[run.range].foregroundColor = Theme.Color.textChip
            attributed[run.range].font = Theme.mono(size - 1)
        }
        return Text(attributed).fixedSize(horizontal: false, vertical: true)
    }
}

/// Code as written: mono 12 on code.bg, scrolled sideways rather than wrapped.
struct CodeBlock: View {
    let text: String
    var body: some View {
        ScrollView(.horizontal) {
            // A file's final newline would show as an empty last line.
            Text(verbatim: text.hasSuffix("\n") ? String(text.dropLast()) : text).font(Theme.mono(12)).foregroundStyle(Theme.Color.textCode).lineSpacing(4)
                .textSelection(.enabled).fixedSize()
                .padding(.horizontal, 14).padding(.vertical, 10)
        }
        .scrollIndicators(.never)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.Color.codeBg, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.Color.borderCard))
    }
}

/// The raw file in place of its rendering: ⌘S / «Сохранить», Esc / «Отмена». While the text
/// differs from the file, leaving the screen asks first (`RegistryModel.unsavedEdit`).
struct MarkdownEditor: View {
    @Environment(RegistryModel.self) private var registry
    /// Non-nil while editing; set to nil when saved or cancelled.
    @Binding var draft: String?
    let original: String
    /// «заметки», «соглашения»: what the guard says is unsaved.
    let what: String
    /// nil: as tall as the screen gives (a page of its own); a card's editor gets a fixed height.
    var height: CGFloat? = 260
    let save: (String) async -> Bool
    @State private var saving = false

    var body: some View {
        VStack(alignment: .trailing, spacing: 8) {
            TextEditor(text: Binding(get: { draft ?? "" }, set: { draft = $0 }))
                .font(Theme.mono(12)).foregroundStyle(Theme.Color.textCode)
                .autocorrectionDisabled()
                .scrollContentBackground(.hidden)
                .padding(.horizontal, 8).padding(.vertical, 8)
                .frame(minHeight: height ?? 200, maxHeight: height ?? .infinity)
                .background(Theme.Color.codeBg, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.Color.accent.opacity(0.6)))
            HStack(spacing: 6) {
                Text(verbatim: "⌘S — сохранить, Esc — отмена").font(Theme.ui(11)).foregroundStyle(Theme.Color.textMuted)
                Spacer(minLength: 0)
                Button { draft = nil } label: { Text(verbatim: "Отмена") }
                    .buttonStyle(CompactButtonStyle(fontSize: 12)).keyboardShortcut(.cancelAction)
                Button {
                    guard let text = draft else { return }
                    saving = true
                    Task {
                        if await save(text) { registry.unsavedEdit = nil; draft = nil }
                        saving = false
                    }
                } label: { Text(verbatim: "Сохранить") }
                    .buttonStyle(CompactButtonStyle(prominent: true, fontSize: 12)).keyboardShortcut("s")
                    .disabled(saving)
            }
        }
        .onChange(of: draft) { _, text in registry.unsavedEdit = text != nil && text != original ? what : nil }
        .onDisappear { registry.unsavedEdit = nil }
    }
}
