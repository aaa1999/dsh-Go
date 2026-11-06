import DshCore
import MarkdownUI
import SwiftUI

/// One conversation: the transcript, the live stream draft, approvals and
/// questions on top, the prompt box at the bottom.
struct ChatView: View {
    @State private var model: ChatModel
    @State private var draft = ""
    @FocusState private var composerFocused: Bool

    init(model: ChatModel) {
        _model = State(initialValue: model)
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        ForEach(model.transcript.items) { item in
                            ChatItemView(item: item)
                                .id(item.id)
                        }
                        if let streaming = model.streaming, !streaming.text.isEmpty {
                            StreamingView(draft: streaming)
                                .id("streaming")
                        }
                        if model.running {
                            HStack(spacing: 8) {
                                ProgressView()
                                Text("思考中…")
                            }
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .id("running")
                        }
                        if !model.dismissedRequestIds.isEmpty {
                            Button {
                                for id in model.dismissedRequestIds {
                                    model.reopen(requestId: id)
                                }
                            } label: {
                                Label("有待确认的请求", systemImage: "exclamationmark.bubble")
                            }
                            .font(.footnote)
                        }
                    }
                    .padding()
                }
                .onChange(of: model.transcript.items.last?.id) {
                    scrollToEnd(proxy)
                }
                .onChange(of: model.streaming?.text) {
                    scrollToEnd(proxy)
                }
            }
            composer
        }
        .navigationTitle(model.title ?? "对话")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: approvalShown) {
            if let approval = model.visibleApproval {
                ApprovalSheet(approval: approval) { decision in
                    Task { await model.answer(approval: approval, decision: decision) }
                }
                .presentationDetents([.medium])
            }
        }
        .sheet(isPresented: questionShown) {
            if let question = model.visibleQuestion {
                QuestionSheet(question: question) { answers in
                    Task { await model.answer(question: question, answers: answers) }
                }
            }
        }
    }

    private var approvalShown: Binding<Bool> {
        Binding(
            get: { model.visibleApproval != nil },
            set: { shown in if !shown, let id = model.visibleApproval?.eventId { model.dismiss(requestId: id) } }
        )
    }

    private var questionShown: Binding<Bool> {
        Binding(
            get: { model.visibleQuestion != nil },
            set: { shown in if !shown, let id = model.visibleQuestion?.eventId { model.dismiss(requestId: id) } }
        )
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("发送消息", text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...5)
                .padding(10)
                .background(.fill.tertiary, in: RoundedRectangle(cornerRadius: 18))
                .focused($composerFocused)
                .onSubmit { send() }
            if model.running {
                Button {
                    Task { await model.stop() }
                } label: {
                    Image(systemName: "stop.circle.fill")
                        .font(.system(size: 30))
                }
                .disabled(model.approvals.isEmpty == false || model.questions.isEmpty == false)
            } else {
                Button {
                    send()
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 30))
                }
                .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private func send() {
        let text = draft
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        draft = ""
        Task { await model.send(text) }
    }

    private func scrollToEnd(_ proxy: ScrollViewProxy) {
        withAnimation {
            proxy.scrollTo(model.streaming?.text.isEmpty == false ? "streaming" : (model.transcript.items.last?.id ?? "running"), anchor: .bottom)
        }
    }
}

/// One settled row of the transcript.
struct ChatItemView: View {
    let item: ChatItem

