// M6.T04 step 4 (R-271 AC2; blueprint C §C.6): the scan pages of one PDF, sequentially at `.utility`, as an
// `AsyncStream<OCRProgress>` (page n of N; the tile's `status.readingScan`). Paused between pages while a chat turn
// generates on T0/T1 (`OCRPause`, set by the conversation). Above 50 pages on T0 the `.fast` level is used.
// `OCRProgressRegistry` keeps, per attachment, the last page done in order (`files.stillReading` {page}, step 5).
import Foundation
import PDFKit
import Synchronization

public struct OCRProgress: Sendable, Equatable {
    /// Scan pages done / to do.
    public var done: Int
    public var total: Int
    /// The PDF page just recognised (1-based) and its Markdown.
    public var page: Int
    public var markdown: String
}

/// "A chat turn is generating on a constrained tier": OCR waits between pages.
public final class OCRPause: Sendable {
    public static let shared = OCRPause()
    private let paused = Mutex(false)
    public init() {}
    public var isPaused: Bool { paused.withLock { $0 } }
    public func set(_ on: Bool) { paused.withLock { $0 = on } }
}

/// Per attachment: the highest page p such that pages 1…p are read (text layer or OCR), while OCR runs.
public final class OCRProgressRegistry: Sendable {
    public static let shared = OCRProgressRegistry()
    private let pages = Mutex<[String: Int]>([:])
    public init() {}
    public func set(_ attachmentID: String, page: Int?) { pages.withLock { $0[attachmentID] = page } }
    public func page(_ attachmentID: String) -> Int? { pages.withLock { $0[attachmentID] } }
}

public struct OCRQueue: Sendable {
    public let ocr: VisionOCR
    public let pause: OCRPause
    /// Poll interval while paused.
    public var pausePoll: Duration = .milliseconds(200)

    public init(ocr: VisionOCR = VisionOCR(), pause: OCRPause = .shared) {
        self.ocr = ocr
        self.pause = pause
    }

    /// T0 above 50 pages → `.fast` (step 4).
    public static func level(tier: String, pages: Int) -> VisionOCR.Level { tier == "T0" && pages > 50 ? .fast : .accurate }

    /// Recognises `pages` (1-based) of the PDF at `url` in order. The stream ends after the last page or on cancel.
    public func run(url: URL, pages: [Int], level: VisionOCR.Level = .accurate) -> AsyncStream<OCRProgress> {
        let (stream, sink) = AsyncStream<OCRProgress>.makeStream()
        let task = Task(priority: .utility) {
            defer { sink.finish() }
            guard let pdf = PDFDocument(url: url) else { return }
            for (i, p) in pages.enumerated() {
                while pause.isPaused, !Task.isCancelled { try? await Task.sleep(for: pausePoll) }
                if Task.isCancelled { return }
                let md: String
                if let page = pdf.page(at: p - 1), let image = VisionOCR.render(page) {
                    md = await ocr.recognize(image, level: level)
                } else {
                    md = ""
                }
                sink.yield(OCRProgress(done: i + 1, total: pages.count, page: p, markdown: md))
            }
        }
        sink.onTermination = { _ in task.cancel() }
        return stream
    }
}
