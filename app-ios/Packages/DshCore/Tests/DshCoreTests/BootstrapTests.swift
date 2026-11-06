import Foundation
import Testing
@testable import DshCore

// RemoteBootstrap: the DSHAPP output protocol and script generation, ported
// from remote_bootstrap.dart's unit-tested parsing.

@Test("probe output: reuse only with a live pid, same command and a token line")
func probeParsing() {
    let probe = RemoteProbe.parse(
        """
        Welcome to Ubuntu 24.04 (login banner noise)
        DSHAPP home /home/dev
        DSHAPP alive 4242
        DSHAPP samecmd
        DSHAPP url dsh web: http://127.0.0.1:39231/?token=tok123
        """
    )
    #expect(probe.home == "/home/dev")
    #expect(probe.pid == 4242)
    #expect(probe.sameCommand)
    #expect(probe.launchLine == "dsh web: http://127.0.0.1:39231/?token=tok123")
    #expect(probe.reusable)
    // A later url line wins (the probe prints only one; the parser keeps the last).
    let overwritten = RemoteProbe.parse(
        "DSHAPP alive 1\nDSHAPP url bad\nDSHAPP url dsh web: http://127.0.0.1:1/?token=x\nDSHAPP samecmd"
    )
    #expect(overwritten.launchLine == "dsh web: http://127.0.0.1:1/?token=x")

    // No pid: nothing to reuse.
    #expect(!RemoteProbe.parse("DSHAPP home /h\nDSHAPP url http://127.0.0.1:1/?token=x").reusable)
    // Different launch command: restart rather than reuse.
    var changed = probe
    changed = RemoteProbe(home: probe.home, pid: probe.pid, sameCommand: false, launchLine: probe.launchLine)
    #expect(!changed.reusable)
}

@Test("start output: endpoint from the url line; failures map to typed errors")
func startParsing() {
    let ok = RemoteExecResult(
        stdout: """
            DSHAPP home /home/dev
            DSHAPP dsh /usr/local/bin/dsh
            DSHAPP started 5151
            DSHAPP url dsh web: http://127.0.0.1:41012/?token=zzz
            """,
        stderr: "",
        exitCode: 0
    )
    let endpoint = try! RemoteDshEndpoint.parseStart(ok, customCommand: false, command: defaultDshLaunchCommand)
    #expect(endpoint.port == 41012)
    #expect(endpoint.token == "zzz")
    #expect(endpoint.pid == 5151)
    #expect(endpoint.home == "/home/dev")
    #expect(endpoint.dshPath == "/usr/local/bin/dsh")
    #expect(endpoint.authority == "127.0.0.1:41012")

    let noDsh = RemoteExecResult(stdout: "DSHAPP nodsh\n", stderr: "", exitCode: 127)
    #expect(throws: HostLinkFailure.self) {
        try RemoteDshEndpoint.parseStart(noDsh, customCommand: false, command: defaultDshLaunchCommand)
    }

    let exited = RemoteExecResult(
        stdout: "DSHAPP home /h\nDSHAPP started 9\nDSHAPP exited\nDSHAPP log /bin/sh: dsh: command not found\n",
        stderr: "",
        exitCode: 1
    )
    do {
        _ = try RemoteDshEndpoint.parseStart(exited, customCommand: false, command: defaultDshLaunchCommand)
        Issue.record("expected dshNotFound")
    } catch let failure as HostLinkFailure {
        guard case .dshNotFound = failure else {
            Issue.record("expected dshNotFound, got \(failure)")
            return
        }
    } catch {
        Issue.record("unexpected error type: \(error)")
    }

    let timedOut = RemoteExecResult(stdout: "DSHAPP timeout\n", stderr: "", exitCode: 1)
    #expect(throws: HostLinkFailure.self) {
        _ = try RemoteDshEndpoint.parseStart(timedOut, customCommand: false, command: defaultDshLaunchCommand)
    }
}

@Test("start script: launches on loopback with port 0, truncates the log, polls for the token")
func startScriptShape() {
    let bootstrap = RemoteDshBootstrap(workingDirectory: "~/projects/x", startTimeout: 60)
    let script = bootstrap.startScript()
    #expect(script.contains("umask 077"))
    #expect(script.contains("D=\"$HOME/.dsh-app-remote\""))
    // PID reuse guard writes the process start time.
    #expect(script.contains("_st \"$P\" > \"$D/web.st\""))
    // The engine listens on the remote loopback with an OS-picked port.
    #expect(script.contains("dsh web --host 127.0.0.1 --port 0 --no-open"))
    #expect(script.contains(">>\"$D/web.log\" 2>&1 &"))
    // Fresh log so the last token line is the running process's.
    #expect(script.contains(": > \"$D/web.log\""))
    // Polls a bounded time for the launch URL.
    #expect(script.contains("while [ $i -lt 60 ]"))
    // Working directory with ~ expanded by the remote shell.
    #expect(script.contains("cd \"$HOME\"/'projects/x'"))
    // dsh is searched where npm-family installers put it.
    #expect(script.contains("command -v dsh"))
    #expect(script.contains(".volta/bin"))

    let probe = bootstrap.probeScript()
    #expect(probe.contains("DSHAPP home %s"))
    #expect(probe.contains("samecmd"))
    #expect(probe.contains("tail -n 1"))
    // Custom command: no dsh search, custom command quoted.
    let custom = RemoteDshBootstrap(launchCommand: "/opt/dsh/bin/dsh web --verbose")
    #expect(!custom.startScript().contains("command -v dsh >/dev/null"))
    #expect(custom.startScript().contains("/opt/dsh/bin/dsh web --verbose --host 127.0.0.1 --port 0 --no-open"))
}

@Test("host key fingerprint: OpenSSH SHA256 form over the wire bytes")
func fingerprintForm() {
    let blob = Data([0x00, 0x01, 0x02, 0xff])
    let fingerprint = Crypto.openSshFingerprint(blob)
    #expect(fingerprint.hasPrefix("SHA256:"))
    #expect(!fingerprint.contains("="))
    #expect(fingerprint == "SHA256:" + Crypto.base64Url(Crypto.sha256(blob)))
}

@Test("redaction: token values never survive into a shown log tail")
func redaction() {
    let tail = "dsh web: http://127.0.0.1:39231/?token=SECRETVALUE and ?token=OTHER"
    let redacted = RemoteDshBootstrap.redactTokens(tail)
    #expect(!redacted.contains("SECRETVALUE"))
    #expect(!redacted.contains("OTHER"))
    #expect(redacted.contains("token=…"))
}

@Test("absolutePath: ~ resolves against the remote home")
func absolutePath() {
    #expect(RemoteDshBootstrap.absolutePath("~", home: "/home/dev") == "/home/dev")
    #expect(RemoteDshBootstrap.absolutePath("~/a/b", home: "/home/dev") == "/home/dev/a/b")
    #expect(RemoteDshBootstrap.absolutePath("~/a/b", home: "/home/dev/") == "/home/dev/a/b")
    #expect(RemoteDshBootstrap.absolutePath("/etc", home: "/home/dev") == "/etc")
    #expect(RemoteDshBootstrap.absolutePath("  ", home: "/home/dev") == nil)
    #expect(RemoteDshBootstrap.absolutePath("~/x", home: nil) == "~/x")
}

@Test("shQuote: single quotes escaped")
func shQuoting() {
    #expect(shQuote("plain") == "'plain'")
    #expect(shQuote("it's") == "'it'\\''s'")
}
