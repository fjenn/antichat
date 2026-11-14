// Automated visual hard checks on window captures (M7.T16 AT-VQ-M7; parity-rubric §2 H3, H5, H6, H7).
//   xcrun swift tools/visual/hard-checks.swift <dir> --catalog App/AntiChat/Localizable.xcstrings [--out <json>]
//        [--allow <file>]   extra visible strings that are content, not copy (fixture answers, server names), one per line
// Walks <dir> recursively for *.png (Retina window captures, 2 px per pt) and runs, per image:
//   H3 contrast  Vision OCR text boxes; per box the background is the median of the box's border pixels and the
//                foreground the pixel farthest from it in luminance (the glyph core); WCAG 2.x ratio ≥ 4.5 (≥ 3.0 when
//                the box is ≥ 18 pt tall). Low-confidence boxes (< 0.5) are skipped.
//   H5 copy      every OCR line must be found in the English strings of the string catalog (placeholders become
//                wildcards; case and punctuation folded) or in the allow list; coverage = matched / lines.
//   H6 grid      long straight edges (≥ 20 pt luminance steps, ≥ 24 contrast levels) measured in points from the window's
//                top-left; an edge is on the grid when its position is within ±0.5 pt of a multiple of 4.
//   H7 sizes     no "0.0 GB" / "0 bytes" / "Zero KB" in any OCR line.
// Prints a summary and writes the JSON; exit 1 when a bar fails (H3: no box below its bar; H5 ≥ 95% here because OCR
// misreads, the exact copy check is copy-sync.py; H6 ≥ 95%; H7 zero hits). CPU only, no network.
import AppKit
import Foundation
import Vision

struct Args {
    var dir = ""
    var catalog = ""
    var out: String?
    var allow: String?
}

func parse() -> Args {
    var a = Args()
    var it = CommandLine.arguments.dropFirst().makeIterator()
    while let x = it.next() {
        switch x {
        case "--catalog": a.catalog = it.next() ?? ""
        case "--out": a.out = it.next()
        case "--allow": a.allow = it.next()
        default: a.dir = x
        }
    }
    return a
}

func fold(_ s: String) -> String {
    let lowered = s.lowercased().folding(options: [.diacriticInsensitive], locale: nil)
    let kept = lowered.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) || $0 == " " ? Character($0) : " " }
    return String(kept).split(separator: " ").joined(separator: " ")
}

/// English catalog strings, folded; `%@`, `{name}` and `%lld` placeholders split a string into its literal parts.
func catalogStrings(_ path: String) -> [String] {
    guard let d = FileManager.default.contents(atPath: path),
          let root = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
          let strings = root["strings"] as? [String: Any] else { return [] }
    var out: [String] = []
    func add(_ v: String) {
        let parts = v.replacingOccurrences(of: "%[0-9$]*(@|lld|ld|d|f|\\.[0-9]f)|\\{[a-zA-Z_]+\\}", with: "\u{1}",
                                           options: .regularExpression).split(separator: "\u{1}")
        out.append(fold(v))
        for p in parts { let f = fold(String(p)); if f.count >= 3 { out.append(f) } }
    }
    for (key, value) in strings {
        add(key)
        guard let v = value as? [String: Any], let locs = v["localizations"] as? [String: Any],
              let en = locs["en"] as? [String: Any] else { continue }
        if let unit = en["stringUnit"] as? [String: Any], let s = unit["value"] as? String { add(s) }
        if let vars = en["variations"] as? [String: Any] {
            for case let group as [String: Any] in vars.values {
                for case let leaf as [String: Any] in group.values {
                    if let unit = leaf["stringUnit"] as? [String: Any], let s = unit["value"] as? String { add(s) }
                }
            }
        }
    }
    return out
}

