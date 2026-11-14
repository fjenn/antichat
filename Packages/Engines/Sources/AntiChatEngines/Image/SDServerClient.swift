// SDServerClient (M0.T06 steps 2–3): the native async job API of sd-server at leejet/stable-diffusion.cpp@e239e4b
// (examples/server/api.md "sdcpp API"; routes_sdcpp.cpp, async_jobs.cpp):
//   - `POST /sdcpp/v1/img_gen` → 202 `{id, poll_url}`; body = the native request schema (prompt, width, height,
//     seed, sample_params{sample_method, sample_steps, guidance.txt_cfg}, preview, preview_interval).
//   - `GET /sdcpp/v1/jobs/{id}` → `{status: queued|generating|completed|failed|cancelled, preview{pass, step,
//     total_steps, b64_json}, result{images[{b64_json}]}}`. The server keeps only the latest preview frame
//     (async_jobs.cpp:46-71 `preview_callback` writes it under `preview_mutex`), so per-step previews are
//     observed by polling faster than one step (the spike polls every 15 ms).
//   - `POST /sdcpp/v1/jobs/{id}/cancel` → 200 `cancel_requested: true`; the job turns `cancelled` at the next
//     cancellation checkpoint (`sd_cancel_generation` inside sampling).
//   - `GET /sdcpp/v1/models/status` → `{state: empty|loading|ready|error}`.
// M4.T05: over the sd-server unix socket only (UP-SD-001 `--listen-ip unix:<path>`), through the same
// UnixHTTPClient as llama-server (no TCP, no URLSession, no proxy). `Transport` is the seam for recorded responses.
import AntiChatFoundation
import Foundation

public struct SDServerClient: Sendable {
    /// One HTTP exchange: (method, path, JSON body) → (status, body bytes).
    public typealias Transport = @Sendable (_ method: String, _ path: String, _ body: Data?) async throws -> (Int, Data)

    public let socketPath: String
    let transport: Transport

    public init(socketPath: String) {
        self.socketPath = socketPath
        let http = UnixHTTPClient(socketPath: socketPath, apiKey: nil)
        transport = { method, path, body in
            // Status probes answer at once; a submit or poll may wait behind a step, never forever.
            try await http.fetch(method: method, path: path, body: body, timeout: path.hasSuffix("/models/status") ? 2 : 60)
        }
    }

    /// Recorded-fixture client (SDServerClientTests).
    public init(transport: @escaping Transport) {
        socketPath = ""
        self.transport = transport
    }

    func json(_ method: String, _ path: String, body: [String: Any]? = nil) async throws -> (Int, [String: Any]) {
        let data = try body.map { try JSONSerialization.data(withJSONObject: $0) }
        let (status, out) = try await transport(method, path, data)
        let obj = (try? JSONSerialization.jsonObject(with: out)) as? [String: Any] ?? [:]
        return (status, obj)
    }

    public func modelStatus() async throws -> String {
        let (code, obj) = try await json("GET", "/sdcpp/v1/models/status")
        guard code == 200 else { return "http\(code)" }
        return obj["state"] as? String ?? "unknown"
    }

    public func submit(prompt: String, width: Int, height: Int, steps: Int, seed: Int64, cfg: Float, sampleMethod: String, preview: String,
                       negativePrompt: String? = nil, initImage: Data? = nil, maskImage: Data? = nil,
                       refImages: [Data] = [], strength: Float? = nil, loras: [String] = []) async throws -> String {
        try await submit(Self.body(prompt: prompt, width: width, height: height, steps: steps, seed: seed, cfg: cfg,
                                   sampleMethod: sampleMethod, preview: preview, negativePrompt: negativePrompt,
                                   initImage: initImage, maskImage: maskImage, refImages: refImages, strength: strength,
                                   loras: loras))
    }

