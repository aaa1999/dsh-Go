import Foundation

/// One `session/page` result.
public struct HistoryPage {
    public let events: [SessionLogEvent]
    /// Older events exist before the first one in `events`.
    public let hasMore: Bool
}

public enum PromptMode: String {
    case queue
    case steer
}

/// `session/follow` window options (session_api.dart's `WatchOptions`,
/// `HISTORY_PAGE_OPTIONS` of the official web client).
public struct WatchOptions {
    public var assistantStream = true
    public var turnWindowMinMessages = 50
    public var turnWindowMinTurns = 2
    public var maxMessages = 500
    /// Forward this session's approvals, questions, status and errors.
    public var includeHostEvents = true
    public var includeConnectionEvents = true

    public init() {}
}

/// What a watch delivers. Ordered: a snapshot (first, and after every
/// reconnect as a resync), then contiguous durable events and live
/// assistant-stream frames, plus this session's host requests.
public enum WatchEvent {
    case snapshot(SessionSnapshot)
    case logEvent(SessionLogEvent)
    case assistantStream(AssistantStreamFrame)
    case connectionState(DshConnectionState, DshError?)
    case approval(ApprovalRequest)
    case question(UserQuestionRequest)
    case requestCancelled(eventId: String)
    case sessionStatus(sessionId: String, running: Bool)
    case sessionError(sessionId: String, message: String)
    case sessionRemoved(sessionId: String)
}

public enum ApprovalDecision {
    /// One-shot grant (`allowed-once`); there is no "always allow" in rc.2.
    case allowOnce
    /// Explicit rejection (`rejected`): the tool call fails for the model.
    case reject
    /// Let other connected clients answer (`{kind: 'next'}`).
    case pass

    var wire: String {
        switch self {
        case .allowOnce: "allowed-once"
        case .reject: "rejected"
        case .pass: "next"
        }
    }
}

