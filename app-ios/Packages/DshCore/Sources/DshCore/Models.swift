import Foundation

// Content parts and messages (models.dart §Content parts).

public enum Part {
    case text(String)
    /// Model reasoning ("thinking"); render collapsed, never as the answer.
    case reasoning(String)
    case image(ImageAttachment, offloaded: Bool)
    case file(FileAttachment)
    case toolCall(id: String, name: String, arguments: String)
    case unknown(type: String, raw: [String: Any])

    public static func parse(_ json: Any?) -> Part {
        let map = Json.asMapOrEmpty(json)
        switch Json.asString(map["type"]) ?? "" {
        case "text": return .text(Json.asString(map["text"]) ?? "")
        case "reasoning": return .reasoning(Json.asString(map["text"]) ?? "")
        case "image": return .image(ImageAttachment.parse(map["attachment"]), offloaded: map["offloaded"] as? Bool == true)
        case "file": return .file(FileAttachment.parse(map["attachment"]))
        case "tool-call":
            return .toolCall(
                id: Json.asString(map["id"]) ?? "",
                name: Json.asString(map["name"]) ?? "",
                arguments: Json.asString(map["arguments"]) ?? ""
            )
        case let type: return .unknown(type: type, raw: map)
        }
    }

    public static func parseList(_ json: Any?) -> [Part] {
        Json.asListOrEmpty(json).map(parse)
    }

    public var text: String? {
        if case let .text(t) = self { return t }
        return nil
    }
}

public struct ImageAttachment: Equatable {
    public let attachmentId: String
    public let mediaType: String
    public let bytes: Int?
    public let width: Int?
    public let height: Int?
    public let name: String?

    public static func parse(_ json: Any?) -> ImageAttachment {
        let map = Json.asMapOrEmpty(json)
        return ImageAttachment(
            attachmentId: Json.asString(map["attachmentId"]) ?? "",
            mediaType: Json.asString(map["mediaType"]) ?? "application/octet-stream",
            bytes: Json.asInt(map["bytes"]),
            width: Json.asInt(map["width"]),
            height: Json.asInt(map["height"]),
            name: Json.asString(map["name"])
        )
    }
}

public struct FileAttachment: Equatable {
    public let attachmentId: String
    public let name: String?
    public let bytes: Int?

    public static func parse(_ json: Any?) -> FileAttachment {
        let map = Json.asMapOrEmpty(json)
        return FileAttachment(
            attachmentId: Json.asString(map["attachmentId"]) ?? "",
            name: Json.asString(map["name"]),
            bytes: Json.asInt(map["bytes"])
        )
    }
}

public enum MessageRole: String {
    case user, assistant, system, developer, tool
    case unknown

    public static func parse(_ raw: Any?) -> MessageRole {
        MessageRole(rawValue: Json.asString(raw) ?? "") ?? .unknown
    }
}

public struct MessageSource {
    /// `user`, `model`, `runtime-context`, ...
    public let kind: String
    /// Matches `session/prompt`'s requestId (optimistic echo pairing).
    public let rpcId: String?
    public let raw: [String: Any]

    public static func parse(_ json: Any?) -> MessageSource {
        let map = Json.asMapOrEmpty(json)
        return MessageSource(
            kind: Json.asString(map["kind"]) ?? "",
            rpcId: Json.asString(map["rpcId"]),
            raw: map
        )
    }
}

public struct Message {
    public let id: String
    public let role: MessageRole
    public let parts: [Part]
    public let source: MessageSource
    public let toolCallId: String?
    public let isError: Bool

    public static func parse(_ json: Any?) -> Message {
        let map = Json.asMapOrEmpty(json)
        return Message(
            id: Json.asString(map["id"]) ?? "",
            role: MessageRole.parse(map["role"]),
            parts: Part.parseList(map["content"]),
            source: MessageSource.parse(map["source"]),
            toolCallId: Json.asString(map["toolCallId"]),
            isError: map["isError"] as? Bool == true
        )
    }

