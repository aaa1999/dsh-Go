import Foundation

/// One rendered row of the conversation (the MVP reduction of
/// transcript.dart: user and assistant messages, tool call rows, turn ends).
public struct ChatItem: Identifiable, Equatable {
    public enum Kind: Equatable {
        /// A user bubble; only `user/message` events with `source.kind == 'user'`.
        case userMessage(text: String)
        /// A settled assistant reply.
        case assistantMessage(text: String, reasoning: String?, interrupted: Bool)
        /// A collapsed tool invocation row.
        case toolCall(name: String, callId: String)
        /// The row's outcome (matched by callId).
        case toolResult(callId: String, ok: Bool, summary: String)
        /// `turn/end`: completed, aborted, blocked, error, max-tokens...
        case turnEnd(reason: String, detail: String?)
    }

    public let id: String
    public let kind: Kind

    /// Durable seq (`e:<seq>`), or a synthetic id for local inserts.
    init(id: String, kind: Kind) {
        self.id = id
        self.kind = kind
    }
}

/// The live model attempt being streamed (block-ordered text so deltas land
/// in the right block).
public struct StreamingDraft: Equatable {
    public var attemptId: String = ""
    public var blocks: [String] = []
    public var reasoning: String = ""

    /// Visible text so far: text blocks in order.
    public var text: String { blocks.joined() }
}

/// Applies watch events to the visible conversation: a snapshot rebuilds
/// everything (a resync's window is contiguous with what was delivered),
/// later events append, assistant-stream frames update [streaming].
public struct Transcript {
    public private(set) var items: [ChatItem] = []
    public private(set) var title: String?
    public private(set) var streaming: StreamingDraft?
    /// A turn is in flight (turn started, not yet ended).
    public private(set) var running = false
    public private(set) var cursor = -1

    public init() {}

    public mutating func apply(_ event: WatchEvent) {
        switch event {
        case let .snapshot(snapshot):
            rebuild(from: snapshot)
        case let .logEvent(event):
            append(event)
        case let .assistantStream(frame):
            applyStream(frame)
        case let .sessionStatus(_, running):
            self.running = running
        default:
            break
        }
    }

    // MARK: Snapshot

    private mutating func rebuild(from snapshot: SessionSnapshot) {
        var rebuilt: [ChatItem] = []
        var inTurn = false
        for event in snapshot.events {
            if event.type == "session/title", let title = event.title, !title.isEmpty {
                self.title = title
            }
            Self.reduce(event, into: &rebuilt, inTurn: &inTurn)
        }
        // Keep anything the (older) snapshot window ends before.
        let kept = items.filter { item in
            guard let seq = Int(item.id.dropFirst(2)) else { return true }
            return seq > snapshot.cursor
        }
        items = rebuilt + kept
        title = snapshot.title ?? title
        cursor = snapshot.cursor
        running = inTurn
        streaming = draftFrom(snapshot.activeAttempt) ?? streaming
    }

    /// Rebuilds the draft from a snapshot's active attempt (its compact
    /// chunks are exactly what was streamed).
    private func draftFrom(_ attempt: ActiveAttempt?) -> StreamingDraft? {
        guard let attempt, !attempt.attemptId.isEmpty else { return nil }
        var out = StreamingDraft()
        out.attemptId = attempt.attemptId
        for timed in attempt.chunks {
            switch timed.chunk {
            case let .blockStart(index, _):
                while out.blocks.count <= index { out.blocks.append("") }
            case let .textDelta(index, text):
                while out.blocks.count <= index { out.blocks.append("") }
                out.blocks[index] += text
            case let .reasoningDelta(_, text):
                out.reasoning += text
            default:
                break
            }
        }
        return out
    }

    // MARK: Durable events

    private mutating func append(_ event: SessionLogEvent) {
        var inTurn = running
        var target = items
        Self.reduce(event, into: &target, inTurn: &inTurn)
        items = target
        if event.type == "session/title", let title = event.title, !title.isEmpty {
            self.title = title
        }
        running = inTurn
        cursor = event.seq
    }

    /// Pure reduction of one durable event; `inTurn` carries whether a turn is
    /// in flight across events.
    private static func reduce(_ event: SessionLogEvent, into items: inout [ChatItem], inTurn: inout Bool) {
        let id = "e:\(event.seq)"
        switch event.type {
        case "turn/start":
            inTurn = true
        case "turn/end":
            inTurn = false
            let reason = event.turnEndReason
            items.append(
                ChatItem(
                    id: id,
                    kind: .turnEnd(
                        reason: reason?.kind ?? "unknown",
                        detail: reason?.error.map { "\($0.code): \($0.message)" }
                    )
                )
            )
        case "user/message":
            // Only the person's input is a user bubble; runtime context stays
            // out of the way in this MVP.
            guard let message = event.userMessage, message.source.kind == "user" else { return }
            items.append(ChatItem(id: id, kind: .userMessage(text: message.text)))
        case "assistant/message":
            guard let (message, usage, interrupted) = event.assistantMessage else { return }
            _ = usage // surfaced later; the text is what the chat shows now
            let text = message.text
            let reasoning = message.reasoning.isEmpty ? nil : message.reasoning
            guard !text.isEmpty || reasoning != nil || !message.toolCallsPlaceholder.isEmpty else {
                // Tool-call-only messages already rendered as call rows.
                return
            }
            items.append(ChatItem(id: id, kind: .assistantMessage(text: text, reasoning: reasoning, interrupted: interrupted)))
        case "tool/call":
            guard let call = event.toolCall else { return }
            items.append(ChatItem(id: id, kind: .toolCall(name: call.name, callId: call.callId)))
        case "tool/result":
            guard let result = event.toolResult else { return }
            let summary = result.message.text.isEmpty
                ? (result.failure.map { "\($0.code): \($0.message)" } ?? "")
                : result.message.text
            items.append(
                ChatItem(id: id, kind: .toolResult(callId: result.message.toolCallId ?? "", ok: !result.message.isError, summary: String(summary.prefix(400))))
            )
        default:
            break
        }
    }

    // MARK: Live stream

    private mutating func applyStream(_ frame: AssistantStreamFrame) {
        switch frame {
        case let .started(attemptId, _, _, _, _):
            streaming = StreamingDraft()
            streaming?.attemptId = attemptId
        case let .chunk(_, _, _, _, chunk):
            guard streaming != nil else { return }
            switch chunk {
            case let .blockStart(index, _):
                while streaming!.blocks.count <= index { streaming!.blocks.append("") }
            case let .textDelta(index, text):
                while streaming!.blocks.count <= index { streaming!.blocks.append("") }
                streaming!.blocks[index] += text
            case let .reasoningDelta(_, text):
                streaming!.reasoning += text
            case let .blockEnd(_, block):
                // The settled block arrives in the durable message; keep the
                // draft's own copy in sync so it doesn't flicker.
                if case let .text(t) = block {
                    // Delta text already covers it; nothing to add.
                    _ = t
                }
            default:
                break
            }
        case let .ended(_, _, _, committed, _, _):
            // Committed: the durable assistant/message replaces the draft;
            // abandoned: drop it. Either way the draft is over.
            _ = committed
            streaming = nil
        case .unknown:
            break
        }
    }
}

private extension Message {
    /// Tool-call parts inside an assistant message (rendered as call rows by
    /// the `tool/call` events themselves).
    var toolCallsPlaceholder: [Part] {
        parts.filter {
            if case .toolCall = $0 { return true }
            return false
        }
    }
}
