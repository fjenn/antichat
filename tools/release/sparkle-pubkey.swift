// tools/release/sparkle-pubkey.swift — print the PUBLIC key that belongs to an Ed25519 key file (line 1 = the
// base64 32-byte private seed: the format `sign_update --ed-key-file` reads and tools/release/key-ceremony.sh
// writes). Used to check, before anything is signed, that the Sparkle key in hand is the one the app trusts
// (Config/Keys.release.plist SparklePublicEDKey): release.yml and tools/release/gh-release-secrets.sh.
// Prints only the public key; the private seed stays in memory and is never written or echoed.
// Usage: swift tools/release/sparkle-pubkey.swift <key file>
import CryptoKit
import Foundation

guard CommandLine.arguments.count == 2,
      let text = try? String(contentsOfFile: CommandLine.arguments[1], encoding: .utf8),
      let line = text.split(whereSeparator: \.isNewline).first,
      let seed = Data(base64Encoded: line.trimmingCharacters(in: .whitespaces)), seed.count == 32,
      let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: seed)
else {
    FileHandle.standardError.write(Data("sparkle-pubkey: line 1 is not a base64 32-byte Ed25519 seed\n".utf8))
    exit(1)
}
print(key.publicKey.rawRepresentation.base64EncodedString())
