import Foundation

/// Connection state of one SSH host link, mirrored into the UI.
public enum HostLinkPhase: Equatable, Sendable {
    case idle
    case connecting
    case verifyingHostKey
    case startingDsh
    case tunneling
    case loggingIn
    case connected
    /// Retryable failure; [connect] starts over (or waits for the next attempt).
    case failed(String)
}

/// The whole chain to one SSH host (ssh_link.dart): connect → verify host key
/// → start `dsh web` → tunnel → login, then a live [DshClient] with the mux
/// reconnecting on top.
///
/// The local tunnel port stays stable across SSH reconnects, so the client's
/// base URL never changes; the forwarder cuts its pipes when SSH dies and the
/// mux's own backoff brings everything back once [recover] reconnects.
public final class SshHostLink: @unchecked Sendable {
    public let config: SshHostConfig

    private let password: () -> String
    private var pinnedFingerprint: String?
    /// Confirm an unseen host key (TOFU); return true to trust and pin it.
    private let decideNewKey: @Sendable (String, SshHostConfig) async -> Bool

    private(set) var transport: SshTransport?
    private(set) var forwarder: LocalForwarder?
    public private(set) var client: DshClient?
    private(set) var endpoint: RemoteDshEndpoint?

    private let stateLock = NSLock()
    private var phaseStorage: HostLinkPhase = .idle
    private var recoverTask: Task<Void, Never>?
    private var keepaliveTask: Task<Void, Never>?
    private var closed = false

    /// NSLock is unavailable inside async functions; this sync wrapper is not.
    private func withLock<T>(_ body: () -> T) -> T {
        stateLock.lock()
        defer { stateLock.unlock() }
        return body()
    }

    /// UI hook; called on arbitrary threads.
    public var onPhaseChange: (@Sendable (HostLinkPhase) -> Void)?

    public var phase: HostLinkPhase {
        withLock { phaseStorage }
    }

    private func setPhase(_ next: HostLinkPhase) {
        withLock { phaseStorage = next }
        onPhaseChange?(next)
    }

    public init(
        config: SshHostConfig,
        password: @escaping () -> String,
        pinnedFingerprint: String?,
        decideNewKey: @escaping @Sendable (String, SshHostConfig) async -> Bool
    ) {
        self.config = config
        self.password = password
        self.pinnedFingerprint = pinnedFingerprint
        self.decideNewKey = decideNewKey
    }

    /// Connects the whole chain once. Throws [HostLinkFailure] on a failure
    /// the caller should show.
    @discardableResult
    public func connect() async throws -> DshClient {
        try await connectOnce()
    }

    private func connectOnce() async throws -> DshClient {
        setPhase(.connecting)
        let transport = SshTransport(config: config)
        self.transport = transport
        transport.onDisconnect = { [weak self] in
            self?.recover()
        }
        setPhase(.verifyingHostKey)
        do {
            try await transport.connect(
                password: password(),
                pinnedFingerprint: pinnedFingerprint,
                decideNewKey: { [weak self] fingerprint in
                    guard let self else { return false }
                    let ok = await self.decideNewKey(fingerprint, self.config)
                    if ok { self.pinnedFingerprint = fingerprint }
                    return ok
                }
            )
        } catch let failure as HostLinkFailure {
            setPhase(.failed("\(failure)"))
            throw failure
        }

        // Start (or reuse) the remote engine.
        setPhase(.startingDsh)
        let bootstrap = RemoteDshBootstrap(
            launchCommand: config.launchCommand ?? defaultDshLaunchCommand,
            workingDirectory: config.workingDirectory
        )
        let run: (String, TimeInterval) async throws -> RemoteExecResult = { command, timeout in
            try await transport.run(command, timeout: timeout)
        }
        let endpoint: RemoteDshEndpoint
        do {
            endpoint = try await bootstrap.ensureRunning(run: run)
        } catch let failure as HostLinkFailure {
            setPhase(.failed("\(failure)"))
            throw failure
        }
        self.endpoint = endpoint

        // Local forward: a fresh listener per engine port.
        setPhase(.tunneling)
        forwarder?.shutdown()
        let forwarder: LocalForwarder
        do {
            forwarder = try await LocalForwarder(remotePort: endpoint.port) { [weak transport] port in
                guard let transport else { throw HostLinkFailure.connectionFailed("ssh closed") }
                return try await transport.openTunnelChannel(targetPort: port)
            }
        } catch let failure as HostLinkFailure {
            setPhase(.failed("\(failure)"))
            throw failure
        }
        self.forwarder = forwarder

        // Login: token → cookie, against the local forward port, presenting
        // the remote engine's authority as the Host header.
        setPhase(.loggingIn)
        let connection = DshConnection(
            baseUrl: URL(string: "http://127.0.0.1:\(forwarder.localPort)")!,
            hostHeader: endpoint.authority
        )
        do {
            try await connection.login(token: endpoint.token)
        } catch {
            // A reused engine whose cookie is gone: force a restart next time.
            setPhase(.failed("登录失败：\(error)"))
            throw HostLinkFailure.connectionFailed("login failed")
        }

        let client = DshClient(connection: connection)
        _ = try? await client.mux.ready()
        self.client = client
        setPhase(.connected)
        startKeepalive()
        return client
    }

    /// SSH died: cut the tunnel's pipes and reconnect the chain, keeping the
    /// same forwarder port so the mux's retry just works.
    private func recover() {
        guard !closed else { return }
        guard withLock({ recoverTask }) == nil else { return }
        let task = Task { [weak self] in
            guard let self else { return }
            defer {
                _ = self.withLock { self.recoverTask = nil }
            }
            self.forwarder?.dropConnections()
            // Backoff like the mux's caps.
            for attempt in 0... {
                guard !self.closed, !Task.isCancelled else { return }
                do {
                    _ = try await self.connectOnce()
                    return
                } catch HostLinkFailure.hostKeyMismatch {
                    // A changed server key needs the person, not a retry.
                    return
                } catch {
                    let caps: [TimeInterval] = [0.5, 1, 2, 4, 8, 10]
                    let cap = caps[min(attempt, caps.count - 1)]
                    try? await Task.sleep(nanoseconds: UInt64(cap * 1_000_000_000))
                }
            }
        }
        withLock { recoverTask = task }
        _ = task
    }

    /// Public kick: the UI knows better than the socket that the network
    /// changed (e.g. Wi-Fi ↔ cellular). A quick SSH probe decides between a
    /// fast return and a full recovery.
    public func kick() {
        guard !closed else { return }
        Task { [weak self] in
            guard let self else { return }
            if let transport = self.transport, await transport.probeAlive() { return }
            self.recover()
        }
    }

    /// Liveness at the SSH layer: a no-op command on a timer (Citadel has no
    /// protocol-level keepalive); two misses in a row recover the link.
    private func startKeepalive() {
        keepaliveTask?.cancel()
        keepaliveTask = Task { [weak self] in
            var misses = 0
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 15_000_000_000)
                guard let self, !self.closed else { return }
                guard let transport = self.transport else { return }
                if await transport.probeAlive() {
                    misses = 0
                } else {
                    misses += 1
                    if misses >= 2 {
                        self.recover()
                        return
                    }
                }
            }
        }
    }

    public func close() {
        closed = true
        keepaliveTask?.cancel()
        recoverTask?.cancel()
        forwarder?.shutdown()
        let transport = self.transport
        let client = self.client
        self.transport = nil
        self.client = nil
        Task {
            await client?.close()
            await transport?.close()
        }
    }
}
