// M10.T04: verify a signed catalog against the pinned keys of a channel (what the app's CatalogVerifier does).
// Usage: swift tools/release/verify-catalog.swift <catalog.json> <catalog.json.sig> Config/Keys.<channel>.plist
// Exit 0 = the detached Ed25519 signature verifies under CatalogPublicKeyA or CatalogPublicKeyB.
import CryptoKit
import Foundation

let a = CommandLine.arguments
guard a.count == 4 else { print("usage: verify-catalog.swift CATALOG SIG KEYS.plist"); exit(2) }
let data = try Data(contentsOf: URL(fileURLWithPath: a[1]))
let sigText = try String(contentsOfFile: a[2], encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
let plist = NSDictionary(contentsOfFile: a[3]) ?? [:]
guard let sig = Data(base64Encoded: sigText), sig.count == 64 else { print("verify-catalog: bad signature file"); exit(1) }
for name in ["CatalogPublicKeyA", "CatalogPublicKeyB"] {
    guard let b64 = plist[name] as? String, let raw = Data(base64Encoded: b64),
          let key = try? Curve25519.Signing.PublicKey(rawRepresentation: raw) else { continue }
    if key.isValidSignature(sig, for: data) { print("verify-catalog: ok (\(name))"); exit(0) }
}
print("verify-catalog: signature does not verify under \(a[3])")
exit(1)