    /// Concatenated visible text (text parts only).
    public var text: String {
        parts.compactMap(\.text).joined()
    }

    public var reasoning: String {
        parts.compactMap { if case let .reasoning(t) = $0 { return t } else { return nil } }.joined()
    }
}

public struct TokenUsage: Equatable {
    public let inputTokens: Int
    public let outputTokens: Int
    public let totalTokens: Int?
    public let cacheReadTokens: Int?
    public let cacheWriteTokens: Int?
    public let reasoningTokens: Int?

    public static func parse(_ json: Any?) -> TokenUsage? {
        guard Json.asMap(json) != nil else { return nil }
        let map = Json.asMapOrEmpty(json)
        return TokenUsage(
            inputTokens: Json.asInt(map["inputTokens"]) ?? 0,
            outputTokens: Json.asInt(map["outputTokens"]) ?? 0,
            totalTokens: Json.asInt(map["totalTokens"]),
            cacheReadTokens: Json.asInt(map["cacheReadTokens"]),
            cacheWriteTokens: Json.asInt(map["cacheWriteTokens"]),
            reasoningTokens: Json.asInt(map["reasoningTokens"])
        )
    }
}

/// Provider or transport failure facts (`LlmFailure`), e.g. `MISSING_CREDENTIAL`.
public struct LlmFailure: Equatable {
    public let message: String
    public let code: String
    public let status: Int?

    public static func parse(_ json: Any?) -> LlmFailure? {
        guard Json.asMap(json) != nil else { return nil }
        let map = Json.asMapOrEmpty(json)
        return LlmFailure(
            message: Json.asString(map["message"]) ?? "",
            code: Json.asString(map["code"]) ?? "UNKNOWN",
            status: Json.asInt(map["status"])
        )
    }
}

// Model streaming chunks (models.dart §Model streaming chunks).

public enum StreamChunk {
    case blockStart(index: Int, blockType: String)
    case textDelta(index: Int, text: String)
    case reasoningDelta(index: Int, text: String)
    case toolCallDelta(index: Int, id: String, name: String?, argumentsDelta: String)
    case blockEnd(index: Int, block: Part)
    case usage(TokenUsage)
    case finish(reason: String, failure: LlmFailure?)
    case unknown(raw: [String: Any])

    public static func parse(_ json: Any?) -> StreamChunk {
        let map = Json.asMapOrEmpty(json)
        let index = Json.asInt(map["index"]) ?? 0
        switch Json.asString(map["type"]) ?? "" {
        case "block-start": return .blockStart(index: index, blockType: Json.asString(map["blockType"]) ?? "")
        case "text-delta": return .textDelta(index: index, text: Json.asString(map["text"]) ?? "")
        case "reasoning-delta": return .reasoningDelta(index: index, text: Json.asString(map["text"]) ?? "")
        case "tool-call-delta":
            return .toolCallDelta(
                index: index,
                id: Json.asString(map["id"]) ?? "",
                name: Json.asString(map["name"]),
                argumentsDelta: Json.asString(map["argumentsDelta"]) ?? ""
            )
        case "block-end": return .blockEnd(index: index, block: Part.parse(map["block"]))
        case "usage":
            return .usage(
                TokenUsage.parse(map["usage"])
                    ?? TokenUsage(inputTokens: 0, outputTokens: 0, totalTokens: nil, cacheReadTokens: nil, cacheWriteTokens: nil, reasoningTokens: nil)
            )
        case "finish":
            let reason = Json.asMapOrEmpty(map["reason"])
            return .finish(reason: Json.asString(reason["kind"]) ?? "unknown", failure: LlmFailure.parse(reason["failure"]))
        default: return .unknown(raw: map)
        }
    }
}

public struct TimedChunk {
    public let time: Date
    public let chunk: StreamChunk

    public init(time: Date, chunk: StreamChunk) {
        self.time = time
        self.chunk = chunk
    }
}