struct Pixels {
    let w: Int, h: Int
    let data: [UInt8]  // RGBA
    init?(_ url: URL) {
        guard let img = NSImage(contentsOf: url), let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        w = cg.width; h = cg.height
        var buf = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(data: &buf, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        data = buf
    }
    /// Relative luminance (WCAG) of pixel (x, y), y from the top.
    func lum(_ x: Int, _ y: Int) -> Double {
        let i = (y * w + x) * 4
        func c(_ v: UInt8) -> Double { let s = Double(v) / 255; return s <= 0.04045 ? s / 12.92 : pow((s + 0.055) / 1.055, 2.4) }
        return 0.2126 * c(data[i]) + 0.7152 * c(data[i + 1]) + 0.0722 * c(data[i + 2])
    }
    func gray(_ x: Int, _ y: Int) -> Int {
        let i = (y * w + x) * 4
        return (Int(data[i]) * 299 + Int(data[i + 1]) * 587 + Int(data[i + 2]) * 114) / 1000
    }
}

func ratio(_ a: Double, _ b: Double) -> Double { (max(a, b) + 0.05) / (min(a, b) + 0.05) }

struct Line { let text: String; let rect: CGRect; let confidence: Float }

func ocr(_ url: URL) -> [Line] {
    guard let img = NSImage(contentsOf: url), let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return [] }
    let req = VNRecognizeTextRequest()
    req.recognitionLevel = .accurate
    req.usesLanguageCorrection = false
    try? VNImageRequestHandler(cgImage: cg).perform([req])
    let W = CGFloat(cg.width), H = CGFloat(cg.height)
    return (req.results ?? []).compactMap { o in
        guard let c = o.topCandidates(1).first else { return nil }
        let b = o.boundingBox
        return Line(text: c.string, rect: CGRect(x: b.minX * W, y: (1 - b.maxY) * H, width: b.width * W, height: b.height * H),
                    confidence: c.confidence)
    }
}

func contrast(_ p: Pixels, _ r: CGRect) -> Double? {
    let x0 = max(0, Int(r.minX) - 2), x1 = min(p.w - 1, Int(r.maxX) + 2)
    let y0 = max(0, Int(r.minY) - 2), y1 = min(p.h - 1, Int(r.maxY) + 2)
    guard x1 - x0 > 4, y1 - y0 > 4 else { return nil }
    var border: [Double] = []
    for x in x0...x1 { border.append(p.lum(x, y0)); border.append(p.lum(x, y1)) }
    for y in y0...y1 { border.append(p.lum(x0, y)); border.append(p.lum(x1, y)) }
    border.sort()
    let bg = border[border.count / 2]
    var far = bg
    for y in y0...y1 { for x in x0...x1 { let l = p.lum(x, y); if abs(l - bg) > abs(far - bg) { far = l } } }
    return ratio(far, bg)
}

/// Edge positions (pt) of long vertical and horizontal luminance steps.
func edges(_ p: Pixels) -> [Double] {
    let minRun = 40, step = 24  // ≥ 20 pt straight edges: containers, dividers, fields (not glyphs or icons)
    var out: [Double] = []
    // Vertical edges: column x where gray(x) - gray(x-1) has the same sign over ≥ minRun consecutive rows.
    for x in 1..<p.w {
        var run = 0, sign = 0
        for y in 0..<p.h {
            let d = p.gray(x, y) - p.gray(x - 1, y)
            let s = d >= step ? 1 : d <= -step ? -1 : 0
            if s != 0 && s == sign { run += 1 } else { run = s != 0 ? 1 : 0; sign = s }
            if run == minRun { out.append(Double(x) / 2) }
        }
    }
    for y in 1..<p.h {
        var run = 0, sign = 0
        for x in 0..<p.w {
            let d = p.gray(x, y) - p.gray(x, y - 1)
            let s = d >= step ? 1 : d <= -step ? -1 : 0
            if s != 0 && s == sign { run += 1 } else { run = s != 0 ? 1 : 0; sign = s }
            if run == minRun { out.append(Double(y) / 2) }
        }
    }
    return out
}

