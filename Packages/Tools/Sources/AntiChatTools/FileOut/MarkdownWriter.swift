// M6.T09 step 7: `create_document` with format "md" writes the Markdown as given: UTF-8 (no BOM), LF line ends, one
// trailing newline.
import Foundation

public enum MarkdownWriter {
    public static func render(_ spec: CreateDocumentSpec) -> Data {
        var text = spec.markdown.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        if !text.hasSuffix("\n") { text += "\n" }
        return Data(text.utf8)
    }
}