/// Expands the compact `AssistantStreamRecord[]` (models.dart's
/// `expandCompactStream`) into the exact chunk sequence.
public func expandCompactStream(_ records: Any?) -> [TimedChunk] {
    var out: [TimedChunk] = []
    for record in Json.asListOrEmpty(records) {
        let map = Json.asMapOrEmpty(record)
        let type = Json.asString(map["type"]) ?? ""
        if type == "chunk" {
            out.append(
                TimedChunk(
                    time: Json.asEpochMs(map["time"]) ?? Date(timeIntervalSince1970: 0),
                    chunk: StreamChunk.parse(map["chunk"])
                )
            )
            continue
        }
        guard type == "text-chunks" || type == "reasoning-chunks" || type == "tool-call-chunks" else { continue }
        let members = Json.asStringList(type == "tool-call-chunks" ? map["args"] : map["texts"])
        let dt = Json.asListOrEmpty(map["dt"]).map { Json.asInt($0) ?? 0 }
        let index = Json.asInt(map["index"]) ?? 0
        var time = Json.asInt(map["time0"]) ?? 0
        for (i, member) in members.enumerated() {
            if i > 0, i - 1 < dt.count { time += dt[i - 1] }
            let chunk: StreamChunk
            switch type {
            case "text-chunks": chunk = .textDelta(index: index, text: member)
            case "reasoning-chunks": chunk = .reasoningDelta(index: index, text: member)
            default:
                chunk = .toolCallDelta(
                    index: index,
                    id: Json.asString(map["id"]) ?? "",
                    name: Json.asString(map["name"]),
                    argumentsDelta: member
                )
            }
            out.append(TimedChunk(time: Date(timeIntervalSince1970: TimeInterval(time) / 1000), chunk: chunk))
        }
    }
    return out
}

// Sessions (models.dart §Sessions).

/// One `session/list` row (also the payload of `api-session/added`).
public struct SessionSummary: Identifiable, Equatable {
    public let sessionId: String
    public let updatedAt: Date
    public let running: Bool
    /// No turn yet ("New session").
    public let blank: Bool
    public let agentAvailable: Bool
    public let cwd: String?
    public let parentSessionId: String?
    /// `subagent` for child sessions; hide those from a top-level list.
    public let origin: String?
    public let title: String?
    public let raw: [String: Any]

    public var id: String { sessionId }
    public var isSubagent: Bool { origin == "subagent" }

    public static func parse(_ json: Any?) -> SessionSummary {
        let map = Json.asMapOrEmpty(json)
        let projections = Json.asMapOrEmpty(map["projections"])
        return SessionSummary(
            sessionId: Json.asString(map["sessionId"]) ?? "",
            updatedAt: Json.asEpochMs(map["updatedAt"]) ?? Date(timeIntervalSince1970: 0),
            running: map["running"] as? Bool == true,
            blank: map["blank"] as? Bool == true,
            agentAvailable: map["agentAvailable"] as? Bool == true,
            cwd: Json.asString(map["cwd"]),
            parentSessionId: Json.asString(map["parentSessionId"]),
            origin: Json.asString(map["origin"]),
            title: Json.asString(projections["title"]),
            raw: map
        )
    }

    public static func == (lhs: SessionSummary, rhs: SessionSummary) -> Bool { lhs.sessionId == rhs.sessionId }
}

public struct SessionCreated: Equatable {
    public let sessionId: String
    public let agentPreset: String?

    public static func parse(_ json: Any?) -> SessionCreated {
        let map = Json.asMapOrEmpty(json)
        return SessionCreated(sessionId: Json.asString(map["sessionId"]) ?? "", agentPreset: Json.asString(map["agentPreset"]))
    }
}

public struct SessionHeader: Equatable {
    public let id: String
    public let version: Int
    public let createdAt: Date
    public let isSeeded: Bool
    public let cwd: String?
    public let origin: String?
    public let agentPreset: String?

