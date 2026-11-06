import Foundation

/// Raw HTTP response with the body fully read (connection.dart's
/// `DshHttpResponse`).
public struct DshHttpResponse {
    public let statusCode: Int
    /// Lower-cased media type without parameters (`application/json`).
    public let contentType: String
    public let body: Data
    /// Raw `Set-Cookie` header values.
    public let setCookies: [String]

    public var text: String {
        String(data: body, encoding: .utf8) ?? String(decoding: body, as: UTF8.self)
    }

    public var json: Any? {
        body.isEmpty ? nil : try? JSONSerialization.jsonObject(with: body)
    }
}

public enum DshHealth: Equatable, Sendable {
    /// `GET /` with the cookie returned 200.
    case ok
    /// 401/403: up, but log in again (or fix `Host`).
    case unauthorized
    /// Nothing answered.
    case unreachable
}

/// URLSession never follows redirects: the login must read the `303`'s
/// `Set-Cookie` (following it drops the intermediate header), and the bounded
/// media reads refuse redirects by design.
private final class NoRedirectDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

/// HTTP + WebSocket carrier to one `dsh web` Host: launch-token login, the
/// authority-bound cookie, RPC POSTs and the mux WebSocket, all with the
/// right `Host` header and never an `Origin` (connection.dart).
///
/// The Host fence trusts only a loopback (or `--trusted-host`) `Host` header.
/// Through the SSH tunnel requests dial `http://127.0.0.1:<local port>` but
/// must present `Host: 127.0.0.1:<remote port>`; [hostHeader] overrides it.
public final class DshConnection {
    public let baseUrl: URL
    public let hostHeader: String?
    public private(set) var cookie: DshCookie?

    let session: URLSession

    /// Authority the Host sees, which is also what the cookie is bound to.
    public var authority: String {
        hostHeader ?? DshConnection.authorityOf(baseUrl)
    }

    public init(baseUrl: URL, hostHeader: String? = nil, cookie: DshCookie? = nil, session: URLSession? = nil) {
        precondition(baseUrl.scheme == "http" || baseUrl.scheme == "https", "expected an http(s) base URL")
        var components = URLComponents(url: baseUrl, resolvingAgainstBaseURL: false)!
        var path = components.path
        while path.count > 1 && path.hasSuffix("/") { path.removeLast() }
        components.path = path == "/" ? "" : path
        self.baseUrl = components.url ?? baseUrl
        self.hostHeader = hostHeader
        self.cookie = cookie
        if let session {
            self.session = session
        } else {
            let config = URLSessionConfiguration.ephemeral
            config.httpShouldSetCookies = false
            config.httpCookieAcceptPolicy = .never
            self.session = URLSession(configuration: config, delegate: NoRedirectDelegate(), delegateQueue: nil)
        }
    }

    // MARK: HTTP

