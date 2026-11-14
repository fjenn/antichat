// M2.T04 step 1 (ci-release §6.1): Ed25519 test keys without the Keychain. `<prefix>.priv` holds the base64 32-byte
// seed (the format `generate_keys -x` exports and `sign_update --ed-key-file` reads), `<prefix>.pub` the base64
// raw public key (what PinnedKeys.swift pins). Production keys come from `generate_keys` at the M10 key ceremony.
import CryptoKit
import Foundation

enum Keygen {
    static func run(prefix: String) throws {
        let key = Curve25519.Signing.PrivateKey()
        try (key.rawRepresentation.base64EncodedString() + "\n").write(toFile: prefix + ".priv", atomically: true, encoding: .utf8)
        try (key.publicKey.rawRepresentation.base64EncodedString() + "\n").write(toFile: prefix + ".pub", atomically: true, encoding: .utf8)
        print("keygen: wrote \(prefix).priv, \(prefix).pub")
    }

    static func privateKey(file: String) throws -> Curve25519.Signing.PrivateKey {
        let s = try String(contentsOfFile: file, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let raw = Data(base64Encoded: s) else { throw ToolError.message("\(file): not base64") }
        // 32-byte seed, or Sparkle's legacy 64-byte (seed ‖ public) export.
        return try Curve25519.Signing.PrivateKey(rawRepresentation: raw.count == 64 ? raw.prefix(32) : raw)
    }
}
