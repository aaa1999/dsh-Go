import DshCore
import Foundation
import Observation

/// An unseen host key awaiting the person's decision (TOFU).
struct HostKeyPrompt: Identifiable {
    let id = UUID()
    let config: SshHostConfig
    let fingerprint: String
    let resolve: (Bool) -> Void
}

/// App-wide state: the saved hosts, the active link and its phase, the
/// session list. The whole iOS build is this remote client; there is no
/// local-engine mode.
@MainActor
@Observable
final class AppModel {
    let store: HostStore

    var phase: HostLinkPhase = .idle
    var activeHostId: String?
    var sessions: [SessionSummary] = []
    var lastError: String?
    var pendingHostKey: HostKeyPrompt?
    var reconnecting = false

    private(set) var link: SshHostLink?
    private(set) var client: DshClient?
    private var loadSessionsTask: Task<Void, Never>?

    init(store: HostStore) {
        self.store = store
    }

    var activeConfig: SshHostConfig? {
        guard let activeHostId else { return nil }
        return store.hosts.first { $0.id == activeHostId }
    }

    var connected: Bool {
        if case .connected = phase { return true }
        return false
    }

    func connect(to config: SshHostConfig) {
        guard link == nil || activeHostId != config.id else { return }
        disconnect()
        activeHostId = config.id
        let link = SshHostLink(
            config: config,
            password: { [weak self] in
                guard let self, let id = self.activeHostId else { return "" }
                return Keychain.password(for: id) ?? ""
            },
            pinnedFingerprint: store.fingerprint(for: config.id),
            decideNewKey: { [weak self] fingerprint, config in
                await self?.confirmHostKey(fingerprint: fingerprint, config: config) ?? false
            }
        )
        self.link = link
        link.onPhaseChange = { [weak self] phase in
            Task { @MainActor in
                self?.phase = phase
            }
        }
        reconnecting = true
        Task { [weak self] in
            guard let self else { return }
            do {
                let client = try await link.connect()
                self.client = client
                self.lastError = nil
                await self.refreshSessions()
            } catch {
                self.lastError = "\(error)"
                self.phase = .failed("\(error)")
            }
            self.reconnecting = false
        }
    }

    /// TOFU: an unseen host key needs the person's confirmation. Returns once
    /// the dialog is answered; a pin is stored on trust.
    private func confirmHostKey(fingerprint: String, config: SshHostConfig) async -> Bool {
        await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            Task { @MainActor in
                self.pendingHostKey = HostKeyPrompt(config: config, fingerprint: fingerprint) { [weak self] trusted in
                    if trusted {
                        self?.store.pin(fingerprint: fingerprint, for: config.id)
                    }
                    cont.resume(returning: trusted)
                }
            }
        }
    }

    /// Resolves the pending prompt (true = trust). Dismissing the sheet also
    /// lands here as a rejection, so the continuation never dangles.
    func answerHostKey(_ trusted: Bool) {
        pendingHostKey?.resolve(trusted)
        pendingHostKey = nil
    }

    func refreshSessions() async {
        guard let client else { return }
        loadSessionsTask?.cancel()
        loadSessionsTask = Task { [weak self] in
            guard let self else { return }
            do {
                let sessions = try await client.listSessions()
                if !Task.isCancelled {
                    self.sessions = sessions.filter { !$0.isSubagent }
                }
            } catch {
                if !Task.isCancelled {
                    self.lastError = "\(error)"
                }
            }
        }
    }

    /// A network change (Wi-Fi ↔ cellular): give the link a kick.
    func kick() {
        link?.kick()
    }

    func disconnect() {
        link?.close()
        link = nil
        client = nil
        sessions = []
        activeHostId = nil
        phase = .idle
    }
}