    /// Exchanges the launch token for the session cookie: `GET /?token=`,
    /// answered `303 ./` with `Set-Cookie: dsh-auth-...; Max-Age=2592000; ...`.
    @discardableResult
    public func login(token: String) async throws -> DshCookie {
        var components = URLComponents(url: baseUrl, resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "token", value: token)]
        guard let url = components.url else {
            throw DshError.protocolFailure("bad base URL")
        }
        let response = try await exchange("GET", url)
        switch response.statusCode {
        case 401:
            throw DshError.http(
                status: 401,
                message: "launch token rejected (stale token, other dsh process, or wrong host:port)"
            )
        case 302, 303:
            break
        default:
            throw DshError.http(status: response.statusCode, message: "unexpected login response")
        }
        guard let minted = response.setCookies.lazy
            .compactMap({ DshCookie.parse(setCookie: $0, authority: self.authority) })
            .first(where: { $0.name.hasPrefix("dsh-auth-") })
        else {
            throw DshError.protocolFailure("login redirect carried no dsh-auth cookie")
        }
        cookie = minted
        return minted
    }

    /// Cheap readiness probe: `GET /` with the cookie.
    public func checkHealth(timeout: TimeInterval = 10) async -> DshHealth {
        guard let response = try? await exchange("GET", baseUrl, timeout: timeout) else {
            return .unreachable
        }
        switch response.statusCode {
        case 200: return .ok
        case 401, 403: return .unauthorized
        default: return .unreachable
        }
    }

    public func postJson(_ path: String, _ body: Any, timeout: TimeInterval? = nil) async throws -> DshHttpResponse {
        let data = try JSONSerialization.data(withJSONObject: body)
        return try await exchange(
            "POST",
            resolve(path),
            body: data,
            contentTypeHeader: "application/json",
            timeout: timeout
        )
    }

    public func resolve(_ path: String) -> URL {
        var components = URLComponents(url: baseUrl, resolvingAgainstBaseURL: false)!
        let mount = components.path
        components.path = mount + (path.hasPrefix("/") ? path : "/" + path)
        return components.url!
    }

    public func webSocketUrl(_ path: String) -> URL {
        var components = URLComponents(url: resolve(path), resolvingAgainstBaseURL: false)!
        components.scheme = components.scheme == "https" ? "wss" : "ws"
        return components.url!
    }

    /// Opens the authenticated `/api/remote.mux` WebSocket. A missing cookie
    /// fails the upgrade with 401; a fence failure with 403.
    public func openWebSocket(path: String, timeout: TimeInterval) throws -> DshWebSocketLink {
        guard let cookie else {
            throw DshError.http(status: 401, message: "WebSocket upgrade refused: no session cookie")
        }
        var request = URLRequest(url: webSocketUrl(path))
        request.timeoutInterval = timeout
        if let hostHeader {
            request.setValue(hostHeader, forHTTPHeaderField: "Host")
        }
        request.setValue(cookie.header, forHTTPHeaderField: "Cookie")
        let task = session.webSocketTask(with: request)
        task.resume()
        return DshWebSocketLink(task: task)
    }

    private func exchange(
        _ method: String,
        _ url: URL,
        body: Data? = nil,
        contentTypeHeader: String? = nil,
        timeout: TimeInterval? = nil
    ) async throws -> DshHttpResponse {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = timeout ?? 120
        if let hostHeader {
            request.setValue(hostHeader, forHTTPHeaderField: "Host")
        }
        if let cookie {
            request.setValue(cookie.header, forHTTPHeaderField: "Cookie")
        }
        if let contentTypeHeader {
            request.setValue(contentTypeHeader, forHTTPHeaderField: "Content-Type")
        }
        request.httpBody = body
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw DshError.transport("\(method) \(url.path): not an HTTP response")
            }
            return DshHttpResponse(
                statusCode: http.statusCode,
                contentType: contentType(of: http),
                body: data,
                setCookies: setCookies(of: http)
            )
        } catch let error as DshError {
            throw error
        } catch let error as URLError where error.code == .timedOut {
            throw DshError.transport("\(method) \(url.path) timed out")
        } catch {
            throw DshError.transport("\(method) \(url.path) failed: \(error.localizedDescription)")
        }
    }

    private func contentType(of response: HTTPURLResponse) -> String {
        guard let raw = response.value(forHTTPHeaderField: "Content-Type") else { return "" }
        return raw.split(separator: ";").first.map { $0.trimmingCharacters(in: .whitespaces).lowercased() } ?? ""
    }

    private func setCookies(of response: HTTPURLResponse) -> [String] {
        var cookies: [String] = []
        for (key, value) in response.allHeaderFields {
            if String(describing: key).lowercased() == "set-cookie" {
                // A single header may arrive comma-joined when several were sent.
                for part in String(describing: value).components(separatedBy: ",") where part.contains("=") {
                    cookies.append(part.trimmingCharacters(in: .whitespaces))
                }
            }
        }
        return cookies
    }

    static func authorityOf(_ url: URL) -> String {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url.host ?? "" }
        let host = (components.host ?? "").contains(":") ? "[\(components.host ?? "")]" : (components.host ?? "")
        let defaultPort = components.scheme == "https" ? 443 : 80
        if let port = components.port, port != defaultPort {
            return "\(host):\(port)"
        }
        return host
    }
}

/// The default carrier: unary `POST /api/<endpoint>` and the
/// `/api/remote.mux` WebSocket over one [DshConnection] (carrier.dart's
/// `DshHttpCarrier`). Business and gateway failures come back as
/// `.remote`; only carrier refusals use HTTP status codes (401 cookie, 403
/// fence, 404 unclaimed, 415 content type).
public final class DshHttpCarrier: DshCarrier {
    public let connection: DshConnection

    public init(connection: DshConnection) {
        self.connection = connection
    }

    public var kind: String { "http" }

    public func call(_ endpoint: String, _ args: [String: Any], timeout: TimeInterval? = nil) async throws -> Any? {
        try Rpc.checkEndpoint(endpoint)
        let rpcId = Rpc.requestId()
        let envelope = Rpc.encodeRequest(rpcId: rpcId, endpoint: endpoint, args: args)
        let response = try await connection.postJson("/api/\(endpoint)", envelope, timeout: timeout)
        guard response.statusCode == 200 else {
            throw DshError.http(status: response.statusCode, message: rpcStatusMessage(response.statusCode, endpoint))
        }
        return try Rpc.readResponse(response.json, rpcId: rpcId, endpoint: endpoint)
    }

    public func openLink(options: MuxOptions) async throws -> DshMuxLink {
        try connection.openWebSocket(path: remoteMuxPath, timeout: options.readyTimeout + 5)
    }

