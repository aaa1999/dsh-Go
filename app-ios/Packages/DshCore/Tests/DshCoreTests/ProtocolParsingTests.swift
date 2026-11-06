import Foundation
import Testing
@testable import DshCore

// Wire-contract tests against the shapes documented in packages/dsh_client's
// tests and the dsh web 0.2.x protocol.

@Test("launch URL: whole line, bare URL, rejected forms")
func launchUrl() {
    let parsed = DshLaunchUrl.tryParse("dsh web: http://127.0.0.1:3080/?token=abc.def")
    #expect(parsed != nil)
    #expect(parsed?.baseUrl.absoluteString == "http://127.0.0.1:3080")
    #expect(parsed?.token == "abc.def")

    let bare = DshLaunchUrl.tryParse("https://h.example/mount/?token=tok")
    #expect(bare?.baseUrl.absoluteString == "https://h.example/mount")
    #expect(bare?.token == "tok")

    #expect(DshLaunchUrl.tryParse("dsh web: http://127.0.0.1:3080/") == nil)
    #expect(DshLaunchUrl.tryParse("dsh web: http://127.0.0.1:3080/?token=") == nil)
    #expect(DshLaunchUrl.tryParse("nothing here") == nil)
}

@Test("cookie: name is bound to the authority; max-age sets the expiry")
func cookieParse() {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let name = DshCookie.expectedName(authority: "127.0.0.1:3080")
    #expect(name.hasPrefix("dsh-auth-"))
    let raw = "\(name)=v1.payload.sig; Max-Age=2592000; Path=/; HttpOnly; SameSite=Strict"
    let cookie = DshCookie.parse(setCookie: raw, authority: "127.0.0.1:3080", now: now)
    #expect(cookie?.name == name)
    #expect(cookie?.value == "v1.payload.sig")
    #expect(cookie?.header == "\(name)=v1.payload.sig")
    if let expiresAt = cookie?.expiresAt {
        #expect(abs(expiresAt.timeIntervalSince(now) - 2_592_000) < 1)
    }
    #expect(cookie?.isExpired(at: now) == false)

    // The Host mints exactly this name for this authority.
    #expect(DshCookie.expectedName(authority: "example.com") != name)
    // No '=' means no cookie.
    #expect(DshCookie.parse(setCookie: "dsh-auth-x; Max-Age=1", authority: "a") == nil)
}

@Test("rpc: endpoint validation rejects traversal and empty segments")
func endpoints() throws {
    try Rpc.checkEndpoint("session/list")
    try Rpc.checkEndpoint("$events/result")
    try Rpc.checkEndpoint("workspace/archiveSession")
    #expect(throws: DshError.self) { try Rpc.checkEndpoint("../etc") }
    #expect(throws: DshError.self) { try Rpc.checkEndpoint("session//list") }
    #expect(throws: DshError.self) { try Rpc.checkEndpoint("") }
    #expect(throws: DshError.self) { try Rpc.checkEndpoint("bad endpoint") }
}

@Test("rpc: request envelope and response reading")
func rpcEnvelope() throws {
    let request = Rpc.encodeRequest(rpcId: "id-1", endpoint: "session/list", args: ["_request": [:] as [String: Any]])
    #expect(Json.asString(request["type"]) == "client-request")
    #expect(Json.asString(request["method"]) == "session/list")
    let payload = Json.asMapOrEmpty(request["payload"])
    #expect(payload.keys.contains("args") && payload.count == 1)

    let ok: [String: Any] = [
        "type": "server-response",
        "rpcId": "id-1",
        "result": ["ok": true, "value": ["items": []]],
    ]
    let value = try Rpc.readResponse(ok, rpcId: "id-1", endpoint: "session/list")
    #expect(Json.asMapOrEmpty(value)["items"] != nil)

    // Void success: no value key.
    let voidOk: [String: Any] = ["type": "server-response", "rpcId": "id-1", "result": ["ok": true]]
    #expect(try Rpc.readResponse(voidOk, rpcId: "id-1", endpoint: "session/cancel") == nil)

    // Business failure is HTTP 200 + ok:false.
    let failed: [String: Any] = [
        "type": "server-response",
        "rpcId": "id-1",
        "result": [
            "ok": false,
            "error": ["code": "session/not-found", "message": "no such session", "details": [:]],
        ],
    ]
    do {
        _ = try Rpc.readResponse(failed, rpcId: "id-1", endpoint: "session/prompt")
        Issue.record("expected a remote error")
    } catch let error as DshError {
        guard case let .remote(code, message, _) = error else {
            Issue.record("expected .remote")
            return
        }
        #expect(code == "session/not-found")
        #expect(message == "no such session")
    }

    #expect(throws: DshError.self) {
        try Rpc.readResponse(["type": "server-response", "rpcId": "other"], rpcId: "id-1", endpoint: "x/y")
    }
}

