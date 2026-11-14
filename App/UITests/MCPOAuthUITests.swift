// M7.T07 AT-257 (R-257 AC1; vq-10): the real sign-in sheet. Connections → Add an MCP server → Sign in with the app →
// Continue → ASWebAuthenticationSession ("AntiChat wants to use … to sign in") → the reference AS
// (`node tools/mcp-ref/mcp.ts`, auto-approves) redirects to antichat://oauth/callback → consent sheet → Allow and
// connect → "Connected". The flow after the browser also runs headless in MCPOAuthFlowTests (all three client-identity
// modes); the browser leg moves to vq-10 under computer use if the system alert stays unreachable (recorded, minor).
//
// Q-015 r4: nothing started the reference AS ("started by the runner" — no runner did), so the add sheet's sign-in
// hit a closed port and the consent sheet could never appear. The test starts its own pair on OS-picked ports. It
// runs with `--no-cimd`: the app's CIMD client_id is the published site URL, which the local AS would have to fetch
// from the internet; DCR keeps the leg offline (CIMD is covered by MCPOAuthFlowTests). The system alert is not an
// interruption the monitor sees while the test only waits, so the test presses its Continue itself.
import Darwin
import XCTest

final class MCPOAuthUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    private static let repo: URL = {
        var u = URL(fileURLWithPath: #filePath)
        for _ in 0..<3 { u.deleteLastPathComponent() }
        return u
    }()

