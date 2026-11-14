// Find on-screen windows whose owner matches one of the given names (M0.T05 step 7 / vq-00 part B) and print
// "<windowID>\t<owner>\t<name>\t<x,y,w,h>" so `screencapture -x -l <windowID>` can capture only the TCC prompt
// (never the whole screen, which may show unrelated private windows).
// Usage: swift tools/audio/tcc-window.swift UserNotificationCenter tccd "System Settings"
import CoreGraphics
import Foundation

let wanted = CommandLine.arguments.dropFirst().map { $0.lowercased() }
let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
for w in list {
    let owner = w[kCGWindowOwnerName as String] as? String ?? ""
    let name = w[kCGWindowName as String] as? String ?? ""
    guard wanted.isEmpty || wanted.contains(where: { owner.lowercased().contains($0) }) else { continue }
    let id = w[kCGWindowNumber as String] as? Int ?? 0
    let b = w[kCGWindowBounds as String] as? [String: Double] ?? [:]
    print("\(id)\t\(owner)\t\(name)\t\(Int(b["X"] ?? 0)),\(Int(b["Y"] ?? 0)),\(Int(b["Width"] ?? 0)),\(Int(b["Height"] ?? 0))")
}
