import Citadel
import CryptoKit
import Foundation
import NIOCore
import NIOSSH

/// An SSH host as the user configured it (credentials live in the Keychain;
/// this type carries only what a connection needs).
public struct SshHostConfig: Codable, Equatable, Identifiable {
    public var id: String
    public var name: String
    public var host: String
    public var port: Int
    public var username: String
    /// Working directory the engine runs in (`~` allowed).
    public var workingDirectory: String?
    public var launchCommand: String?

    public init(
        id: String = UUID().uuidString,
        name: String,
        host: String,
        port: Int = 22,
        username: String,
        workingDirectory: String? = nil,
        launchCommand: String? = nil
    ) {
        self.id = id
        self.name = name
        self.host = host
        self.port = port
        self.username = username
        self.workingDirectory = workingDirectory
        self.launchCommand = launchCommand
    }

    public var address: String { "\(host):\(port)" }
}

/// TOFU host-key validation (ssh_transport.dart's `checkHostKey`): a pinned
/// fingerprint must match; an unknown key goes to [decideNewKey] (the UI
/// confirms and pins); a mismatch fails closed.
final class TofuHostKeyDelegate: NIOSSHClientServerAuthenticationDelegate {
    let pinnedFingerprint: String?
    let decideNewKey: @Sendable (String) async -> Bool

    init(pinnedFingerprint: String?, decideNewKey: @escaping @Sendable (String) async -> Bool) {
        self.pinnedFingerprint = pinnedFingerprint
        self.decideNewKey = decideNewKey
    }

    func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        var buffer = ByteBuffer()
        hostKey.write(to: &buffer)
        let fingerprint = Crypto.openSshFingerprint(Data(buffer.readableBytesView))
        if let pinned = pinnedFingerprint {
            if pinned == fingerprint {
                validationCompletePromise.succeed(())
            } else {
                validationCompletePromise.fail(HostLinkFailure.hostKeyMismatch)
            }
            return
        }
        Task {
            if await decideNewKey(fingerprint) {
                validationCompletePromise.succeed(())
            } else {
                validationCompletePromise.fail(HostLinkFailure.hostKeyMismatch)
            }
        }
    }
}

/// One SSH connection: authentication (password for now), TOFU host keys,
/// command execution and direct-tcpip channels (ssh_transport.dart).
public final class SshTransport: @unchecked Sendable {
    public let config: SshHostConfig
    public private(set) var client: SSHClient?
    public private(set) var fingerprint: String?

    /// Set when the connection drops on its own.
    public var onDisconnect: (() -> Void)?

    private var disconnectHandlerInstalled = false

    public init(config: SshHostConfig) {
        self.config = config
    }

    /// Connects and authenticates. [password] comes from the Keychain.
    /// [pinnedFingerprint] is the TOFU pin; [decideNewKey] confirms an unknown
    /// key (return true to trust and pin it).
    public func connect(
        password: String,
        pinnedFingerprint: String?,
        decideNewKey: @escaping @Sendable (String) async -> Bool
    ) async throws {
        let delegate = TofuHostKeyDelegate(pinnedFingerprint: pinnedFingerprint, decideNewKey: decideNewKey)
        let username = config.username
        let settings = SSHClientSettings(
            host: config.host,
            port: config.port,
            authenticationMethod: { .passwordBased(username: username, password: password) },
            hostKeyValidator: .custom(delegate)
        )
        do {
            let client = try await SSHClient.connect(to: settings)
            self.client = client
            installDisconnectHandler()
        } catch let failure as HostLinkFailure {
            throw failure
        } catch {
            throw HostLinkFailure.connectionFailed(describeSshError(error))
        }
    }

    private func installDisconnectHandler() {
        guard !disconnectHandlerInstalled, let client else { return }
        disconnectHandlerInstalled = true
        client.onDisconnect { [weak self] in
            self?.onDisconnect?()
        }
    }

    public var isConnected: Bool {
        client?.isConnected ?? false
    }

    /// Runs [command], collecting stdout and stderr separately. A non-zero
    /// exit is not an error here: the result carries the exit code (the
    /// bootstrap parser needs the output either way).
    public func run(_ command: String, timeout: TimeInterval) async throws -> RemoteExecResult {
        guard let client else {
            throw HostLinkFailure.connectionFailed("not connected")
        }
        var stdout = ""
        var stderr = ""
        var exitCode: Int?
        do {
            let stream = try await client.executeCommandStream(command)
            for try await chunk in stream {
                switch chunk {
                case let .stdout(buffer):
                    stdout += String(buffer: buffer)
                case let .stderr(buffer):
                    stderr += String(buffer: buffer)
                }
            }
        } catch let error as SSHClient.CommandFailed {
            exitCode = error.exitCode
        } catch let error as HostLinkFailure {
            throw error
        } catch {
            throw HostLinkFailure.connectionFailed(describeSshError(error))
        }
        if exitCode == nil, Task.isCancelled {
            throw HostLinkFailure.connectionFailed("cancelled")
        }
        _ = timeout // The scripts bound their own waiting; per-call racing is M4.
        return RemoteExecResult(stdout: stdout, stderr: stderr, exitCode: exitCode)
    }

    /// Opens a direct-tcpip channel to the remote's loopback (the tunnel leg
    /// of the local forward). Any failure is retried by the forwarder while it
    /// waits out an SSH reconnect; past its wait limit the local side sees a
    /// refused connection.
    public func openTunnelChannel(targetPort: Int) async throws -> Channel {
        guard let client else {
            throw HostLinkFailure.connectionFailed("not connected")
        }
        let originator = try SocketAddress(ipAddress: "127.0.0.1", port: 0)
        do {
            return try await client.createDirectTCPIPChannel(
                using: .init(targetHost: "127.0.0.1", targetPort: targetPort, originatorAddress: originator)
            ) { channel in
                channel.pipeline.addHandler(ByteToBytePassthrough())
            }
        } catch let error as HostLinkFailure {
            throw error
        } catch {
            throw HostLinkFailure.connectionFailed(describeSshError(error))
        }
    }

    /// Cheap liveness probe: one no-op command.
    public func probeAlive() async -> Bool {
        guard let client else { return false }
        do {
            _ = try await client.executeCommand(":", maxResponseSize: 1 << 16)
            return true
        } catch {
            return false
        }
    }

    public func close() async {
        guard let client else { return }
        self.client = nil
        try? await client.close()
    }
}

/// Keeps the channel's byte buffers flowing (the direct-tcpip channel already
/// speaks ByteBuffer after Citadel's codec).
final class ByteToBytePassthrough: ChannelDuplexHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    typealias InboundOut = ByteBuffer
    typealias OutboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        context.fireChannelRead(data)
    }

    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        context.write(data, promise: promise)
    }
}

func describeSshError(_ error: Error) -> String {
    if let failure = error as? HostLinkFailure {
        return "\(failure)"
    }
    let text = String(describing: error)
    return text.count > 200 ? String(text.prefix(200)) + "…" : text
}
