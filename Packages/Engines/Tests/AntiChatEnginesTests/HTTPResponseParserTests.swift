import Foundation
import Testing
@testable import AntiChatEngines

@Suite struct HTTPResponseParserTests {
    @Test func contentLength() throws {
        let p = HTTPResponseParser()
        let out = try p.feed(Data("HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\nhello".utf8))
        #expect(out.head?.status == 200)
        #expect(String(decoding: out.body, as: UTF8.self) == "hello")
        #expect(out.finished)
    }

    @Test func chunkedAcrossFeeds() throws {
        let p = HTTPResponseParser()
        let raw = "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n5\r\ndata:\r\n3\r\n ab\r\n0\r\n\r\n"
        var body: [UInt8] = []
        var done = false
        var status: Int?
        for b in raw.utf8 {  // byte by byte: worst-case fragmentation
            let o = try p.feed(Data([b]))
            if let h = o.head { status = h.status }
            body += o.body
            done = done || o.finished
        }
        #expect(status == 200)
        #expect(String(decoding: body, as: UTF8.self) == "data: ab")
        #expect(done)
    }

    @Test func identityUntilClose() throws {
        let p = HTTPResponseParser()
        let o = try p.feed(Data("HTTP/1.1 401 Unauthorized\r\n\r\nno".utf8))
        #expect(o.head?.status == 401)
        #expect(String(decoding: o.body, as: UTF8.self) == "no")
        #expect(p.finish().finished)
    }

    @Test func truncatedBodyIsReported() throws {
        let p = HTTPResponseParser()
        _ = try p.feed(Data("HTTP/1.1 200 OK\r\nContent-Length: 10\r\n\r\nhel".utf8))
        #expect(p.finish().truncated)
        let q = HTTPResponseParser()
        _ = try q.feed(Data("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nda".utf8))
        #expect(q.finish().truncated)
    }

    @Test func negativeLengthsAreMalformed() {
        #expect(throws: UnixHTTPError.self) {
            _ = try HTTPResponseParser().feed(Data("HTTP/1.1 200 OK\r\nContent-Length: -5\r\n\r\nx".utf8))
        }
        #expect(throws: UnixHTTPError.self) {
            _ = try HTTPResponseParser().feed(Data("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n-1\r\nx".utf8))
        }
    }
}
