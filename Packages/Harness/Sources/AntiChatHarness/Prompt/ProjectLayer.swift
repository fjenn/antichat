// M8.T04 step 4 (R-064 AC2): the project's instructions in the stable prompt layer, right after the user's custom
// instructions (personalization) and before the memory snapshot. The text is the one frozen at the chat's first send
// (`ProjectStore.frozenInstructions`), so editing a project's instructions changes new chats only (R-243 rule).
// It is text the user chose: rendered verbatim under one heading, no added clause.
public enum ProjectLayer {
    public static let heading = "## Project instructions"

    public static func render(_ instructions: String) -> String {
        let t = PromptText.normalize(instructions)
        return t.isEmpty ? "" : "\(heading)\n\(t)"
    }
}