    public static func parse(_ json: Any?) -> SessionHeader {
        let map = Json.asMapOrEmpty(json)
        return SessionHeader(
            id: Json.asString(map["id"]) ?? "",
            version: Json.asInt(map["version"]) ?? 0,
            createdAt: Json.asEpochMs(map["createdAt"]) ?? Date(timeIntervalSince1970: 0),
            isSeeded: map["isSeeded"] as? Bool == true,
            cwd: Json.asString(map["cwd"]),
            origin: Json.asString(map["origin"]),
            agentPreset: Json.asString(map["agentPreset"])
        )
    }
}

/// In-flight model attempt carried by a follow snapshot.
public struct ActiveAttempt {
    public let attemptId: String
    public let startedAfterSeq: Int
    public let turn: Int
    public let step: Int
    /// Index the next `chunk` frame of this attempt will carry.
    public let nextIndex: Int
    public let chunks: [TimedChunk]

    public static func parse(_ map: [String: Any]) -> ActiveAttempt {
        ActiveAttempt(
            attemptId: Json.asString(map["attemptId"]) ?? "",
            startedAfterSeq: Json.asInt(map["startedAfterSeq"]) ?? -1,
            turn: Json.asInt(map["turn"]) ?? 0,
            step: Json.asInt(map["step"]) ?? 0,
            nextIndex: Json.asInt(map["nextIndex"]) ?? 0,
            chunks: expandCompactStream(map["stream"])
        )
    }
}

/// One durable session event: contiguous `seq`, epoch-ms `time`, typed `data`.
/// The Dart client models these as sealed subclasses; here one struct with the
/// `type` plus typed accessors for the events the chat renders.
public struct SessionLogEvent: Equatable {
    public let seq: Int
    public let time: Date
    public let type: String
    public let data: [String: Any]

    public static func parse(_ json: Any?) -> SessionLogEvent {
        let map = Json.asMapOrEmpty(json)
        return SessionLogEvent(
            seq: Json.asInt(map["seq"]) ?? -1,
            time: Json.asEpochMs(map["time"]) ?? Date(timeIntervalSince1970: 0),
            type: Json.asString(map["type"]) ?? "",
            data: Json.asMapOrEmpty(map["data"])
        )
    }

    public var turn: Int { Json.asInt(data["turn"]) ?? 0 }
    public var step: Int { Json.asInt(data["step"]) ?? 0 }

    public var userMessage: Message? {
        type == "user/message" ? Message.parse(data) : nil
    }

    public var assistantMessage: (message: Message, usage: TokenUsage?, interrupted: Bool)? {
        guard type == "assistant/message" else { return nil }
        return (
            Message.parse(data["message"]),
            TokenUsage.parse(data["usage"]),
            data["interrupted"] as? Bool == true
        )
    }

    public var toolCall: (callId: String, name: String, arguments: String)? {
        guard type == "tool/call" else { return nil }
        return (
            Json.asString(data["callId"]) ?? "",
            Json.asString(data["name"]) ?? "",
            Json.asString(data["arguments"]) ?? ""
        )
    }

    public var toolResult: (message: Message, failure: LlmFailure?)? {
        guard type == "tool/result" else { return nil }
        return (Message.parse(data["message"]), LlmFailure.parse(data["error"]))
    }

    /// `completed`, `aborted`, `blocked`, `error`, `max-tokens`, `interrupted`, `forked`.
    public var turnEndReason: TurnEndReason? {
        guard type == "turn/end" else { return nil }
        return TurnEndReason.parse(data["reason"])
    }

    public var title: String? {
        guard type == "session/title" else { return nil }
        return Json.asString(data["title"]) ?? ""
    }

    public static func == (lhs: SessionLogEvent, rhs: SessionLogEvent) -> Bool { lhs.seq == rhs.seq }
}

