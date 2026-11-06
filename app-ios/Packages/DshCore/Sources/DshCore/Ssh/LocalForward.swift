import Foundation
import Network
import NIOCore

/// Local half of the SSH tunnel (local_forward.dart): a listener on a local
/// temporary port. Every accepted TCP connection opens a fresh direct-tcpip
/// channel to the remote `127.0.0.1:<port>` and pipes bytes both ways.
///
/// The listener outlives SSH reconnects: [dropConnections] cuts every live
/// pipe when the SSH connection goes down (the engine's WebSocket notices at
/// once and retries); new local connections wait for the channel opener to
/// work again, up to the tunnel wait limit.
public final class LocalForwarder: @unchecked Sendable {
    public let localPort: Int
    private let state: ForwardState

    public init(
        remotePort: Int,
        openChannel: @escaping @Sendable (Int) async throws -> Channel
    ) async throws {
        let state = ForwardState(remotePort: remotePort, openChannel: openChannel)
        self.state = state
        // Bind on loopback only and read the OS-assigned port before returning.
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: params, on: .any)
        state.listener = listener
        let port: Int = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Int, Error>) in
            let resumed = ResumeOnce()
            listener.stateUpdateHandler = { listenerState in
                switch listenerState {
                case .ready:
                    if let raw = listener.port?.rawValue, let port = Int(exactly: raw), resumed.claim() {
                        cont.resume(returning: port)
                    }
                case let .failed(error):
                    if resumed.claim() {
                        cont.resume(throwing: HostLinkFailure.connectionFailed("tunnel listener: \(error)"))
                    }
                default:
                    break
                }
            }
            listener.newConnectionHandler = { [weak state] connection in
                state?.accept(connection)
            }
            listener.start(queue: state.queue)
        }
        self.localPort = port
    }

    /// Cuts every live pipe (SSH died); the listener stays for the reconnect.
    public func dropConnections() {
        state.dropConnections()
    }

    public func shutdown() {
        state.shutdown()
    }
}

/// Mutable tunnel state, independent of the forwarder's init order.
final class ForwardState: @unchecked Sendable {
    let remotePort: Int
    let openChannel: @Sendable (Int) async throws -> Channel
    let tunnelWaitLimit: TimeInterval = 20
    let queue = DispatchQueue(label: "dsh.local-forward")
    var listener: NWListener?
    var pipes: [ObjectIdentifier: TunnelPipe] = [:]

    init(remotePort: Int, openChannel: @escaping @Sendable (Int) async throws -> Channel) {
        self.remotePort = remotePort
        self.openChannel = openChannel
    }

    func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        let pipe = TunnelPipe(
            local: connection,
            remotePort: remotePort,
            openChannel: openChannel,
            tunnelWaitLimit: tunnelWaitLimit
        )
        pipes[ObjectIdentifier(pipe)] = pipe
        pipe.onClose = { [weak self, weak pipe] in
            guard let self, let pipe else { return }
            self.queue.async { self.pipes[ObjectIdentifier(pipe)] = nil }
        }
        pipe.start()
    }

    func dropConnections() {
        queue.async {
            for pipe in self.pipes.values {
                pipe.cancel()
            }
            self.pipes.removeAll()
        }
    }

    func shutdown() {
        queue.async {
            for pipe in self.pipes.values {
                pipe.cancel()
            }
            self.pipes.removeAll()
            self.listener?.cancel()
            self.listener = nil
        }
    }
}

/// One accepted local connection wired to one direct-tcpip channel.
final class TunnelPipe: @unchecked Sendable {
    private let local: NWConnection
    private let remotePort: Int
    private let openChannel: @Sendable (Int) async throws -> Channel
    private let tunnelWaitLimit: TimeInterval
    private var channel: Channel?
    private var pending: [Data] = []
    private var closed = false
    var onClose: (() -> Void)?

    init(
        local: NWConnection,
        remotePort: Int,
        openChannel: @escaping @Sendable (Int) async throws -> Channel,
        tunnelWaitLimit: TimeInterval
    ) {
        self.local = local
        self.remotePort = remotePort
        self.openChannel = openChannel
        self.tunnelWaitLimit = tunnelWaitLimit
    }

    func start() {
        receiveLocal()
        Task { [weak self] in
            guard let self else { return }
            do {
                let channel = try await self.waitForChannel()
                self.channelReady(channel)
            } catch {
                self.cancel()
            }
        }
    }

    /// Waits out an SSH reconnect: the tunnel may come back any moment; past
    /// the limit the local side sees a dead connection, exactly like a
    /// refused tunnel.
    private func waitForChannel() async throws -> Channel {
        try await withThrowingTaskGroup(of: Channel.self) { group in
            group.addTask { [weak self] in
                guard let self else { throw HostLinkFailure.connectionFailed("pipe gone") }
                while !Task.isCancelled {
                    do {
                        return try await self.openChannel(self.remotePort)
                    } catch {
                        try? await Task.sleep(nanoseconds: 300_000_000)
                    }
                }
                throw HostLinkFailure.connectionFailed("tunnel wait cancelled")
            }
            group.addTask { [weak self] in
                guard let self else { throw HostLinkFailure.connectionFailed("pipe gone") }
                try? await Task.sleep(nanoseconds: UInt64(self.tunnelWaitLimit * 1_000_000_000))
                throw HostLinkFailure.connectionFailed("tunnel wait timed out")
            }
            guard let first = try await group.next() else {
                throw HostLinkFailure.connectionFailed("tunnel wait ended")
            }
            group.cancelAll()
            return first
        }
    }

    private func channelReady(_ channel: Channel) {
        guard !closed else {
            channel.close(promise: nil)
            return
        }
        self.channel = channel
        channel.closeFuture.whenComplete { [weak self] _ in
            self?.cancel()
        }
        // Forward remote bytes to the local socket.
        let sink = RemoteSink { [weak self] data in
            self?.sendLocal(data)
        }
        _ = channel.pipeline.addHandler(sink)
        _ = channel.setOption(ChannelOptions.autoRead, value: true)
        for data in pending {
            writeRemote(data)
        }
        pending.removeAll()
    }

    private func receiveLocal() {
        local.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                self.writeRemote(Data(data))
            }
            if isComplete || error != nil {
                self.channel?.close(mode: .output, promise: nil)
                return
            }
            self.receiveLocal()
        }
    }

    private func writeRemote(_ data: Data) {
        guard let channel else {
            pending.append(data)
            return
        }
        let buffer = ByteBuffer(bytes: [UInt8](data))
        channel.writeAndFlush(buffer, promise: nil)
    }

    private func sendLocal(_ data: Data) {
        guard !closed else { return }
        local.send(content: data, completion: .contentProcessed { _ in })
    }

    func cancel() {
        guard !closed else { return }
        closed = true
        local.cancel()
        channel?.close(promise: nil)
        onClose?()
    }
}

/// Reads ByteBuffer chunks off the SSH channel and hands the bytes to the pipe.
final class RemoteSink: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer

    private let receive: @Sendable (Data) -> Void

    init(receive: @escaping @Sendable (Data) -> Void) {
        self.receive = receive
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var buffer = unwrapInboundIn(data)
        if let bytes = buffer.readData(length: buffer.readableBytes) {
            receive(bytes)
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        context.close(promise: nil)
    }
}

/// One-time latch so a continuation resumes exactly once.
final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if claimed { return false }
        claimed = true
        return true
    }
}
