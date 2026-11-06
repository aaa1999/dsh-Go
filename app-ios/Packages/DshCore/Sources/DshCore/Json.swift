import Foundation

/// Tolerant JSON access, mirroring packages/dsh_client/lib/src/json.dart:
/// every wire parser ignores unknown fields and degrades instead of throwing.
public enum Json {
    public static func asMap(_ value: Any?) -> [String: Any]? {
        value as? [String: Any]
    }

    public static var emptyMap: [String: Any] { [:] }

    public static func asMapOrEmpty(_ value: Any?) -> [String: Any] {
        asMap(value) ?? emptyMap
    }

    public static func asString(_ value: Any?) -> String? {
        value as? String
    }

    public static func asInt(_ value: Any?) -> Int? {
        switch value {
        case let n as Int: n
        case let n as UInt: Int(exactly: n)
        case let n as Double: n.rounded() == n ? Int(n) : nil
        case let n as NSNumber: n.intValue
        case let s as String: Int(s)
        default: nil
        }
    }

    public static func asBool(_ value: Any?) -> Bool? {
        value as? Bool
    }

    public static func asEpochMs(_ value: Any?) -> Date? {
        asInt(value).map { Date(timeIntervalSince1970: TimeInterval($0) / 1000) }
    }

    public static func asListOrEmpty(_ value: Any?) -> [Any] {
        value as? [Any] ?? []
    }

    public static func asStringList(_ value: Any?) -> [String] {
        asListOrEmpty(value).compactMap { $0 as? String }
    }

    public static func tryDecodeJson(_ text: String) -> Any? {
        data(text).flatMap { try? JSONSerialization.jsonObject(with: $0) }
    }

    public static func data(_ text: String) -> Data? {
        Data(text.utf8)
    }

    /// Sorted, stable encoding used for tests and logs (keys sorted like Dart's JsonEncoder on maps).
    public static func encodeSorted(_ value: Any) throws -> Data {
        try JSONSerialization.data(
            withJSONObject: value,
            options: [.sortedKeys]
        )
    }
}
