import CryptoKit
import Foundation

/// The URL `dsh web` prints on stdout once ready, e.g.
/// `dsh web: http://127.0.0.1:3080/?token=...` — connection.dart's
/// `DshLaunchUrl`. Accepts the whole line or a bare URL; nil when no URL with
/// a non-empty `token` query is present.
public struct DshLaunchUrl: Equatable {
    /// `http://127.0.0.1:3080` (mount path kept, query/fragment stripped, no trailing `/`).
    public let baseUrl: URL
    public let token: String

    public static func tryParse(_ text: String) -> DshLaunchUrl? {
        guard let range = text.range(of: #"https?://\S+"#, options: .regularExpression),
            let url = URL(string: String(text[range])),
            let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else { return nil }
        let token = components.queryItems?.first { $0.name == "token" }?.value
        guard let token, !token.isEmpty else { return nil }
        var base = URLComponents()
        base.scheme = components.scheme
        base.host = components.host
        base.port = components.port
        var path = components.path
        while path.count > 1 && path.hasSuffix("/") { path.removeLast() }
        base.path = path == "/" ? "" : path
        guard let baseUrl = base.url else { return nil }
        return DshLaunchUrl(baseUrl: baseUrl, token: token)
    }
}

/// The signed browser-session cookie minted by `GET /?token=`; bound to the
/// exact `host:port` authority of the login. A bearer credential: keep it in
/// the Keychain and re-login only on 401.
public struct DshCookie: Equatable, Codable {
    /// `dsh-auth-<base64url(sha256(authority))>`.
    public let name: String
    /// `v1.<payload>.<signature>`; opaque.
    public let value: String
    /// `host:port` the cookie is bound to; requests must send this `Host`.
    public let authority: String
    public let expiresAt: Date?

    public var header: String { "\(name)=\(value)" }

    public init(name: String, value: String, authority: String, expiresAt: Date?) {
        self.name = name
        self.value = value
        self.authority = authority
        self.expiresAt = expiresAt
    }

    public func isExpired(at now: Date = Date()) -> Bool {
        guard let expiresAt else { return false }
        return now >= expiresAt
    }

    /// connection.dart's `_parseSetCookie`: `max-age` wins over `expires`.
    public static func parse(setCookie raw: String, authority: String, now: Date = Date()) -> DshCookie? {
        let parts = raw.split(separator: ";", omittingEmptySubsequences: false).map(String.init)
        guard let first = parts.first, let eq = first.firstIndex(of: "="), eq > first.startIndex else {
            return nil
        }
        let name = String(first[..<eq]).trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return nil }
        let value = String(first[first.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
        var expiresAt: Date?
        for attribute in parts.dropFirst() {
            let key: String
            let attrValue: String
            if let at = attribute.firstIndex(of: "=") {
                key = String(attribute[..<at]).trimmingCharacters(in: .whitespaces).lowercased()
                attrValue = String(attribute[attribute.index(after: at)...]).trimmingCharacters(in: .whitespaces)
            } else {
                key = attribute.trimmingCharacters(in: .whitespaces).lowercased()
                attrValue = ""
            }
            if key == "max-age" {
                if let seconds = TimeInterval(attrValue) {
                    expiresAt = now.addingTimeInterval(seconds)
                }
            } else if key == "expires", expiresAt == nil {
                // Keep the cookie without an expiry rather than failing login.
                expiresAt = DateFormatter.httpDate.date(from: attrValue)
            }
        }
        return DshCookie(name: name, value: value, authority: authority, expiresAt: expiresAt)
    }

    /// The cookie name the Host mints for an authority (`dsh-auth-<base64url(sha256)>`).
    public static func expectedName(authority: String) -> String {
        "dsh-auth-\(Crypto.base64Url(Crypto.sha256(Data(authority.utf8))))"
    }
}

extension DateFormatter {
    /// RFC 7231 IMF-fixdate (`HttpDate.parse` on the Dart side).
    static let httpDate: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        formatter.timeZone = TimeZone(identifier: "GMT")
        return formatter
    }()
}

/// SHA-256 and base64url helpers (CryptoKit).
public enum Crypto {
    public static func sha256(_ data: Data) -> Data {
        Data(SHA256.hash(data: data))
    }

    /// base64url without padding.
    public static func base64Url(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// OpenSSH fingerprint form: `SHA256:<unpadded base64 of the raw digest>`.
    public static func openSshFingerprint(_ data: Data) -> String {
        "SHA256:" + base64Url(sha256(data))
    }
}
