// Thin ONNX Runtime wrapper (P-media-14: onnxruntime-swift-package-manager 1.24.2 @ b7fb7f7), over the
// C API through the CSCOrt shim (see CSCOrt/include/csc_ort.h for why not the Objective-C bindings).
import CSCOrt
import Foundation

package enum DetectorError: Error, Sendable, Equatable {
    case modelMissing(String)
    case modelLoad(String)
    case inference(String)
    case preprocessing
    case timeout
}

/// Execution provider for the detector sessions.
public enum ExecutionProvider: String, Sendable, CaseIterable {
    /// ONNX Runtime CoreML EP (MLProgram, CPU + GPU + ANE); unsupported ops fall back to CPU.
    case coreml
    /// ONNX Runtime CPU EP only.
    case cpu
}

/// One ONNX session with a single fixed-shape float32 input and a single float32 output.
/// ORT sessions support concurrent `Run` calls, hence `@unchecked Sendable`.
package final class OrtModel: @unchecked Sendable {
    private let session: OpaquePointer
    private let inputCount: Int
    package let provider: ExecutionProvider

    package init(path: URL, inputShape: [Int], provider: ExecutionProvider, cacheDirectory: URL? = nil) throws {
        guard FileManager.default.fileExists(atPath: path.path) else {
            throw DetectorError.modelMissing(path.lastPathComponent)
        }
        if let cacheDirectory {
            try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        }
        var err = [CChar](repeating: 0, count: 1024)
        let shape = inputShape.map(Int64.init)
        let s: OpaquePointer? = shape.withUnsafeBufferPointer { sp in
            err.withUnsafeMutableBufferPointer { ep in
                if let cacheDirectory {
                    return cacheDirectory.path.withCString { cp in
                        csc_session_create(path.path, sp.baseAddress, sp.count, provider == .coreml ? 1 : 0, cp,
                                           ep.baseAddress, ep.count)
                    }
                }
                return csc_session_create(path.path, sp.baseAddress, sp.count, provider == .coreml ? 1 : 0, nil,
                                          ep.baseAddress, ep.count)
            }
        }
        guard let s else {
            throw DetectorError.modelLoad("\(path.lastPathComponent): \(Self.message(err))")
        }
        session = s
        inputCount = inputShape.reduce(1, *)
        self.provider = provider
        // Warm-up run: proves the graph executes on this EP (fail closed at load, not at first use).
        _ = try run([Float](repeating: 0, count: inputCount))
    }

    deinit { csc_session_free(session) }

    package func run(_ input: [Float]) throws -> [Float] {
        try InferenceLock.run { try runUnlocked(input) }
    }

    private func runUnlocked(_ input: [Float]) throws -> [Float] {
        var out = [Float](repeating: 0, count: 64)
        var n = 0
        var err = [CChar](repeating: 0, count: 1024)
        let rc = input.withUnsafeBufferPointer { ip in
            out.withUnsafeMutableBufferPointer { op in
                err.withUnsafeMutableBufferPointer { ep in
                    csc_session_run(session, ip.baseAddress, ip.count, op.baseAddress, op.count, &n,
                                    ep.baseAddress, ep.count)
                }
            }
        }
        guard rc == 0 else { throw DetectorError.inference(Self.message(err)) }
        guard n > 0, n <= out.count else { throw DetectorError.inference("unexpected output size \(n)") }
        return Array(out.prefix(n))
    }

    private static func message(_ err: [CChar]) -> String {
        String(decoding: err.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}

/// Every model run in the process holds one engine lock, whoever calls (evaluations are also serialised as a whole,
/// `ChildSafetyCheck.inference`; this covers direct detector calls and the load-time warm-up runs):
/// - `onnx`: every ONNX Runtime session run (Freepik, Marqo, MiVOLO; CoreML EP partitions plus their CPU fallbacks).
///   No two ever overlap: concurrent Run calls on a CoreML-partitioned session were measured to change scores
///   (M4, commit 401e9c8be).
/// - `accelerate`: the age-bin forward (SigLIP on the CPU with Accelerate BLAS; no ONNX Runtime, no Core ML). No two
///   ever overlap.
/// Within ONE evaluation the age-bin forward of the body-only people may run beside the MiVOLO runs of the same image
/// (F7 tail, A-M9-T05-F7): different engines, no shared session or state, and each engine still runs one model at a time.
package enum InferenceLock {
    package static let onnx = EngineLock()
    package static let accelerate = EngineLock()

    /// An ONNX Runtime run (the `onnx` lock).
    package static func run<T>(_ body: () throws -> T) rethrows -> T {
        try onnx.run(body)
    }
}

/// One engine's model-run mutex.
package final class EngineLock: @unchecked Sendable {
    private let lock = NSLock()

    package func run<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }
}

package func softmax(_ x: [Float]) -> [Double] {
    let m = x.max() ?? 0
    let e = x.map { exp(Double($0 - m)) }
    let s = e.reduce(0, +)
    return e.map { $0 / s }
}
