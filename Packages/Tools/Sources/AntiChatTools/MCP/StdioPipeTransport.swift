// M7.T06 step 9 (R-258 interop) and the M11 local-server groundwork (M7.T09 moved, D-026): MCP's stdio transport
// (newline-delimited JSON-RPC) over two FileHandles of a process someone else started. This file launches nothing:
// the caller owns the process (InteropTests today; M11's sandboxed ProcessLauncher later).
import Foundation
import Logging
import MCP

public actor StdioPipeTransport: Transport {
    public nonisolated let logger = Logging.Logger(label: "app.antichat.mcp.stdio", factory: { _ in SwiftLogNoOpLogHandler() })
    private let input: FileHandle   // the server's stdout
    private let output: FileHandle  // the server's stdin
    private var connected = false
    private let stream: AsyncThrowingStream<Data, any Swift.Error>
    private let continuation: AsyncThrowingStream<Data, any Swift.Error>.Continuation

    public init(readingFrom input: FileHandle, writingTo output: FileHandle) {
        self.input = input
        self.output = output
        (stream, continuation) = AsyncThrowingStream.makeStream()
    }

    public func connect() async throws {
        guard !connected else { return }
        connected = true
        // readabilityHandler (dispatch, non-blocking): one AsyncBytes reader per pipe would park a pool thread each.
        let continuation = continuation
        let buffer = LineBuffer()
        input.readabilityHandler = { h in
            let d = h.availableData
            if d.isEmpty { h.readabilityHandler = nil; continuation.finish(); return }
            for line in buffer.append(d) where !line.isEmpty { continuation.yield(line) }
        }
    }

    public func disconnect() async {
        input.readabilityHandler = nil
        connected = false
        continuation.finish()
    }

    public func send(_ data: Data) async throws {
        var line = data
        line.append(0x0A)
        try output.write(contentsOf: line)
    }

    public func receive() -> AsyncThrowingStream<Data, any Swift.Error> { stream }
}

/// Splits a byte stream into newline-terminated lines.
final class LineBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var pending = Data()
    func append(_ d: Data) -> [Data] {
        lock.withLock {
            pending.append(d)
            var out: [Data] = []
            while let i = pending.firstIndex(of: 0x0A) {
                out.append(pending[pending.startIndex..<i])
                pending.removeSubrange(pending.startIndex...i)
            }
            return out
        }
    }
}
