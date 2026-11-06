import DshCore
import SwiftUI

@main
struct DshGoApp: App {
    @State private var app = AppModel(store: HostStore())

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(app)
        }
    }
}

/// The iOS build is a remote-only client: the engine runs on a host reached
/// over SSH (a Linux server or any machine with `dsh` installed), never on
/// the phone. First run starts at host setup; then the session list.
struct RootView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var app = app
        return NavigationStack {
            if app.store.hosts.isEmpty {
                HostFormView(existing: nil)
            } else {
                SessionListView()
            }
        }
        .sheet(item: $app.pendingHostKey, onDismiss: {
            // A swipe-down must not leave the handshake hanging: it decides.
            app.answerHostKey(false)
        }) { pending in
            HostKeySheet(config: pending.config, fingerprint: pending.fingerprint) {
                app.answerHostKey(true)
            } onReject: {
                app.answerHostKey(false)
            }
            .interactiveDismissDisabled()
        }
    }
}

/// TOFU: the server's key was never seen before.
struct HostKeySheet: View {
    let config: SshHostConfig
    let fingerprint: String
    let onTrust: () -> Void
    let onReject: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "key.horizontal")
                .font(.system(size: 40))
                .foregroundStyle(.tint)
            Text("首次连接 \(config.name)")
                .font(.title3.bold())
            Text("确认服务器 \(config.address) 的指纹：")
                .foregroundStyle(.secondary)
            Text(fingerprint)
                .font(.system(.footnote, design: .monospaced))
                .textSelection(.enabled)
                .padding(12)
                .background(.fill.tertiary, in: RoundedRectangle(cornerRadius: 10))
            Text("指纹不匹配时请拒绝连接并检查服务器。")
                .font(.footnote)
                .foregroundStyle(.secondary)
            HStack(spacing: 12) {
                Button("拒绝", role: .destructive, action: onReject)
                    .buttonStyle(.bordered)
                Button("信任并连接", action: onTrust)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .presentationDetents([.medium])
    }
}
