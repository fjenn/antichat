// M4.T06 step 7: SDServerClient against recorded sd-server responses (api.md shapes at e239e4b): the img_gen body (no
// negative_prompt unless given; init/mask as base64), a job with a per-step preview, a completed result, a failure,
// and the cancel route — all over the injected transport (the live one is the unix socket, UP-SD-001).
import Foundation
import Synchronization
import Testing
@testable import AntiChatEngines

@Suite struct SDServerClientTests {
    final class Recorder: @unchecked Sendable {
        let lock = NSLock()
        var calls: [(String, String, [String: Any])] = []
        var replies: [String: (Int, String)] = [:]
        func transport() -> SDServerClient.Transport {
            { method, path, body in
                let obj = body.flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] } ?? [:]
                return self.lock.withLock {
                    self.calls.append((method, path, obj))
                    let r = self.replies["\(method) \(path)"] ?? (404, "{}")
                    return (r.0, Data(r.1.utf8))
                }
            }
        }
    }

    static let png1 = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg=="

    @Test func submitPollPreviewResultAndCancel() async throws {
        let rec = Recorder()
        rec.replies = [
            "POST /sdcpp/v1/img_gen": (202, #"{"id":"job-1","poll_url":"/sdcpp/v1/jobs/job-1"}"#),
            "GET /sdcpp/v1/jobs/job-1": (200, #"{"status":"generating","preview":{"pass":1,"step":2,"total_steps":4,"b64_json":"\#(Self.png1)"}}"#),
            "POST /sdcpp/v1/jobs/job-1/cancel": (200, #"{"cancel_requested":true}"#),
            "GET /sdcpp/v1/models/status": (200, #"{"state":"ready"}"#),
        ]
        let c = SDServerClient(transport: rec.transport())
        #expect(try await c.modelStatus() == "ready")
        let id = try await c.submit(prompt: "a fox", width: 768, height: 512, steps: 4, seed: 9, cfg: 1, sampleMethod: "euler", preview: "proj",
                                    initImage: Data([1, 2, 3]))
        #expect(id == "job-1")
        let body = rec.calls[1].2
        #expect(body["negative_prompt"] == nil, "omitted unless the model uses one (R-286 AC3)")
        #expect(body["init_image"] as? String == Data([1, 2, 3]).base64EncodedString() && body["mask_image"] == nil)
        #expect((body["sample_params"] as? [String: Any])?["sample_steps"] as? Int == 4 && body["preview_interval"] as? Int == 1)
        let st = try await c.job(id)
        #expect(st.status == "generating" && st.previewStep == 2 && st.previewTotal == 4 && (st.previewPNG?.count ?? 0) > 0)
        try await c.cancel(id)
        #expect(rec.calls.last?.1 == "/sdcpp/v1/jobs/job-1/cancel")
        let neg = SDServerClient.body(prompt: "x", width: 1, height: 1, steps: 1, seed: 1, cfg: 1, sampleMethod: "euler", preview: "none",
                                      negativePrompt: "blur")
        #expect(neg["negative_prompt"] as? String == "blur")
    }

    @Test func completedFailedAndHTTPErrors() async throws {
        let rec = Recorder()
        rec.replies = [
            "GET /sdcpp/v1/jobs/ok": (200, #"{"status":"completed","result":{"images":[{"b64_json":"\#(Self.png1)"}]},"started":1000,"completed":3500}"#),
            "GET /sdcpp/v1/jobs/bad": (200, #"{"status":"failed","error":{"code":"oom","message":"out of memory"}}"#),
            "POST /sdcpp/v1/img_gen": (500, #"{"error":"x"}"#),
        ]
        let c = SDServerClient(transport: rec.transport())
        let ok = try await c.job("ok")
        #expect(ok.status == "completed" && ok.imagePNG != nil && ok.completedMS == 3500)
        let bad = try await c.job("bad")
        #expect(bad.status == "failed" && bad.error?.contains("oom") == true)
        await #expect(throws: (any Error).self) { _ = try await c.job("missing") }
        await #expect(throws: (any Error).self) {
            _ = try await c.submit(prompt: "x", width: 1, height: 1, steps: 1, seed: 1, cfg: 1, sampleMethod: "euler", preview: "none")
        }
    }
}
