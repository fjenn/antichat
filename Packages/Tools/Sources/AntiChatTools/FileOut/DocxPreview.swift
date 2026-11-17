// The side panel shows a .docx through the system's own reader (NSAttributedString, officeOpenXML). That reader takes
// a switched-OFF run property (`<w:b w:val="false"/>`, `<w:strike w:val="false"/>`: how the app's DOCX writer, and
// Word, spell "not bold" / "not struck through") as switched ON, so a whole letter came out bold, italic and struck
// through. `readableCopy` is a copy of the file without those off-switches (an absent switch is off as well).
import Foundation
import ZIPFoundation

public enum DocxPreview {
    static let offSwitch = #"<w:(b|bCs|i|iCs|strike|dstrike|caps|smallCaps|vanish|outline|shadow|emboss|imprint)\s+w:val="(false|0|off)"\s*/>"#

    /// `xml` without switched-off run properties.
    static func withoutOffSwitches(_ xml: String) -> String {
        xml.replacingOccurrences(of: offSwitch, with: "", options: .regularExpression)
    }

    /// A copy of `url` in `folder` for the system reader (nil when the file cannot be read as a zip). The caller
    /// removes it after reading.
    public static func readableCopy(of url: URL, in folder: URL) -> URL? {
        let copy = folder.appendingPathComponent("docpreview-\(UUID().uuidString).docx")
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: url, to: copy)
            let archive = try Archive(url: copy, accessMode: .update)
            for path in ["word/document.xml", "word/styles.xml"] {
                guard let entry = archive[path] else { continue }
                var data = Data()
                _ = try archive.extract(entry) { data.append($0) }
                guard let xml = String(data: data, encoding: .utf8) else { continue }
                let fixed = withoutOffSwitches(xml)
                guard fixed != xml else { continue }
                let out = Data(fixed.utf8)
                try archive.remove(entry)
                try archive.addEntry(with: path, type: .file, uncompressedSize: Int64(out.count), compressionMethod: .deflate) { position, size in
                    out.subdata(in: Int(position)..<Int(position) + size)
                }
            }
            return copy
        } catch {
            try? FileManager.default.removeItem(at: copy)
            return nil
        }
    }
}
