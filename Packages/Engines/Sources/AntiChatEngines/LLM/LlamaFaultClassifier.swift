// llama-server fault classification (M1.T12 step 3; P-shell-10). Design port of Jan's `classify_fault` /
// `FaultReader` (janhq/jan@7890e41:src-tauri/plugins/tauri-plugin-llamacpp/src/engine/worker.rs:78-230,
// Apache-2.0): one stderr line at a time, lowercased once; Metal's two-line command-buffer failure (a status
// line, then `error: <cause>`) is held until the next line decides it; EBADARCH (86) from exec = wrong CPU.
// Added for llama.cpp b11669 @ 620d222: model-file corruption lines
// (`ggml/src/gguf.cpp:482` invalid magic, `src/llama-model-loader.h:46` "data is not within the file bounds",
// `src/llama.cpp:375,433` "error loading model" / "failed to load model"). Same texts at b12254 @ 45c8ea8
// (llama.cpp:374,432; the others unmoved).
// The fault decides the user-facing error: oom → model.notEnoughMemory, model_corrupt → model.corrupt,
// everything else (metal_backend, unknown crash) → engine.restarted; bad_arch → engine.error (not transient).
import AntiChatFoundation
import Foundation

public enum LlamaFault: String, Sendable, Hashable, Codable {
    case oom
    case metalBackend = "metal_backend"
    case badArch = "bad_arch"
    case modelCorrupt = "model_corrupt"
    case unknown

    /// Severity order when several faults were seen: the most specific cause wins.
    var rank: Int {
        switch self {
        case .badArch: 4
        case .oom: 3
        case .modelCorrupt: 2
        case .metalBackend: 1
        case .unknown: 0
        }
    }

    /// The error a failed load or a died stream reports (copy-deck §8 keys).
    public func error(detail: String) -> AntiChatError {
        switch self {
        case .oom: AntiChatError(.modelNotEnoughMemory, detail: detail)
        case .modelCorrupt: AntiChatError(.modelCorrupt, detail: detail)
        case .metalBackend, .unknown: AntiChatError(.engineRestarted, detail: detail)
        case .badArch: AntiChatError.engine("badArch", detail)
        }
    }
}

public enum LlamaFaultClassifier {
    /// `EBADARCH`: macOS's exec error for a Mach-O without a slice for this CPU ("Bad CPU type in executable").
    public static let EBADARCH: Int32 = 86

    /// Classifies one already-lowercased line; nil = not a fault line.
    public static func classify(_ lower: String) -> LlamaFault? {
        if isOOM(lower) { return .oom }
        if isCorrupt(lower) { return .modelCorrupt }
        if isBackend(lower) { return .metalBackend }
        return nil
    }

    static func isOOM(_ l: String) -> Bool {
        // Metal reports a mapped model outgrowing recommendedMaxWorkingSetSize with these codes; "insufficient
        // memory" is both their localized text and ggml_aligned_malloc's ENOMEM message (Jan is_oom_line).
        if l.contains("erroroutofdevicememory") || l.contains("erroroutofhostmemory")
            || l.contains("kiogpucommandbuffercallbackerroroutofmemory") || l.contains("insufficient memory")
        {
            return true
        }
        return l.contains("failed to allocate") && l.contains("buffer of size")
    }

    static func isCorrupt(_ l: String) -> Bool {
        l.contains("invalid magic characters") || l.contains("is not within the file bounds")
            || l.contains("model is corrupted or incomplete") || l.contains("error loading model")
            || l.contains("failed to load model") || l.contains("gguf_init_from_file")
                && (l.contains("failed") || l.contains("invalid"))
    }

    static func isBackend(_ l: String) -> Bool {
        if l.contains("ggml_assert(") { return true }
        if l.contains("ggml_metal") && l.contains("error") { return true }
        if l.contains("devicelost") || l.contains("device lost") || l.contains("terminate called after throwing")
            || l.contains("libc++abi: terminating")
        {
            return true
        }
        return ["corrupted size vs. prev_size", "double free or corruption", "malloc: ", "stack smashing detected",
                "buffer overflow detected"].contains { l.contains($0) }
    }

    /// The fault for a spawn that failed with `errno`.
    public static func spawnFault(errno code: Int32) -> LlamaFault { code == EBADARCH ? .badArch : .unknown }
}

/// Turns stderr lines into faults, one call per line (Jan `FaultReader`). Not thread-safe: one reader per
/// stderr stream.
public struct LlamaFaultReader: Sendable {
    private var pendingMetalStatus: String?

    public init() {}

    public mutating func feed(_ line: String) -> [(LlamaFault, String)] {
        let lower = line.lowercased()
        var out: [(LlamaFault, String)] = []
        let isStatus = lower.contains("command buffer") && lower.contains("failed with status")
        if let status = pendingMetalStatus {
            pendingMetalStatus = nil
            if !isStatus && lower.contains("error:") {
                out.append((LlamaFaultClassifier.classify(lower) ?? .metalBackend, "\(status) \(line)"))
                return out
            }
            out.append((.metalBackend, status))
        }
        if isStatus {
            pendingMetalStatus = line
            return out
        }
        if let f = LlamaFaultClassifier.classify(lower) { out.append((f, line)) }
        return out
    }

    /// A held status line whose detail never came.
    public mutating func flush() -> (LlamaFault, String)? {
        defer { pendingMetalStatus = nil }
        return pendingMetalStatus.map { (.metalBackend, $0) }
    }
}

/// What a supervised llama-server said before it failed: the strongest fault seen and the last stderr lines.
public struct LlamaFaultLog: Sendable {
    public private(set) var fault: LlamaFault?
    public private(set) var faultLine: String?
    public private(set) var tail: [String] = []
    private var reader = LlamaFaultReader()
    static let tailLines = 8
    static let tailLineChars = 300

    public init() {}

    public mutating func feed(_ line: String) {
        for (f, l) in reader.feed(line) { record(f, l) }
        // ggml prints one `load_backend:` line per backend at start: noise for an error tail (Jan is_tail_noise).
        if !line.hasPrefix("load_backend:") {
            tail.append(String(line.prefix(Self.tailLineChars)))
            if tail.count > Self.tailLines { tail.removeFirst(tail.count - Self.tailLines) }
        }
    }

    public mutating func finish() {
        if let (f, l) = reader.flush() { record(f, l) }
    }

    mutating func record(_ f: LlamaFault, _ line: String) {
        if fault == nil || f.rank > fault!.rank {
            fault = f
            faultLine = String(line.prefix(Self.tailLineChars))
        }
    }

    /// The error for a process that died (or a load that failed) after these lines.
    public func error(default fallback: LlamaFault = .unknown, context: String) -> AntiChatError {
        (fault ?? fallback).error(detail: "\(context): \(faultLine ?? tail.last ?? "no stderr")")
    }
}
