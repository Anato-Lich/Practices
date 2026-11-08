import SwiftUI
import AppKit
import PracticesCore

/// A space's `conventions.md` read in the app (and edited with «Править»), then its `templates/`
/// — each opens into its text with «Скопировать». Agents read the same through `get_conventions`.
struct ConventionsView: View {
    @Environment(RegistryModel.self) private var registry
    let space: String
    @State private var openTemplate: String?
    @State private var draft: String?

    private var file: URL { registry.registry.dir(ofSpace: space).appendingPathComponent("conventions.md") }

    var body: some View {
        let text = registry.registry.conventions(of: space)
        let templates = registry.registry.templates(of: space)
        Group {
            if draft != nil {
                MarkdownEditor(draft: $draft, original: text ?? "", what: "соглашения", height: nil) {
                    await registry.saveConventions($0, of: space)
                }
                .frame(maxWidth: 820)
                .padding(.horizontal, 20).padding(.vertical, 16)
                .frame(maxWidth: .infinity)
            } else {
                page(text, templates)
            }
        }
        .toolbarTrailing {
            if draft == nil {
                ToolbarButton(text == nil ? "Добавить" : "Править", systemImage: "pencil", prominent: true) { draft = text ?? "" }
            }
            Button { NSWorkspace.shared.open(file) } label: { Text(verbatim: "Открыть в редакторе") }.disabled(text == nil)
            Button { NSWorkspace.shared.activateFileViewerSelecting([file]) } label: { Text(verbatim: "Показать в Finder") }.disabled(text == nil)
        }
        .onAppear {
            #if DEBUG
            // DevRender: `--template <path>` opens that template, `--edit` the editor.
            let args = CommandLine.arguments
            if let i = args.firstIndex(of: "--template"), i + 1 < args.count { openTemplate = args[i + 1] }
            if args.contains("--edit") { draft = text ?? "" }
            #endif
        }
    }

    private func page(_ text: String?, _ templates: [(path: String, text: String)]) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                if let text {
                    MarkdownView(text: text)
                } else {
                    Text(verbatim: "Соглашений нет").font(Theme.ui(13)).foregroundStyle(Theme.Color.textMuted)
                }
                if !templates.isEmpty {
                    SectionTitle("Шаблоны · \(templates.count)").padding(.top, 18)
                    ForEach(templates, id: \.path) { template(path: $0.path, text: $0.text) }
                }
            }
            .frame(maxWidth: 720, alignment: .leading)
            .padding(.horizontal, 20).padding(.vertical, 20)
            .frame(maxWidth: .infinity)
        }
    }

    private func template(path: String, text: String) -> some View {
        let open = openTemplate == path
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Button { openTemplate = open ? nil : path } label: {
                    HStack(spacing: 8) {
                        Image(systemName: open ? "chevron.down" : "chevron.right").font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Theme.Color.textMuted).frame(width: 12)
                        Text(verbatim: "templates/" + path).font(Theme.mono(12.5)).foregroundStyle(Theme.Color.text)
                        Text(verbatim: ru(text.split(separator: "\n").count, "строка", "строки", "строк"))
                            .font(Theme.ui(11)).foregroundStyle(Theme.Color.textMuted)
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if open {
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(text, forType: .string)
                    } label: { Text(verbatim: "Скопировать") }
                    .buttonStyle(CompactButtonStyle(height: 22, fontSize: 11.5))
                }
            }
            if open { CodeBlock(text: text) }
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .background(Theme.Color.cardBg, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.Color.borderCard))
    }
}
