// M5.T11 (NFR-B5, AT-NFR-B5 / testPausedForOtherApp): simulates another app holding the GPU — a Metal compute loop
// that keeps the GPU busy for `--seconds N` (default 30) at roughly `--duty P` percent (default 90). It touches no file
// and no network. Build: tools/perf/gpu-burn/build.sh → build/tools/gpu-burn. Never run in unit tests (smoke build only).
import Foundation
import Metal

var seconds = 30.0, duty = 0.9
var it = CommandLine.arguments.dropFirst().makeIterator()
while let a = it.next() {
    switch a {
    case "--seconds": seconds = Double(it.next() ?? "") ?? seconds
    case "--duty": duty = min(1, max(0.05, (Double(it.next() ?? "") ?? 90) / 100))
    case "--help", "-h": print("usage: gpu-burn [--seconds N] [--duty PERCENT]"); exit(0)
    default: FileHandle.standardError.write(Data("gpu-burn: unknown argument \(a)\n".utf8)); exit(64)
    }
}
let source = """
#include <metal_stdlib>
using namespace metal;
kernel void burn(device float *buf [[buffer(0)]], uint id [[thread_position_in_grid]]) {
    float x = buf[id];
    for (uint i = 0; i < 4096; i++) { x = fma(x, 1.000001f, 0.000001f); x = sin(x) * cos(x) + x; }
    buf[id] = x;
}
"""
guard let dev = MTLCreateSystemDefaultDevice(), let queue = dev.makeCommandQueue() else {
    FileHandle.standardError.write(Data("gpu-burn: no Metal device\n".utf8)); exit(69)
}
let lib = try dev.makeLibrary(source: source, options: nil)
let pso = try dev.makeComputePipelineState(function: lib.makeFunction(name: "burn")!)
let n = 1 << 20
let buf = dev.makeBuffer(length: n * MemoryLayout<Float>.size, options: .storageModePrivate)!
let end = Date().addingTimeInterval(seconds)
var batches = 0
print("gpu-burn: pid \(getpid()) device \(dev.name) for \(seconds) s at ~\(Int(duty * 100)) %")
while Date() < end {
    let t0 = Date()
    guard let cb = queue.makeCommandBuffer(), let enc = cb.makeComputeCommandEncoder() else { break }
    enc.setComputePipelineState(pso)
    enc.setBuffer(buf, offset: 0, index: 0)
    enc.dispatchThreads(MTLSize(width: n, height: 1, depth: 1),
                        threadsPerThreadgroup: MTLSize(width: pso.maxTotalThreadsPerThreadgroup, height: 1, depth: 1))
    enc.endEncoding()
    cb.commit()
    cb.waitUntilCompleted()
    batches += 1
    let busy = Date().timeIntervalSince(t0)
    if duty < 1 { Thread.sleep(forTimeInterval: busy * (1 - duty) / duty) }
}
print("gpu-burn: done, \(batches) batches")
