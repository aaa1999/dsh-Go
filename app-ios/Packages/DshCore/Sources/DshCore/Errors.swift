import Foundation

/// The failure taxonomy of the Dart client's `errors.dart`: business failures
/// come back as values ([DshRemoteError]); carrier refusals, wire malformness
/// and network faults throw.
public enum DshError: Error, CustomStringConvertible {
    /// `ok: false` from the Host: `gateway/*`, `session/*`, ...
    case remote(code: String, message: String, details: [String: Any])

    /// HTTP status the carrier refuses to translate: 401 cookie, 403 fence,
    /// 404 unclaimed endpoint, 415 content type.
    case http(status: Int, message: String)

    /// Malformed wire data (bad envelope, missing cookie, ...).
    case protocolFailure(String)

    /// Network level: connection refused, timeout, DNS, broken socket.
    case transport(String)

    /// The client was closed; nothing may be retried.
    case closed(String)

    /// A physical link died; the mux reconnects, logical streams see this.
    case carrierLost(String)

    public var description: String {
        switch self {
        case let .remote(code, message, _): "remote \(code): \(message)"
        case let .http(status, message): "http \(status): \(message)"
        case let .protocolFailure(reason): "protocol: \(reason)"
        case let .transport(message): "transport: \(message)"
        case let .closed(message): "closed: \(message)"
        case let .carrierLost(message): "connection lost: \(message)"
        }
    }

    public var isUnauthorized: Bool {
        if case let .http(status, _) = self { return status == 401 || status == 403 }
        return false
    }

    /// The watch treats these as transient: back off and retry.
    public var isTransient: Bool {
        switch self {
        case .transport, .protocolFailure, .carrierLost: true
        case let .http(status, _): status >= 500 || status == 408 || status == 429
        case let .remote(code, _, details):
            code == "gateway/internal" || (details["retryable"] as? Bool == true)
        case .closed: false
        }
    }

    /// Builds `.remote` from an error object `{code, message, details}` — the
    /// mux `error` frame payload or an envelope's `result.error`.
    static func remoteError(_ json: Any?) -> DshError {
        let error = Json.asMapOrEmpty(json)
        return .remote(
            code: Json.asString(error["code"]) ?? "gateway/internal",
            message: Json.asString(error["message"]) ?? "",
            details: Json.asMapOrEmpty(error["details"])
        )
    }
}

/// `httpRpcStatusMessage` of rpc_envelope.dart.
func rpcStatusMessage(_ status: Int, _ endpoint: String) -> String {
    switch status {
    case 401: "\(endpoint): unauthorized (cookie missing, expired, or bound to another host:port)"
    case 403: "\(endpoint): forbidden (Host fence: Host header not trusted)"
    case 404: "\(endpoint): not a registered Remote endpoint"
    case 415: "\(endpoint): unsupported content type"
    default: "\(endpoint): HTTP \(status)"
    }
}
