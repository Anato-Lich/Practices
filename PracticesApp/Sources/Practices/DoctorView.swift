import SwiftUI
import AppKit
import PracticesCore

/// Doctor's report (`design/Doctor.dc.html`). Only reports: nothing in the projects is changed,
/// and a finding carries names and paths, never values.
struct DoctorView: View {
    @Environment(RegistryModel.self) private var registry

    var body: some View {
        Group {
            if let findings = registry.findings, !registry.doctorRunning {
                if findings.isEmpty {
                    EmptyState(glyph: "✓", tint: Theme.Color.ok, title: "Нечего сообщать",
                               text: "Ни утечек, ни расхождений с реестром, ни общих секретов, ни копий.") {
                        StateButton("Запустить снова") { run() }
                    }
                    .padding(.horizontal, 20).padding(.vertical, 16)
                } else {
                    report(findings)
                }
            } else if registry.doctorRunning {
                ProgressView { Text(verbatim: "Читаю " + roots + "…") }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                EmptyState(glyph: "≠", tint: Theme.Color.link, title: "Doctor",
                           text: "Сравнивает .env и текстовые файлы в " + roots + " с реестром. В отчёт попадают имена и пути, не значения.") {
                    StateButton("Запустить", prominent: true) { run() }
                }
                .padding(.horizontal, 20).padding(.vertical, 16)
            }
        }
        .toolbarLeading {
            HStack(spacing: 12) {
                Text(verbatim: "Doctor").font(Theme.ui(15, .semibold)).foregroundStyle(Theme.Color.text)
                Text(verbatim: roots + " · сравнение с реестром · имена и пути, не значения")
                    .font(Theme.mono(12)).foregroundStyle(Theme.Color.textSecondary).lineLimit(1)
            }
        }
        .toolbarTrailing {
            Button { run() } label: { Label { Text(verbatim: "Запустить снова") } icon: { Image(systemName: "arrow.clockwise") } }
                .disabled(registry.doctorRunning)
        }
    }

    private func run() { Task { await registry.runDoctor() } }

    private var roots: String {
        registry.registry.searchRoots.map { ($0 as NSString).abbreviatingWithTildeInPath }.joined(separator: ", ")
    }

    private static let kinds: [DoctorFinding.Kind] = [.leak, .drift, .shared, .duplicate]

