// perf/t4-video (NFR-VID1): the final check of a video job runs while the runtime is still decoding. The engine
// opens one `VideoCheckStream` per job (`MediaJobOutputs.beginVideoCheck`) when the decode starts, hands it every
// frame as it arrives from the runtime (in memory, nothing written), and closes it with
// `MediaJobOutputs.finishVideo` once the runtime reported `frames_ready`. The gate (`MediaOutputGate.checkVideo`,
// called by MediaJobRunner only) consumes the sampled frames (≥ 2 fps + first + last, NFR-F9) as they come, so the
// detector work overlaps the decode instead of following it. The rules of D-006 / R-285 are unchanged: every sampled
// frame is checked, the verdict is applied only when the whole clip is in (`finishVideo`), nothing is shown or
// written before the gate allowed it, and an incomplete or aborted stream never allows (the check fails closed).
import AntiChatEngineProtocol
import AntiChatFoundation
import CoreGraphics
import Foundation

public final class VideoCheckStream: @unchecked Sendable {
    public let frameCount: Int
    public let width: Int
    public let height: Int
    public let fps: Double
    let job: MediaJobID
    /// The indices the check must see (the gate checks exactly these; frames in between are only kept for the MP4).
    let sampled: Set<Int>
    /// The running check (started by the runner); its outcome is applied by `MediaJobRunner.finishVideo`.
    let check: Task<GateOutcome, Never>
    let startedAt: ContinuousClock.Instant

    private let lock = NSLock()
    private var frames: [Data?]
    private var received = 0
    private var closed = false
    private let cont: AsyncThrowingStream<MediaFrame, Error>.Continuation

    init(job: MediaJobID, frameCount: Int, width: Int, height: Int, fps: Double,
         start: (AsyncThrowingStream<MediaFrame, Error>) -> Task<GateOutcome, Never>) {
        self.job = job
        self.frameCount = frameCount
        self.width = width
        self.height = height
        self.fps = fps
        sampled = Set(MediaOutputGate.sampleIndices(frameCount: frameCount, fps: fps))
        frames = Array(repeating: nil, count: frameCount)
        let (stream, cont) = AsyncThrowingStream<MediaFrame, Error>.makeStream()
        self.cont = cont
        startedAt = .now
        check = start(stream)
    }

    /// Frames received so far (the next index the engine pulls; frames come in order).
    public var count: Int { lock.withLock { received } }

    /// Adds the next frames in order (RGBA8, `width × height × 4` bytes each). A wrong size, an out-of-range index or
    /// a frame after `close` ends the stream with an error: the check then blocks (fail closed) and `finishVideo`
    /// throws. Sampled frames go to the check right away.
    public func append(_ batch: [Data]) throws {
        let frameBytes = width * height * 4
        for data in batch {
            let (index, ok): (Int, Bool) = lock.withLock {
                guard !closed, received < frameCount, data.count == frameBytes else { return (received, false) }
                frames[received] = data
                received += 1
                return (received - 1, true)
            }
            guard ok else {
                abort()
                throw AntiChatError.engine("video.badFrames", "frame \(index) of \(frameCount) (\(data.count) B)")
            }
            guard sampled.contains(index) else { continue }
            guard let image = MediaJobRunner.cgImage(rgba: data, width: width, height: height) else {
                abort()
                throw AntiChatError.engine("video.badFrames", "frame \(index)")
            }
            cont.yield(MediaFrame(index: index, image: image, isPreview: false))
        }
    }

    /// No more frames will come. Returns all frames when the clip is complete, else nil (the check still ends, and
    /// blocks: its stream ended before every sampled index arrived).
    func close() -> [Data]? {
        let all: [Data]? = lock.withLock {
            closed = true
            guard received == frameCount else { return nil }
            return frames.compactMap { $0 }
        }
        cont.finish()
        return all
    }

    /// Stops the check (job cancelled, failed or withheld elsewhere): its stream ends with an error, so it can only
    /// block; nobody applies that outcome. Idempotent.
    public func abort() {
        lock.withLock {
            closed = true
            frames = []
        }
        cont.finish(throwing: CancellationError())
        check.cancel()
    }

    /// R2 review P2-1: a stream dropped without `close` / `abort` (an engine path that threw after taking it) still
    /// ends its check — a dropped continuation does not finish the stream by itself, and the check would wait forever
    /// holding the detectors. Ended with an error, so the check can only block; nobody applies that outcome.
    deinit {
        let open = lock.withLock { !closed }
        if open {
            cont.finish(throwing: CancellationError())
            check.cancel()
        }
    }
}