/// The typed API over one carrier: unary session RPCs, the `$events`
/// answer path and live session watches (session_api.dart's `DshClient`).
public actor DshClient {
    public let carrier: DshCarrier
    public let mux: DshMux

    public init(connection: DshConnection, muxOptions: MuxOptions = MuxOptions()) {
        let carrier = DshHttpCarrier(connection: connection)
        self.carrier = carrier
        mux = DshMux(carrier: carrier, options: muxOptions)
    }

    public init(carrier: DshCarrier, muxOptions: MuxOptions = MuxOptions()) {
        self.carrier = carrier
        mux = DshMux(carrier: carrier, options: muxOptions)
    }

    /// One unary call; throws `.remote` for Host failures, `.http` for
    /// carrier refusals.
    @discardableResult
    public func call(_ endpoint: String, _ args: [String: Any] = [:], timeout: TimeInterval? = nil) async throws -> Any? {
        try Rpc.checkEndpoint(endpoint)
        return try await carrier.call(endpoint, args, timeout: timeout)
    }

    // MARK: Sessions

    /// `session/list`, newest first (archived included; subagents filtered).
    public func listSessions() async throws -> [SessionSummary] {
        let value = Json.asMapOrEmpty(try await call("session/list", ["_request": [:]] as [String: Any]))
        return Json.asListOrEmpty(value["items"]).map(SessionSummary.parse)
    }

    /// `session/create`. Pass `cwd` for a bare directory; with neither the
    /// Host uses the `dsh web` process cwd. `sessionId` adopts an existing
    /// stored session.
    public func createSession(cwd: String? = nil, workspaceId: String? = nil, agentPreset: String? = nil, sessionId: String? = nil) async throws -> SessionCreated {
        var request: [String: Any] = [:]
        if let workspaceId { request["workspaceId"] = workspaceId }
        if let cwd { request["cwd"] = cwd }
        if let sessionId { request["sessionId"] = sessionId }
        if let agentPreset { request["agentPreset"] = agentPreset }
        let value = Json.asMapOrEmpty(try await call("session/create", ["request": request]))
        return SessionCreated.parse(value)
    }

    /// `session/rename`; pins the title (automatic titling stops).
    public func renameSession(_ sessionId: String, title: String) async throws {
        _ = try await call("session/rename", ["request": ["sessionId": sessionId, "title": title]])
    }

    /// `session/prompt`; resolves once the prompt entered the Agent inbox and
    /// returns its requestId (echoed as `user/message.source.rpcId`). Retrying
    /// with the same requestId is idempotent.
    @discardableResult
    public func prompt(_ sessionId: String, _ text: String, mode: PromptMode = .queue, requestId: String? = nil, timeZone: String? = nil) async throws -> String {
        let id = requestId ?? Rpc.requestId()
        var request: [String: Any] = [
            "requestId": id,
            "sessionId": sessionId,
            "mode": mode.rawValue,
            "content": [["type": "text", "text": text]] as [[String: Any]],
        ]
        if let timeZone { request["clientTimeZone"] = timeZone }
        _ = try await call("session/prompt", ["request": request])
        return id
    }

    /// `session/cancel`: interrupts the running turn; answers ok even when idle.
    public func cancel(_ sessionId: String) async throws {
        _ = try await call("session/cancel", ["request": ["sessionId": sessionId]])
    }

    /// `session/page`: the durable log before a point (`throughSeq` down to
    /// `beforeSeq`), for filling snapshot gaps.
    public func history(_ sessionId: String, throughSeq: Int, beforeSeq: Int? = nil, maxMessages: Int? = nil) async throws -> HistoryPage {
        var request: [String: Any] = [
            "address": ["kind": "session", "sessionId": sessionId] as [String: Any],
            "throughSeq": throughSeq,
        ]
        if let beforeSeq { request["beforeSeq"] = beforeSeq }
        if let maxMessages { request["maxMessages"] = maxMessages }
        let value = Json.asMapOrEmpty(try await call("session/page", ["request": request]))
        return HistoryPage(
            events: Json.asListOrEmpty(value["records"]).map { SessionLogEvent.parse(Json.asMapOrEmpty($0)["event"]) },
            hasMore: value["hasMore"] as? Bool == true
        )
    }

    // MARK: Approvals and questions

    /// Answers an `approval/request` (via `$events/result`).
    public func respondApproval(_ request: ApprovalRequest, decision: ApprovalDecision) async throws {
        let outcome: [String: Any] =
            decision == .pass
            ? ["kind": "next"]
            : ["kind": "result", "value": ["kind": decision.wire]]
        try await respondHostEvent(request.eventId, outcome: outcome)
    }

    /// Answers a `user-questions/request` while its tool call is still open.
    public func answerQuestion(_ request: UserQuestionRequest, answers: [QuestionAnswer]) async throws {
        try await respondHostEvent(
            request.eventId,
            outcome: ["kind": "result", "value": ["answers": answers.map(\.json)]]
        )
    }

    /// Rejects a question request.
    public func rejectQuestion(_ request: UserQuestionRequest, name: String = "UserQuestionError", message: String = "declined") async throws {
        try await respondHostEvent(
            request.eventId,
            outcome: ["kind": "rejected", "error": ["name": name, "message": message]]
        )
    }

    /// Low-level `$events/result`, with the Dart client's stale-clientId retry:
    /// pending requests are redelivered to new generations with the same eventId.
    public func respondHostEvent(_ eventId: String, outcome: [String: Any]) async throws {
        for attempt in 0...2 {
            let generation = try await mux.ready()
            do {
                _ = try await call(
                    "$events/result",
                    ["clientId": generation.clientId, "eventId": eventId, "outcome": outcome]
                )
                await mux.resolvePendingRequest(eventId)
                return
            } catch let error as DshError {
                let stale: Bool
                if case let .remote(_, message, _) = error {
                    stale = message.contains("identifies no active event stream")
                } else {
                    stale = false
                }
                if !stale || attempt == 2 { throw error }
                try? await Task.sleep(nanoseconds: 300_000_000)
            }
        }
    }

    // MARK: Watch

    /// Live view of one session: snapshot first, then contiguous durable
    /// events, assistant-stream deltas and this session's host requests.
    /// Survives link loss (the mux reconnects; the follow reopens with a
    /// resync snapshot); six transient failures without a snapshot end it.
    public func watch(_ sessionId: String, options: WatchOptions = WatchOptions()) -> AsyncThrowingStream<WatchEvent, Error> {
        AsyncThrowingStream { continuation in
            let watcher = SessionWatch(client: self, sessionId: sessionId, options: options)
            // The termination closure holds the watcher for the stream's
            // lifetime; the watch tasks only keep it weakly.
            continuation.onTermination = { _ in
                watcher.stop()
            }
            watcher.run(continuation: continuation)
        }
    }

    public func close() async {
        await mux.close()
        await carrier.close()
    }
}

/// Port of session_api.dart's `_SessionWatch` recovery loop, flattened:
/// snapshot-first, `seq` continuity with `session/page` gap repair and resync,
/// assistant-stream `revision` continuity, host-event forwarding for this
/// session, backoff on transient failures (six without a snapshot end it).
final class SessionWatch {
    private let client: DshClient
    private let sessionId: String
    private let options: WatchOptions

