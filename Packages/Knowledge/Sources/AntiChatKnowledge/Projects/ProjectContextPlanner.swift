// M8.T05 step 1 (R-245 AC1/AC2): a project's files go into a chat whole while they fit 30 % of the model's context,
// otherwise per-turn retrieval (ProjectRetriever). The heuristic is our own (P-media-01 residual: Claude's "switch to
// retrieval when it gets big" behaviour, reference only). Re-evaluated on every send (files may finish indexing).
// Rollback `ff.projectRetrieval` off: whole files up to the context (80 % of it), the rest cut with a notice.
import AntiChatFoundation
import AntiChatStorage
import Foundation
import GRDB

public struct ProjectContextPlan: Sendable, Equatable {
    public enum Mode: String, Sendable, Equatable { case none, whole, retrieval }
    public var mode: Mode
    /// Σ text_tokens of the project's ready files.
    public var totalTokens: Int
    /// floor(0.30 × context).
    public var budget: Int
    /// The ready files (whole: in this order), oldest first.
    public var files: [ProjectFile]
    /// `ff.projectRetrieval` off and the files exceed the forced-whole cap: whole files were cut (notice).
    public var truncated = false
}

public enum ProjectContextPlanner {
    public static let wholeFraction = 0.30
    /// ff.projectRetrieval off: whole files up to this share of the context, the rest cut.
    public static let forcedWholeFraction = 0.80

    public static func budget(contextLength: Int) -> Int { Int((Double(contextLength) * wholeFraction).rounded(.down)) }

    /// The rule alone: `total ≤ budget` → whole.
    public static func mode(totalTokens: Int, contextLength: Int, retrievalEnabled: Bool = true) -> ProjectContextPlan.Mode {
        if totalTokens <= 0 { return .none }
        if !retrievalEnabled { return .whole }
        return totalTokens <= budget(contextLength: contextLength) ? .whole : .retrieval
    }

    public static func plan(projectID: String, contextLength: Int, db: Database,
                            retrievalEnabled: Bool = FeatureFlag.projectRetrieval.isEnabled()) throws -> ProjectContextPlan {
        let files = try ProjectFile.filter(Column("project_id") == projectID && Column("index_state") == ProjectIndexState.ready.rawValue)
            .order(Column("created_at"), Column("display_name")).fetchAll(db)
        let total = files.reduce(0) { $0 + max(0, $1.textTokens ?? 0) }
        let m = mode(totalTokens: total, contextLength: contextLength, retrievalEnabled: retrievalEnabled)
        let truncated = !retrievalEnabled && Double(total) > Double(contextLength) * forcedWholeFraction
        return ProjectContextPlan(mode: m, totalTokens: total, budget: budget(contextLength: contextLength), files: files,
                                  truncated: truncated)
    }

    /// The chat's project plan (nil outside a project or for a deleted one).
    public static func plan(chatID: String, contextLength: Int, db: Database,
                            retrievalEnabled: Bool = FeatureFlag.projectRetrieval.isEnabled()) throws -> (projectID: String, plan: ProjectContextPlan)? {
        guard let pid = try String.fetchOne(db, sql: """
            SELECT p.id FROM chat c JOIN project p ON p.id = c.project_id WHERE c.id = ? AND p.deleted_at IS NULL
            """, arguments: [chatID]) else { return nil }
        return (pid, try plan(projectID: pid, contextLength: contextLength, db: db, retrievalEnabled: retrievalEnabled))
    }
}
