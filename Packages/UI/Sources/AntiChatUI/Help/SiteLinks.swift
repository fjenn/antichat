// M10.T06/T07: links from Help and Legal to the website. The site root comes from `Endpoints.plist` `DownloadURL`
// (the hosting switch; Debug → `DownloadURLDev`, the `make site-dev` host, written without its trailing slash), so
// the root is that URL minus its `/download` path, with or without the slash. Links go to the browser through
// `open(_:)`, which `-OpenURLSpy <file>` (DEBUG; HelpUITests / LegalUITests) turns into a line in that file.
import AntiChatFoundation
import AntiChatPlatform
import AppKit
import Foundation

enum SiteLinks {
    /// Pure (unit-tested): `https://h/download/` and `http://h:4321/download` → `https://h` / `http://h:4321`.
    static func root(downloadURL: String) -> String {
        var s = downloadURL
        while s.hasSuffix("/") { s.removeLast() }
        if s.hasSuffix("/download") { s.removeLast("/download".count) }
        return s
    }

    /// `path` on the site (absolute path, e.g. `/help/faq/`), or nil without a `DownloadURL`.
    static func url(_ path: String, downloadURL: String? = Endpoints.string("DownloadURL")) -> URL? {
        downloadURL.flatMap { URL(string: root(downloadURL: $0) + path) }
    }

    /// The browser, or (DEBUG `-OpenURLSpy`) a line in the spy file; never both.
    @MainActor static func open(_ url: URL) {
        #if DEBUG || ANTICHAT_PERF_HARNESS
        if let spy = LaunchOptions.current.openURLSpy {
            let file = URL(fileURLWithPath: spy), line = Data((url.absoluteString + "\n").utf8)
            if let h = try? FileHandle(forWritingTo: file) {
                h.seekToEndOfFile()
                h.write(line)
                try? h.close()
            } else {
                try? line.write(to: file, options: .atomic)
            }
            return
        }
        #endif
        NSWorkspace.shared.open(url)
    }
}
