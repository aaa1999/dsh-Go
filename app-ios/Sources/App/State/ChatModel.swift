import DshCore
import Foundation
import Observation

/// One open conversation: the watch task feeding a [Transcript], the prompt
/// box, the running turn, and this session's approvals/questions (M5's
/// interaction lands on the same screen).
@MainActor
@Observable
final class ChatModel {
    let sessionId: String
    private let client: DshClient

    var transcript = Transcript()
    var streaming: StreamingDraft?
    var title: String?
    var running = false
    var connectionState: DshConnectionState = .idle
    var approvals: [ApprovalRequest] = []
    var questions: [UserQuestionRequest] = []
    /// Requests the person swiped away this session; a banner brings them back.
    var dismissedRequestIds: Set<String> = []
    var error: String?

    private var watchTask: Task<Void, Never>?
    private var pendingPromptIds = Set<String>()

    init(sessionId: String, client: DshClient) {
        self.sessionId = sessionId
        self.client = client
        start()
    }

    private func start() {
        watchTask = Task { [weak self] in
            guard let self else { return }
            let stream = await self.client.watch(self.sessionId)
            do {
                for try await event in stream {
                    await self.apply(event)
                }
            } catch {
                if !Task.isCancelled {
                    self.error = "\(error)"
                }
            }
        }
    }

    private func apply(_ event: WatchEvent) async {
        transcript.apply(event)
        streaming = transcript.streaming
        title = transcript.title
        running = transcript.running
        switch event {
        case let .connectionState(state, _):
            connectionState = state
        case let .logEvent(logEvent) where logEvent.type == "user/message":
            // Drop the optimistic echo once the durable one lands.
            if let rpcId = logEvent.userMessage?.source.rpcId {
                pendingPromptIds.remove(rpcId)
            }
        case let .approval(request):
            if !approvals.contains(where: { $0.eventId == request.eventId }) {
                approvals.append(request)
            }
        case let .question(request):
            if !questions.contains(where: { $0.eventId == request.eventId }) {
                questions.append(request)
            }
        case let .requestCancelled(eventId):
            approvals.removeAll { $0.eventId == eventId }
            questions.removeAll { $0.eventId == eventId }
        default:
            break
        }
    }

    /// Sends the prompt; the message appears at once (optimistic) and is
    /// replaced by the durable `user/message` event.
    func send(_ text: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do {
            let requestId = try await client.prompt(sessionId, trimmed, timeZone: TimeZone.current.identifier)
            pendingPromptIds.insert(requestId)
            running = true
        } catch {
            self.error = "\(error)"
        }
    }

    func stop() async {
        do {
            try await client.cancel(sessionId)
        } catch {
            self.error = "\(error)"
        }
    }

    func answer(approval: ApprovalRequest, decision: ApprovalDecision) async {
        approvals.removeAll { $0.eventId == approval.eventId }
        do {
            try await client.respondApproval(approval, decision: decision)
        } catch {
            self.error = "\(error)"
        }
    }

    func answer(question: UserQuestionRequest, answers: [QuestionAnswer]) async {
        questions.removeAll { $0.eventId == question.eventId }
        do {
            try await client.answerQuestion(question, answers: answers)
        } catch {
            self.error = "\(error)"
        }
    }

    func cancelWatch() {
        watchTask?.cancel()
    }

    /// The first approval not swiped away (the sheet's content).
    var visibleApproval: ApprovalRequest? {
        approvals.first { !dismissedRequestIds.contains($0.eventId) }
    }

    var visibleQuestion: UserQuestionRequest? {
        questions.first { !dismissedRequestIds.contains($0.eventId) }
    }

    func dismiss(requestId: String) {
        dismissedRequestIds.insert(requestId)
    }

    func reopen(requestId: String) {
        dismissedRequestIds.remove(requestId)
    }
}
