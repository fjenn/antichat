// Quick Look (M4.T10 step 2, P-files-tools-07, Apple QuickLookUI): full size through SwiftUI `.quickLookPreview($url)`
// (cards: click or Space); inline through a `QLPreviewView` representable (SidePanel body, M4.T11). If an Office
// file fails inline, the panel shows the thumbnail and the full-size preview still works (M4.T10 fallback).
import AppKit
import Quartz
import SwiftUI

public struct InlineQuickLook: NSViewRepresentable {
    let url: URL

    public init(url: URL) { self.url = url }

    public func makeNSView(context: Context) -> QLPreviewView {
        let view = QLPreviewView(frame: .zero, style: .normal) ?? QLPreviewView()
        view.autostarts = true
        view.shouldCloseWithWindow = true
        view.previewItem = url as NSURL
        return view
    }

    public func updateNSView(_ view: QLPreviewView, context: Context) {
        if (view.previewItem as? NSURL) as URL? != url { view.previewItem = url as NSURL }
    }

    public static func dismantleNSView(_ view: QLPreviewView, coordinator: ()) {
        view.close()
    }
}