public struct TurnEndReason: Equatable {
    public let kind: String
    /// For `aborted`: `user`, `parent`, `hook`, `disposed`, `legacy`.
    public let cancelCause: String?
    public let error: LlmFailure?

    public static func parse(_ json: Any?) -> TurnEndReason {
        let map = Json.asMapOrEmpty(json)
        return TurnEndReason(
            kind: Json.asString(map["kind"]) ?? "unknown",
            cancelCause: Json.asString(Json.asMapOrEmpty(map["reason"])["kind"]),
            error: LlmFailure.parse(map["error"])
        )
    }
}

/// First frame of every `session/follow` generation. `events` is a window of
/// the durable log ending at `cursor`; on a resync merge by `seq`.
public struct SessionSnapshot {
    public let header: SessionHeader
    /// Seq of the last durable event at the cut (`-1` for an empty log).
    public let cursor: Int
    public let events: [SessionLogEvent]
    public let hasMore: Bool
    public let title: String?
    /// Baseline for assistant-stream revisions (each frame is +1).
    public let assistantRevision: Int?
    /// Model attempt streaming right now, with everything streamed so far.
    public let activeAttempt: ActiveAttempt?
    public let isResync: Bool

    public static func parse(_ json: Any?, isResync: Bool = false) -> SessionSnapshot {
        let map = Json.asMapOrEmpty(json)
        let stream = Json.asMapOrEmpty(map["assistantStream"])
        let attempt = Json.asMap(stream["activeAttempt"])
        return SessionSnapshot(
            header: SessionHeader.parse(map["header"]),
            cursor: Json.asInt(map["cursor"]) ?? -1,
            events: Json.asListOrEmpty(map["records"]).map { SessionLogEvent.parse(Json.asMapOrEmpty($0)["event"]) },
            hasMore: map["hasMore"] as? Bool == true,
            title: Json.asString(Json.asMapOrEmpty(map["projections"])["title"]),
            assistantRevision: Json.asInt(stream["revision"]),
            activeAttempt: attempt.map { ActiveAttempt.parse($0) },
            isResync: isResync
        )
    }
}

/// One `session/follow` item: `snapshot`, `event` or `assistant-stream`.
public enum FollowFrame {
    case snapshot(SessionSnapshot)
    case event(SessionLogEvent)
    case assistantStream(AssistantStreamFrame)
    case unknown(raw: [String: Any])

    public static func parse(_ value: Any?, isResync: Bool = false) -> FollowFrame {
        let map = Json.asMapOrEmpty(value)
        switch Json.asString(map["type"]) ?? "" {
        case "snapshot": return .snapshot(SessionSnapshot.parse(map, isResync: isResync))
        case "event": return .event(SessionLogEvent.parse(map["event"]))
        case "assistant-stream": return .assistantStream(AssistantStreamFrame.parse(map["frame"]))
        default: return .unknown(raw: map)
        }
    }
}

/// Live assistant stream (cursorless, `assistantStream: true` follow frames):
/// every frame's `revision` is exactly previous + 1.
public enum AssistantStreamFrame {
    case started(attemptId: String, revision: Int, turn: Int, step: Int, startedAfterSeq: Int)
    case chunk(attemptId: String, revision: Int, index: Int, time: Date, chunk: StreamChunk)
    case ended(attemptId: String, revision: Int, index: Int, committed: Bool, committedEventType: String?, committedSeq: Int?)
    case unknown(raw: [String: Any])

    public var attemptId: String {
        switch self {
        case let .started(id, _, _, _, _), let .chunk(id, _, _, _, _), let .ended(id, _, _, _, _, _):
            return id
        case .unknown: return ""
        }
    }

    public var revision: Int {
        switch self {
        case let .started(_, r, _, _, _), let .chunk(_, r, _, _, _), let .ended(_, r, _, _, _, _):
            return r
        case .unknown: return -1
        }
    }

