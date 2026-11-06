/// The protocol layer of the native iOS remote client: the dsh web API
/// (login cookie, RPC envelope, the remote.mux WebSocket) and the SSH host
/// link, ported 1:1 from packages/dsh_client and app/lib/remote/ssh.
///
/// Pure Swift with no UI imports, so it builds and tests on any host with
/// `swift test`. The SSH transport (swift-nio-ssh / Citadel) joins in M3.
public enum DshCore {
    /// Client version reported to hosts and shown in the placeholder UI.
    public static let version = "0.1.0"
}
