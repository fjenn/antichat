// M6 review #13 (NFR-SEC5): untrusted content (documents, excerpts, OCR text, captions, sheet profiles) sits inside
// `<… untrusted="true">` wrappers in the prompt. A body that contains the wrapper's own closing tag would end the block
// early and put the rest outside it, so every closing tag of a wrapper kind inside a body is neutralised (`</document`
// → `&lt;/document`); the text stays readable to the model.
import Foundation

public enum UntrustedText {
    /// The wrapper elements the prompt layer uses for untrusted content.
    /// M7.T15: + the web results, MCP/Composio tool results and skill bodies (a page or server could otherwise end its block).
    public static let wrappers = ["document", "excerpt", "image_text", "image_description", "sheet_tables",
                                  "web_results", "tool_result", "skill", "skill_file"]
    private static let closing = try! NSRegularExpression(
        pattern: "<(\\s*/\\s*)(" + wrappers.joined(separator: "|") + ")(?![A-Za-z0-9_-])", options: [.caseInsensitive])

    /// M7.T16 review #7: a skill file or script output as untrusted context (`<skill_file … untrusted="true">`).
    public static func skillFile(skill: String, path: String, body: String) -> String {
        func attr(_ s: String) -> String {
            s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "\"", with: "&quot;")
                .replacingOccurrences(of: "<", with: "&lt;")
        }
        return "<skill_file skill=\"\(attr(skill))\" path=\"\(attr(path))\" untrusted=\"true\">\n\(neutralised(body))\n</skill_file>"
    }

    /// `body` with every closing tag of a wrapper element made inert.
    public static func neutralised(_ body: String) -> String {
        guard body.contains("<") else { return body }
        let ns = body as NSString
        return closing.stringByReplacingMatches(in: body, range: NSRange(location: 0, length: ns.length),
                                                withTemplate: "&lt;$1$2")
    }
}