    var body: some View {
        switch item.kind {
        case let .userMessage(text):
            HStack {
                Spacer(minLength: 48)
                Text(text)
                    .padding(12)
                    .background(Color.accentColor.opacity(0.18), in: RoundedRectangle(cornerRadius: 16))
            }
        case let .assistantMessage(text, reasoning, interrupted):
            VStack(alignment: .leading, spacing: 6) {
                if let reasoning, !reasoning.isEmpty {
                    DisclosureGroup("思考过程") {
                        Text(reasoning)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    .font(.footnote)
                }
                Markdown(text)
                if interrupted {
                    Label("已被打断", systemImage: "exclamationmark.triangle")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.fill.tertiary, in: RoundedRectangle(cornerRadius: 16))
        case let .toolCall(name, _):
            Label(name, systemImage: "wrench.and.screwdriver")
                .font(.footnote)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.fill.quaternary, in: RoundedRectangle(cornerRadius: 10))
        case let .toolResult(_, ok, summary):
            VStack(alignment: .leading, spacing: 2) {
                Label(ok ? "完成" : "失败", systemImage: ok ? "checkmark.circle" : "xmark.circle")
                if !summary.isEmpty {
                    Text(summary)
                        .font(.system(.caption, design: .monospaced))
                        .lineLimit(6)
                        .foregroundStyle(.secondary)
                }
            }
            .font(.footnote)
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.fill.quaternary, in: RoundedRectangle(cornerRadius: 10))
        case let .turnEnd(reason, detail):
            HStack(spacing: 6) {
                Image(systemName: icon(for: reason))
                    .foregroundStyle(color(for: reason))
                Text(label(for: reason))
                if let detail {
                    Text(detail).lineLimit(1)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private func icon(for reason: String) -> String {
        switch reason {
        case "completed": "checkmark.circle"
        case "aborted": "stop.circle"
        case "error": "exclamationmark.triangle"
        case "max-tokens": "text.word.spacing"
        case "blocked": "hand.raised"
        default: "circle"
        }
    }

    private func color(for reason: String) -> Color {
        switch reason {
        case "completed": .green
        case "aborted": .secondary
        case "error": .orange
        default: .secondary
        }
    }

    private func label(for reason: String) -> String {
        switch reason {
        case "completed": "完成"
        case "aborted": "已停止"
        case "error": "出错了"
        case "max-tokens": "达到长度上限"
        case "blocked": "被拦截"
        default: reason
        }
    }
}

/// The live model output while it streams.
struct StreamingView: View {
    let draft: StreamingDraft

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !draft.reasoning.isEmpty {
                DisclosureGroup("思考过程") {
                    Text(draft.reasoning)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .font(.footnote)
            }
            Markdown(draft.text)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.fill.tertiary, in: RoundedRectangle(cornerRadius: 16))
    }
}

/// An agent asking to run a tool.
struct ApprovalSheet: View {
    let approval: ApprovalRequest
    let onDecision: (ApprovalDecision) -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "questionmark.shield")
                .font(.system(size: 36))
                .foregroundStyle(.orange)
            Text("允许执行工具？")
                .font(.title3.bold())
            Text(approval.describe(locale: Locale.current.language.languageCode?.identifier ?? "en"))
                .multilineTextAlignment(.center)
            Text("工具：\(approval.toolName)")
                .font(.footnote)
                .foregroundStyle(.secondary)
            HStack(spacing: 12) {
                Button("拒绝") { onDecision(.reject) }
                    .buttonStyle(.bordered)
                Button("允许一次") { onDecision(.allowOnce) }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
    }
}

/// The agent asking the person a question.
struct QuestionSheet: View {
    let question: UserQuestionRequest
    let onAnswer: ([QuestionAnswer]) -> Void

    @State private var selections: [String: Set<String>] = [:]
    @State private var customs: [String: String] = [:]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                ForEach(question.questions, id: \.id) { item in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(item.question)
                            .font(.headline)
                        if let detail = item.detail {
                            Markdown(detail)
                                .font(.subheadline)
                        }
                        if item.options.isEmpty {
                            TextField("输入回答", text: binding(custom: item.id))
                                .textFieldStyle(.roundedBorder)
                        } else {
                            ForEach(item.options, id: \.label) { option in
                                Button {
                                    toggle(option.label, in: item)
                                } label: {
                                    HStack {
                                        Text(option.label)
                                        Spacer()
                                        if isSelected(option.label, in: item) {
                                            Image(systemName: "checkmark")
                                        }
                                    }
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    .padding()
                    .background(.fill.tertiary, in: RoundedRectangle(cornerRadius: 12))
                }
                Button("回答") {
                    var answers: [QuestionAnswer] = []
                    for item in question.questions {
                        if item.options.isEmpty {
                            answers.append(QuestionAnswer(id: item.id, custom: customs[item.id] ?? ""))
                        } else {
                            answers.append(QuestionAnswer(id: item.id, selected: Array(selections[item.id] ?? [])))
                        }
                    }
                    onAnswer(answers)
                }
                .buttonStyle(.borderedProminent)
                .frame(maxWidth: .infinity)
            }
            .padding()
        }
    }

    private func binding(custom id: String) -> Binding<String> {
        Binding(
            get: { customs[id] ?? "" },
            set: { customs[id] = $0 }
        )
    }

    private func isSelected(_ label: String, in item: UserQuestion) -> Bool {
        selections[item.id]?.contains(label) ?? false
    }

    private func toggle(_ label: String, in item: UserQuestion) {
        var current = selections[item.id] ?? []
        if current.contains(label) {
            current.remove(label)
        } else {
            if !item.multiSelect {
                current = []
            }
            current.insert(label)
        }
        selections[item.id] = current
    }
}
