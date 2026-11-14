// M5.T03 (P-media-11 RL-005 HTTP client glue): the helper's client of the video runtime server (`antichat_video.server`,
// protocol.py) over its unix socket — `UnixHTTPClient` (NWConnection) with the per-launch bearer token. SSE events are
// parsed by EventSource 1.5.1 (`AsyncSequence<UInt8>.events`, as LlamaServerAdapter does); a dropped stream
// reconnects with `Last-Event-ID` so no event is lost or repeated. Frames come back length-prefixed RGBA8 into memory
// only (the runtime never writes a frame or a video file; neither does this client).
import AntiChatFoundation
import EventSource
import Foundation

public struct VideoRuntimeClient: Sendable {
    public let socketPath: String
    let http: UnixHTTPClient

    public init(socketPath: String, token: String) {
        self.socketPath = socketPath
        http = UnixHTTPClient(socketPath: socketPath, apiKey: token)
    }

    /// The `POST /v1/video/jobs` body.
    public struct Job: Codable, Sendable, Equatable {
        public var jobID: String
        public var modelDir: String
        public var taehvPath: String?
        public var prompt: String
        public var negativePrompt: String?
        public var width: Int
        public var height: Int
        public var numFrames: Int
        public var fps: Int
        public var steps: Int
        public var seed: Int64
        public var memoryLimitBytes: UInt64
        public var preview: Bool
        /// M5.T07: `wan22` | `ltx`; the LTX text encoder dir; keep the sound track.
        public var modelKind: String = "wan22"
        public var gemmaDir: String?
        public var audio: Bool = false
        /// fix/t05-video (VID2; runtime ≥ 0.3.4, older ones ignore both): previews at this short side (the gate's
        /// valid preview size) and only for steps with step / total ≥ `previewMinFraction` (VideoPreviewPolicy).
        public var previewShortSide: Int?
        public var previewMinFraction: Double?

        enum CodingKeys: String, CodingKey {
            case jobID = "job_id", modelDir = "model_dir", taehvPath = "taehv_path", prompt, negativePrompt = "negative_prompt"
            case width, height, numFrames = "num_frames", fps, steps, seed, memoryLimitBytes = "memory_limit_bytes", preview
            case modelKind = "model_kind", gemmaDir = "gemma_dir", audio
            case previewShortSide = "preview_short_side", previewMinFraction = "preview_min_fraction"
        }

        public init(jobID: String, modelDir: String, taehvPath: String?, prompt: String, negativePrompt: String? = nil, width: Int,
                    height: Int, numFrames: Int, fps: Int, steps: Int = 3, seed: Int64, memoryLimitBytes: UInt64, preview: Bool = true) {
            self.jobID = jobID
            self.modelDir = modelDir
            self.taehvPath = taehvPath
            self.prompt = prompt
            self.negativePrompt = negativePrompt
            self.width = width
            self.height = height
            self.numFrames = numFrames
            self.fps = fps
            self.steps = steps
            self.seed = seed
            self.memoryLimitBytes = memoryLimitBytes
            self.preview = preview
        }
    }

    /// One server event (protocol.py).
    public enum Event: Sendable, Equatable {
        case progress(stage: String, step: Int, total: Int)
        case preview(frameIndex: Int, frames: Int, width: Int, height: Int, jpeg: Data, step: Int, total: Int)
        case framesReady(count: Int, width: Int, height: Int, fps: Int)
        case error(code: String)
        case end(status: String, metrics: [String: Double])
    }

    public struct Health: Decodable, Sendable {
        public var ok: Bool
        public var version: String
        public var mlxVersion: String?
        enum CodingKeys: String, CodingKey { case ok, version, mlxVersion = "mlx_version" }
    }

    public func health(timeout: TimeInterval = 5) async throws -> Health {
        let (st, body) = try await http.fetch(method: "GET", path: "/health", body: nil, timeout: timeout)
        guard st == 200 else { throw AntiChatError.engine("video.health", "HTTP \(st)") }
        return try JSONDecoder().decode(Health.self, from: body)
    }

    public func submit(_ job: Job) async throws {
        let (st, body) = try await http.fetch(method: "POST", path: "/v1/video/jobs", body: try JSONEncoder().encode(job), timeout: 30)
        guard st == 202 else {
            let code = ((try? JSONSerialization.jsonObject(with: body)) as? [String: Any])?["error"] as? String ?? "HTTP \(st)"
            throw AntiChatError.engine(st == 409 ? "video.busy" : "video.submitFailed", code)
        }
    }

