// M2.T22 (R-235 AC1/AC2; G-013; P-shell-13): the pre-router's output for one turn, handed to the TurnController
// before the request is built. Routes are the router-300 label scheme (fixtures/prompts/router-300.jsonl): seven
// intents plus `chat`. Scores only EXPOSE and FORCE tools; they never block, rewrite or refuse a request (R-241).
import AntiChatEngineProtocol
import Foundation

public enum Route: String, Codable, Sendable, CaseIterable, Comparable {
    case imageCreate = "image_create", imageEdit = "image_edit", videoCreate = "video_create",
         videoFromImage = "video_from_image", webNeeded = "web_needed", fileOutput = "file_output",
         memoryWrite = "memory_write", chat

    /// The seven scored intents (R-235 AC2).
    public static let intents: [Route] = allCases.filter { $0 != .chat }

    /// The tools a route exposes (antichat-tools-200 names; a name absent from the registry is skipped).
    public var tools: [String] {
        switch self {
        case .imageCreate, .imageEdit: ["create_image"]
        case .videoCreate, .videoFromImage: ["create_video"]
        case .webNeeded: ["web_search"]
        case .fileOutput: ["create_file"]
        case .memoryWrite: ["memory_write"]
        case .chat: []
        }
    }

    public var isImage: Bool { self == .imageCreate || self == .imageEdit }
    public var isVideo: Bool { self == .videoCreate || self == .videoFromImage }
    public var isMedia: Bool { isImage || isVideo }

    public static func < (a: Route, b: Route) -> Bool { a.rawValue < b.rawValue }
}

/// Per-route thresholds on the margin `score − chat score` (fitted by `tools/router/fit.py`, M2.T23): `low` exposes the route's tools in the
/// pruned set; `high` is "confident" (the fallback intent check's trigger).
public struct RouteThreshold: Codable, Sendable, Hashable {
    public var low: Float
    public var high: Float
    public init(low: Float, high: Float) {
        self.low = low
        self.high = high
    }
}

public struct RouteDecision: Sendable, Hashable {
    /// Cosine top-k means per route (all seven intents and `chat`); empty when nothing was scored (no embed model,
    /// pure conversation, router off).
    public var scores: [Route: Float]
    /// The intent whose margin over chat reached its `low` threshold by the most (nil = chat).
    public var top: Route?
    /// `top` reached its `high` threshold.
    public var confident: Bool
    /// A media `top` is backed by the request's words or its attached image (`MediumCue.confirmsMedia`). An
    /// unconfirmed media route still exposes its tool, but never replaces the reply with an install card and never
    /// forces the tool (InstallCardPolicy, FallbackIntentCheck). Always true for a non-media top.
    public var mediaConfirmed: Bool = true
    /// A chip's tool: sent with `tool_choice` = that function on every step until it was called (R-235 AC1).
    public var forcedTool: String?
    /// The tools the model sees this turn (≤ 4 on T0–T2, ToolPruner).
    public var toolsToExpose: [ToolSchema]
    /// Why the scores are empty (diagnostics).
    public var skipped: Skipped?
    /// M7.T14: the scored routes' tools, best first (ToolPruner.routedTools; ToolSelector's intent leg). Empty when
    /// nothing was scored.
    public var routedTools: [String] = []

    public enum Skipped: String, Sendable, Hashable { case disabled, conversational, noEmbedder, notReady, failed, timedOut }

    public init(scores: [Route: Float] = [:], top: Route? = nil, confident: Bool = false, mediaConfirmed: Bool = true,
                forcedTool: String? = nil, toolsToExpose: [ToolSchema] = [], skipped: Skipped? = nil) {
        self.scores = scores
        self.top = top
        self.confident = confident
        self.mediaConfirmed = mediaConfirmed
        self.forcedTool = forcedTool
        self.toolsToExpose = toolsToExpose
        self.skipped = skipped
    }

    /// The `tool_choice` of the first step: the forced function, else auto (nil when no tools are exposed).
    public var toolChoice: ToolChoice? {
        if let forcedTool { return .function(forcedTool) }
        return toolsToExpose.isEmpty ? nil : .auto
    }
}
