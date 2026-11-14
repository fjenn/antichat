// M7.T07 step 3 (R-257 AC1): the sign-in round trip. `WebAuthPresenter` opens the authorization URL in
// `ASWebAuthenticationSession` (callback scheme `antichat`, `prefersEphemeralWebBrowserSession = false`, so the
// user's existing browser sign-in is reused) and returns the callback URL. The system shows its own
// "wants to use … to sign in" alert. Tests use `HeadlessAuthPresenter` (DEBUG only).
import AppKit
import AuthenticationServices
import Foundation

public protocol MCPAuthPresenter: Sendable {
    /// Shows `url` and returns the redirect (callback) URL the authorization server sent the browser to.
    func present(_ url: URL, callbackScheme: String) async throws -> URL
}

public struct WebAuthPresenter: MCPAuthPresenter {
    public init() {}

    @MainActor
    final class Anchor: NSObject, ASWebAuthenticationPresentationContextProviding {
        nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
            MainActor.assumeIsolated {  // NSApp is nil in a headless process (no application object)
                let app = NSApp as NSApplication?
                return app?.keyWindow ?? app?.windows.first ?? NSWindow()
            }
        }
    }

    /// Keeps the session and its (weakly held) presentation provider alive until the session calls back.
    private final class Keep: @unchecked Sendable {
        var session: ASWebAuthenticationSession?
        var anchor: AnyObject?
    }

    @MainActor
    public func present(_ url: URL, callbackScheme: String) async throws -> URL {
        let keep = Keep()
        keep.anchor = Anchor()
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<URL, any Error>) in
            // Q-015 r6 (crash, MCPOAuthUITests): AuthenticationServices calls this back on its XPC reply queue, not the
            // main thread. A closure written inside this @MainActor method is main-actor isolated, so Swift 6's
            // isolation check trapped (EXC_BREAKPOINT in `_dispatch_assert_queue_fail`) whenever the session ended
            // that way (the sign-in alert's Continue / Cancel). Explicitly @Sendable: nonisolated; it only resumes
            // the continuation and releases the session on the main queue.
            let completion: @Sendable (URL?, (any Error)?) -> Void = { callback, error in
                DispatchQueue.main.async { keep.session = nil; keep.anchor = nil }
                if let callback { cont.resume(returning: callback) }
                else if let e = error as? ASWebAuthenticationSessionError, e.code == .canceledLogin { cont.resume(throwing: MCPOAuthError.cancelled) }
                else { cont.resume(throwing: error ?? MCPOAuthError.cancelled) }
            }
            let s = ASWebAuthenticationSession(url: url, callback: .customScheme(callbackScheme), completionHandler: completion)
            s.presentationContextProvider = keep.anchor as? Anchor
            s.prefersEphemeralWebBrowserSession = false
            keep.session = s
            if !s.start() { keep.session = nil; keep.anchor = nil; cont.resume(throwing: MCPOAuthError.cancelled) }
        }
    }
}