@Test("host events: ready, emits, waterfalls, cancel")
func hostEvents() {
    guard case let .ready(clientId, home) = HostEvent.parse(
        ["type": "ready", "clientId": "c1", "host": ["home": "/root"]]
    ) else {
        Issue.record("expected ready")
        return
    }
    #expect(clientId == "c1")
    #expect(home == "/root")

    guard case let .sessionAdded(summary) = HostEvent.parse(
        ["type": "emit", "event": "api-session/added", "args": [["sessionId": "s1", "running": true, "updatedAt": 1000]]]
    ) else {
        Issue.record("expected sessionAdded")
        return
    }
    #expect(summary.sessionId == "s1")
    #expect(summary.running)

    guard case let .approvalRequested(approval) = HostEvent.parse([
        "type": "waterfall",
        "event": "approval/request",
        "eventId": "ev1",
        "agentId": "s1",
        "request": ["toolName": "bash", "displayReason": ["zh": "允许运行命令？", "en": "Allow running a command?"]],
    ]) else {
        Issue.record("expected approvalRequested")
        return
    }
    #expect(approval.eventId == "ev1")
    #expect(approval.sessionId == "s1")
    #expect(approval.describe(locale: "zh") == "允许运行命令？")
    #expect(approval.describe(locale: "fr") == "Allow running a command?")

    guard case let .userQuestionRequested(question) = HostEvent.parse([
        "type": "waterfall",
        "event": "user-questions/request",
        "eventId": "ev2",
        "agentId": "s1",
        "request": [
            "questions": [["id": "q1", "question": "Which?", "options": [["label": "A"], ["label": "B"]]]],
            "wait": ["callId": "call-9"],
        ],
    ]) else {
        Issue.record("expected userQuestionRequested")
        return
    }
    #expect(question.questions.count == 1)
    #expect(question.questions.first?.options.map(\.label) == ["A", "B"])
    #expect(question.waitCallId == "call-9")

    guard case let .requestCancelled(eventId) = HostEvent.parse(["type": "cancel", "eventId": "ev1"]) else {
        Issue.record("expected requestCancelled")
        return
    }
    #expect(eventId == "ev1")
}

@Test("follow frames: snapshot, event and assistant-stream")
func followFrames() {
    let snapshotJson: [String: Any] = [
        "type": "snapshot",
        "header": ["id": "s1", "version": 4, "createdAt": 1000],
        "cursor": 5,
        "records": [
            ["event": ["seq": 4, "time": 2000, "type": "user/message", "data": [
                "role": "user",
                "content": [["type": "text", "text": "hi"]],
                "source": ["kind": "user", "rpcId": "r1"],
            ]]],
        ],
        "hasMore": true,
        "projections": ["title": "First chat"],
        "assistantStream": ["revision": 7, "activeAttempt": [
            "attemptId": "a1",
            "startedAfterSeq": 5,
            "turn": 1,
            "step": 0,
            "nextIndex": 3,
            "stream": [
                ["type": "text-chunks", "texts": ["Hel", "lo"], "dt": [10, 20], "index": 0, "time0": 3000],
            ],
        ]],
    ]
    guard case let .snapshot(snapshot) = FollowFrame.parse(snapshotJson) else {
        Issue.record("expected snapshot")
        return
    }
    #expect(snapshot.cursor == 5)
    #expect(snapshot.title == "First chat")
    #expect(snapshot.events.count == 1)
    #expect(snapshot.events.first?.seq == 4)
    #expect(snapshot.events.first?.userMessage?.text == "hi")
    #expect(snapshot.assistantRevision == 7)
    #expect(snapshot.activeAttempt?.chunks.count == 2)
    if case let .textDelta(_, second) = snapshot.activeAttempt?.chunks[1].chunk {
        #expect(second == "lo")
    } else {
        Issue.record("expected a text delta from the compact record")
    }

    guard case let .event(event) = FollowFrame.parse([
        "type": "event",
        "event": ["seq": 6, "time": 3000, "type": "assistant/message", "data": [
            "turn": 1,
            "step": 0,
            "message": [
                "role": "assistant",
                "content": [["type": "text", "text": "Hello!"]],
                "source": ["kind": "model"],
            ],
            "usage": ["inputTokens": 10, "outputTokens": 5],
        ]],
    ]) else {
        Issue.record("expected event")
        return
    }
    #expect(event.seq == 6)
    #expect(event.assistantMessage?.message.text == "Hello!")
    #expect(event.assistantMessage?.usage?.outputTokens == 5)

    guard case let .assistantStream(frame) = FollowFrame.parse([
        "type": "assistant-stream",
        "frame": ["type": "chunk", "attemptId": "a1", "revision": 8, "index": 0, "chunk": [
            "type": "text-delta", "index": 0, "text": "Hi",
        ]],
    ]) else {
        Issue.record("expected assistant-stream")
        return
    }
    #expect(frame.revision == 8)
    if case let .chunk(_, _, _, _, chunk) = frame, case let .textDelta(_, text) = chunk {
        #expect(text == "Hi")
    } else {
        Issue.record("expected a text delta chunk")
    }
}

