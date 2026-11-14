// UUIDv7 ids for every storage row keyed by text (architecture §5.1: "id (UUIDv7 text)"), RFC 9562 §5.7.
// Lowercase canonical text so ids sort by creation time (48-bit ms timestamp first, then a 12-bit
// per-millisecond sequence in `rand_a`, so ids made in the same millisecond still sort in creation order).
// Plain `String` on purpose: M1.T05 owns the typed ids in AntiChatFoundation/IDs.swift (M1-plan W1 note).
import Foundation
import Synchronization

public enum StorageID {
    private struct Clock { var lastMillis: UInt64 = 0; var sequence: UInt16 = 0 }
    private static let clock = Mutex(Clock())

    /// A new UUIDv7, lowercase text.
    public static func make(now: Date = Date()) -> String {
        uuid(now: now).uuidString.lowercased()
    }

    static func uuid(now: Date) -> UUID {
        let wall = UInt64(max(0, now.timeIntervalSince1970 * 1000))
        let (millis, sequence) = clock.withLock { state -> (UInt64, UInt16) in
            if wall > state.lastMillis {
                state.lastMillis = wall
                state.sequence = UInt16.random(in: 0..<0x400)  // leave headroom before the 12-bit wrap
            } else if state.sequence < 0x0FFF {
                state.sequence += 1
            } else {
                state.lastMillis += 1  // sequence exhausted: borrow the next millisecond (monotonic)
                state.sequence = 0
            }
            return (state.lastMillis, state.sequence)
        }
        var bytes = [UInt8](repeating: 0, count: 16)
        for i in 0..<6 { bytes[i] = UInt8(truncatingIfNeeded: millis >> (8 * (5 - UInt64(i)))) }
        bytes[6] = 0x70 | UInt8(truncatingIfNeeded: sequence >> 8)  // version 7
        bytes[7] = UInt8(truncatingIfNeeded: sequence)
        var random = SystemRandomNumberGenerator()
        for i in 8..<16 { bytes[i] = UInt8.random(in: 0...255, using: &random) }
        bytes[8] = 0x80 | (bytes[8] & 0x3F)  // RFC 9562 variant
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }
}
