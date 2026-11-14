// M2.T05 step 1 (R-220 AC1, NFR-SEC7; adr-distribution §4): a catalog is genuine when its detached Ed25519
// signature verifies under pinned key A **or** key B (rotation). The `.sig` file is base64 of the 64-byte raw
// signature over the exact catalog bytes (what `sign_update -p` prints).
import CryptoKit
import Foundation

public struct CatalogVerifier: Sendable {
    public let keys: [Curve25519.Signing.PublicKey]

    public init(base64Keys: [String] = PinnedKeys.keys) {
        keys = base64Keys.compactMap { Data(base64Encoded: $0).flatMap { try? Curve25519.Signing.PublicKey(rawRepresentation: $0) } }
    }

    /// `sig` is the `.sig` file's content (base64 text, surrounding whitespace ignored).
    public func verify(data: Data, sig: Data) -> Bool {
        let text = String(decoding: sig, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let raw = Data(base64Encoded: text), raw.count == 64 else { return false }
        return keys.contains { $0.isValidSignature(raw, for: data) }
    }
}
