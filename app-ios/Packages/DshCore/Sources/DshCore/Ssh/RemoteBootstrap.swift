import Foundation

/// dsh-app's state directory on the remote (pid, log, launch command).
public let remoteStateDir = "$HOME/.dsh-app-remote"

/// Marker that prefixes every structured line our scripts print, so login
/// banners and `~/.profile` chatter can't be mistaken for results.
let dshappTag = "DSHAPP"

public let defaultDshLaunchCommand = "dsh web"

/// POSIX sh quoting (`shQuote` of remote_shell.dart).
func shQuote(_ value: String) -> String {
    "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
}

/// A `dsh web` on the remote that the client can reach through a tunnel
/// (remote_bootstrap.dart's `RemoteDshEndpoint`).
public struct RemoteDshEndpoint: Equatable {
    /// Port on the remote's loopback (`--host 127.0.0.1`).
    public let port: Int
    /// Launch token from the `dsh web: http://…/?token=` line; good for this
    /// process's lifetime only.
    public let token: String
    public let pid: Int?
    /// An instance started earlier was still running.
    public let reused: Bool
    /// Remote `$HOME`, to expand `~` in the configured working directory.
    public let home: String?
    /// Resolved `dsh` binary (default command only).
    public let dshPath: String?

    /// `127.0.0.1:<port>`: the Host header DSH's fence accepts.
    public var authority: String { "127.0.0.1:\(port)" }
}

/// What the probe found on the remote (`RemoteProbe`).
public struct RemoteProbe: Equatable {
    public let home: String?
    /// Pid of the instance started earlier, if it's still alive.
    public let pid: Int?
    /// That instance was started with the command configured now.
    public let sameCommand: Bool
    /// Latest `dsh web: http://…?token=` line from its log.
    public let launchLine: String?

    public var reusable: Bool {
        guard let pid, let launchLine else { return false }
        return sameCommand && DshLaunchUrl.tryParse(launchLine) != nil && pid > 0
    }
}

/// One remote command run: collected stdout/stderr and whether it failed.
public struct RemoteExecResult {
    public let stdout: String
    public let stderr: String
    /// nil when the exit status is unknown (channel died first).
    public let exitCode: Int?
}

/// Finds or starts the managed `dsh web` on the remote
/// (remote_bootstrap.dart, ported 1:1 — the scripts are POSIX sh and are
/// tested against a real `/bin/sh`).
///
/// Files under `~/.dsh-app-remote/` (mode 700):
/// * `web.pid` — pid of the `dsh web` process we started;
/// * `web.log` — its stdout/stderr, truncated on every start, so the last
///   `token=` line always belongs to the running process;
/// * `web.cmd` — the launch command it was started with (a different command
///   means restart).
///
/// The server starts as `<command> --host 127.0.0.1 --port 0 --no-open` under
/// `nohup`, so it outlives the connection and is reused next time.
public struct RemoteDshBootstrap {
    public var launchCommand: String
    public var workingDirectory: String?
    /// Extra variables exported before anything runs.
    public var environment: [String: String]
    public var startTimeout: TimeInterval

    public init(
        launchCommand: String = defaultDshLaunchCommand,
        workingDirectory: String? = nil,
        environment: [String: String] = [:],
        startTimeout: TimeInterval = 60
    ) {
        let trimmed = launchCommand.trimmingCharacters(in: .whitespacesAndNewlines)
        self.launchCommand = trimmed.isEmpty ? defaultDshLaunchCommand : trimmed
        self.workingDirectory = workingDirectory
        self.environment = environment
        self.startTimeout = startTimeout
    }

    var usesDefaultCommand: Bool { launchCommand == defaultDshLaunchCommand }

    /// Reuses the running instance when it's healthy, otherwise starts one.
    public func ensureRunning(
        forceRestart: Bool = false,
        run: (String, TimeInterval) async throws -> RemoteExecResult
    ) async throws -> RemoteDshEndpoint {
        if !forceRestart {
            let probe = try await probe(run: run)
            if probe.reusable, let url = DshLaunchUrl.tryParse(probe.launchLine!) {
                return RemoteDshEndpoint(
                    port: url.baseUrl.port ?? 80,
                    token: url.token,
                    pid: probe.pid,
                    reused: true,
                    home: probe.home,
                    dshPath: nil
                )
            }
        }
        return try await start(run: run)
    }

    public func probe(run: (String, TimeInterval) async throws -> RemoteExecResult) async throws -> RemoteProbe {
        let result = try await run(probeScript(), 20)
        if Self.missingShell(result) { throw HostLinkFailure.noShell(result.stderr) }
        return RemoteProbe.parse(result.stdout)
    }

