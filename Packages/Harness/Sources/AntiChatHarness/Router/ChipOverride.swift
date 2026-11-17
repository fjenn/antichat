// M2.T22 step 4 (R-235 AC1): a tool chip from the composer's + menu forces its tool. While the chip is present every
// turn's first step goes out with `tool_choice` = that function (OpenAI's "required(tool)" form; llama-server gets
// `required` over that one tool, MLX a grammar that opens the call at once), so a model that would have answered in
// text calls the tool. Later steps of the same turn are `auto` again (the loop can answer with the result).
import AntiChatEngineProtocol
import Foundation

public enum ChipOverride {
    /// Composer menu item id → tool name (`ComposerMenuItem.id`: the actions `image`, `video`, `web`, `file`, and
    /// `tool:<name>` for a registry tool).
    public static func toolName(forChip id: String) -> String? {
        switch id {
        case "image": "create_image"
        case "video": "create_video"
        case "web": "web_search"
        case "readUrl": "read_url"  // M7.T03 step 4: the "Read this URL" suggestion chip
        case "file": "create_document"  // the general file tool; its wrong-format check redirects to the others
        default: id.hasPrefix("tool:") ? String(id.dropFirst(5)) : nil
        }
    }

    /// The tool the chips force: the first-picked chip whose tool is offered (nil = none).
    public static func forcedTool(chips: [String], offered: [ToolSchema]) -> String? {
        let names = Set(offered.map(\.name))
        return chips.lazy.compactMap(toolName(forChip:)).first { names.contains($0) }
    }
}
