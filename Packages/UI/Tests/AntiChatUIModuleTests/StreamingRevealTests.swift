// StreamingRevealTests (M1.T09 step 2, IS-3): the reveal clock is independent of token arrival — bursts and stalls
// in the input become a steady per-frame reveal of whole words; Stop shows exactly the received text.
import Testing
@testable import AntiChatUI

@Suite(.isolatedSettings) struct StreamingRevealTests {
    @Test func revealsWholeWordsOnly() {
        var r = StreamingReveal()
        r.update(target: "Hello wor", finished: false)
        for _ in 0..<30 { r.tick(1.0 / 60) }
        #expect(r.shownText == "Hello")  // "wor" may still grow
        r.update(target: "Hello world ", finished: false)
        for _ in 0..<30 { r.tick(1.0 / 60) }
        #expect(r.shownText == "Hello world")
        r.update(target: "Hello world again", finished: true)
        for _ in 0..<30 { r.tick(1.0 / 60) }
        #expect(r.shownText == "Hello world again")
        #expect(r.isComplete)
    }

    /// A 600-character burst arriving in one frame is spread over ~`catchUp` seconds of frames, not shown at once.
    @Test func burstIsSpreadOverFrames() {
        var r = StreamingReveal()
        let words = (0..<120).map { "w\($0)" }.joined(separator: " ") + " "
        r.update(target: words, finished: false)
        var frames = 0
        var gap = 0
        var maxGap = 0
        while r.backlog > 1, frames < 600 {  // backlog 1 = the trailing space
            if r.tick(1.0 / 60) > 0 { gap = 0 } else { gap += 1; maxGap = max(maxGap, gap) }
            frames += 1
        }
        #expect(frames >= 12)  // ≥ 0.2 s at 60 Hz: not dumped in one frame
        #expect(frames <= 60)  // ≤ 1 s: the reveal never lags far behind the model
        // New words at least every 4th frame (≥ 15 Hz of new words; the 180 ms fade animates every frame between).
        #expect(maxGap <= 3)
    }

    /// Slow trickle (1 word / 100 ms): each word appears within a few frames of arriving.
    @Test func trickleKeepsUp() {
        var r = StreamingReveal()
        var text = ""
        var maxLagFrames = 0
        for i in 0..<20 {
            text += "word\(i) "
            r.update(target: text, finished: false)
            var lag = 0
            while r.backlog > 1, lag < 60 { r.tick(1.0 / 60); lag += 1 }  // backlog 1 = the trailing space
            maxLagFrames = max(maxLagFrames, lag)
            for _ in 0..<5 { r.tick(1.0 / 60) }
        }
        #expect(maxLagFrames <= 6)
    }

    @Test func stopRevealsEverything() {
        var r = StreamingReveal()
        r.update(target: "one two three four five six seven", finished: false)
        r.tick(1.0 / 60)
        r.update(target: "one two three four five six seven", finished: true)
        r.revealAll()
        #expect(r.shownText == "one two three four five six seven")
    }

    @Test func nonAppendRestartsAtCommonPrefix() {
        var r = StreamingReveal(revealed: "The answer is 42.", finished: true)
        r.update(target: "The answer is 41, actually.", finished: false)
        #expect(r.shownText == "The answer is ")
    }

    @Test func multibyteNeverSplit() {
        var r = StreamingReveal()
        r.update(target: "naïve café 😀 über ", finished: false)
        for _ in 0..<60 {
            r.tick(1.0 / 60)
            #expect(r.shownText.unicodeScalars.allSatisfy { $0 != "\u{FFFD}" })
        }
        #expect(r.shownText == "naïve café 😀 über")
    }
}
