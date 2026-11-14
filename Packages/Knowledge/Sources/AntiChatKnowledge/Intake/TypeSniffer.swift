// M6.T01 step 2 (R-020 AC2; blueprint C §C.7): what a file really is, from its first bytes, not its name. A file
// whose extension disagrees with its magic (a HEIC named `.jpg`) is read as the magic type and flagged `isLying`
// (no error). Encrypted PDFs (`isEncrypted && isLocked`) and password-protected OOXML (an OLE file holding an
// `EncryptedPackage` stream) are flagged `isEncrypted`. Magic table: `%PDF-`, `PK\x03\x04` (+ the main part →
// docx/xlsx/pptx/epub), PNG, JPEG, HEIC (`ftyp` heic/heix/mif1/msf1/hevc), WebP, GIF, `{\rtf`, OLE (`Workbook`/`Book`
// stream → xls, else legacy doc/ppt = unsupported), WAV/MP3/M4A/AAC/FLAC, UTF-8/16 text.
import Foundation
import OsaurusVendored
import PDFKit
import UniformTypeIdentifiers

/// The file kinds intake knows (R-020 AC2 + XLS from R-272 AC1 / A-M6-10, + audio routed to transcription).
public enum AttachmentKind: String, Sendable, Codable, CaseIterable {
    case pdf, docx, xlsx, xls, csv, tsv, pptx, text, markdown, rtf, html, json, epub, code
    case png, jpeg, heic, webp, gif
    case wav, mp3, m4a, aac, flac
    /// Legacy binary Word / PowerPoint (OLE without a workbook): never read.
    case legacyOffice
    case unknown

    public var isImage: Bool { [.png, .jpeg, .heic, .webp, .gif].contains(self) }
    public var isAudio: Bool { [.wav, .mp3, .m4a, .aac, .flac].contains(self) }
    public var isSheet: Bool { [.xlsx, .xls, .csv, .tsv].contains(self) }
    /// Text-family kinds: the magic only says "text", the extension picks which.
    public var isTextFamily: Bool { [.text, .markdown, .json, .csv, .tsv, .code, .html].contains(self) }

    /// R-020 AC2 supported set (XLS read through libxls since M6.T07).
    public var isSupported: Bool { self != .legacyOffice && self != .unknown }

    /// The extension the media store uses for this kind (`…/Media/<yyyy>/<sha256>.<ext>`); nil = keep the original.
    public var canonicalExtension: String? {
        switch self {
        case .pdf, .docx, .xlsx, .xls, .csv, .tsv, .pptx, .rtf, .json, .epub, .png, .gif, .webp, .heic, .wav, .mp3,
             .m4a, .aac, .flac: rawValue
        case .jpeg: "jpg"
        case .markdown: "md"
        case .html: "html"
        case .text: "txt"
        case .code, .legacyOffice, .unknown: nil
        }
    }

    public var utType: UTType {
        switch self {
        case .pdf: .pdf
        case .docx: UTType("org.openxmlformats.wordprocessingml.document") ?? .data
        case .xlsx: UTType("org.openxmlformats.spreadsheetml.sheet") ?? .spreadsheet
        case .xls: UTType("com.microsoft.excel.xls") ?? .spreadsheet
        case .pptx: UTType("org.openxmlformats.presentationml.presentation") ?? .presentation
        case .csv: .commaSeparatedText
        case .tsv: .tabSeparatedText
        case .text: .plainText
        case .markdown: UTType("net.daringfireball.markdown") ?? .plainText
        case .rtf: .rtf
        case .html: .html
        case .json: .json
        case .epub: .epub
        case .code: .sourceCode
        case .png: .png
        case .jpeg: .jpeg
        case .heic: .heic
        case .webp: .webP
        case .gif: .gif
        case .wav: .wav
        case .mp3: .mp3
        case .m4a: .mpeg4Audio
        case .aac: UTType("public.aac-audio") ?? .audio
        case .flac: UTType("org.xiph.flac") ?? .audio
        case .legacyOffice, .unknown: .data
        }
    }

    /// Code extensions of step 3 (plus anything whose UTType conforms to `public.source-code`).
    public static let codeExtensions: Set<String> = ["swift", "py", "js", "ts", "c", "h", "cpp", "java", "go", "rs", "rb",
                                                      "kt", "sh", "sql", "yaml", "yml", "toml"]

    /// The kind an extension claims (nil = unknown extension).
    public static func claimed(byExtension ext: String) -> AttachmentKind? {
        switch ext.lowercased() {
        case "pdf": .pdf
        case "docx": .docx
        case "xlsx": .xlsx
        case "xls": .xls
        case "csv": .csv
        case "tsv", "tab": .tsv
        case "pptx": .pptx
        case "txt", "text", "log": .text
        case "md", "markdown": .markdown
        case "rtf": .rtf
        case "html", "htm", "xhtml": .html
        case "json": .json
        case "epub": .epub
        case "png": .png
        case "jpg", "jpeg": .jpeg
        case "heic", "heif": .heic
        case "webp": .webp
        case "gif": .gif
        case "wav": .wav
        case "mp3": .mp3
        case "m4a": .m4a
        case "aac": .aac
        case "flac": .flac
        case "doc", "ppt": .legacyOffice
        case let e where codeExtensions.contains(e): .code
        case let e:
            UTType(filenameExtension: e)?.conforms(to: .sourceCode) == true ? .code : nil
        }
    }
}

public struct SniffResult: Sendable, Equatable {
    public var kind: AttachmentKind
    public var uttype: UTType
    /// The original extension (lowercased).
    public var ext: String
    public var isEncrypted: Bool
    /// The extension claims a different kind than the bytes (the magic wins; no error).
    public var isLying: Bool
}

