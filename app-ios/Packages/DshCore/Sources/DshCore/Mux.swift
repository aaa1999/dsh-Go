import Foundation

public let remoteMuxPath = "/api/remote.mux"
public let hostEventsEndpoint = "$events"

/// One established connection generation (a link whose `$events` stream
/// delivered `ready`).
public struct MuxGeneration: Equatable {
    /// Increments on every successful (re)connect, starting at 1.
    public let number: Int
    /// Must accompany `$events/result` replies sent during this generation.
    public let clientId: String
    public let home: String

    public static func == (lhs: MuxGeneration, rhs: MuxGeneration) -> Bool { lhs.number == rhs.number }
}

public enum DshConnectionState: Equatable, Sendable {
    case idle, connecting, connected, reconnecting, unauthorized, closed
}

/// Backoff caps in seconds (the official web client's schedule), 50-100% jitter.
public struct MuxOptions {
    public var readyTimeout: TimeInterval = 15
    public var pingInterval: TimeInterval = 15
    public var retryCaps: [TimeInterval] = [0.5, 1, 2, 4, 8, 10]
    public var autoReconnect = true

    public init() {}
}

/// One physical link carrying logical streams (a WebSocket, or later an
/// encrypted tunnel connection). Callbacks arrive on arbitrary threads; the
/// mux marshals them into its actor.
public protocol DshMuxLink: AnyObject {
    /// Frame delivery (`item`/`end`/`error`) and at-most-once loss notice.
    var onFrame: (([String: Any]) -> Void)? { get set }
    var onLost: ((DshError, DshError?) -> Void)? { get set }
    /// Begins delivery; the ping interval is the mux's dead-link detection.
    func start(pingInterval: TimeInterval)
    /// Opens logical stream `streamId`; `payload` is `{"args": {...}}`.
    func open(streamId: String, endpoint: String, payload: [String: Any])
    func sendItem(streamId: String, value: Any?)
    func endUplink(streamId: String)
    func cancel(streamId: String)
    func close(code: Int, reason: String) async
}

/// Transport for one Host: unary calls and fresh physical links.
public protocol DshCarrier: AnyObject {
    var kind: String { get }
    /// One unary call; Host failures throw `.remote`, carrier refusals `.http`.
    func call(_ endpoint: String, _ args: [String: Any], timeout: TimeInterval?) async throws -> Any?
    func openLink(options: MuxOptions) async throws -> DshMuxLink
    func close() async
}