    public static func parse(_ json: Any?) -> AssistantStreamFrame {
        let frame = Json.asMapOrEmpty(json)
        let attemptId = Json.asString(frame["attemptId"]) ?? ""
        let revision = Json.asInt(frame["revision"]) ?? -1
        switch Json.asString(frame["type"]) ?? "" {
        case "started":
            return .started(
                attemptId: attemptId,
                revision: revision,
                turn: Json.asInt(frame["turn"]) ?? 0,
                step: Json.asInt(frame["step"]) ?? 0,
                startedAfterSeq: Json.asInt(frame["startedAfterSeq"]) ?? -1
            )
        case "chunk":
            return .chunk(
                attemptId: attemptId,
                revision: revision,
                index: Json.asInt(frame["index"]) ?? 0,
                time: Json.asEpochMs(frame["time"]) ?? Date(),
                chunk: StreamChunk.parse(frame["chunk"])
            )
        case "ended":
            let outcome = Json.asMapOrEmpty(frame["outcome"])
            return .ended(
                attemptId: attemptId,
                revision: revision,
                index: Json.asInt(frame["index"]) ?? 0,
                committed: Json.asString(outcome["kind"]) == "committed",
                committedEventType: Json.asString(outcome["eventType"]),
                committedSeq: Json.asInt(outcome["seq"])
            )
        default:
            return .unknown(raw: frame)
        }
    }
}

// Host events (the `$events` stream after `ready`).

public enum HostEvent {
    /// Opening item of each `$events` generation.
    case ready(clientId: String, home: String)
    case sessionAdded(SessionSummary)
    case sessionRemoved(sessionId: String)
    /// A turn started (`running: true`) or the session went idle.
    case sessionStatus(sessionId: String, running: Bool)
    case sessionActivity(sessionId: String, updatedAt: Date)
    /// A live failure with no turn position (show as a toast/banner).
    case sessionError(sessionId: String, message: String)
    case approvalRequested(ApprovalRequest)
    case userQuestionRequested(UserQuestionRequest)
    /// A pending approval/question was answered (by any client) or withdrawn.
    case requestCancelled(eventId: String)
    case unknown(event: String, raw: [String: Any], eventId: String?, agentId: String?)

    public static func parse(_ json: Any?) -> HostEvent {
        let frame = Json.asMapOrEmpty(json)
        switch Json.asString(frame["type"]) ?? "" {
        case "ready":
            return .ready(
                clientId: Json.asString(frame["clientId"]) ?? "",
                home: Json.asString(Json.asMapOrEmpty(frame["host"])["home"]) ?? ""
            )
        case "emit":
            return parseEmit(Json.asString(frame["event"]) ?? "", args: Json.asListOrEmpty(frame["args"]))
        case "waterfall":
            let event = Json.asString(frame["event"]) ?? ""
            let eventId = Json.asString(frame["eventId"]) ?? ""
            let agentId = Json.asString(frame["agentId"]) ?? ""
            if event == "approval/request" {
                return .approvalRequested(ApprovalRequest.parse(eventId: eventId, agentId: agentId, json: frame["request"]))
            }
            if event == "user-questions/request" {
                return .userQuestionRequested(UserQuestionRequest.parse(eventId: eventId, agentId: agentId, json: frame["request"]))
            }
            return .unknown(event: event, raw: frame, eventId: eventId, agentId: agentId)
        case "cancel":
            return .requestCancelled(eventId: Json.asString(frame["eventId"]) ?? "")
        case let type:
            return .unknown(event: type, raw: frame, eventId: nil, agentId: nil)
        }
    }

