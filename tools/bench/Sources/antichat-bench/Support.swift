// Shared plumbing of antichat-bench subcommands: arguments, bundle relocation, dev model slots, tier caps.
import AntiChatHarness
import Darwin
import AppKit
import Foundation

struct BenchArgs: Sendable {
    var opts: [String: String] = [:]
    init(_ a: [String]) {
        var i = 0
        while i < a.count {
            guard a[i].hasPrefix("--") else { i += 1; continue }
            let k = String(a[i].dropFirst(2))
            if i + 1 < a.count, !a[i + 1].hasPrefix("--") {
                opts[k] = a[i + 1]
                i += 2
            } else {
                opts[k] = "1"
                i += 1
            }
        }
    }
    subscript(_ k: String) -> String? { opts[k] }
    func int(_ k: String, _ d: Int) -> Int { opts[k].flatMap(Int.init) ?? d }
}

func runAsync(_ body: @escaping @Sendable () async throws -> Void) -> Never {
    Task.detached {
        do {
            try await body()
            exit(0)
        } catch {
            FileHandle.standardError.write(Data("antichat-bench: \(error)\n".utf8))
            exit(1)
        }
    }
    dispatchMain()
}

/// `runAsync` for subcommands that drive WebKit (RenderHost: the DOCX / PPTX / chart writers): WKWebView needs a
/// running NSApplication main run loop, which `dispatchMain()` does not provide (M6.T10 fileout-golden).
func runAsyncApp(_ body: @escaping @Sendable () async throws -> Void) -> Never {
    let app = NSApplication.shared
    app.setActivationPolicy(.prohibited)
    Task.detached {
        do {
            try await body()
            exit(0)
        } catch {
            FileHandle.standardError.write(Data("antichat-bench: \(error)\n".utf8))
            exit(1)
        }
    }
    app.run()
    exit(0)
}

func say(_ s: String) { FileHandle.standardError.write(Data((s + "\n").utf8)) }

enum BundleRelocation {
    /// Re-executes from inside `--app` (default `build/AntiChat.app`) unless already running there.
    static func ensureInsideApp(args: BenchArgs) {
        let me = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        if me.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().pathExtension == "app" { return }
        let app = URL(fileURLWithPath: args["app"] ?? "build/AntiChat.app")
        guard FileManager.default.fileExists(atPath: app.appendingPathComponent("Contents/XPCServices/AntiChatEngine.xpc").path) else {
            say("antichat-bench: \(app.path) has no Contents/XPCServices/AntiChatEngine.xpc (run make build, or pass --app)")
            exit(66)
        }
        let dest = app.appendingPathComponent("Contents/MacOS/antichat-bench")
        do {
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.copyItem(at: me, to: dest)
        } catch {
            say("antichat-bench: cannot install into \(dest.path): \(error)")
            exit(73)
        }
        var cargs = [dest.path] + CommandLine.arguments.dropFirst()
        let cptrs = cargs.map { strdup($0) } + [nil]
        execv(dest.path, cptrs)
        cargs.removeAll()
        say("antichat-bench: execv failed: \(String(cString: strerror(errno)))")
        exit(71)
    }
}

enum DevSlots {
    /// Tier budgets B in GB (hardware-tiers §2.2; M0.md C5; same table as the app's M0 bench). 1 GB = 1e9 bytes.
    static let tierB: [String: Double] = [
        "T0": 4.0, "T1": 9.5, "T2-24": 16, "T2-32": 21, "T2-36": 24, "T3-48": 36, "T3-64": 48, "T3": 36, "T4": 0, "none": 0,
    ]

    static var modelsDir: URL {
        if let c = ProcessInfo.processInfo.environment["ANTICHAT_DEV_CACHE"], !c.isEmpty {
            return URL(fileURLWithPath: c).appendingPathComponent("Models")
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/AntiChat-Dev/Models")
    }

    static func directorySize(_ url: URL) -> UInt64 {
        guard let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total: UInt64 = 0
        for case let f as URL in e {
            total += UInt64((try? f.resolvingSymlinksInPath().resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return total
    }

    /// M2.T15: the content-addressed install view `<Models>/installs/<key>` when present, else `<Models>/<key>`.
    static func view(_ key: String) -> URL {
        let v = modelsDir.appendingPathComponent("installs").appendingPathComponent(key)
        return FileManager.default.fileExists(atPath: v.appendingPathComponent("manifest.json").path) ? v : modelsDir.appendingPathComponent(key)
    }

    /// `<key>` = MLX dir under the dev models dir; `path:<dir>` = MLX dir; `scripted:<file.jsonl>`; `gguf:<file>`.
    static func slot(_ key: String) -> ModelSlot {
        if key.hasPrefix("scripted:") { return .scripted(String(key.dropFirst(9))) }
        if key.hasPrefix("llama:") {  // M2.T15: a GGUF model dir (model + optional mmproj), router name = key
            let k = String(key.dropFirst(6))
            let dir = view(k)
            let files = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
            let weights = files.filter { $0.hasSuffix(".gguf") }.reduce(UInt64(0)) {
                $0 + ((try? FileManager.default.attributesOfItem(
                    atPath: dir.appendingPathComponent($1).resolvingSymlinksInPath().path)[.size] as? UInt64) ?? 0)
            }
            let mmproj = files.contains { $0.lowercased().contains("mmproj") && $0.hasSuffix(".gguf") }
            return ModelSlot(engine: .llama, key: k, path: dir.path, footprintBytes: UInt64(Double(weights) * 1.1), vision: mmproj,
                             contextTokens: 16384)
        }
        if key.hasPrefix("gguf:") {
            let p = String(key.dropFirst(5))
            let size = (try? FileManager.default.attributesOfItem(atPath: p)[.size] as? UInt64) ?? 0
            return ModelSlot(engine: .llama, key: URL(fileURLWithPath: p).lastPathComponent, path: p, footprintBytes: size)
        }
        if key.hasSuffix("+vision") {  // M6.T05: the MLX model loaded with its vision tower (VLM factory)
            let base = slot(String(key.dropLast(7)))
            return ModelSlot(engine: base.engine, key: key, path: base.path, footprintBytes: base.footprintBytes, vision: true)
        }
        let dir = key.hasPrefix("path:") ? URL(fileURLWithPath: String(key.dropFirst(5))) : view(key)
        // Catalog footprint ≈ weights × 1.1 until M2's catalog [ASSUMPTION, as in the M0 bench].
        return ModelSlot(engine: .mlx, key: key.hasPrefix("path:") ? dir.lastPathComponent : key, path: dir.path, footprintBytes: UInt64(Double(directorySize(dir)) * 1.1))
    }
}

enum Stats {
    static func quantile(_ xs: [Double], _ q: Double) -> Double {
        guard !xs.isEmpty else { return -1 }
        let s = xs.sorted()
        let pos = Double(s.count - 1) * q
        let lo = Int(pos.rounded(.down)), hi = Int(pos.rounded(.up))
        return s[lo] + (s[hi] - s[lo]) * (pos - Double(lo))
    }

    static func summary(_ xs: [Double]) -> [String: Double] {
        ["p50": quantile(xs, 0.5), "p95": quantile(xs, 0.95), "min": xs.min() ?? -1, "max": xs.max() ?? -1]
    }

    static func secs(_ d: Duration) -> Double { Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18 }
}