public enum TypeSniffer {
    static let headerBytes = 64

    public static func sniff(_ url: URL) throws -> SniffResult {
        let ext = url.pathExtension.lowercased()
        let claimed = AttachmentKind.claimed(byExtension: ext)
        let handle = try FileHandle(forReadingFrom: url)
        let head = (try handle.read(upToCount: 4096)) ?? Data()
        try? handle.close()
        var encrypted = false
        var kind = magicKind(head, url: url, encrypted: &encrypted) ?? textKind(head, url: url, claimed: claimed)
        // Password-protected OOXML is an OLE container; the extension names what is inside.
        if encrypted, kind == .legacyOffice || kind == .unknown, let claimed, [.docx, .xlsx, .pptx].contains(claimed) {
            kind = claimed
        }
        let lying: Bool = {
            guard let claimed, kind != .unknown else { return false }
            if claimed == kind { return false }
            if claimed.isTextFamily && kind.isTextFamily { return false }  // .log vs .txt, .csv read as text …
            return true
        }()
        if kind == .pdf, let doc = PDFDocument(url: url), doc.isEncrypted, doc.isLocked { encrypted = true }
        let ut = kind == .code ? (UTType(filenameExtension: ext) ?? .sourceCode) : kind.utType
        return SniffResult(kind: kind, uttype: ut, ext: ext, isEncrypted: encrypted, isLying: lying)
    }

    static func magicKind(_ d: Data, url: URL, encrypted: inout Bool) -> AttachmentKind? {
        let b = [UInt8](d.prefix(headerBytes))
        func starts(_ s: [UInt8], at o: Int = 0) -> Bool { b.count >= o + s.count && Array(b[o..<o + s.count]) == s }
        func ascii(_ s: String, at o: Int = 0) -> Bool { starts(Array(s.utf8), at: o) }
        if ascii("%PDF-") { return .pdf }
        if starts([0x89, 0x50, 0x4E, 0x47]) { return .png }
        if starts([0xFF, 0xD8, 0xFF]) { return .jpeg }
        if ascii("GIF8") { return .gif }
        if ascii("RIFF"), ascii("WEBP", at: 8) { return .webp }
        if ascii("RIFF"), ascii("WAVE", at: 8) { return .wav }
        if ascii("ftyp", at: 4) {
            let brand = b.count >= 12 ? String(decoding: b[8..<12], as: UTF8.self) : ""
            if ["heic", "heix", "mif1", "msf1", "hevc", "heim", "heis", "hevx"].contains(brand) { return .heic }
            if ["M4A ", "M4B ", "mp42", "isom"].contains(brand) { return .m4a }
            return nil
        }
        if ascii("fLaC") { return .flac }
        if ascii("ID3") { return .mp3 }
        if b.count >= 2, b[0] == 0xFF, b[1] & 0xF6 == 0xF0 { return .aac }  // ADTS
        if b.count >= 2, b[0] == 0xFF, b[1] & 0xE0 == 0xE0 { return .mp3 }  // MPEG frame sync
        if ascii("{\\rtf") { return .rtf }
        if starts([0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1]) { return oleKind(url, encrypted: &encrypted) }
        if starts([0x50, 0x4B, 0x03, 0x04]) { return zipKind(url) }
        return nil
    }

    /// OOXML / EPUB by the zip's members.
    static func zipKind(_ url: URL) -> AttachmentKind {
        guard let data = try? Data(contentsOf: url, options: .alwaysMapped),
              let names = try? Set(ZipArchive.entries(in: data).map(\.name)) else { return .unknown }
        if names.contains("word/document.xml") { return .docx }
        if names.contains("xl/workbook.xml") { return .xlsx }
        if names.contains("ppt/presentation.xml") { return .pptx }
        if names.contains("META-INF/container.xml") || names.contains("mimetype") { return .epub }
        return .unknown
    }

    /// OLE compound file: a `Workbook` / `Book` stream → xls; `EncryptedPackage` → encrypted OOXML; else legacy doc/ppt.
    static func oleKind(_ url: URL, encrypted: inout Bool) -> AttachmentKind {
        guard let data = try? Data(contentsOf: url, options: .alwaysMapped) else { return .legacyOffice }
        func has(_ name: String) -> Bool { data.range(of: Data(name.utf16.flatMap { [UInt8($0 & 0xFF), UInt8($0 >> 8)] })) != nil }
        if has("EncryptedPackage") { encrypted = true; return .legacyOffice }
        if has("Workbook") || has("Book\u{0}") { return .xls }
        return .legacyOffice
    }

    /// No binary magic: text when the head decodes (BOM UTF-16, or UTF-8 without NULs); the extension picks the kind.
    static func textKind(_ d: Data, url: URL, claimed: AttachmentKind?) -> AttachmentKind {
        let b = [UInt8](d)
        let utf16 = b.count >= 2 && ((b[0] == 0xFF && b[1] == 0xFE) || (b[0] == 0xFE && b[1] == 0xFF))
        let isText: Bool = {
            if utf16 { return true }
            if b.contains(0) { return false }
            // A cut multi-byte sequence at the 4 KiB edge is fine: drop up to 3 trailing bytes.
            for cut in 0...min(3, b.count) where String(bytes: b.dropLast(cut), encoding: .utf8) != nil {
                return true
            }
            return false
        }()
        guard isText else { return .unknown }
        if let claimed, claimed.isTextFamily { return claimed }
        if claimed != nil { return .text }  // e.g. a `.pdf` / `.rtf` that is really plain text: lying, read as text
        return PlainTextAdapter().canHandle(url: url, uti: nil) ? .text : .unknown  // .xml, .ini, .log, …
    }
}
