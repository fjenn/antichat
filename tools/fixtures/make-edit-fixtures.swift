// M4.T13 / M4.T15 fixtures (deterministic; CC0 inputs only): `swift tools/fixtures/make-edit-fixtures.swift <fixtures dir>`.
//   * images/edit-golden/: 5 instruction edits on photos-cc0 pictures — `goldens.json` (source, instruction, mask) +
//     one 1024² 8-bit mask PNG each (white = the region the instruction is about), drawn from hand-picked geometric
//     shapes (rectangle / ellipse in 1024² pixel coordinates, listed in goldens.json). EditGoldenTests (M4.T13: the
//     edited region changes) and MaskFidelityTests (M4.T15: Erase keeps everything outside the dilated mask) read them.
//   * images/bg-removal/: 10 composites with an EXACT ground-truth foreground mask by construction, for
//     RemoveBackgroundTests (IoU ≥ 0.9). Background = a photos-cc0 scene without a dominant subject; subject = a framed
//     panel (white 24 px frame, rounded corners, drop shadow) whose inside is the colours of another photos-cc0 picture
//     smoothed to 6×6 (no recognisable object, so the subject is unambiguous). `mask-NN.png` = the panel's outline.
// No people as subjects, nothing sexual (fixtures rule); inputs are the CC0 files listed in photos-cc0/SOURCES.md.
import CoreGraphics
import Foundation
import ImageIO

let root = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "fixtures")
let photos = root.appendingPathComponent("images/photos-cc0")
let W = 1024

func load(_ name: String) -> CGImage {
    let s = CGImageSourceCreateWithURL(photos.appendingPathComponent(name) as CFURL, nil)!
    return CGImageSourceCreateImageAtIndex(s, 0, nil)!
}

func writePNG(_ img: CGImage, _ url: URL) {
    try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let d = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)!
    CGImageDestinationAddImage(d, img, nil)
    precondition(CGImageDestinationFinalize(d))
}

/// An 8-bit mask, white inside `path` (top-left origin coordinates).
func mask(_ draw: (CGContext) -> Void) -> CGImage {
    let ctx = CGContext(data: nil, width: W, height: W, bitsPerComponent: 8, bytesPerRow: W, space: CGColorSpaceCreateDeviceGray(),
                        bitmapInfo: CGImageAlphaInfo.none.rawValue)!
    ctx.setFillColor(gray: 0, alpha: 1)
    ctx.fill(CGRect(x: 0, y: 0, width: W, height: W))
    ctx.translateBy(x: 0, y: CGFloat(W))
    ctx.scaleBy(x: 1, y: -1)
    ctx.setFillColor(gray: 1, alpha: 1)
    ctx.setShouldAntialias(false)
    draw(ctx)
    return ctx.makeImage()!
}

// MARK: edit goldens

struct Golden: Codable {
    var id: String
    var source: String
    var instruction: String
    var shape: String
    var rect: [Int]  // x0, y0, x1, y1 (1024² pixels, top-left origin)
    var mask: String
}

let goldens = [
    Golden(id: "01-car", source: "037.jpg", instruction: "Make the car red.", shape: "rect", rect: [0, 140, 1024, 970], mask: "01-car-mask.png"),
    Golden(id: "02-boat", source: "018.jpg", instruction: "Make the boat red.", shape: "rect", rect: [0, 470, 1024, 880], mask: "02-boat-mask.png"),
    Golden(id: "03-cat", source: "032.jpg", instruction: "Make the cat completely black.", shape: "ellipse", rect: [180, 330, 860, 800], mask: "03-cat-mask.png"),
    Golden(id: "04-flag", source: "009.jpg", instruction: "Make the flag plain green.", shape: "rect", rect: [240, 130, 580, 1000], mask: "04-flag-mask.png"),
    Golden(id: "05-dog", source: "040.jpg", instruction: "Make the dog black.", shape: "ellipse", rect: [200, 570, 520, 840], mask: "05-dog-mask.png"),
]
let goldenDir = root.appendingPathComponent("images/edit-golden")
for g in goldens {
    let r = CGRect(x: g.rect[0], y: g.rect[1], width: g.rect[2] - g.rect[0], height: g.rect[3] - g.rect[1])
    writePNG(mask { g.shape == "ellipse" ? $0.fillEllipse(in: r) : $0.fill(r) }, goldenDir.appendingPathComponent(g.mask))
}
let enc = JSONEncoder()
enc.outputFormatting = [.prettyPrinted, .sortedKeys]
try enc.encode(goldens).write(to: goldenDir.appendingPathComponent("goldens.json"))

// MARK: background-removal composites

let pairs: [(bg: String, fg: String)] = [("019", "022"), ("039", "026"), ("020", "023"), ("011", "007"), ("036", "040"),
                                         ("028", "032"), ("024", "012"), ("016", "037"), ("021", "030"), ("025", "018")]
let bgDir = root.appendingPathComponent("images/bg-removal")
let panel = CGRect(x: 280, y: 200, width: 470, height: 470)  // CG (bottom-left) coordinates
for (i, p) in pairs.enumerated() {
    let n = String(format: "%02d", i + 1)
    let ctx = CGContext(data: nil, width: W, height: W, bitsPerComponent: 8, bytesPerRow: W * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    ctx.interpolationQuality = .high
    ctx.draw(load("\(p.bg).jpg"), in: CGRect(x: 0, y: 0, width: W, height: W))
    let outline = CGPath(roundedRect: panel, cornerWidth: 60, cornerHeight: 60, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 30, color: CGColor(gray: 0, alpha: 0.6))
    ctx.addPath(outline)
    ctx.setFillColor(CGColor(gray: 1, alpha: 1))
    ctx.fillPath()
    ctx.restoreGState()
    let inner = panel.insetBy(dx: 24, dy: 24)
    ctx.saveGState()
    ctx.addPath(CGPath(roundedRect: inner, cornerWidth: 40, cornerHeight: 40, transform: nil))
    ctx.clip()
    let small = CGContext(data: nil, width: 6, height: 6, bitsPerComponent: 8, bytesPerRow: 24, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    small.interpolationQuality = .high
    small.draw(load("\(p.fg).jpg"), in: CGRect(x: 0, y: 0, width: 6, height: 6))
    ctx.draw(small.makeImage()!, in: inner)
    ctx.restoreGState()
    writePNG(ctx.makeImage()!, bgDir.appendingPathComponent("composite-\(n).png"))
    // Ground truth: the panel outline (flip to top-left: the mask helper flips, so give it top-left coordinates).
    let tl = CGRect(x: panel.minX, y: CGFloat(W) - panel.maxY, width: panel.width, height: panel.height)
    writePNG(mask { c in c.addPath(CGPath(roundedRect: tl, cornerWidth: 60, cornerHeight: 60, transform: nil)); c.fillPath() },
             bgDir.appendingPathComponent("mask-\(n).png"))
}
print("wrote \(goldens.count) goldens, \(pairs.count) composites")
