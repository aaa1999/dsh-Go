import Darwin
import DshCore
import Foundation

// End-to-end smoke of the protocol stack against a real local `dsh web`:
// start the engine, log the launch URL in, open the mux, list/create a
// session, prompt and stream the turn to its end, print the transcript.
//
//   swift run DshProbe
//
// Exits 0 when every step passed; a model key is not required (the turn then
// ends with a credential error, which is still a complete round trip).

@main
struct DshProbe {
    static func main() async {
        // Line-buffered stdout so a piped run streams progress live.
        setvbuf(stdout, nil, _IOLBF, 4096)
        do {
            try await run()
            print("PROBE OK")
            exit(0)
        } catch {
            print("PROBE FAILED: \(error)")
            exit(1)
        }
    }

    static func run() async throws {
        // 1. Start the engine and wait for its launch URL line.
        print("· starting dsh web…")
        let engine = try EngineProcess()
        let launch = try await engine.waitForLaunchUrl()
        let port = launch.baseUrl.port ?? 80
        print("· dsh web on 127.0.0.1:\(port)")

        // 2. Token → cookie.
        let connection = DshConnection(baseUrl: URL(string: "http://127.0.0.1:\(port)")!)
        let cookie = try await connection.login(token: launch.token)
        let expectedName = DshCookie.expectedName(authority: connection.authority)
        guard cookie.name == expectedName else {
            throw DshError.protocolFailure("cookie \(cookie.name) != expected \(expectedName)")
        }
        print("· cookie \(cookie.name.prefix(24))… ok")

        // 3. Mux ready ($events).
        let client = DshClient(connection: connection)
        let generation = try await withTimeout(20) { try await client.mux.ready() }
        print("· mux ready (generation \(generation.number))")

        // 4. Sessions.
        let sessions = try await withTimeout(20) { try await client.listSessions() }
        print("· session/list: \(sessions.count) sessions")

        // 5. Create + prompt + watch the turn end.
        let created = try await withTimeout(20) { try await client.createSession() }
        print("· session/create: \(created.sessionId)")
        _ = try await withTimeout(20) {
            try await client.prompt(created.sessionId, "用一句话打个招呼", timeZone: TimeZone.current.identifier)
        }
        print("· prompt sent; streaming…")

        var transcript = Transcript()
        let watch = await client.watch(created.sessionId)
        // Overall deadline: without a model key the engine may never settle
        // the turn; every wire event still proves the stack end to end.
        var events = 0
        let deadline = Date().addingTimeInterval(90)
        var lastEvent = Date()
        for try await event in watch {
            events += 1
            lastEvent = Date()
            transcript.apply(event)
            switch event {
            case let .snapshot(snapshot):
                print("· snapshot cursor=\(snapshot.cursor) events=\(snapshot.events.count)")
            case let .logEvent(logEvent):
                print("  event seq=\(logEvent.seq) \(logEvent.type)")
            case let .assistantStream(frame):
                if case let .chunk(_, _, _, _, chunk) = frame, case let .textDelta(_, text) = chunk, !text.isEmpty {
                    print("  stream: \(text)", terminator: "")
                    fflush(stdout)
                }
            default:
                break
            }
            if case let .logEvent(logEvent) = event, logEvent.type == "turn/end" {
                break
            }
            if Date() > deadline {
                print()
                print("· deadline reached (no turn/end) after \(events) events")
                break
            }
            if Date().timeIntervalSince(lastEvent) > 20 {
                print()
                print("· stalled: no events for 20s (got \(events))")
                break
            }
        }
        print()
        guard events > 0 else {
            throw DshError.transport("watch delivered nothing")
        }
        if let last = transcript.items.last, case let .turnEnd(reason, detail) = last.kind {
            print("· turn ended: \(reason) \(detail ?? "")")
        }
        print("· transcript rows: \(transcript.items.count)")

        await client.close()
        engine.stop()
        try await Task.sleep(nanoseconds: 300_000_000)
    }
}

/// Runs `dsh web` as a child process and tails its stdout for the URL line.
final class EngineProcess {
    private let process = Process()
    private var stdoutPipe = Pipe()
    private var lineBuffer = ""
    private var continuation: CheckedContinuation<DshLaunchUrl, Never>?

    init() throws {
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["dsh", "web", "--host", "127.0.0.1", "--port", "0", "--no-open"]
        process.standardOutput = stdoutPipe
        process.standardError = Pipe()
        try process.run()
        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let self else {
                handle.readabilityHandler = nil
                return
            }
            self.lineBuffer += String(data: data, encoding: .utf8) ?? ""
            while let newline = self.lineBuffer.firstIndex(of: "\n") {
                let line = String(self.lineBuffer[..<newline])
                self.lineBuffer = String(self.lineBuffer[self.lineBuffer.index(after: newline)...])
                if let launch = DshLaunchUrl.tryParse(line) {
                    self.continuation?.resume(returning: launch)
                    self.continuation = nil
                    handle.readabilityHandler = nil
                    return
                }
            }
        }
    }

    func waitForLaunchUrl() async throws -> DshLaunchUrl {
        try await withTimeout(60) {
            await withCheckedContinuation { (cont: CheckedContinuation<DshLaunchUrl, Never>) in
                self.continuation = cont
            }
        }
    }

    func stop() {
        process.terminate()
    }
}

func withTimeout<T>(_ seconds: TimeInterval, _ body: @escaping () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await body() }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            throw DshError.transport("timed out after \(seconds)s")
        }
        guard let first = try await group.next() else {
            throw DshError.transport("no result")
        }
        group.cancelAll()
        return first
    }
}
