// M4.T03 step 3 (R-285 AC6): the app side of the ChildSafetyCheck. Photo/Video entry points ask `SafetyStatus` before
// submitting a job; `missing`/`damaged` shows `SafetyMissingCard` (`safety.missing` with the repair size) and runs no
// job. A blocked output only increments one local counter (`child_safety_blocks`); no other record, never sent.
import AntiChatStorage
import CryptoKit
import Foundation
import GRDB

public enum SafetyStatus: Sendable, Equatable {
    case available
    /// The detector files are not installed; `sizeBytes` = their download size from the catalog.
    case missing(sizeBytes: Int64)
    /// Installed but a file is absent or fails its sha256; repair re-downloads `sizeBytes`.
    case damaged(sizeBytes: Int64)

    /// One detector file of the `csam_check` slot (and its `requires`), as the catalog pins it.
    public struct DetectorFile: Sendable, Equatable {
        public var path: URL
        public var sha256: String
        public var size: Int64
        public init(path: URL, sha256: String, size: Int64) { self.path = path; self.sha256 = sha256; self.size = size }
    }

    /// Classifies the installed detector files. `verify` re-hashes (slow; the helper's gate always verifies before
    /// loading, so the app passes `false` for the cheap entry-point check and `true` for a repair check).
    public static func evaluate(_ files: [DetectorFile], installed: Bool, verify: Bool = false) -> SafetyStatus {
        let size = files.reduce(0) { $0 + $1.size }
        guard !files.isEmpty, installed else { return .missing(sizeBytes: size) }
        for f in files {
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: f.path.path),
                  (attrs[.size] as? NSNumber)?.int64Value == f.size else { return .damaged(sizeBytes: size) }
            if verify, sha256Hex(f.path) != f.sha256.lowercased() { return .damaged(sizeBytes: size) }
        }
        return .available
    }

    /// R-285 AC6 / D-006 (Q-015 r5): the entry-point check before a Photo job is submitted. A missing manifest or an
    /// absent detector file is `missing` (the repair size from the manifest) and the caller runs no job; the helper's
    /// gate still verifies every file's sha256 before loading, so `available` here never skips the real check.
    public static func preflight(_ manifest: SafetyManifest?) -> SafetyStatus {
        guard let m = manifest else { return .missing(sizeBytes: 0) }
        let paths = [m.nudityPath, m.agePath, m.ageBinsPath] + (m.nudity2Path.map { [$0] } ?? [])
        return paths.allSatisfy { FileManager.default.fileExists(atPath: $0) } ? .available : .missing(sizeBytes: m.sizeBytes)
    }

    public var repairBytes: Int64? {
        switch self {
        case .available: nil
        case .missing(let s), .damaged(let s): s
        }
    }

    static func sha256Hex(_ url: URL) -> String? {
        guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        var hasher = SHA256()
        do {
            while let chunk = try h.read(upToCount: 8 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        } catch { return nil }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

/// M4.T04: the helper's `SafetyManifest` from an installed models root (catalog keys → the files the gate loads).
public enum SafetyManifestResolver {
    /// Catalog key → path inside the key's directory (catalog `models.yaml` files of the `csam_check` slot).
    public static let files: [(key: String, path: String)] = [
        ("csc-nudity", "onnx/model.onnx"), ("csc-age", "mivolo_v2_age.onnx"), ("csc-age-bins", "model.safetensors"),
    ]

    /// `pinned` = the catalog's sha256 per key (the gate re-verifies them before loading). Nil when a file is absent or
    /// a key has no pin: a manifest always carries the signed catalog's hashes, never hashes of the files themselves.
    public static func resolve(modelsRoot: URL, pinned: [String: String], repairBytes: Int64 = 0) -> SafetyManifest? {
        resolve(modelsRoot: modelsRoot, repairBytes: repairBytes) { key, _ in pinned[key] }
    }

    #if DEBUG || ANTICHAT_PERF_HARNESS
    /// Dev models, tests, Debug benches only: the expected sha256 is computed from the file as installed, so the gate's
    /// verify-before-load compares a file with itself. M4 review P1-1 (D-006: no launch argument may change the gate):
    /// compiled out of Release, and `tools/ci/r241-audit.py` rule 2c fails any use outside `#if DEBUG` or a test.
    public static func resolveUnpinned(modelsRoot: URL) -> SafetyManifest? {
        resolve(modelsRoot: modelsRoot, repairBytes: 0) { _, url in SafetyStatus.sha256Hex(url) }
    }

    /// The dev models root (`make models-dev`): `~/Library/Application Support/AntiChat-Dev/Models`.
    public static var devModelsRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/AntiChat-Dev/Models")
    }
    #endif

    private static func resolve(modelsRoot: URL, repairBytes: Int64, sha256: (String, URL) -> String?) -> SafetyManifest? {
        var paths: [String: String] = [:]
        var sha: [String: String] = [:]
        var size: Int64 = 0
        for f in files {
            let url = modelsRoot.appendingPathComponent(f.key).appendingPathComponent(f.path)
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path) else { return nil }
            size += (attrs[.size] as? NSNumber)?.int64Value ?? 0
            paths[f.key] = url.path
            guard let h = sha256(f.key, url) else { return nil }
            sha[f.key] = h
        }
        return SafetyManifest(nudityPath: paths["csc-nudity"]!, agePath: paths["csc-age"]!, ageBinsPath: paths["csc-age-bins"]!,
                              sha256: sha, sizeBytes: repairBytes > 0 ? repairBytes : size)
    }
}

/// The single record a block leaves (M4.T03 step 2): `local_counter['child_safety_blocks'] += 1`. Local only.
public enum ChildSafetyCounter {
    public static let key = "child_safety_blocks"

    @discardableResult
    public static func recordBlock(in db: Database) throws -> Int64 {
        try LocalCounterRecord.increment(key, in: db)
    }
}
