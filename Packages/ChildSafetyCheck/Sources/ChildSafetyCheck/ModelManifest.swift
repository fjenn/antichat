// The detector files the check loads, with the sha256 the catalog pins for each (R-285 AC3, AC6).
// `ChildSafetyCheck(manifest:)` verifies every hash before loading anything: a missing file is
// `modelsMissing`, a wrong hash or a file that fails to load is `modelsDamaged`; the caller then shows
// `safety.missing` with a repair action and produces no Photo/Video output (fail closed).
import CryptoKit
import Foundation

/// Why the check could not be created. The only error that leaves the package.
public enum CheckError: Error, Sendable, Equatable {
    /// A required detector file is absent.
    case modelsMissing
    /// A detector file has the wrong sha256, the thresholds are unreadable, or a model failed to load.
    case modelsDamaged
}

public struct ModelManifest: Sendable, Equatable {
    /// Catalog keys of the detector entries (catalog/models.yaml, role `child_safety`).
    public static let nudityKey = "csc-nudity"
    public static let ageKey = "csc-age"
    public static let nudity2Key = "csc-nudity2"
    public static let ageBinsKey = "csc-age-bins"

    /// Freepik EVA02 nudity model (`csc-nudity`, `onnx/model.onnx`).
    public let nudity: URL
    /// MiVOLO v2 age model (`csc-age`, `mivolo_v2_age.onnx`).
    public let age: URL
    /// SigLIP2 age bins (`csc-age-bins`, `model.safetensors`): the body-only second age signal.
    public let ageBins: URL
    /// Optional Marqo-384 second nudity signal (`csc-nudity2`); it can only add blocks.
    public let nudity2: URL?
    /// Expected lowercase hex sha256 per catalog key (`csc-nudity`, `csc-age`, `csc-age-bins`, `csc-nudity2`).
    public let sha256: [String: String]
    /// A `thresholds.json` to use instead of the bundled one (a newer catalog version); nil = bundled.
    public let thresholds: URL?

    public init(nudity: URL, age: URL, ageBins: URL, nudity2: URL?, sha256: [String: String], thresholds: URL? = nil) {
        self.nudity = nudity
        self.age = age
        self.ageBins = ageBins
        self.nudity2 = nudity2
        self.sha256 = sha256
        self.thresholds = thresholds
    }

    /// The conventional layout of an install folder holding the entries under their catalog keys.
    /// `nudity2` is included only when its hash is given (the entry is optional).
    public static func standard(modelDirectory: URL, sha256: [String: String]) -> ModelManifest {
        ModelManifest(
            nudity: modelDirectory.appending(path: FreepikNudity.relativePath),
            age: modelDirectory.appending(path: MiVOLOAge.relativePath),
            ageBins: modelDirectory.appending(path: SigLIPAgeBins.relativePath),
            nudity2: sha256[nudity2Key] == nil ? nil : modelDirectory.appending(path: MarqoNudity.relativePath),
            sha256: sha256)
    }

    /// (catalog key, file) for every file this manifest names.
    var files: [(key: String, url: URL)] {
        [(Self.nudityKey, nudity), (Self.ageKey, age), (Self.ageBinsKey, ageBins)] + (nudity2.map { [(Self.nudity2Key, $0)] } ?? [])
    }

    /// Checks presence first (all files), then hashes. Throws the first failure class found.
    func verify() throws(CheckError) {
        try verifyPresence()
        for f in files { try verifyFile(f.key, f.url) }
    }

    /// Every named file exists (else `modelsMissing`), checked before any hash so a missing file always reads as missing.
    func verifyPresence() throws(CheckError) {
        for f in files where !FileManager.default.fileExists(atPath: f.url.path) { throw .modelsMissing }
    }

    /// `url`'s sha256 equals the pin for `key` (else `modelsDamaged`).
    func verifyFile(_ key: String, _ url: URL) throws(CheckError) {
        guard let expected = sha256[key]?.lowercased(), let actual = Self.sha256Hex(of: url), actual == expected else {
            throw .modelsDamaged
        }
    }

    /// Streaming sha256 (detector files are up to ~350 MB). nil if the file cannot be read.
    package static func sha256Hex(of url: URL) -> String? {
        guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        var hasher = SHA256()
        do {
            // `read(upToCount:)` returns nil or empty data at end of file; a read error throws.
            while let chunk = try h.read(upToCount: 8 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        } catch {
            return nil
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