    /// Starts the reference AS + protected MCP server; returns the MCP endpoint once its protected-resource metadata
    /// answers. Stopped at teardown.
    private func startReferenceServer() throws -> URL {
        // Q-015 r4: the UI test runner is sandboxed (network client only): it can neither bind a port nor give node a
        // listening socket. tools/ci/with-mcp-ref.sh starts the pair outside it and passes the endpoint
        // (`TEST_RUNNER_ANTICHAT_MCP_REF_URL`, `make test-ui` does this). Starting it here stays for an unsandboxed runner.
        if let s = ProcessInfo.processInfo.environment["ANTICHAT_MCP_REF_URL"], let mcp = URL(string: s) {
            var prm = URLComponents(url: mcp, resolvingAgainstBaseURL: false)!
            prm.path = "/.well-known/oauth-protected-resource/mcp"
            let deadline = Date().addingTimeInterval(30)
            while !Self.answers(prm.url!), Date() < deadline { usleep(100_000) }
            XCTAssertTrue(Self.answers(prm.url!), "the reference server at \(s) does not answer")
            return mcp
        }
        guard let node = ["/opt/homebrew/bin/node", "/usr/local/bin/node"].first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw XCTSkip("not run: node missing (Q-007)")
        }
        for _ in 1...3 {
            guard let ports = try? Self.freePorts(2) else {
                XCTFail("this runner cannot bind a port (sandboxed): run through tools/ci/with-mcp-ref.sh")
                throw CocoaError(.featureUnsupported)
            }
            let p = Process()
            p.executableURL = URL(fileURLWithPath: node)
            p.arguments = [Self.repo.appendingPathComponent("tools/mcp-ref/mcp.ts").path, "--port", "\(ports[0])",
                           "--as-port", "\(ports[1])", "--no-cimd"]
            p.environment = ["PATH": "/usr/bin:/bin", "HOME": NSTemporaryDirectory(), "NODE_NO_WARNINGS": "1"]
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            try p.run()
            addTeardownBlock {
                p.terminate()
                let end = Date().addingTimeInterval(10)
                while p.isRunning, Date() < end { usleep(10_000) }
                if p.isRunning { kill(p.processIdentifier, SIGKILL) }
            }
            let prm = URL(string: "http://127.0.0.1:\(ports[0])/.well-known/oauth-protected-resource/mcp")!
            let asMeta = URL(string: "http://127.0.0.1:\(ports[1])/.well-known/oauth-authorization-server")!
            let deadline = Date().addingTimeInterval(30)
            var up = false
            while !up, p.isRunning, Date() < deadline {
                up = Self.answers(prm) && Self.answers(asMeta)
                if !up { usleep(100_000) }
            }
            if up, p.isRunning { return URL(string: "http://127.0.0.1:\(ports[0])/mcp")! }
            p.terminate()  // lost a port race (another worktree's server): fresh ports
        }
        XCTFail("reference AS/MCP did not start on 3 port picks")
        throw CocoaError(.featureUnsupported)
    }

    private static func answers(_ url: URL) -> Bool {
        final class Result: @unchecked Sendable { var ok = false }  // written before the signal, read after it
        let done = DispatchSemaphore(value: 0)
        let result = Result()
        var r = URLRequest(url: url)
        r.timeoutInterval = 2
        URLSession.shared.dataTask(with: r) { _, resp, _ in
            result.ok = (resp as? HTTPURLResponse)?.statusCode == 200
            done.signal()
        }.resume()
        return done.wait(timeout: .now() + 3) == .success && result.ok
    }

    /// `n` distinct TCP ports the OS reports free on 127.0.0.1 (all bound at once, then released).
    private static func freePorts(_ n: Int) throws -> [Int] {
        var fds: [Int32] = []
        defer { fds.forEach { close($0) } }
        var ports: [Int] = []
        for _ in 0..<n {
            let fd = socket(AF_INET, SOCK_STREAM, 0)
            guard fd >= 0 else { throw POSIXError(.EMFILE) }
            fds.append(fd)
            var addr = sockaddr_in()
            addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_addr.s_addr = inet_addr("127.0.0.1")
            var len = socklen_t(MemoryLayout<sockaddr_in>.size)
            let ok = withUnsafeMutablePointer(to: &addr) { p in
                p.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, len) == 0 && getsockname(fd, $0, &len) == 0 }
            }
            guard ok else { throw POSIXError(.EADDRINUSE) }
            ports.append(Int(UInt16(bigEndian: addr.sin_port)))
        }
        return ports
    }

    @MainActor func testSignInFlow() throws {
        let mcp = try startReferenceServer()
        let app = XCUIApplication.foreground()
        let container = FileManager.default.temporaryDirectory.appendingPathComponent("oauth-ui-\(UUID().uuidString)").path
        app.launchArguments += ["-ANTICHAT_DEV_CONTAINER", container, "-SkipOnboarding", "YES", "-UseScriptedEngine", "NO"]
        addUIInterruptionMonitor(withDescription: "web auth alert") { alert in
            let go = alert.buttons["Continue"]
            if go.exists { go.click(); return true }
            return false
        }
        app.launch()
        app.typeKey(",", modifierFlags: .command)
        app.descendants(matching: .any).matching(identifier: "settings.nav.tools").firstMatch.click()
        // Connections sit below the fold of Tools & Connections; bring them on screen (Q-015 catch-up).
        app.scrollViews.matching(identifier: "settings.detail.tools").firstMatch.scroll(byDeltaX: 0, deltaY: -700)
        app.buttons["connections.add"].click()
        let url = app.textFields["connections.url"]
        url.click(); url.typeText(mcp.absoluteString)
        app.descendants(matching: .any).matching(identifier: "connections.authMode").firstMatch.radioButtons.element(boundBy: 2).click()  // Sign in with the app
        app.buttons["connections.check"].click()
        // The system's "wants to use … to sign in" alert: press Continue wherever it is shown (a sheet on the add
        // sheet's window, or the authentication agent's own window). The user's one action in the browser leg.
        let consent = app.descendants(matching: .any).matching(identifier: "mcpConsent").firstMatch
        // Q-015 r4: on macOS 26 the authentication agent is a bare executable with no bundle id (querying
        // XCUIApplication(bundleIdentifier:) for it raised "could not be found", and macOS XCUITest has no
        // process-id initialiser), so the alert is pressed through the app (a sheet on its window) or the
        // interruption monitor.
        func hosts() -> [XCUIApplication] { [app] }
        let deadline = Date().addingTimeInterval(60)
        var pressed = false
        while !consent.exists, Date() < deadline {
            if !pressed {
                for h in hosts() {
                    let go = h.buttons.matching(NSPredicate(format: "label == 'Continue' AND identifier != 'connections.check'")).firstMatch  // r5: not the add sheet's own Continue
                    if go.exists { go.click(); pressed = true; break }
                }
            }
            if !pressed { app.activate() }  // lets the interruption monitor fire on the alert
            _ = consent.waitForExistence(timeout: 1)
        }
        XCTAssertTrue(consent.waitForExistence(timeout: 5), "consent sheet after sign-in (alert Continue pressed: \(pressed))")
        app.buttons["mcpConsent.allow"].click()
        // Q-015 r7: the row's state line is a static text, whose words are its AX value on macOS (label empty).
        let connected = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Connected' OR value BEGINSWITH 'Connected'")).firstMatch
        XCTAssertTrue(connected.waitForExistence(timeout: 15))
    }
}
