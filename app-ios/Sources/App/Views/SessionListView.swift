import DshCore
import SwiftUI

/// The host's conversations, newest first.
struct SessionListView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        List {
            Section {
                ForEach(app.sessions) { session in
                    NavigationLink(value: session.sessionId) {
                        SessionRow(session: session)
                    }
                }
            } header: {
                statusHeader
            }
        }
        .overlay {
            if app.sessions.isEmpty {
                ContentUnavailableView(
                    app.connected ? "还没有对话" : "未连接",
                    systemImage: app.connected ? "bubble.left.and.bubble.right" : "antenna.radiowaves.left.and.right.slash",
                    description: Text(app.connected ? "新建一个对话开始。" : statusText)
                )
            }
        }
        .navigationTitle("DSH Go")
        .navigationDestination(for: String.self) { sessionId in
            if let client = app.client {
                ChatView(model: ChatModel(sessionId: sessionId, client: client))
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Menu {
                    ForEach(app.store.hosts) { host in
                        Button {
                            app.connect(to: host)
                        } label: {
                            Label(
                                host.name,
                                systemImage: host.id == app.activeHostId ? "checkmark.circle.fill" : "server.rack"
                            )
                        }
                    }
                    Divider()
                    NavigationLink {
                        HostFormView(existing: app.activeConfig)
                    } label: {
                        Label("编辑当前主机", systemImage: "square.and.pencil")
                    }
                    NavigationLink {
                        HostFormView(existing: nil)
                    } label: {
                        Label("添加主机", systemImage: "plus")
                    }
                    Button(role: .destructive) {
                        app.disconnect()
                    } label: {
                        Label("断开", systemImage: "xmark.circle")
                    }
                } label: {
                    Image(systemName: "server.rack")
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task { await newSession() }
                } label: {
                    Image(systemName: "square.and.pencil")
                }
                .disabled(!app.connected)
            }
        }
        .refreshable {
            await app.refreshSessions()
        }
        .task {
            if app.activeHostId == nil, let first = app.store.hosts.first {
                app.connect(to: first)
            }
        }
        .onChange(of: app.connected) {
            if app.connected {
                Task { await app.refreshSessions() }
            }
        }
    }

    private var statusHeader: some View {
        HStack(spacing: 6) {
            Image(systemName: app.connected ? "circle.fill" : "circle.dashed")
                .font(.system(size: 8))
                .foregroundStyle(app.connected ? .green : .orange)
            Text(statusText)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .textCase(nil)
    }

    private var statusText: String {
        if app.reconnecting { return "连接中…" }
        switch app.phase {
        case .connected: return app.activeConfig?.name ?? "已连接"
        case .idle: return "未连接"
        case .connecting, .verifyingHostKey: return "连接中…"
        case .startingDsh: return "启动引擎…"
        case .tunneling: return "建立隧道…"
        case .loggingIn: return "登录…"
        case let .failed(reason): return "连接失败：\(reason)"
        }
    }

    private func newSession() async {
        guard let client = app.client else { return }
        do {
            _ = try await client.createSession(
                cwd: RemoteDshBootstrap.absolutePath(app.activeConfig?.workingDirectory, home: nil)
            )
            await app.refreshSessions()
        } catch {
            app.lastError = "\(error)"
        }
    }
}

struct SessionRow: View {
    let session: SessionSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(session.title ?? (session.blank ? "新对话" : String(session.sessionId.prefix(8))))
                    .lineLimit(1)
                    .font(.body)
                if session.running {
                    Image(systemName: "waveform")
                        .font(.caption)
                        .foregroundStyle(.green)
                }
            }
            HStack(spacing: 8) {
                Text(session.updatedAt, style: .relative)
                if let cwd = session.cwd {
                    Text(cwd)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }
}