    private static func parseEmit(_ event: String, args: [Any]) -> HostEvent {
        func arg(_ i: Int) -> Any? { i < args.count ? args[i] : nil }
        switch event {
        case "api-session/added": return .sessionAdded(SessionSummary.parse(arg(0)))
        case "api-session/removed": return .sessionRemoved(sessionId: Json.asString(arg(0)) ?? "")
        case "api-session/status": return .sessionStatus(sessionId: Json.asString(arg(0)) ?? "", running: arg(1) as? Bool == true)
        case "api-session/activity":
            return .sessionActivity(sessionId: Json.asString(arg(0)) ?? "", updatedAt: Json.asEpochMs(arg(1)) ?? Date())
        case "api-session/error":
            return .sessionError(sessionId: Json.asString(arg(0)) ?? "", message: Json.asString(arg(1)) ?? "")
        default:
            return .unknown(event: event, raw: ["type": "emit", "event": event, "args": args], eventId: nil, agentId: nil)
        }
    }
}

public struct ApprovalRequest: Identifiable, Equatable {
    public let eventId: String
    /// The Agent id; equal to the session id for ordinary sessions.
    public let sessionId: String
    public let toolName: String
    public let callId: String?
    public let reason: String?
    /// Localized presentation text keyed by locale (`en` always present).
    public let displayReason: [String: String]

    public var id: String { eventId }

    /// Best text to show: localized display reason, else `reason`.
    public func describe(locale: String = "en") -> String {
        displayReason[locale] ?? displayReason["en"] ?? reason ?? "Allow \(toolName)?"
    }

    public static func parse(eventId: String, agentId: String, json: Any?) -> ApprovalRequest {
        let map = Json.asMapOrEmpty(json)
        let display = Json.asMapOrEmpty(map["displayReason"])
        var displayReason: [String: String] = [:]
        for (key, value) in display where value is String {
            displayReason[key] = value as? String
        }
        return ApprovalRequest(
            eventId: eventId,
            sessionId: agentId,
            toolName: Json.asString(map["toolName"]) ?? "tool",
            callId: Json.asString(map["callId"]),
            reason: Json.asString(map["reason"]),
            displayReason: displayReason
        )
    }
}

public struct QuestionOption: Equatable {
    public let label: String
    public let description: String?
}

public struct UserQuestion: Equatable {
    public let id: String
    public let question: String
    /// Markdown detail (the plan text for `intent.kind == 'plan-review'`).
    public let detail: String?
    public let header: String?
    public let options: [QuestionOption]
    public let multiSelect: Bool

    public static func parse(_ json: Any?) -> UserQuestion {
        let map = Json.asMapOrEmpty(json)
        return UserQuestion(
            id: Json.asString(map["id"]) ?? "",
            question: Json.asString(map["question"]) ?? "",
            detail: Json.asString(map["detail"]),
            header: Json.asString(map["header"]),
            options: Json.asListOrEmpty(map["options"]).map {
                let option = Json.asMapOrEmpty($0)
                return QuestionOption(label: Json.asString(option["label"]) ?? "", description: Json.asString(option["description"]))
            },
            multiSelect: map["multiSelect"] as? Bool == true
        )
    }
}

public struct QuestionAnswer {
    public let id: String
    /// Selected option labels (empty when `custom` replaces a single choice).
    public let selected: [String]
    public let custom: String?

    public init(id: String, selected: [String] = [], custom: String? = nil) {
        self.id = id
        self.selected = selected
        self.custom = custom
    }

    public var json: [String: Any] {
        var out: [String: Any] = ["id": id, "selected": selected]
        if let custom { out["custom"] = custom }
        return out
    }
}

/// `user-questions/request` waterfall (the `ask_user_question` tool).
public struct UserQuestionRequest: Identifiable, Equatable {
    public let eventId: String
    public let sessionId: String
    public let questions: [UserQuestion]
    public let waitCallId: String?

    public var id: String { eventId }

    public static func parse(eventId: String, agentId: String, json: Any?) -> UserQuestionRequest {
        let map = Json.asMapOrEmpty(json)
        return UserQuestionRequest(
            eventId: eventId,
            sessionId: agentId,
            questions: Json.asListOrEmpty(map["questions"]).map(UserQuestion.parse),
            waitCallId: Json.asString(Json.asMapOrEmpty(map["wait"])["callId"])
        )
    }
}