    public func start(run: (String, TimeInterval) async throws -> RemoteExecResult) async throws -> RemoteDshEndpoint {
        let result = try await run(startScript(), startTimeout + 20)
        if Self.missingShell(result) { throw HostLinkFailure.noShell(result.stderr) }
        return try RemoteDshEndpoint.parseStart(result, customCommand: !usesDefaultCommand, command: launchCommand)
    }

    /// Stops the managed instance (if any). Not used on disconnect: the
    /// server is meant to outlive the connection.
    public func stop(run: (String, TimeInterval) async throws -> RemoteExecResult) async throws {
        _ = try await run(stopScript(), 15)
    }

    // MARK: Scripts (POSIX sh)

    func prelude() -> String {
        var lines: [String] = ["umask 077"]
        for (key, value) in environment.sorted(by: { $0.key < $1.key }) {
            guard key.range(of: #"^[A-Za-z_][A-Za-z0-9_]*$"#, options: .regularExpression) != nil else { continue }
            lines.append("\(key)=\(shQuote(value)); export \(key)")
        }
        lines.append("D=\"\(remoteStateDir)\"")
        // A PID can be recycled after reboot; bind ownership to its start time.
        lines.append(
            #"""
            _st() {
              if [ -r "/proc/$1/stat" ]; then
                S=$(cat "/proc/$1/stat" 2>/dev/null) || return 1
                S=${S##*) }
                set -- $S
                [ "$#" -ge 20 ] || return 1
                shift 19
                printf '%s\n' "$1"
              else
                ps -p "$1" -o lstart= 2>/dev/null
              fi
            }
            ours() {
              kill -0 "$1" 2>/dev/null || return 1
              if [ -f "$D/web.st" ]; then
                A=$(_st "$1") || return 1
                B=$(cat "$D/web.st" 2>/dev/null) || return 1
                [ -n "$A" ] && [ -n "$B" ] && [ "$A" = "$B" ]
                return $?
              fi
              A=$(ps -p "$1" -o args= 2>/dev/null) || return 1
              case "$A" in
                *'--host 127.0.0.1 --port 0 --no-open'*) return 0;;
                *) return 1;;
              esac
            }
            """#
        )
        return lines.joined(separator: "\n") + "\n"
    }

    public func probeScript() -> String {
        prelude()
            + "printf '\(dshappTag) home %s\\n' \"$HOME\"\n"
            + "if [ -f \"$D/web.pid\" ]; then\n"
            + "  P=$(cat \"$D/web.pid\" 2>/dev/null)\n"
            + "  if [ -n \"$P\" ] && ours \"$P\"; then\n"
            + "    printf '\(dshappTag) alive %s\\n' \"$P\"\n"
            + "    if [ \"$(cat \"$D/web.cmd\" 2>/dev/null)\" = \(shQuote(launchCommand)) ]; then printf '\(dshappTag) samecmd\\n'; fi\n"
            + "    L=$(grep -E 'https?://[^ ]*[?&]token=' \"$D/web.log\" 2>/dev/null | tail -n 1)\n"
            + "    printf '\(dshappTag) url %s\\n' \"$L\"\n"
            + "  else\n"
            + "    rm -f \"$D/web.pid\"\n"
            + "  fi\n"
            + "fi\n"
            + "true\n"
    }

    func stopOld() -> String {
        "if [ -f \"$D/web.pid\" ]; then\n"
            + "  P=$(cat \"$D/web.pid\" 2>/dev/null)\n"
            + "  if [ -n \"$P\" ] && ours \"$P\"; then\n"
            + "    if command -v pkill >/dev/null 2>&1; then pkill -TERM -P \"$P\" 2>/dev/null; fi\n"
            + "    kill \"$P\" 2>/dev/null\n"
            + "    i=0; while kill -0 \"$P\" 2>/dev/null && [ $i -lt 10 ]; do sleep 1; i=$((i+1)); done\n"
            + "    ours \"$P\" && kill -9 \"$P\" 2>/dev/null\n"
            + "  fi\n"
            + "  rm -f \"$D/web.pid\"\n"
            + "fi\n"
    }

    public func stopScript() -> String {
        prelude() + stopOld() + "true\n"
    }

    /// Looks for `dsh` where npm, nvm, volta, bun, pnpm and Homebrew put it,
    /// since a non-interactive SSH shell often lacks the PATH from `~/.bashrc`.
    static let dshSearch = #"""
        if ! command -v dsh >/dev/null 2>&1; then
          F=""
          for c in "$HOME/.local/bin" "$HOME/.npm-global/bin" "$HOME/.npm/bin" "$HOME/.volta/bin" "$HOME/.bun/bin" \
                   "$HOME/.local/share/pnpm" "$HOME/Library/pnpm" /usr/local/bin /opt/homebrew/bin \
                   "$HOME"/.nvm/versions/node/*/bin "$HOME"/.local/share/fnm/node-versions/*/installation/bin; do
            if [ -x "$c/dsh" ]; then F="$c"; fi
          done
          if [ -n "$F" ]; then PATH="$F:$PATH"; export PATH; fi
        fi
        if ! command -v dsh >/dev/null 2>&1; then printf 'DSHAPP nodsh\n'; exit 127; fi
        printf 'DSHAPP dsh %s\n' "$(command -v dsh)"
        """#

    public func startScript() -> String {
        let seconds = Int(startTimeout.rounded()).clamped(to: 5...600)
        var script = prelude()
        script += "printf '\(dshappTag) home %s\\n' \"$HOME\"\n"
        script += "mkdir -p \"$D\" || { printf '\(dshappTag) nodir\\n'; exit 70; }\n"
        script += "chmod 700 \"$D\" 2>/dev/null\n"
        script += stopOld()
        if usesDefaultCommand {
            script += Self.dshSearch + "\n"
        }
        if let cwd = workingDirectory?.trimmingCharacters(in: .whitespacesAndNewlines), !cwd.isEmpty {
            script += "cd \(Self.remotePathExpr(cwd)) 2>/dev/null || printf '\(dshappTag) nocwd\\n'\n"
        }
        script += "printf '%s' \(shQuote(launchCommand)) > \"$D/web.cmd\"\n"
        script += ": > \"$D/web.log\"\n"
        script += "NO_COLOR=1; export NO_COLOR\n"
        script += "N=\"\"; if command -v nohup >/dev/null 2>&1; then N=nohup; fi\n"
        script += "$N \(launchCommand) --host 127.0.0.1 --port 0 --no-open </dev/null >>\"$D/web.log\" 2>&1 &\n"
        script += "P=$!\n"
        script += "_st \"$P\" > \"$D/web.st\"\n"
        script += "printf '%s\\n' \"$P\" > \"$D/web.pid\"\n"
        script += "printf '\(dshappTag) started %s\\n' \"$P\"\n"
        script += "i=0\n"
        script += "while [ $i -lt \(seconds) ]; do\n"
        script += "  L=$(grep -E 'https?://[^ ]*[?&]token=' \"$D/web.log\" 2>/dev/null | tail -n 1)\n"
        script += "  if [ -n \"$L\" ]; then printf '\(dshappTag) url %s\\n' \"$L\"; exit 0; fi\n"
        script += "  if ! kill -0 \"$P\" 2>/dev/null; then\n"
        script += "    printf '\(dshappTag) exited\\n'; tail -n 20 \"$D/web.log\" 2>/dev/null | sed 's/^\(dshappTag) log /'; exit 1\n"
        script += "  fi\n"
        script += "  sleep 1; i=$((i+1))\n"
        script += "done\n"
        script += "printf '\(dshappTag) timeout\\n'; tail -n 20 \"$D/web.log\" 2>/dev/null | sed 's/^\(dshappTag) log /'; exit 1\n"
        return script
    }

    // MARK: Parsing (pure; unit-tested without a shell)

    static func tagged(_ stdout: String) -> [(String, String)] {
        var out: [(String, String)] = []
        for raw in stdout.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw).trimmingCharacters(in: .whitespacesAndNewlines)
            guard line.hasPrefix("\(dshappTag) ") else { continue }
            let rest = String(line.dropFirst(dshappTag.count + 1))
            if let space = rest.firstIndex(of: " ") {
                out.append((String(rest[..<space]), String(rest[rest.index(after: space)...])))
            } else {
                out.append((rest, ""))
            }
        }
        return out
    }

    static func missingShell(_ result: RemoteExecResult) -> Bool {
        !result.stdout.contains(dshappTag)
            && result.stderr.range(
                of: #"'sh' is not recognized|sh: (command )?not found|command not found: sh|No such file or directory.*\bsh\b"#,
                options: .regularExpression
            ) != nil
    }

    /// `token=…` values replaced, so a log tail can be shown or copied safely.
    public static func redactTokens(_ text: String) -> String {
        text.replacingOccurrences(
            of: #"(token=)[^\s&]+"#,
            with: "$1…",
            options: .regularExpression
        )
    }

    /// Shell expression for a remote path with `~` expanded by the remote shell.
    static func remotePathExpr(_ path: String) -> String {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed == "~" { return "\"$HOME\"" }
        if trimmed.hasPrefix("~/") { return "\"$HOME\"/\(shQuote(String(trimmed.dropFirst(2))))" }
        return shQuote(trimmed)
    }

    /// [path] with `~` resolved against the remote [home] (for `session/create`).
    public static func absolutePath(_ path: String?, home: String?) -> String? {
        guard let trimmed = path?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        guard let home, !home.isEmpty else { return trimmed }
        if trimmed == "~" { return home }
        if trimmed.hasPrefix("~/") {
            let base = home.hasSuffix("/") ? String(home.dropLast()) : home
            return "\(base)/\(trimmed.dropFirst(2))"
        }
        return trimmed
    }
}

// MARK: - Pure parsing extensions used by tests and the host link

extension RemoteProbe {
    public static func parse(_ stdout: String) -> RemoteProbe {
        var home: String?
        var pid: Int?
        var same = false
        var url: String?
        for (key, value) in RemoteDshBootstrap.tagged(stdout) {
            switch key {
            case "home":
                home = value.isEmpty ? nil : value
            case "alive":
                pid = Int(value.trimmingCharacters(in: .whitespaces))
            case "samecmd":
                same = true
            case "url":
                let trimmed = value.trimmingCharacters(in: .whitespaces)
                url = trimmed.isEmpty ? nil : trimmed
            default:
                break
            }
        }
        return RemoteProbe(home: home, pid: pid, sameCommand: same, launchLine: url)
    }
}

extension RemoteDshEndpoint {
    static func parseStart(
        _ result: RemoteExecResult,
        customCommand: Bool,
        command: String
    ) throws -> RemoteDshEndpoint {
        var home: String?
        var dsh: String?
        var pid: Int?
        var url: String?
        var noDsh = false
        var exited = false
        var timedOut = false
        var log: [String] = []
        for (key, value) in RemoteDshBootstrap.tagged(result.stdout) {
            switch key {
            case "home":
                home = value.isEmpty ? nil : value
            case "dsh":
                dsh = value.trimmingCharacters(in: .whitespaces)
            case "started":
                pid = Int(value.trimmingCharacters(in: .whitespaces))
            case "url":
                url = value.trimmingCharacters(in: .whitespaces)
            case "nodsh":
                noDsh = true
            case "exited":
                exited = true
            case "timeout":
                timedOut = true
            case "log":
                log.append(value)
            default:
                break
            }
        }
        if let url, let parsed = DshLaunchUrl.tryParse(url) {
            return RemoteDshEndpoint(
                port: parsed.baseUrl.port ?? 80,
                token: parsed.token,
                pid: pid,
                reused: false,
                home: home,
                dshPath: dsh
            )
        }
        let tail = RemoteDshBootstrap.redactTokens(log.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.joined(separator: "\n"))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        func looksNotFound(_ text: String) -> Bool {
            text.range(of: #"command not found|not found|No such file or directory|can.t open|ENOENT"#, options: [.regularExpression, .caseInsensitive]) != nil
        }
        if noDsh || (exited && looksNotFound(tail)) {
            var detail = customCommand ? "command not found: \(command)" : "服务器上没有安装 dsh"
            if !customCommand {
                detail += "\nnpm install -g @deepseek-ai/dsh"
            }
            if !tail.isEmpty { detail += "\n\(tail)" }
            throw HostLinkFailure.dshNotFound(detail)
        }
        if timedOut {
            throw HostLinkFailure.dshStartTimeout(tail.isEmpty ? nil : tail)
        }
        if exited {
            throw HostLinkFailure.dshStartFailed(tail.isEmpty ? "dsh web 启动后立即退出了" : tail)
        }
        var detail = "dsh web 启动失败"
        if let code = result.exitCode {
            detail += "\nexit \(code)"
        }
        let stderr = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        if !stderr.isEmpty {
            detail += "\n" + stderr.split(separator: "\n").prefix(6).joined(separator: "\n")
        }
        throw HostLinkFailure.dshStartFailed(detail)
    }
}

extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}

/// Host-link failures the UI shows as-is (host_link error kinds).
public enum HostLinkFailure: Error, Equatable {
    case noShell(String)
    case dshNotFound(String)
    case dshStartTimeout(String?)
    case dshStartFailed(String)
    case hostKeyMismatch
    case connectionFailed(String)
    case refused(String)
}