@Test("compact stream expansion keeps order and timing")
func compactStream() {
    let chunks = expandCompactStream([
        ["type": "text-chunks", "texts": ["a", "b", "c"], "dt": [5, 5], "index": 0, "time0": 1000],
        ["type": "tool-call-chunks", "args": ["{\"x\"", ": 1}"], "dt": [1], "index": 1, "id": "c1", "name": "bash", "time0": 2000],
    ])
    #expect(chunks.count == 5)
    if case let .textDelta(_, second) = chunks[1].chunk {
        #expect(second == "b")
    } else {
        Issue.record("expected text delta b")
    }
    if case let .toolCallDelta(_, _, name, delta) = chunks[4].chunk {
        #expect(name == "bash")
        #expect(delta == ": 1}")
    } else {
        Issue.record("expected tool call delta")
    }
}

@Test("transcript: snapshot rebuild, stream deltas, settled messages")
func transcriptReduction() {
    var transcript = Transcript()
    transcript.apply(
        .snapshot(
            SessionSnapshot.parse([
                "header": ["id": "s1", "version": 4],
                "cursor": 2,
                "records": [
                    ["event": ["seq": 0, "time": 1, "type": "turn/start", "data": ["turn": 1]]],
                    ["event": ["seq": 1, "time": 2, "type": "user/message", "data": [
                        "role": "user",
                        "content": [["type": "text", "text": "question"]],
                        "source": ["kind": "user"],
                    ]]],
                    ["event": ["seq": 2, "time": 3, "type": "assistant/message", "data": [
                        "turn": 1,
                        "message": [
                            "role": "assistant",
                            "content": [["type": "text", "text": "answer"]],
                            "source": ["kind": "model"],
                        ],
                    ]]],
                ],
                "hasMore": false,
                "projections": ["title": "T"],
            ])
        )
    )
    #expect(transcript.items.map(\.id) == ["e:1", "e:2"])
    #expect(transcript.title == "T")
    #expect(transcript.cursor == 2)

    // A tool call and its result, then the live stream of the next attempt.
    transcript.apply(
        .logEvent(
            SessionLogEvent.parse([
                "seq": 3, "time": 4, "type": "tool/call",
                "data": ["turn": 2, "callId": "c1", "name": "bash", "arguments": "{}"],
            ])
        )
    )
    transcript.apply(
        .logEvent(
            SessionLogEvent.parse([
                "seq": 4, "time": 5, "type": "tool/result",
                "data": ["turn": 2, "message": ["role": "tool", "toolCallId": "c1", "content": [["type": "text", "text": "done"]], "source": ["kind": "tool"]]],
            ])
        )
    )
    #expect(transcript.items.count == 4)
    #expect(transcript.cursor == 4)

    transcript.apply(.assistantStream(.started(attemptId: "a1", revision: 0, turn: 2, step: 1, startedAfterSeq: 4)))
    transcript.apply(.assistantStream(.chunk(attemptId: "a1", revision: 1, index: 0, time: Date(), chunk: .blockStart(index: 0, blockType: "text"))))
    transcript.apply(.assistantStream(.chunk(attemptId: "a1", revision: 2, index: 1, time: Date(), chunk: .textDelta(index: 0, text: "Think"))))
    #expect(transcript.streaming?.text == "Think")

    // Committed: the draft clears and the durable message lands.
    transcript.apply(.assistantStream(.ended(attemptId: "a1", revision: 3, index: 2, committed: true, committedEventType: "assistant/message", committedSeq: 5)))
    #expect(transcript.streaming == nil)
    transcript.apply(
        .logEvent(
            SessionLogEvent.parse([
                "seq": 5, "time": 6, "type": "assistant/message",
                "data": ["turn": 2, "message": [
                    "role": "assistant",
                    "content": [["type": "text", "text": "final"]],
                    "source": ["kind": "model"],
                ]],
            ])
        )
    )
    #expect(transcript.items.count == 5)
    #expect(transcript.cursor == 5)

    // Turn end closes the running flag.
    transcript.apply(
        .logEvent(
            SessionLogEvent.parse(["seq": 6, "time": 7, "type": "turn/end", "data": ["turn": 2, "reason": ["kind": "completed"]]])
        )
    )
    #expect(transcript.running == false)
    if case let .turnEnd(reason, _) = transcript.items.last?.kind {
        #expect(reason == "completed")
    } else {
        Issue.record("expected a turnEnd row")
    }
}

@Test("errors: taxonomy and retry classification")
func errorTaxonomy() {
    #expect(DshError.http(status: 401, message: "x").isUnauthorized)
    #expect(DshError.http(status: 403, message: "x").isUnauthorized)
    #expect(!DshError.http(status: 404, message: "x").isUnauthorized)
    #expect(DshError.transport("down").isTransient)
    #expect(DshError.http(status: 503, message: "x").isTransient)
    #expect(!DshError.remote(code: "session/not-found", message: "", details: [:]).isTransient)
    #expect(DshError.remote(code: "gateway/internal", message: "", details: [:]).isTransient)
}