    private var lastSeq = -1
    private var assistantRevision: Int?
    private var failures = 0
    private var resyncs = 0
    private var forwardedEventIds = Set<String>()
    private var stopped = false
    private var current: MuxStream?
    private var hostEventsTask: Task<Void, Never>?
    private var statesTask: Task<Void, Never>?

    init(client: DshClient, sessionId: String, options: WatchOptions) {
        self.client = client
        self.sessionId = sessionId
        self.options = options
    }

    func run(continuation: AsyncThrowingStream<WatchEvent, Error>.Continuation) {
        // onTermination (set by DshClient.watch) holds this watcher for the
        // stream's lifetime and calls stop() on cancellation; assigning here
        // would clobber that retention and deallocate the watcher.

        let client = self.client
        hostEventsTask = Task { [weak self] in
            guard let self else { return }
            let pending = await client.mux.pendingRequests
            for event in pending {
                self.forwardHost(event) { self.emit($0, to: continuation) }
            }
            for await event in await client.mux.hostEvents() {
                guard !self.stopped else { return }
                self.forwardHost(event) { self.emit($0, to: continuation) }
            }
        }
        statesTask = Task { [weak self] in
            guard let self else { return }
            for await state in await client.mux.states() {
                guard !self.stopped else { return }
                if self.options.includeConnectionEvents {
                    self.emit(.connectionState(state, nil), to: continuation)
                }
            }
        }
        Task { [weak self] in
            if DshWebSocketLink.trace { print("[watch] loop task firing, self=\(self != nil)") }
            await self?.loop(continuation: continuation)
        }
    }

    func stop() {
        stopped = true
        current?.cancel()
        hostEventsTask?.cancel()
        statesTask?.cancel()
    }

    private func emit(_ event: WatchEvent, to continuation: AsyncThrowingStream<WatchEvent, Error>.Continuation) {
        guard !stopped else { return }
        continuation.yield(event)
    }

    private func forwardHost(_ event: HostEvent, _ emit: (WatchEvent) -> Void) {
        switch event {
        case .ready:
            break
        case let .approvalRequested(request) where request.sessionId == sessionId:
            forwardedEventIds.insert(request.eventId)
            emit(.approval(request))
        case let .userQuestionRequested(request) where request.sessionId == sessionId:
            forwardedEventIds.insert(request.eventId)
            emit(.question(request))
        case let .requestCancelled(eventId) where forwardedEventIds.remove(eventId) != nil:
            emit(.requestCancelled(eventId: eventId))
        case let .sessionStatus(id, running) where id == sessionId:
            emit(.sessionStatus(sessionId: id, running: running))
        case let .sessionError(id, message) where id == sessionId:
            emit(.sessionError(sessionId: id, message: message))
        case let .sessionRemoved(id) where id == sessionId:
            emit(.sessionRemoved(sessionId: id))
        default:
            break
        }
    }

    private func loop(continuation: AsyncThrowingStream<WatchEvent, Error>.Continuation) async {
        if DshWebSocketLink.trace { print("[watch] loop entered") }
        while !stopped {
            do {
                if DshWebSocketLink.trace { print("[watch] awaiting ready") }
                try await client.mux.ready()
                if DshWebSocketLink.trace { print("[watch] ready ok") }
            } catch {
                if !stopped {
                    continuation.finish(throwing: error)
                }
                stop()
                return
            }
            if DshWebSocketLink.trace { print("[watch] opening follow") }
            let stream = await client.mux.open(
                "session/follow",
                [
                    "request": [
                        "address": ["kind": "session", "sessionId": sessionId] as [String: Any],
                        "assistantStream": options.assistantStream,
                        "maxMessages": options.maxMessages,
                        "turnWindow": [
                            "minMessages": options.turnWindowMinMessages,
                            "minTurns": options.turnWindowMinTurns,
                        ] as [String: Any],
                    ] as [String: Any],
                ]
            )
            current = stream
            do {
                var opened = false
                for try await item in stream.throwingValues {
                    if stopped { return }
                    if !opened {
                        let first = FollowFrame.parse(item, isResync: lastSeq >= 0)
                        guard case let .snapshot(snapshot) = first else {
                            throw DshError.protocolFailure("follow opened without snapshot")
                        }
                        try await onSnapshot(snapshot, continuation: continuation)
                        opened = true
                    } else {
                        try onFrame(item, continuation: continuation)
                        resyncs = 0
                    }
                }
                if stopped { return }
                // The Host ended the follow without an error: reopen shortly.
                stream.cancel()
                try? await Task.sleep(nanoseconds: 500_000_000)
            } catch let error as DshError {
                if DshWebSocketLink.trace { print("[watch] follow ended: \(error)") }
                if case .closed = error {
                    stop()
                    continuation.finish(throwing: error)
                    return
                }
                if case .carrierLost = error {
                    continue
                }
                if !recover(error) {
                    if !stopped {
                        continuation.finish(throwing: error)
                    }
                    stop()
                    return
                }
                try? await Task.sleep(nanoseconds: UInt64(backoffDelay() * 1_000_000_000))
            } catch {
                if !stopped {
                    continuation.finish(throwing: DshError.transport("\(error)"))
                }
                stop()
                return
            }
        }
    }

