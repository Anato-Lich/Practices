import SwiftUI
import PracticesCore

/// Last lines of one container's log, re-read every two seconds while following.
struct LogsView: View {
    static let windowID = "logs"

    @Environment(MonitorModel.self) private var model
    let containerID: String
    @State private var text = ""
    @State private var following = true
    @State private var error: String?

    private var container: Container? {
        model.snapshot?.containers?.first { $0.id == containerID }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(verbatim: container?.name ?? String(containerID.prefix(12))).font(.headline)
                if let status = container?.status {
                    Text(verbatim: status).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("Follow", isOn: $following).toggleStyle(.switch).controlSize(.small)
                Button { Task { await load() } } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless)
            }
            .padding(10)
            Divider()
            ScrollViewReader { proxy in
                ScrollView([.vertical, .horizontal]) {
                    Text(verbatim: error ?? text)
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                    Color.clear.frame(height: 1).id("end")
                }
                .onChange(of: text) { if following { proxy.scrollTo("end", anchor: .bottom) } }
            }
        }
        .navigationTitle(container?.name ?? "Logs")
        .task(id: containerID) {
            while !Task.isCancelled {
                if following || text.isEmpty { await load() }
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    private func load() async {
        do {
            text = try await Docker.logs(containerID, tail: 500)
            error = nil
        } catch {
            self.error = String(describing: error)
        }
    }
}