    /// The `img_gen` body (api.md `:1102-1185`; SDServerAPI.md). `negative_prompt` only when given (R-286 AC3).
    /// M4.T13: `ref_images` (base64 PNGs; the instruction-edit source) and `strength` (img2img fallback) only when set.
    public static func body(prompt: String, width: Int, height: Int, steps: Int, seed: Int64, cfg: Float, sampleMethod: String,
                            preview: String, negativePrompt: String? = nil, initImage: Data? = nil, maskImage: Data? = nil,
                            refImages: [Data] = [], strength: Float? = nil, loras: [String] = []) -> [String: Any] {
        var body: [String: Any] = [
            "prompt": prompt, "width": width, "height": height, "seed": seed, "batch_count": 1,
            "sample_params": ["sample_method": sampleMethod, "sample_steps": steps, "guidance": ["txt_cfg": cfg]],
            "preview": preview, "preview_interval": 1, "output_format": "png", "embed_image_metadata": false,
        ]
        if let negativePrompt { body["negative_prompt"] = negativePrompt }
        if let initImage { body["init_image"] = initImage.base64EncodedString() }
        if let maskImage { body["mask_image"] = maskImage.base64EncodedString() }
        if !refImages.isEmpty { body["ref_images"] = refImages.map { $0.base64EncodedString() } }
        if let strength { body["strength"] = strength }
        // LoRAs by their name under `--lora-model-dir` (absolute paths are refused by the server).
        if !loras.isEmpty { body["lora"] = loras.map { ["path": ($0 as NSString).lastPathComponent, "multiplier": 1.0] } }
        return body
    }

    /// M5.T04: `POST /sdcpp/v1/vid_gen` (body: `SDVideoEngine.body`) → the job id.
    public func submitVideo(_ body: [String: Any]) async throws -> String {
        let (code, obj) = try await json("POST", "/sdcpp/v1/vid_gen", body: body)
        guard code == 202, let id = obj["id"] as? String else {
            throw mediaError("sdSubmitFailed", "HTTP \(code) \(obj)")
        }
        return id
    }

    func submit(_ body: [String: Any]) async throws -> String {
        let (code, obj) = try await json("POST", "/sdcpp/v1/img_gen", body: body)
        guard code == 202, let id = obj["id"] as? String else {
            throw mediaError("sdSubmitFailed", "HTTP \(code) \(obj)")
        }
        return id
    }

    public struct JobState: Sendable {
        public var status: String
        public var previewPass: Int?
        public var previewStep: Int?
        public var previewTotal: Int?
        public var previewPNG: Data?
        public var imagePNG: Data?
        /// `vid_gen`: the encoded container (`result.b64_json`), its frame count and fps.
        public var video: Data?
        public var frameCount: Int?
        public var fps: Int?
        public var error: String?
        public var startedMS: Int64?
        public var completedMS: Int64?
    }

    public func job(_ id: String) async throws -> JobState {
        let (code, obj) = try await json("GET", "/sdcpp/v1/jobs/\(id)")
        guard code == 200 else { throw mediaError("sdJobHTTP", "HTTP \(code)") }
        var s = JobState(status: obj["status"] as? String ?? "unknown")
        if let p = obj["preview"] as? [String: Any] {
            s.previewPass = p["pass"] as? Int
            s.previewStep = p["step"] as? Int
            s.previewTotal = p["total_steps"] as? Int
            s.previewPNG = (p["b64_json"] as? String).flatMap { Data(base64Encoded: $0) }
        }
        if let r = obj["result"] as? [String: Any], let imgs = r["images"] as? [[String: Any]], let b = imgs.first?["b64_json"] as? String {
            s.imagePNG = Data(base64Encoded: b)
        }
        if let r = obj["result"] as? [String: Any], let b = r["b64_json"] as? String {
            s.video = Data(base64Encoded: b)
            s.frameCount = (r["frame_count"] as? NSNumber)?.intValue
            s.fps = (r["fps"] as? NSNumber)?.intValue
        }
        if let e = obj["error"] as? [String: Any] { s.error = "\(e["code"] ?? "")\u{20}\(e["message"] ?? "")" }
        s.startedMS = (obj["started"] as? NSNumber)?.int64Value
        s.completedMS = (obj["completed"] as? NSNumber)?.int64Value
        return s
    }

    public func cancel(_ id: String) async throws {
        _ = try await json("POST", "/sdcpp/v1/jobs/\(id)/cancel", body: [:])
    }
}

extension SDServerClient.JobState {
    init(status: String) {
        self.status = status
    }
}

func mediaError(_ code: String, _ detail: String? = nil) -> AntiChatError {
    AntiChatError(domain: .media, code: code, userMessageKey: "media.error", detail: detail)
}