let a = parse()
let catalog = catalogStrings(a.catalog)
let allow = (a.allow.flatMap { try? String(contentsOfFile: $0, encoding: .utf8) } ?? "")
    .split(separator: "\n").map { fold(String($0)) }.filter { !$0.isEmpty }
let haystack = catalog + allow
func known(_ line: String) -> Bool {
    func hit(_ f: String) -> Bool {
        guard f.count >= 3, f.contains(where: \.isLetter) else { return true }  // digits, symbols, single letters
        return haystack.contains { $0.contains(f) || (f.count > 12 && f.contains($0) && $0.count * 10 >= f.count * 7) }
    }
    let f = fold(line)
    if hit(f) { return true }
    // OCR reads an SF Symbol next to a label as a stray 1–2 character token ("Q Search", "{o General"): drop it.
    let parts = f.split(separator: " ")
    if parts.count > 1, parts[0].count <= 2 { return hit(parts.dropFirst().joined(separator: " ")) }
    return false
}

var images: [[String: Any]] = []
var h3Fail = 0, h5Lines = 0, h5Hit = 0, h6Edges = 0, h6On = 0, h7Hits: [String] = []
let fm = FileManager.default
let pngs = (fm.enumerator(atPath: a.dir)?.compactMap { $0 as? String } ?? []).filter { $0.hasSuffix(".png") }.sorted()
for rel in pngs {
    let url = URL(fileURLWithPath: a.dir).appendingPathComponent(rel)
    guard let p = Pixels(url) else { continue }
    let lines = ocr(url)
    var low: [[String: Any]] = [], unknown: [String] = []
    for l in lines where l.confidence >= 0.5 {
        if let c = contrast(p, l.rect) {
            let bar = l.rect.height / 2 >= 18 ? 3.0 : 4.5
            if c < bar { low.append(["text": l.text, "ratio": (c * 100).rounded() / 100, "bar": bar]) }
        }
        h5Lines += 1
        if known(l.text) { h5Hit += 1 } else { unknown.append(l.text) }
        if l.text.range(of: #"\b0[.,]0 ?GB\b|\b0 bytes\b|Zero KB"#, options: [.regularExpression, .caseInsensitive]) != nil { h7Hits.append("\(rel): \(l.text)") }
    }
    let e = edges(p)
    let on = e.filter { v in let m = v.truncatingRemainder(dividingBy: 4); return m <= 0.5 || m >= 3.5 }.count
    h3Fail += low.count; h6Edges += e.count; h6On += on
    images.append(["image": rel, "lines": lines.count, "h3_low": low, "h5_unknown": unknown,
                   "h6_edges": e.count, "h6_on_grid": on])
}
let h5 = h5Lines == 0 ? 1 : Double(h5Hit) / Double(h5Lines)
let h6 = h6Edges == 0 ? 1 : Double(h6On) / Double(h6Edges)
let summary: [String: Any] = [
    "images": pngs.count,
    "H3": ["below_bar": h3Fail, "pass": h3Fail == 0],
    "H5": ["lines": h5Lines, "matched": h5Hit, "coverage": (h5 * 1000).rounded() / 1000, "pass": h5 >= 0.95],
    "H6": ["edges": h6Edges, "on_grid": h6On, "share": (h6 * 1000).rounded() / 1000, "pass": h6 >= 0.95],
    "H7": ["hits": h7Hits, "pass": h7Hits.isEmpty],
]
let doc: [String: Any] = ["summary": summary, "per_image": images]
if let out = a.out, let d = try? JSONSerialization.data(withJSONObject: doc, options: [.prettyPrinted, .sortedKeys]) {
    try? d.write(to: URL(fileURLWithPath: out))
}
if let d = try? JSONSerialization.data(withJSONObject: summary, options: [.prettyPrinted, .sortedKeys]) {
    print(String(decoding: d, as: UTF8.self))
}
let pass = h3Fail == 0 && h5 >= 0.95 && h6 >= 0.95 && h7Hits.isEmpty
exit(pass ? 0 : 1)
