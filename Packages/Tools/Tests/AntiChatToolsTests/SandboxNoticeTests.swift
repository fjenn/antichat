// M6.T18 step 3: a stopped or refused run maps to exactly one notice key (R-018 AC5); a normal Python error maps to
// none (the model handles it). The suite-level check on the real service is SecuritySuiteTests.
//   make test-unit FILTER=SandboxNoticeTests
import AntiChatEngineProtocol
import AntiChatTools
import Testing

@Suite struct SandboxNoticeTests {
    func err(_ type: String, _ message: String, errno: Int? = nil, tb: String = "") -> RunResult {
        RunResult(error: RunError(type: type, message: message, traceback: tb, errno: errno))
    }

    @Test func killsMapToTimeoutOrKilledWithAReason() {
        #expect(SandboxNotice.for(RunResult(killedReason: .timeout)) == SandboxNotice(key: "sandbox.timeout"))
        for k in [KilledReason.memory, .fileSize, .processes, .crash] {
            #expect(SandboxNotice.for(RunResult(killedReason: k)) == SandboxNotice(key: "sandbox.killed", reasonKey: "sandbox.reason.\(k.rawValue)"))
        }
        #expect(SandboxNotice.for(err("MemoryError", "")) == SandboxNotice(key: "sandbox.killed", reasonKey: "sandbox.reason.memory"))
        #expect(SandboxNotice.for(err("OSError", "[Errno 27] File too large", errno: 27))?.reasonKey == "sandbox.reason.fileSize")
    }

    @Test func refusalsMapToNetworkOffOrDenied() {
        let net = err("PermissionError", "[Errno 1] Operation not permitted", errno: 1,
                      tb: "  File \"socket.py\", line 852, in create_connection\n    sock.connect(sa)\n")
        #expect(SandboxNotice.for(net) == SandboxNotice(key: "sandbox.networkOff"))
        #expect(SandboxNotice.for(net)?.linksToSettings == true)
        #expect(SandboxNotice.for(err("PermissionError", "[Errno 1] Network is off for code (socket.connect)", errno: 1))?.key == "sandbox.networkOff")
        let read = err("PermissionError", "[Errno 1] Operation not permitted: '/Users/u/Documents/canary.txt'", errno: 1,
                       tb: "  File \"<cell x>\", line 1, in <module>\n    open(p)\n")
        #expect(SandboxNotice.for(read) == SandboxNotice(key: "sandbox.denied"))
        #expect(SandboxNotice.for(err("PermissionError", "Starting another process is not allowed (subprocess.Popen)", errno: 1))?.key == "sandbox.denied")
    }

    @Test func ordinaryErrorsAndCleanRunsGetNoNotice() {
        #expect(SandboxNotice.for(RunResult(stdout: "42\n")) == nil)
        #expect(SandboxNotice.for(err("KeyError", "'amount'")) == nil)
        #expect(SandboxNotice.for(err("FileNotFoundError", "in/x.csv", errno: 2)) == nil)
        #expect(SandboxNotice.allKeys.count == 8)
    }
}