/// The `/api/remote.mux` multiplexer: frames of
/// `open / item / end / error / cancel` over one link, the `$events` ready
/// handshake, connection generations, reconnect backoff and pending
/// approval/question bookkeeping (mux.dart).
///
/// Nothing is replayed across links: one-way notifications are lost, pending
/// waterfalls are redelivered with the same eventId, and every logical stream
/// must be reopened (follow streams start with a fresh snapshot).
public actor DshMux {
    public let carrier: DshCarrier
    public let options: MuxOptions

    public private(set) var state: DshConnectionState = .idle
    public private(set) var generation: MuxGeneration?
    public private(set) var lastError: DshError?

    /// Approval/question requests delivered in the current generation and not
    /// yet answered or cancelled, in arrival order.
    public private(set) var pendingRequests: [HostEvent] = []

    private var streams: [String: MuxStream] = [:]
    private var pendingOpens: [MuxStream] = []
    private var readyWaiters: [CheckedContinuation<MuxGeneration, Error>] = []
    private var generationCounter = 0
    private var attempt = 0
    private var running = false
    private var closed = false
    private var everConnected = false
    private var connecting = false
    private var retryTask: Task<Void, Never>?
    private var readyTask: Task<Void, Never>?
    private var link: DshMuxLink?
    private var eventsStreamId: String?

    private var stateListeners: [UUID: AsyncStream<DshConnectionState>.Continuation] = [:]
    private var hostEventListeners: [UUID: AsyncStream<HostEvent>.Continuation] = [:]
    private var generationListeners: [UUID: AsyncStream<MuxGeneration>.Continuation] = [:]

    public init(carrier: DshCarrier, options: MuxOptions = MuxOptions()) {
        self.carrier = carrier
        self.options = options
    }

    // MARK: Subscriptions

    public func states() -> AsyncStream<DshConnectionState> {
        AsyncStream { continuation in
            let id = UUID()
            stateListeners[id] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeStateListener(id) }
            }
        }
    }

    public func hostEvents() -> AsyncStream<HostEvent> {
        AsyncStream { continuation in
            let id = UUID()
            hostEventListeners[id] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeHostEventListener(id) }
            }
        }
    }

    /// Fires on every new ready generation: reopen your logical streams.
    public func generations() -> AsyncStream<MuxGeneration> {
        AsyncStream { continuation in
            let id = UUID()
            generationListeners[id] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeGenerationListener(id) }
            }
        }
    }

    private func removeStateListener(_ id: UUID) { stateListeners[id] = nil }
    private func removeHostEventListener(_ id: UUID) { hostEventListeners[id] = nil }
    private func removeGenerationListener(_ id: UUID) { generationListeners[id] = nil }

    // MARK: Lifecycle

    /// Starts connecting (if needed) and resolves with the first ready generation.
    @discardableResult
    public func ready() async throws -> MuxGeneration {
        if closed { throw DshError.closed("mux closed") }
        if let current = generation { return current }
        if state == .unauthorized, let error = lastError { throw error }
        running = true
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<MuxGeneration, Error>) in
            readyWaiters.append(cont)
            ensureConnecting()
        }
    }

    /// Drops the current link (if any) and starts a fresh attempt now,
    /// resetting the backoff. Also the way out of `unauthorized` after a new
    /// login.
    public func reconnect() {
        guard !closed else { return }
        running = true
        attempt = 0
        retryTask?.cancel()
        retryTask = nil
        if let link {
            handleLoss(DshError.carrierLost("reconnect requested"))
            Task { await link.close(code: 4000, reason: "reconnect requested") }
        }
        ensureConnecting()
    }

    /// Opens one logical stream. The `open` frame is sent once a generation is
    /// ready; if the link drops first the stream fails with `.carrierLost` and
    /// the caller decides whether to reopen.
    public func open(_ endpoint: String, _ args: [String: Any]) -> MuxStream {
        let stream = MuxStream(streamId: Rpc.requestId(), endpoint: endpoint, payload: ["args": args])
        stream.setMux(self)
        if DshWebSocketLink.trace {
            print("[mux] open \(endpoint) state=\(state) link=\(link != nil) jsonOk=\(JSONSerialization.isValidJSONObject(stream.payload))")
        }
        if let link, state == .connected {
            sendOpen(link, stream)
        } else {
            pendingOpens.append(stream)
            running = true
            ensureConnecting()
        }
        return stream
    }

    /// Forget a pending request locally (after this client answered it).
    public func resolvePendingRequest(_ eventId: String) {
        pendingRequests.removeAll { eventIdOf($0) == eventId }
        deliverHostEvent(.requestCancelled(eventId: eventId))
    }

    public func close() async {
        guard !closed else { return }
        closed = true
        running = false
        retryTask?.cancel()
        readyTask?.cancel()
        let error = DshError.closed("mux closed")
        for stream in streams.values {
            stream.fail(error)
        }
        streams.removeAll()
        for stream in pendingOpens {
            stream.fail(error)
        }
        pendingOpens.removeAll()
        for waiter in readyWaiters {
            waiter.resume(throwing: error)
        }
        readyWaiters.removeAll()
        let link = self.link
        self.link = nil
        generation = nil
        if let link {
            await link.close(code: 1000, reason: "client closed")
        }
        setState(.closed)
        for continuation in stateListeners.values { continuation.finish() }
        for continuation in hostEventListeners.values { continuation.finish() }
        for continuation in generationListeners.values { continuation.finish() }
    }

    // MARK: Internals

    private func eventIdOf(_ event: HostEvent) -> String? {
        switch event {
        case let .approvalRequested(request): request.eventId
        case let .userQuestionRequested(request): request.eventId
        case let .unknown(_, _, eventId, _): eventId
        default: nil
        }
    }

    private func setState(_ next: DshConnectionState) {
        guard state != next else { return }
        state = next
        for continuation in stateListeners.values { continuation.yield(next) }
    }

    private func deliverHostEvent(_ event: HostEvent) {
        for continuation in hostEventListeners.values { continuation.yield(event) }
    }

    private func ensureConnecting() {
        guard !closed, !connecting, link == nil, retryTask == nil else { return }
        connecting = true
        Task { await connectOnce() }
    }

    private func connectOnce() async {
        setState(everConnected ? .reconnecting : .connecting)
        let link: DshMuxLink
        do {
            link = try await carrier.openLink(options: options)
        } catch let error as DshError {
            lastError = error
            connecting = false
            if error.isUnauthorized {
                refuse(error)
            } else {
                scheduleRetry()
            }
            return
        } catch {
            lastError = DshError.transport("\(error)")
            connecting = false
            scheduleRetry()
            return
        }
        if closed {
            connecting = false
            await link.close(code: 1000, reason: "client closed")
            return
        }
        self.link = link
        connecting = false
        link.onFrame = { [weak self] frame in
            Task { await self?.frameArrived(frame) }
        }
        link.onLost = { [weak self] failure, cause in
            Task { await self?.linkLost(failure, cause: cause) }
        }
        link.start(pingInterval: options.pingInterval)
        let eventsId = Rpc.requestId()
        eventsStreamId = eventsId
        link.open(streamId: eventsId, endpoint: hostEventsEndpoint, payload: ["args": [:]])
        readyTask?.cancel()
        let timeout = options.readyTimeout
        readyTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            await self?.readyTimedOut()
        }
    }

    private func readyTimedOut() {
        guard let link, generation == nil, !closed else { return }
        lastError = DshError.transport("Host did not send ready on $events in time")
        handleLoss(.carrierLost("ready timeout"))
        Task { await link.close(code: 4001, reason: "ready timeout") }
    }

    /// Stops reconnecting until `reconnect`: the carrier needs user action.
    private func refuse(_ error: DshError) {
        running = false
        setState(.unauthorized)
        failWaiters(error)
    }

    private func frameArrived(_ frame: [String: Any]) {
        guard let streamId = Json.asString(frame["streamId"]) else { return }
        if streamId == eventsStreamId {
            eventsFrameArrived(frame)
            return
        }
        streams[streamId]?.deliver(frame)
    }

    private func eventsFrameArrived(_ frame: [String: Any]) {
        let type = Json.asString(frame["type"]) ?? ""
        guard type == "item" else {
            // `$events` ended or failed: this generation is no longer valid.
            let failure: DshError = type == "error" ? .remoteError(frame["error"]) : .carrierLost("$events ended")
            lastError = failure
            handleLoss(.carrierLost("$events stream closed: \(failure)"))
            Task { await link?.close(code: 4003, reason: "$events closed") }
            return
        }
        let event = HostEvent.parse(frame["value"])
        if generation == nil {
            guard case let .ready(clientId, home) = event else {
                protocolFailure("$events opened without ready")
                return
            }
            readyTask?.cancel()
            attempt = 0
            everConnected = true
            pendingRequests.removeAll()
            generationCounter += 1
            let generation = MuxGeneration(number: generationCounter, clientId: clientId, home: home)
            self.generation = generation
            setState(.connected)
            for waiter in readyWaiters {
                waiter.resume(returning: generation)
            }
            readyWaiters.removeAll()
            let pending = pendingOpens
            pendingOpens.removeAll()
            for stream in pending where !stream.isClosed {
                if let link { sendOpen(link, stream) }
            }
            for continuation in generationListeners.values { continuation.yield(generation) }
            deliverHostEvent(event)
            return
        }
        switch event {
        case .approvalRequested, .userQuestionRequested:
            pendingRequests.append(event)
        case let .requestCancelled(eventId):
            pendingRequests.removeAll { eventIdOf($0) == eventId }
        default:
            break
        }
        deliverHostEvent(event)
    }

    private func protocolFailure(_ reason: String) {
        lastError = .protocolFailure(reason)
        handleLoss(.carrierLost("protocol failure: \(reason)"))
        Task { await link?.close(code: 4002, reason: reason) }
    }

    private func linkLost(_ failure: DshError, cause: DshError?) {
        if let cause { lastError = cause }
        handleLoss(failure)
    }

    /// Cleans up after the link is gone; ignores links already replaced.
    private func handleLoss(_ failure: DshError) {
        guard link != nil else { return }
        link = nil
        eventsStreamId = nil
        generation = nil
        readyTask?.cancel()
        pendingRequests.removeAll()
        for stream in streams.values {
            stream.fail(failure)
        }
        streams.removeAll()
        if closed { return }
        if running, options.autoReconnect {
            setState(.reconnecting)
            scheduleRetry()
        } else {
            setState(.idle)
            failWaiters(failure)
        }
    }

    private func scheduleRetry() {
        guard !closed, running, options.autoReconnect else {
            failWaiters(lastError ?? .carrierLost("not connected"))
            if !closed { setState(.idle) }
            return
        }
        let cap = options.retryCaps[min(attempt, options.retryCaps.count - 1)]
        let delay = cap * (0.5 + Double.random(in: 0...0.5))
        attempt += 1
        setState(everConnected ? .reconnecting : .connecting)
        retryTask?.cancel()
        retryTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard let self, !Task.isCancelled else { return }
            await self.retryFired()
        }
    }

    private func retryFired() {
        retryTask = nil
        ensureConnecting()
    }

    private func failWaiters(_ error: DshError) {
        for waiter in readyWaiters {
            waiter.resume(throwing: error)
        }
        readyWaiters.removeAll()
        let pending = pendingOpens
        pendingOpens.removeAll()
        for stream in pending {
            stream.fail(error)
        }
    }

    private func sendOpen(_ link: DshMuxLink, _ stream: MuxStream) {
        stream.attach(to: link)
        streams[stream.streamId] = stream
        link.open(streamId: stream.streamId, endpoint: stream.endpoint, payload: stream.payload)
        stream.flushUplink()
    }

    /// Removes a cancelled stream from the books.
    func streamCancelled(_ stream: MuxStream) {
        streams[stream.streamId] = nil
        pendingOpens.removeAll { $0.streamId == stream.streamId }
    }
}