    public func close() async {}
}

/// `/api/remote.mux`: one JSON text frame per WebSocket message. The Host
/// pings every 2 s (`URLSession` answers); the client adds its own ping for
/// dead-link detection.
public final class DshWebSocketLink: NSObject, DshMuxLink, @unchecked Sendable {
    /// Wire tracing for probes (`DSH_TRACE=1` in the environment).
    public static var trace = ProcessInfo.processInfo.environment["DSH_TRACE"] == "1"

    private func traceOut(_ label: String, _ frame: [String: Any]) {
        guard Self.trace else { return }
        let text = (try? String(data: JSONSerialization.data(withJSONObject: frame), encoding: .utf8)) ?? "?"
        print("[ws \(label)] \(text.prefix(300))")
    }

    private let task: URLSessionWebSocketTask
    private var pingInterval: TimeInterval = 15
    private var receiveTask: Task<Void, Never>?
    private var pingTask: Task<Void, Never>?
    private var lost = false

    public var onFrame: (([String: Any]) -> Void)?
    public var onLost: ((DshError, DshError?) -> Void)?

    init(task: URLSessionWebSocketTask) {
        self.task = task
        super.init()
    }

    public func start(pingInterval: TimeInterval) {
        self.pingInterval = pingInterval
        receiveTask = Task { [weak self] in
            await self?.receiveLoop()
        }
        pingTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64((self?.pingInterval ?? 15) * 1_000_000_000))
                guard let self, !self.lost else { return }
                self.task.sendPing { [weak self] error in
                    if error != nil {
                        Task { self?.lose(.carrierLost("WebSocket ping timed out"), nil) }
                    }
                }
            }
        }
    }

    private func receiveLoop() async {
        while !lost {
            do {
                let message = try await task.receive()
                guard !lost else { return }
                switch message {
                case let .string(text):
                    if Self.trace {
                        print("[ws in] \(text.prefix(300))")
                    }
                    guard let frame = decodeFrame(text) else {
                        lose(
                            DshError.carrierLost("protocol failure: invalid Remote stream frame"),
                            DshError.protocolFailure("invalid Remote stream frame")
                        )
                        Task { await self.close(code: 4002, reason: "invalid Remote stream frame") }
                        return
                    }
                    onFrame?(frame)
                case .data:
                    lose(
                        DshError.carrierLost("protocol failure: binary WebSocket message"),
                        DshError.protocolFailure("binary WebSocket message")
                    )
                    Task { await self.close(code: 4002, reason: "binary WebSocket message") }
                    return
                @unknown default:
                    continue
                }
            } catch {
                lose(DshError.carrierLost("WebSocket closed: \(error.localizedDescription)"), nil)
                return
            }
        }
    }

    /// Frames must be JSON objects with a non-empty `streamId` and a downlink
    /// `type` (carrier.dart's `_WebSocketMuxLink.start`).
    private func decodeFrame(_ text: String) -> [String: Any]? {
        guard let decoded = Json.tryDecodeJson(text), let frame = Json.asMap(decoded),
            let streamId = Json.asString(frame["streamId"]), !streamId.isEmpty,
            let type = Json.asString(frame["type"]),
            type == "item" || type == "end" || type == "error"
        else { return nil }
        return frame
    }

    /// At most once; late frames for a closed link are ignored.
    private func lose(_ failure: DshError, _ cause: DshError?) {
        guard !lost else { return }
        lost = true
        receiveTask?.cancel()
        pingTask?.cancel()
        onLost?(failure, cause)
    }

    private func send(_ frame: [String: Any]) {
        guard !lost, let text = String(data: (try? JSONSerialization.data(withJSONObject: frame)) ?? Data(), encoding: .utf8) else {
            return
        }
        traceOut("out", frame)
        task.send(.string(text)) { [weak self] error in
            if error != nil {
                self?.lose(.carrierLost("WebSocket send failed"), nil)
            }
        }
    }

    public func open(streamId: String, endpoint: String, payload: [String: Any]) {
        send(["type": "open", "streamId": streamId, "endpoint": endpoint, "payload": payload])
    }

    public func sendItem(streamId: String, value: Any?) {
        send(["type": "item", "streamId": streamId, "value": value ?? NSNull()])
    }

    public func endUplink(streamId: String) {
        send(["type": "end", "streamId": streamId])
    }

    public func cancel(streamId: String) {
        send(["type": "cancel", "streamId": streamId])
    }

    /// URLSession only accepts the well-known close codes, so the mux's 4xxx
    /// codes are informational here.
    public func close(code: Int, reason: String) async {
        lost = true
        receiveTask?.cancel()
        pingTask?.cancel()
        task.cancel(with: .normalClosure, reason: nil)
    }
}
