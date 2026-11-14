// M2.T03 (R-209 AC5): the turn a piece of work belongs to, as a task-local. TurnController sets it around tool
// calls; NetworkGate.tag stamps it on every request (`ac.turn`), so the turn's globe chip lists exactly the hosts
// contacted inside that turn. Lives here because Harness (sets it) and Network (reads it) share only Foundation.
import Foundation

public enum TurnContext {
    @TaskLocal public static var requestID: String?
    /// M6.T08: the chat a tool call runs for (per-chat tools such as `query_data` read their chat's DuckDB store).
    @TaskLocal public static var chatID: String?
    /// M4.T07 step 2: the composer's aspect chip ("2:3") while Create image is present; it overrides the `aspect`
    /// the model wrote into `create_image` (R-030 AC2). nil = the model's choice.
    @TaskLocal public static var imageAspect: String?
    /// M4.T08: the id of the tool call running now (an image job is tied to its call's card).
    @TaskLocal public static var toolCallID: String?
    /// M4.T13: the user asked for the best-quality edit this turn (img-edit where installed; else the quick model).
    @TaskLocal public static var imageEditBest = false
    /// AT-273: the newest user message of the turn (the file format it asks for; file-out normalisation).
    @TaskLocal public static var userText: String?
}
