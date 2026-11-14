// M7.T07 step 5 (R-257 AC2; RFC 9207 §2.4): mix-up defence. When the AS metadata advertises
// `authorization_response_iss_parameter_supported`, the callback MUST carry `iss` and it MUST equal the metadata's
// `issuer` (simple string comparison, RFC 9207 §2.4); otherwise the response is rejected before the code is used.
// Without the advertisement an `iss` that is present is still compared (a mismatch is never accepted).
// The P-files-tools-13 port source (osaurus MCPOAuthService) is not in the vendored tree, so this is written from
// RFC 9207 itself; the swift-sdk authorizer has no `iss` check at the A-M7-02 pin (upstream PR offered).
import Foundation

public enum IssuerCheck {
    public static func verify(callback: URL, issuer: String, advertised: Bool) throws {
        let iss = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "iss" }?.value
        guard let iss else {
            if advertised { throw MCPOAuthError.issuerMissing }
            return
        }
        guard iss == issuer else { throw MCPOAuthError.issuerMismatch(expected: issuer, got: iss) }
    }
}
