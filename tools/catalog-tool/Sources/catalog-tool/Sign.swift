// M2.T04 step 5 (P-platform-02): detached Ed25519 signature over the exact bytes, base64 in `<file>.sig`.
// Default path: Sparkle's `sign_update --ed-key-file <key> -p` (the pinned 2.10.1 artefact bundle, file key, no
// Keychain); the result is verified with CryptoKit before it is written. `--cryptokit` (or no sign_update binary)
// signs with CryptoKit directly (the M2.T04 known-failure fallback).
import CryptoKit
import Foundation

enum Sign {
    static func defaultSignUpdate(root: URL) -> URL? {
        let u = root.appending(path: ".build/artifacts/sparkle/Sparkle/bin/sign_update")
        return FileManager.default.isExecutableFile(atPath: u.path) ? u : nil
    }

    static func signature(of data: Data, key: Curve25519.Signing.PrivateKey) throws -> Data { try key.signature(for: data) }

    static func sparkleSignature(file: URL, keyFile: String, tool: URL) throws -> Data {
        let p = Process()
        p.executableURL = tool
        p.arguments = ["--ed-key-file", keyFile, "-p", file.path]
        let out = Pipe(); p.standardOutput = out; p.standardError = Pipe()
        try p.run(); p.waitUntilExit()
        let s = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard p.terminationStatus == 0, let sig = Data(base64Encoded: s) else { throw ToolError.message("sign_update failed (\(p.terminationStatus))") }
        return sig
    }

    /// Signs `file`, writes `<file>.sig` (or `out`), returns the base64 signature.
    @discardableResult
    static func run(file: URL, keyFile: String, signUpdate: URL?, out: URL? = nil) throws -> String {
        let data = try Data(contentsOf: file)
        let key = try Keygen.privateKey(file: keyFile)
        var sig: Data
        if let tool = signUpdate {
            sig = try sparkleSignature(file: file, keyFile: keyFile, tool: tool)
        } else {
            sig = try signature(of: data, key: key)
        }
        guard key.publicKey.isValidSignature(sig, for: data) else {
            if signUpdate != nil {
                // Raw-signature mismatch (P-platform-02 residual): fall back to CryptoKit.
                sig = try signature(of: data, key: key)
                guard key.publicKey.isValidSignature(sig, for: data) else { throw ToolError.message("signature does not verify") }
                return try write(sig, to: out ?? URL(fileURLWithPath: file.path + ".sig"))
            }
            throw ToolError.message("signature does not verify")
        }
        return try write(sig, to: out ?? URL(fileURLWithPath: file.path + ".sig"))
    }

    static func write(_ sig: Data, to url: URL) throws -> String {
        let b64 = sig.base64EncodedString()
        try (b64 + "\n").write(to: url, atomically: true, encoding: .utf8)
        return b64
    }
}