    private func report(_ findings: [DoctorFinding]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                ForEach(Self.kinds, id: \.self) { kind in
                    let n = findings.filter { $0.kind == kind }.count
                    StatTile(String(n), tileLabel(kind, n), color: kind.color)
                        .overlay {
                            if kind == .leak || kind == .drift {
                                RoundedRectangle(cornerRadius: 8).strokeBorder(kind.color.opacity(0.45))
                            }
                        }
                }
            }
            ScrollView {
                VStack(spacing: 10) {
                    ForEach(Self.kinds, id: \.self) { kind in
                        let items = findings.filter { $0.kind == kind }
                        if !items.isEmpty { section(kind, items) }
                    }
                }
            }
            Text(verbatim: "Doctor только читает: ничего в проектах не меняет. Значения в отчёт не попадают, в каталог тоже.")
                .font(Theme.ui(11)).foregroundStyle(Theme.Color.textMuted)
        }
        .padding(.horizontal, 20).padding(.vertical, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func section(_ kind: DoctorFinding.Kind, _ items: [DoctorFinding]) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                SectionTitle(title(kind) + " · \(items.count)", color: kind.color)
                Spacer(minLength: 8)
                Text(verbatim: footer(kind)).font(Theme.ui(11)).foregroundStyle(Theme.Color.textMuted).lineLimit(1)
            }
            .padding(.horizontal, 14).padding(.vertical, 8)
            .overlay(alignment: .bottom) { Theme.Color.borderCard.frame(height: 1) }
            ForEach(items, id: \.self) { row($0) }
        }
        .background(Theme.Color.cardBg, in: RoundedRectangle(cornerRadius: 10))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10)
            .strokeBorder(kind == .leak || kind == .drift ? kind.color.opacity(0.45) : Theme.Color.borderCard))
    }

    private func row(_ finding: DoctorFinding) -> some View {
        let kind = finding.kind
        // For shared, `related` are other files; otherwise service ids.
        let services = kind == .shared ? [] : finding.related.compactMap(registry.service)
        return HStack(spacing: 12) {
            Text(verbatim: kind.glyph).font(Theme.mono(12, .semibold)).foregroundStyle(kind.color)
                .frame(width: 22, height: 22)
                .background(kind.color.opacity(0x22 / 255), in: RoundedRectangle(cornerRadius: 6))
            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: short(finding.path)).font(Theme.mono(12)).foregroundStyle(Theme.Color.text)
                    .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                Text(verbatim: finding.keys.joined(separator: ", ")).font(Theme.mono(10.5)).foregroundStyle(Theme.Color.textSecondary)
                if let related = relation(finding) {
                    Text(verbatim: related).font(Theme.mono(10.5)).foregroundStyle(Theme.Color.textMuted).lineLimit(2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            ForEach(services, id: \.id) { service in
                Button { registry.selection = .service(service.id) } label: {
                    Text(verbatim: service.id).font(Theme.mono(11)).foregroundStyle(ServiceClass(for: service).color)
                }
                .buttonStyle(CompactButtonStyle(fontSize: 11))
            }
            Button { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: finding.path)]) } label: {
                Text(verbatim: "Finder")
            }
            .buttonStyle(CompactButtonStyle(fontSize: 12))
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .overlay(alignment: .bottom) { Color(hex: 0x2E2E33).frame(height: 1) }
    }

    /// The finding's tie to the registry, from what `DoctorFinding` carries.
    private func relation(_ f: DoctorFinding) -> String? {
        guard !f.related.isEmpty else { return nil }
        switch f.kind {
        case .leak: return "совпадает с " + f.related.joined(separator: ", ")
        case .drift: return "реестр: " + f.related.joined(separator: ", ") + ", другое значение"
        case .shared: return f.related.map { "= " + short($0) }.joined(separator: " · ")
        case .duplicate:
            let env = registry.service(f.related[0]).map { "@" + $0.defaultEnv } ?? ""
            return "practicesctl run \(f.related[0])\(env) -- …"
        }
    }

    private func title(_ kind: DoctorFinding.Kind) -> String {
        switch kind {
        case .leak: "Секреты в открытом виде"
        case .drift: "Расходится с реестром"
        case .shared: "Один секрет в нескольких проектах"
        case .duplicate: "Копии реестра"
        }
    }

    private func footer(_ kind: DoctorFinding.Kind) -> String {
        switch kind {
        case .leak: "значение из реестра записано в файл — вынести и удалить копию"
        case .drift: "ключ есть в реестре с другим значением — одно из них устарело"
        case .shared: "одно значение под разными именами — сервис, которого в реестре ещё нет"
        case .duplicate: "все ключи совпадают с реестром — файл можно заменить на practicesctl run"
        }
    }

    private func tileLabel(_ kind: DoctorFinding.Kind, _ n: Int) -> String {
        switch kind {
        case .leak: String(ru(n, "секрет", "секрета", "секретов").drop { $0 != " " }.dropFirst()) + " в открытом виде"
        case .drift: "расходится с реестром"
        case .shared: "один секрет в нескольких проектах"
        case .duplicate: "копия реестра — можно заменить на practicesctl run"
        }
    }

    private func short(_ path: String) -> String { (path as NSString).abbreviatingWithTildeInPath }
}

private extension DoctorFinding.Kind {
    var color: Color {
        switch self {
        case .leak: Theme.Color.error
        case .drift: Theme.Color.warn
        case .shared: ServiceClass.api.color
        case .duplicate: Theme.Color.textSecondary
        }
    }
    var glyph: String {
        switch self {
        case .leak: "!"
        case .drift: "≠"
        case .shared: "⧉"
        case .duplicate: "="
        }
    }
}
