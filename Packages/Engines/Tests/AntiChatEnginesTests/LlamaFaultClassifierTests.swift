// M1.T12 step 3: stderr lines → faults → user-facing errors (Jan classify_fault port + llama.cpp corrupt-model lines).
import AntiChatFoundation
import Foundation
import Testing
@testable import AntiChatEngines

@Suite("LlamaFaultClassifierTests") struct LlamaFaultClassifierTests {
    @Test(arguments: [
        ("ggml_metal_graph_compute: command buffer 0 failed with status 5", nil as LlamaFault?),  // held, see below
        ("error: Insufficient Memory (00000008:kIOGPUCommandBufferCallbackErrorOutOfMemory)", .oom),
        ("ggml_backend_metal_buffer_type_alloc_buffer: error: failed to allocate buffer of size 9876543210", .oom),
        ("gguf_init_from_file_impl: invalid magic characters: 'xxxx', expected 'GGUF'", .modelCorrupt),
        ("llama_model_load: error loading model: tensor 'blk.0' data is not within the file bounds, model is corrupted or incomplete", .modelCorrupt),
        ("llama_init_from_model: failed to load model", .modelCorrupt),
        ("/llama.cpp/ggml/src/ggml.c:1234: GGML_ASSERT(ctx) failed", .metalBackend),
        ("libc++abi: terminating due to uncaught exception of type std::runtime_error", .metalBackend),
        ("srv  update_slots: all slots are idle", nil),
        ("load_backend: loaded CPU backend from /x", nil),
    ])
    func classifiesSingleLines(line: String, expected: LlamaFault?) {
        let lower = line.lowercased()
        if lower.contains("failed with status") { return }  // two-line case, covered by heldMetalStatus
        #expect(LlamaFaultClassifier.classify(lower) == expected, "\(line)")
    }

    @Test func heldMetalStatusTakesItsCauseLine() {
        var r = LlamaFaultReader()
        #expect(r.feed("ggml_metal: command buffer 0 failed with status 5").isEmpty)
        let out = r.feed("error: Insufficient Memory (00000008:kIOGPUCommandBufferCallbackErrorOutOfMemory)")
        #expect(out.map(\.0) == [.oom])
        #expect(r.flush() == nil)
    }

    @Test func heldMetalStatusWithoutCauseIsBackend() {
        var r = LlamaFaultReader()
        _ = r.feed("ggml_metal: command buffer 0 failed with status 5")
        #expect(r.feed("srv  log: next").map(\.0) == [.metalBackend])
        _ = r.feed("ggml_metal: command buffer 1 failed with status 3")
        #expect(r.flush()?.0 == .metalBackend)
    }

    @Test func strongestFaultWinsAndMapsToCopyKeys() {
        var log = LlamaFaultLog()
        log.feed("/x/ggml.c:1: GGML_ASSERT(x) failed")
        log.feed("ggml_backend_metal_buffer_type_alloc_buffer: error: failed to allocate buffer of size 123")
        log.finish()
        #expect(log.fault == .oom)
        #expect(log.error(context: "t").userMessageKey == "model.notEnoughMemory")
        #expect(LlamaFault.modelCorrupt.error(detail: "x").userMessageKey == "model.corrupt")
        #expect(LlamaFault.unknown.error(detail: "x").is(.engineRestarted))
        #expect(LlamaFault.metalBackend.error(detail: "x").recovery == [.retry])
        #expect(LlamaFaultClassifier.spawnFault(errno: 86) == .badArch)
    }

    @Test func tailKeepsTheLastLinesWithoutBackendNoise() {
        var log = LlamaFaultLog()
        log.feed("load_backend: loaded Metal backend")
        for i in 0..<20 { log.feed("line \(i)") }
        #expect(log.tail.count == LlamaFaultLog.tailLines)
        #expect(log.tail.last == "line 19")
        #expect(!log.tail.contains { $0.hasPrefix("load_backend") })
        // No fault seen: a died server is reported as an engine restart.
        #expect(log.error(context: "kill").is(.engineRestarted))
    }
}
