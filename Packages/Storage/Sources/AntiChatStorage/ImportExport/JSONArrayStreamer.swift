// M8.T06 step 4 (R-092 AC2): the elements of a top-level JSON array, one at a time, without the whole file in
// memory. A byte scanner tracks string / bracket state over 4 MB reads (inside a string it jumps to the next quote
// with memchr, so the export's text is skipped at memory speed); each depth-1 element's bytes are handed to
// JSONSerialization on their own (peak memory ≈ the largest conversation, not the export). A top-level object is
// yielded whole (a single-conversation export).
import Foundation

public struct JSONArrayStreamer {
    public static let defaultReadSize = 4 << 20

    public let url: URL
    public let readSize: Int
    public init(url: URL, readSize: Int = JSONArrayStreamer.defaultReadSize) {
        self.url = url
        self.readSize = max(1, readSize)
    }

    public var totalBytes: Int64 {
        Int64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
    }

    /// Calls `body(elementBytes, bytesConsumed)` for each element; `body` returns false to stop.
    public func forEach(_ body: (Data, Int64) throws -> Bool) throws {
        let fh = try FileHandle(forReadingFrom: url)
        defer { try? fh.close() }
        var depth = 0
        var inString = false
        var backslashes = 0  // run of `\` just before the current byte inside a string (carried across reads)
        var topIsObject = false
        var started = false
        var element = Data()
        var collecting = false
        var consumed: Int64 = 0
        var stop = false
        // Each 4 MB read is an autoreleased NSData: without a pool per read a 1 GB file kept every chunk alive until
        // the caller's pool drained (+1 GB RSS in AT-092).
        while !stop, let chunk = try autoreleasepool(invoking: { try fh.read(upToCount: readSize) }), !chunk.isEmpty {
            try chunk.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                let p = raw.bindMemory(to: UInt8.self)
                let n = p.count
                var segStart = collecting ? 0 : -1
                var i = 0
                while i < n {
                    if inString {
                        // the next quote; a quote preceded by an odd run of backslashes is escaped
                        guard let q = memchr(p.baseAddress! + i, 0x22, n - i) else {
                            var k = n - 1
                            var run = 0
                            while k >= i, p[k] == 0x5C { run += 1; k -= 1 }
                            backslashes = (k < i) ? backslashes + run : run
                            i = n
                            break
                        }
                        let qi = p.baseAddress!.distance(to: q.assumingMemoryBound(to: UInt8.self))
                        var k = qi - 1
                        var run = 0
                        while k >= i, p[k] == 0x5C { run += 1; k -= 1 }
                        if k < i { run += backslashes }
                        backslashes = 0
                        i = qi + 1
                        if run % 2 == 0 { inString = false }
                        continue
                    }
                    let b = p[i]
                    switch b {
                    case 0x22:
                        inString = true
                        backslashes = 0
                    case 0x5B, 0x7B:  // [ {
                        if !started {
                            started = true
                            topIsObject = b == 0x7B
                            if topIsObject { collecting = true; segStart = i }
                        } else if depth == 1, !topIsObject {
                            collecting = true
                            segStart = i
                        }
                        depth += 1
                    case 0x5D, 0x7D:  // ] }
                        depth -= 1
                        if collecting, topIsObject ? depth == 0 : depth == 1 {
                            element.append(p.baseAddress! + max(0, segStart), count: i - max(0, segStart) + 1)
                            collecting = false
                            segStart = -1
                            if try !body(element, consumed + Int64(i + 1)) { stop = true; return }
                            element.removeAll(keepingCapacity: true)
                        }
                    default:
                        break
                    }
                    i += 1
                }
                if collecting { element.append(p.baseAddress! + max(0, segStart), count: n - max(0, segStart)) }
            }
            consumed += Int64(chunk.count)
        }
    }
}
