// M7.T07 step 3 (DEBUG only, compiled out of Release): unattended sign-in for tests and `-OAuthHeadless YES`.
// Performs the authorize GET itself on the gated `.mcp` session without following redirects and returns the
// `Location` the authorization server answered with (the reference AS in `tools/mcp-ref` auto-approves), so the
// OAuth tests need no browser and no system prompt. Everything after the callback is the production path.
#if DEBUG || ANTICHAT_PERF_HARNESS
import AntiChatNetwork
import Foundation

public final class HeadlessAuthPresenter: MCPAuthPresenter, @unchecked Sendable {
    /// Every callback URL this presenter returned (tests replay one for the code-replay case).
    public private(set) var callbacks: [URL] = []
    /// Tests: return this callback instead of performing the GET (code replay).
    public var replay: URL?
    private let lock = NSLock()

    public init() {}

    final class NoRedirect: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest) async -> URLRequest? { nil }
    }

    public func present(_ url: URL, callbackScheme: String) async throws -> URL {
        if let r = lock.withLock({ replay }) { return r }
        let session = NetworkGate.session(for: .mcp, delegate: NoRedirect())
        defer { session.finishTasksAndInvalidate() }
        var r = URLRequest(url: url)
        r.setValue("text/html, application/json", forHTTPHeaderField: "Accept")
        let (_, response) = try await session.data(for: NetworkGate.tag(r, category: .mcp))
        guard let http = response as? HTTPURLResponse else { throw MCPOAuthError.authorizationFailed(0) }
        guard (300..<400).contains(http.statusCode), let loc = http.value(forHTTPHeaderField: "Location"), let u = URL(string: loc) else {
            throw MCPOAuthError.authorizationFailed(http.statusCode)
        }
        lock.withLock { callbacks.append(u) }
        return u
    }
}
#endif