    /// The job's events up to and including `end`. Reconnects (`Last-Event-ID`) up to `reconnects` times when the
    /// stream drops before `end`.
    public func events(_ jobID: String, reconnects: Int = 3) -> AsyncThrowingStream<Event, Error> {
        AsyncThrowingStream { cont in
            let task = Task {
                var lastID: Int?
                var left = reconnects
                while !Task.isCancelled {
                    do {
                        var headers = ["Accept": "text/event-stream"]
                        if let lastID { headers["Last-Event-ID"] = String(lastID) }
                        let r = try await http.send(method: "GET", path: "/v1/video/jobs/\(jobID)/events", body: nil, headers: headers)
                        guard r.status == 200 else { throw AntiChatError.engine("video.events", "HTTP \(r.status)") }
                        for try await e in r.body.events {
                            if let id = e.id.flatMap({ Int($0) }) { lastID = id }
                            guard let ev = Self.parse(event: e.event ?? "message", data: e.data) else { continue }
                            cont.yield(ev)
                            if case .end = ev {
                                cont.finish()
                                return
                            }
                        }
                        throw UnixHTTPError.closed
                    } catch {
                        if Task.isCancelled { break }
                        left -= 1
                        if left < 0 {
                            cont.finish(throwing: error)
                            return
                        }
                        try? await Task.sleep(for: .milliseconds(100))
                    }
                }
                cont.finish(throwing: CancellationError())
            }
            cont.onTermination = { _ in task.cancel() }
        }
    }

    /// Parses one SSE event of protocol.py (unknown kinds → nil).
    public static func parse(event: String, data: String) -> Event? {
        guard let o = (try? JSONSerialization.jsonObject(with: Data(data.utf8))) as? [String: Any] else { return nil }
        func i(_ k: String) -> Int { (o[k] as? NSNumber)?.intValue ?? 0 }
        switch event {
        case "progress": return .progress(stage: o["stage"] as? String ?? "", step: i("step"), total: i("total"))
        case "preview":
            guard let b64 = o["jpeg_b64"] as? String, let jpeg = Data(base64Encoded: b64) else { return nil }
            return .preview(frameIndex: i("frame_index"), frames: i("frames"), width: i("width"), height: i("height"), jpeg: jpeg,
                            step: i("step"), total: i("total"))
        case "frames_ready": return .framesReady(count: i("count"), width: i("width"), height: i("height"), fps: i("fps"))
        case "error": return .error(code: o["code"] as? String ?? "unknown")
        case "end":
            var m: [String: Double] = [:]
            for (k, v) in (o["metrics"] as? [String: Any]) ?? [:] { if let n = v as? NSNumber { m[k] = n.doubleValue } }
            return .end(status: o["status"] as? String ?? "failed", metrics: m)
        default: return nil
        }
    }

    /// `GET …/frames` → RGBA8 frames (width × height × 4 bytes each), in memory.
    public func frames(_ jobID: String, start: Int = 0, count: Int, width: Int, height: Int) async throws -> [Data] {
        let (st, body) = try await http.fetch(method: "GET", path: "/v1/video/jobs/\(jobID)/frames?start=\(start)&count=\(count)",
                                              body: nil, timeout: 120)
        guard st == 200 else { throw AntiChatError.engine("video.frames", "HTTP \(st)") }
        return try Self.splitFrames(body, frameBytes: width * height * 4)
    }

    /// M5.T07: `GET …/audio` → the sound track (float32 LE interleaved stereo, 48 kHz), in memory; nil when the job has none.
    public func audio(_ jobID: String) async throws -> Data? {
        let (st, body) = try await http.fetch(method: "GET", path: "/v1/video/jobs/\(jobID)/audio", body: nil, timeout: 60)
        if st == 404 { return nil }
        guard st == 200, body.count % 8 == 0 else { throw AntiChatError.engine("video.audio", "HTTP \(st) \(body.count) B") }
        return body
    }

    /// Length-prefixed (4-byte big-endian) frames; each must be exactly `frameBytes`.
    public static func splitFrames(_ body: Data, frameBytes: Int) throws -> [Data] {
        var out: [Data] = []
        var off = body.startIndex
        while off < body.endIndex {
            guard body.endIndex - off >= 4 else { throw AntiChatError.engine("video.frames", "truncated length") }
            let n = body[off..<off + 4].reduce(0) { ($0 << 8) | Int($1) }
            off += 4
            guard n == frameBytes, body.endIndex - off >= n else { throw AntiChatError.engine("video.frames", "bad frame size \(n)") }
            out.append(body.subdata(in: off..<off + n))
            off += n
        }
        return out
    }

    public func cancel(_ jobID: String) async throws { try await control(jobID, "cancel") }
    public func pause(_ jobID: String) async throws { try await control(jobID, "pause") }
    public func resume(_ jobID: String) async throws { try await control(jobID, "resume") }
    public func release(_ jobID: String) async throws { try await control(jobID, "release") }

    func control(_ jobID: String, _ action: String) async throws {
        let (st, _) = try await http.fetch(method: "POST", path: "/v1/video/jobs/\(jobID)/\(action)", body: nil, timeout: 5)
        guard st == 200 else { throw AntiChatError.engine("video.\(action)", "HTTP \(st)") }
    }

    public func shutdown() async throws {
        _ = try await http.fetch(method: "POST", path: "/v1/shutdown", body: nil, timeout: 3)
    }
}
