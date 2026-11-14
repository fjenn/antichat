// Closed value sets of the v1 schema (CHECK constraints in Migrations.swift, architecture §5.1).
import GRDB

public enum ChatMode: String, Codable, Sendable, CaseIterable, DatabaseValueConvertible { case normal, evil }

public enum TitleState: String, Codable, Sendable, CaseIterable, DatabaseValueConvertible { case pending, auto, user }

/// Where a chat came from: made here, or imported (G-058 / R-296).
public enum ChatSource: String, Codable, Sendable, CaseIterable, DatabaseValueConvertible {
    case local, chatgpt, claude, antichat
}

public enum MessageRole: String, Codable, Sendable, CaseIterable, DatabaseValueConvertible {
    case user, assistant, tool
    case systemNote = "system_note"
}

public enum MessageStatus: String, Codable, Sendable, CaseIterable, DatabaseValueConvertible {
    case pending, streaming, done, interrupted, error
}

public enum PartKind: String, Codable, Sendable, CaseIterable, DatabaseValueConvertible {
    case text, reasoning, image, file, audio, citation, activity
    case toolCall = "tool_call"
    case toolResult = "tool_result"
}

public enum FeedbackKind: String, Codable, Sendable, CaseIterable, DatabaseValueConvertible {
    case liked, disliked, refused, report
}

public enum BlobOrigin: String, Codable, Sendable, CaseIterable, DatabaseValueConvertible {
    case upload, generated, `import`
    /// M3.T03: a dictation's audio (Settings → Voice → Recent recordings).
    case recording
}

public enum OCRState: String, Codable, Sendable, CaseIterable, DatabaseValueConvertible { case none, pending, done, failed }

public enum ExcerptPolicy: String, Codable, Sendable, CaseIterable, DatabaseValueConvertible { case whole, excerpt }

/// `attachment.extract_state` (v14, M6.T01): where a file attachment's text extraction stands.
public enum ExtractState: String, Codable, Sendable, CaseIterable, DatabaseValueConvertible {
    case none, reading, ready, failed, encrypted, unsupported
}

public enum MediaJobState: String, Codable, Sendable, CaseIterable, DatabaseValueConvertible {
    case queued, running, done, blocked, failed, cancelled, lost
}

/// Import notice stored on `chat.import_notice`.
public enum ImportNotice: String, Codable, Sendable, DatabaseValueConvertible {
    /// The export had no parent ids, so the chat was imported as one linear path (M0.T11 fallback 1).
    case flattenedNoParentIds = "flattened_no_parent_ids"
}
