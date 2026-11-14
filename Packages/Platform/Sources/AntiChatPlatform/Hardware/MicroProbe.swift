// M2.T01 step 3 (K-054): the unknown-chip micro-probe. Runs only when the chip is not in `bandwidth.json`,
// once, async and off the main thread after the first window; its result is stored with the hardware profile.
// About 2 s: an fp16 MPS matmul loop (compute → speed class) and a blit copy loop (memory bandwidth).
import Foundation
import Metal
import MetalPerformanceShaders

public enum MicroProbe {
    public struct Result: Codable, Sendable, Equatable {
        public var bandwidthGBs: Double
        public var matmulTFLOPS: Double
        public init(bandwidthGBs: Double, matmulTFLOPS: Double) {
            self.bandwidthGBs = bandwidthGBs; self.matmulTFLOPS = matmulTFLOPS
        }

        /// Speed class from measured fp16 matmul throughput. [ASSUMPTION] thresholds (K-054), anchored on the one
        /// measured chip: this Mac (M5 Max 40-core, table class S4) measures 17.9 TFLOPS (2026-11-03); the others
        /// scale with GPU fp16 rate so the pp512 bands of hardware-tiers §2.3 line up: < 4 S1, < 8 S2, < 16 S3, else S4.
        public var speedClass: SpeedClass {
            switch matmulTFLOPS {
            case ..<4: .S1
            case ..<8: .S2
            case ..<16: .S3
            default: .S4
            }
        }
    }

    /// Runs the probe for about `budget` seconds total; nil without a Metal device.
    public static func run(budget: TimeInterval = 2) -> Result? {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else { return nil }
        let tflops = matmul(device: device, queue: queue, seconds: budget * 0.6)
        let gbs = bandwidth(device: device, queue: queue, seconds: budget * 0.4)
        guard let tflops, let gbs else { return nil }
        return Result(bandwidthGBs: (gbs * 10).rounded() / 10, matmulTFLOPS: (tflops * 10).rounded() / 10)
    }

    static func matmul(device: MTLDevice, queue: MTLCommandQueue, seconds: TimeInterval) -> Double? {
        let n = 2048
        let rowBytes = n * MemoryLayout<UInt16>.stride
        let desc = MPSMatrixDescriptor(rows: n, columns: n, rowBytes: rowBytes, dataType: .float16)
        guard let a = device.makeBuffer(length: n * rowBytes, options: .storageModePrivate),
              let b = device.makeBuffer(length: n * rowBytes, options: .storageModePrivate),
              let c = device.makeBuffer(length: n * rowBytes, options: .storageModePrivate) else { return nil }
        let ma = MPSMatrix(buffer: a, descriptor: desc), mb = MPSMatrix(buffer: b, descriptor: desc)
        let mc = MPSMatrix(buffer: c, descriptor: desc)
        let mul = MPSMatrixMultiplication(device: device, resultRows: n, resultColumns: n, interiorColumns: n)
        func batch(_ k: Int) -> TimeInterval {
            guard let cb = queue.makeCommandBuffer() else { return .infinity }
            for _ in 0..<k { mul.encode(commandBuffer: cb, leftMatrix: ma, rightMatrix: mb, resultMatrix: mc) }
            cb.commit()
            cb.waitUntilCompleted()
            return cb.gpuEndTime - cb.gpuStartTime
        }
        _ = batch(2)  // warm-up
        var ops = 0.0, time = 0.0
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            let t = batch(8)
            guard t.isFinite, t > 0 else { break }
            ops += 8 * 2 * pow(Double(n), 3)
            time += t
        }
        return time > 0 ? ops / time / 1e12 : nil
    }

    static func bandwidth(device: MTLDevice, queue: MTLCommandQueue, seconds: TimeInterval) -> Double? {
        let bytes = 256 << 20
        guard let src = device.makeBuffer(length: bytes, options: .storageModePrivate),
              let dst = device.makeBuffer(length: bytes, options: .storageModePrivate) else { return nil }
        var moved = 0.0, time = 0.0
        let deadline = Date().addingTimeInterval(seconds)
        repeat {
            guard let cb = queue.makeCommandBuffer(), let blit = cb.makeBlitCommandEncoder() else { return nil }
            for _ in 0..<4 { blit.copy(from: src, sourceOffset: 0, to: dst, destinationOffset: 0, size: bytes) }
            blit.endEncoding()
            cb.commit()
            cb.waitUntilCompleted()
            let t = cb.gpuEndTime - cb.gpuStartTime
            if t > 0 { moved += Double(4 * 2 * bytes); time += t }  // read + write
        } while Date() < deadline
        return time > 0 ? moved / time / 1e9 : nil
    }
}
