// Which video frames the check evaluates (D-014, NFR-F9): every frame at a step of max(1, floor(fps / 2))
// (≥ 2 checked frames per second), plus the first and the last frame. Preview frames are always checked
// individually, whatever their index.
import CoreGraphics

/// One decoded video frame handed to `ChildSafetyCheck.evaluateVideo(frames:frameCount:fps:)`.
public struct VideoFrame: @unchecked Sendable {
    public let index: Int
    public let image: CGImage
    /// A preview shown during generation: always evaluated, sampled or not.
    public let isPreview: Bool

    public init(index: Int, image: CGImage, isPreview: Bool) {
        self.index = index
        self.image = image
        self.isPreview = isPreview
    }
}

package enum VideoFrameSampler {
    /// Sorted, de-duplicated frame indices to check for a clip of `frameCount` frames at `fps`.
    package static func sampleIndices(frameCount: Int, fps: Double) -> [Int] {
        guard frameCount > 0 else { return [] }
        let step = fps.isFinite ? max(1, Int((fps / 2).rounded(.down))) : 1
        var s = Set(stride(from: 0, to: frameCount, by: step))
        s.insert(0)
        s.insert(frameCount - 1)
        return s.sorted()
    }
}

extension ChildSafetyCheck {
    /// Frame indices a video of `frameCount` frames at `fps` must have checked (≥ 2 fps + first + last).
    public static func sampleIndices(frameCount: Int, fps: Double) -> [Int] {
        VideoFrameSampler.sampleIndices(frameCount: frameCount, fps: fps)
    }

    /// Evaluates a video as its frames arrive: every sampled index and every preview frame. Blocks on the
    /// first blocked frame (and stops consuming). Fails closed: a stream error, cancellation, or a stream
    /// that ends before every sampled index was checked ⇒ `.block`; so does an empty clip.
    public func evaluateVideo(frames: AsyncThrowingStream<VideoFrame, Error>, frameCount: Int, fps: Double) async -> Verdict {
        var pending = Set(Self.sampleIndices(frameCount: frameCount, fps: fps))
        guard !pending.isEmpty else { return .block }
        do {
            for try await frame in frames {
                let sampled = pending.remove(frame.index) != nil
                guard sampled || frame.isPreview else { continue }
                if await evaluate(image: frame.image) == .block { return .block }
            }
        } catch {
            return .block
        }
        if Task.isCancelled { return .block }
        return pending.isEmpty ? .allow : .block
    }
}
