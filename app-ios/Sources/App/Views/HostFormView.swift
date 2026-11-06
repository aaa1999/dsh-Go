import DshCore
import SwiftUI

/// Add or edit an SSH host. The password goes straight to the Keychain.
struct HostFormView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var host = ""
    @State private var port = "22"
    @State private var username = ""
    @State private var password = ""
    @State private var workingDirectory = ""

    private let existing: SshHostConfig?

    init(existing: SshHostConfig?) {
        self.existing = existing
        if let existing {
            _name = State(initialValue: existing.name)
            _host = State(initialValue: existing.host)
            _port = State(initialValue: String(existing.port))
            _username = State(initialValue: existing.username)
            _workingDirectory = State(initialValue: existing.workingDirectory ?? "")
        }
    }

    private var valid: Bool {
        !host.trimmingCharacters(in: .whitespaces).isEmpty
            && !username.trimmingCharacters(in: .whitespaces).isEmpty
            && (Int(port) ?? 0) > 0
            && (existing != nil || !password.isEmpty)
    }

    var body: some View {
        Form {
            Section("服务器") {
                TextField("名称（如：我的服务器）", text: $name)
                TextField("主机（如：203.0.113.10）", text: $host)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                TextField("端口", text: $port)
                    .keyboardType(.numberPad)
                TextField("用户名", text: $username)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }
            Section {
                SecureField(existing == nil ? "密码" : "密码（留空保持不变）", text: $password)
            } footer: {
                Text("密码只存在手机的钥匙串里。服务器需要有 SSH，并已安装 dsh（`npm i -g @deepseek-ai/dsh`）；没有装的话 App 会给出提示。")
            }
            Section {
                TextField("工作目录（可选，支持 ~）", text: $workingDirectory)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            } footer: {
                Text("引擎在这个目录里运行；留空用服务器上 dsh 的默认目录。")
            }
            Section {
                Button(existing == nil ? "添加并连接" : "保存") { save() }
                    .frame(maxWidth: .infinity)
                    .disabled(!valid)
            }
            if existing != nil {
                Section {
                    Button("删除这台主机", role: .destructive) { delete() }
                        .frame(maxWidth: .infinity)
                }
            }
        }
        .navigationTitle(existing == nil ? "添加 SSH 主机" : "编辑主机")
    }

    private func save() {
        var config =
            existing
            ?? SshHostConfig(name: "", host: "", username: "")
        config.name = name.trimmingCharacters(in: .whitespaces).isEmpty ? host : name
        config.host = host.trimmingCharacters(in: .whitespaces)
        config.port = Int(port) ?? 22
        config.username = username.trimmingCharacters(in: .whitespaces)
        config.workingDirectory = workingDirectory.isEmpty ? nil : workingDirectory
        app.store.save(config, password: password.isEmpty ? nil : password)
        if let first = app.store.hosts.first, app.activeHostId == nil {
            app.connect(to: first)
        }
        dismiss()
    }

    private func delete() {
        if let existing {
            app.store.remove(hostId: existing.id)
            if app.activeHostId == existing.id {
                app.disconnect()
            }
        }
        dismiss()
    }
}
