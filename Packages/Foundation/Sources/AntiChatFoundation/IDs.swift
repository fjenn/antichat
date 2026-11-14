// Typed identifiers (architecture.md §2 AntiChatFoundation "IDs"). A phantom tag keeps a ChatID from being
// passed where a MessageID is expected; the wire/DB form is the bare UUID (single-value Codable).
import Foundation

public struct TypedID<Tag>: Hashable, Codable, Sendable, CustomStringConvertible, Comparable {
    public let raw: UUID

    public init(_ raw: UUID = UUID()) { self.raw = raw }

    public init?(uuidString: String) {
        guard let u = UUID(uuidString: uuidString) else { return nil }
        raw = u
    }

    public var uuidString: String { raw.uuidString }
    public var description: String { raw.uuidString }

    public static func < (a: TypedID, b: TypedID) -> Bool { a.raw.uuidString < b.raw.uuidString }

    public init(from decoder: any Decoder) throws {
        raw = try decoder.singleValueContainer().decode(UUID.self)
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(raw)
    }
}

public enum ChatTag {}
public enum MessageTag {}
public enum ProjectTag {}
/// One engine request (chat turn, warmup, job); `ChatRequest.requestID` on the wire.
public enum RequestTag {}
/// One app ↔ helper conversation context (`ChatRequest.sessionID`).
public enum EngineSessionTag {}

public typealias ChatID = TypedID<ChatTag>
public typealias MessageID = TypedID<MessageTag>
public typealias ProjectID = TypedID<ProjectTag>
public typealias RequestID = TypedID<RequestTag>
public typealias EngineSessionID = TypedID<EngineSessionTag>
