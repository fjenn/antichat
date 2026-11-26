// Lays screenshots side by side, each with a caption, and writes one JPEG.
//
//   swift e2e/antichat/scripts/contact-sheet.swift <out.jpg> <height> <label=path> [<label=path> ...]
//
// macOS only (AppKit). Reads PNG, JPEG and WebP, so ChatGPT reference images
// can sit next to our screenshots.
import AppKit

let arguments = CommandLine.arguments
guard arguments.count >= 4, let height = Double(arguments[2]) else {
  FileHandle.standardError.write("usage: contact-sheet.swift <out.jpg> <height> <label=path>...\n".data(using: .utf8)!)
  exit(2)
}
let gap = 24.0
let caption = 44.0
var tiles: [(String, NSImage, Double)] = []
for item in arguments[3...] {
  let parts = item.split(separator: "=", maxSplits: 1).map(String.init)
  let (label, path) = parts.count == 2 ? (parts[0], parts[1]) : ("", parts[0])
  guard let image = NSImage(contentsOfFile: path), let rep = image.representations.first else {
    FileHandle.standardError.write("cannot read \(path)\n".data(using: .utf8)!)
    exit(1)
  }
  let width = height * Double(rep.pixelsWide) / Double(rep.pixelsHigh)
  tiles.append((label, image, width))
}
let totalWidth = tiles.reduce(gap) { $0 + $1.2 + gap }
let totalHeight = height + caption + gap
guard let bitmap = NSBitmapImageRep(
  bitmapDataPlanes: nil, pixelsWide: Int(totalWidth), pixelsHigh: Int(totalHeight),
  bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
  colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
else { exit(1) }
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
NSColor(white: 0.5, alpha: 1).setFill()
NSRect(x: 0, y: 0, width: totalWidth, height: totalHeight).fill()
let attributes: [NSAttributedString.Key: Any] = [
  .font: NSFont.systemFont(ofSize: 22, weight: .semibold),
  .foregroundColor: NSColor.white,
]
var x = gap
for (label, image, width) in tiles {
  image.draw(in: NSRect(x: x, y: gap, width: width, height: height),
             from: .zero, operation: .copy, fraction: 1)
  (label as NSString).draw(at: NSPoint(x: x, y: gap + height + 8), withAttributes: attributes)
  x += width + gap
}
NSGraphicsContext.restoreGraphicsState()
guard let data = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.85]) else { exit(1) }
try data.write(to: URL(fileURLWithPath: arguments[1]))
