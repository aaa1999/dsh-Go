import Foundation

/// `POST /api/<endpoint>` envelope of the default HTTP carrier
/// (carrier.dart's `DshHttpCarrier`): every unary call is
/// `{"type":"client-request","rpcId":"<uuid>","method":..,"payload":{"args":{..}}}`
/// answered by
/// `{"type":"server-response","rpcId":"<echo>","result":{ok:true,value?}|{ok:false,error:{..}}}`.
public enum Rpc {
    /// rpc.dart's `checkRemoteEndpoint`: `[A-Za-z0-9_$.-]` segments, no `.`/`..`.
    public static func checkEndpoint(_ endpoint: String) throws {
        let pattern = #"^[A-Za-z0-9_$.\-]+$"#
        let segments = endpoint.split(separator: "/", omittingEmptySubsequences: false)
        guard !segments.isEmpty else { throw DshError.protocolFailure("invalid endpoint: \(endpoint)") }
        for segment in segments {
            let s = String(segment)
            if s.isEmpty || s == "." || s == ".." || s.range(of: pattern, options: .regularExpression) == nil {
                throw DshError.protocolFailure("invalid endpoint: \(endpoint)")
            }
        }
    }

    public static func requestId() -> String {
        UUID().uuidString.lowercased()
    }

    public static func encodeRequest(rpcId: String, endpoint: String, args: [String: Any]) -> [String: Any] {
        [
            "type": "client-request",
            "rpcId": rpcId,
            "method": endpoint,
            "payload": ["args": args],
        ]
    }

    /// rpc_envelope.dart's `readRpcEnvelope`: returns the success value or
    /// throws `.remote` / `.protocolFailure`.
    public static func readResponse(_ json: Any?, rpcId: String, endpoint: String) throws -> Any? {
        let map = Json.asMapOrEmpty(json)
        guard Json.asString(map["type"]) == "server-response" else {
            throw DshError.protocolFailure("\(endpoint): not a server-response envelope")
        }
        guard Json.asString(map["rpcId"]) == rpcId else {
            throw DshError.protocolFailure("\(endpoint): rpcId mismatch")
        }
        let result = Json.asMapOrEmpty(map["result"])
        if result["ok"] as? Bool == true {
            return result["value"]
        }
        throw DshError.remoteError(result["error"])
    }
}