    /// Whether to reopen after [error]: refused credentials wait for a new
    /// login generation, transient failures back off, anything else ends.
    private func recover(_ error: DshError) -> Bool {
        guard !stopped else { return false }
        if error.isUnauthorized {
            // The mux parks in `unauthorized` until a new login; the next
            // `ready()` in the loop blocks until then.
            return true
        }
        guard error.isTransient, failures < 6 else { return false }
        failures += 1
        return true
    }

    private func backoffDelay() -> TimeInterval {
        let caps: [TimeInterval] = [0.5, 1, 2, 4, 8, 10]
        let cap = caps[min(failures - 1, caps.count - 1)]
        return cap * (0.5 + Double.random(in: 0...0.5))
    }

    private func onSnapshot(_ snapshot: SessionSnapshot, continuation: AsyncThrowingStream<WatchEvent, Error>.Continuation) async throws {
        assistantRevision = snapshot.assistantRevision
        var events = snapshot.events
        // A resync whose window starts after the last event we delivered:
        // fill the hole from history so merging by seq leaves nothing.
        if lastSeq >= 0, snapshot.cursor > lastSeq {
            let firstSeq = events.first?.seq ?? (snapshot.cursor + 1)
            if firstSeq > lastSeq + 1 {
                let filled = try await fillGap(from: lastSeq + 1, before: firstSeq, through: snapshot.cursor)
                events = filled + events
            }
        }
        lastSeq = snapshot.cursor
        failures = 0
        emit(.snapshot(SessionSnapshot(
            header: snapshot.header,
            cursor: snapshot.cursor,
            events: events,
            hasMore: snapshot.hasMore,
            title: snapshot.title,
            assistantRevision: snapshot.assistantRevision,
            activeAttempt: snapshot.activeAttempt,
            isResync: snapshot.isResync
        )), to: continuation)
    }

    private func fillGap(from: Int, before: Int, through: Int) async throws -> [SessionLogEvent] {
        let page = try await client.history(sessionId, throughSeq: through, beforeSeq: before)
        return page.events.filter { $0.seq >= from && $0.seq < before }
    }

    private func onFrame(_ item: Any?, continuation: AsyncThrowingStream<WatchEvent, Error>.Continuation) throws {
        switch FollowFrame.parse(item) {
        case let .snapshot(snapshot):
            // A second snapshot without a loss is a server-driven resync.
            lastSeq = snapshot.cursor
            assistantRevision = snapshot.assistantRevision
            emit(.snapshot(snapshot), to: continuation)
        case let .event(event):
            // Durable events are strictly contiguous; a hole is a protocol
            // failure (the resync path above should have prevented it).
            if event.seq != lastSeq + 1 {
                if event.seq <= lastSeq { return } // duplicate dropped
                throw DshError.protocolFailure("session event gap: expected \(lastSeq + 1), got \(event.seq)")
            }
            lastSeq = event.seq
            emit(.logEvent(event), to: continuation)
        case let .assistantStream(frame):
            // Known frames' revision is exactly previous + 1; a skipped one
            // means missed deltas — resync via a fresh follow. Unknown frame
            // types pass through unchecked, exactly like the Dart client's
            // UnknownFrameEvent branch.
            if case .unknown = frame {
                emit(.assistantStream(frame), to: continuation)
                return
            }
            let expected = (assistantRevision ?? 0) + 1
            guard frame.revision == expected else {
                throw DshError.protocolFailure(
                    "assistant stream revision gap: expected \(expected), got \(frame.revision)"
                )
            }
            assistantRevision = frame.revision
            emit(.assistantStream(frame), to: continuation)
        case .unknown:
            break
        }
    }
}