/// One logical stream on the mux: yields each `item` value, finishes on `end`.
/// `AsyncStream` cannot fail, so the terminal error is kept in
/// [terminalError] for the consumer to read after its iteration ends;
/// [throwingValues] wraps that contract.
public final class MuxStream {
    public let streamId: String
    public let endpoint: String
    public let payload: [String: Any]

    /// The error that ended this stream, if any (read after `values` finishes).
    public private(set) var terminalError: DshError?

    public let values: AsyncStream<Any?>
    private let continuation: AsyncStream<Any?>.Continuation
    private var uplink: [[String: Any]] = []
    private weak var carrier: DshMuxLink?
    private var opened = false
    private var terminal = false
    private var cancelled = false
    private weak var mux: DshMux?

    init(streamId: String, endpoint: String, payload: [String: Any]) {
        self.streamId = streamId
        self.endpoint = endpoint
        self.payload = payload
        var continuation: AsyncStream<Any?>.Continuation?
        values = AsyncStream { continuation = $0 }
        self.continuation = continuation!
        self.continuation.onTermination = { [weak self] _ in
            guard let self else { return }
            Task { await self.mux?.streamCancelled(self) }
        }
    }

    public var isClosed: Bool { terminal || cancelled }

    /// `values` with the terminal error rethrown at the end.
    public var throwingValues: AsyncThrowingStream<Any?, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                for await value in values {
                    continuation.yield(value)
                }
                if let terminalError {
                    continuation.finish(throwing: terminalError)
                } else {
                    continuation.finish()
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// The mux registers itself so a cancelled iteration cleans up.
    func setMux(_ mux: DshMux) {
        self.mux = mux
    }

    func attach(to link: DshMuxLink) {
        carrier = link
        opened = true
    }

    /// Queues one uplink item (endpoints that read uplink).
    public func send(_ value: Any?) {
        guard !isClosed else { return }
        uplink.append(["type": "item", "streamId": streamId, "value": value ?? NSNull()])
        flushUplink()
    }

    /// Half-closes the uplink.
    public func endUplink() {
        guard !isClosed else { return }
        uplink.append(["type": "end", "streamId": streamId])
        flushUplink()
    }

    /// Stops the stream: sends `cancel` unless the Host already finished it.
    public func cancel() {
        guard !isClosed else { return }
        cancelled = true
        if opened, let carrier {
            carrier.cancel(streamId: streamId)
        }
        continuation.finish()
    }

    func flushUplink() {
        guard opened, let carrier else { return }
        for frame in uplink {
            if Json.asString(frame["type"]) == "item" {
                carrier.sendItem(streamId: streamId, value: frame["value"])
            } else {
                carrier.endUplink(streamId: streamId)
            }
        }
        uplink.removeAll()
    }

    func deliver(_ frame: [String: Any]) {
        guard !isClosed else { return }
        switch Json.asString(frame["type"]) ?? "" {
        case "item":
            continuation.yield(frame["value"])
        case "end":
            terminal = true
            continuation.finish()
        case "error":
            terminal = true
            terminalError = DshError.remoteError(frame["error"])
            continuation.finish()
        default:
            break
        }
    }

    func fail(_ error: DshError) {
        guard !isClosed else { return }
        terminal = true
        terminalError = error
        continuation.finish()
    }
}
