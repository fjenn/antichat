// AT-033 img-edit set (R-033; M4.T13 steps 4–5), `@realModels` — opt-in, never in the ordinary unit run:
//   ANTICHAT_REAL_SD=1 [ANTICHAT_REAL_EDIT=klein|qwen] ANTICHAT_FIXTURES=$PWD/fixtures \
//     ~/AntiChat-tools/gpu-run.sh shared -- swift test --filter 'EditGoldenTests|ImageEditLaunchTests'
// (memory checked by the caller first: free ≥ model set + 20 GB).
//   * EditGoldenTests: the 5 `fixtures/images/edit-golden/` instruction edits through the signed sd-server — the
//     source goes in as a reference picture (`ref_images`), the instruction is the prompt, 4 steps; the region the
//     instruction names must change: mean |diff| inside the golden mask > 8/255. (The outside-mask ≤ 1/255 rule needs
//     MaskCompositor and is asserted by M4.T15 MaskFidelityTests.) klein = T1 cap (768², img-klein Q4 + Qwen3-4B);
//     qwen = T3 cap (img-edit Q4_K_M + Lightning + Qwen2.5-VL-7B Q8 with mmproj + Qwen VAE, chat unloaded).
//   * ImageEditLaunchTests/testQwenEditVisionEnabled: the img-edit launch argv carries `--model-args
//     qwen_image_zero_cond_t=true` and the mmproj; the server log has none of `vision disabled`, `loading llm vision
//     from … failed`, `ignoring invalid Qwen Image model arg` after a real edit job.
// Generated pictures stay in memory (only numbers are logged): nothing ungated is written or shown (D-006).
import AntiChatEngineProtocol
import CryptoKit
import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import AntiChatEngines

enum RealPhoto {
    static let enabled = ProcessInfo.processInfo.environment["ANTICHAT_REAL_SD"] == "1"
    static let models = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/AntiChat-Dev/Models")
    static let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    static var fixtures: URL {
        if let f = ProcessInfo.processInfo.environment["ANTICHAT_FIXTURES"], !f.isEmpty { return URL(fileURLWithPath: f) }
        return repo.appendingPathComponent("fixtures")
    }
    static var binary: String { repo.appendingPathComponent("build/binaries/sd-server").path }

    /// T1 photo set (klein Q4_0 + Qwen3-4B Q4_K_M + FLUX.2 VAE).
    static func klein() -> ImageModelSet {
        ImageModelSet(key: "img-klein-q4", diffusionModel: models.appendingPathComponent("img-klein/flux-2-klein-4b-Q4_0.gguf").path,
                      llm: models.appendingPathComponent("img-te/Qwen3-4B-Q4_K_M.gguf").path,
                      vae: models.appendingPathComponent("img-vae-flux2/split_files/vae/flux2-vae.safetensors").path,
                      footprintBytes: 6_300_000_000)
    }

    /// T3 img-edit set (A-M4-04 / D-018 pins, model-matrix §11.5).
    /// A reference cap under test (`ANTICHAT_EDIT_REF_PIXELS`); 0 = the product setting, no cap (sd.cpp's 1 MP default, A-M9-T05-P4).
    static var refPixels: Int {
        Int(ProcessInfo.processInfo.environment["ANTICHAT_EDIT_REF_PIXELS"] ?? "") ?? 0
    }

    static func qwenEdit(refPixels: Int = RealPhoto.refPixels) -> ImageModelSet {
        ImageModelSet(key: "img-edit-q4", diffusionModel: models.appendingPathComponent("img-edit/qwen-image-edit-2511-Q4_K_M.gguf").path,
                      llm: models.appendingPathComponent("img-edit-te/Qwen2.5-VL-7B-Instruct-Q8_0.gguf").path,
                      vae: models.appendingPathComponent("img-vae-qwen/split_files/vae/qwen_image_vae.safetensors").path,
                      footprintBytes: 24_000_000_000,
                      extraArgs: ["--llm_vision", models.appendingPathComponent("img-edit-te/mmproj-Qwen2.5-VL-7B-Instruct-Q8_0.gguf").path,
                                  "--model-args", "qwen_image_zero_cond_t=true"]
                                  + (refPixels > 0 ? ["--ref-image-args", "vae_input_max_pixels=\(refPixels)"] : []),
                      loras: [models.appendingPathComponent("img-edit-lightning/Qwen-Image-Edit-2511-Lightning-4steps-V1.0-bf16.safetensors").path])
    }

    static func installed(_ s: ImageModelSet) -> Bool {
        ([s.diffusionModel, s.llm, s.vae] + (s.loras ?? [])).allSatisfy { FileManager.default.fileExists(atPath: $0) }
    }

    static func load(_ url: URL) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(src, 0, nil)
    }

    /// Runs one job to its end; the PNG stays in memory.
    static func run(_ client: SDServerClient, prompt: String, size: Int, steps: Int, seed: Int64, refs: [Data] = [],
                    initImage: Data? = nil, mask: Data? = nil, loras: [String] = [], strength: Float? = nil) async throws -> (Data, Double) {
        let t0 = ContinuousClock.now
        let job = try await client.submit(prompt: prompt, width: size, height: size, steps: steps, seed: seed, cfg: 1, sampleMethod: "euler",
                                          preview: "none", initImage: initImage, maskImage: mask, refImages: refs, strength: strength, loras: loras)
        var st = try await client.job(job)
        let end = ContinuousClock.now + .seconds(900)
        while !["completed", "failed", "cancelled"].contains(st.status), ContinuousClock.now < end {
            try await Task.sleep(for: .milliseconds(50))
            st = try await client.job(job)
        }
        let d = ContinuousClock.now - t0
        guard st.status == "completed", let png = st.imagePNG else { throw CocoaError(.featureUnsupported, userInfo: ["status": "\(st.status) \(st.error ?? "")"]) }
        return (png, Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18)
    }

    struct Golden: Decodable {
        var id: String
        var source: String
        var instruction: String
        var mask: String
    }

    static func goldens() throws -> [Golden] {
        let dir = fixtures.appendingPathComponent("images/edit-golden")
        return try JSONDecoder().decode([Golden].self, from: Data(contentsOf: dir.appendingPathComponent("goldens.json")))
    }

    static func sourceURL(_ g: Golden) -> URL { fixtures.appendingPathComponent("images/photos-cc0").appendingPathComponent(g.source) }
    static func maskURL(_ g: Golden) -> URL { fixtures.appendingPathComponent("images/edit-golden").appendingPathComponent(g.mask) }

    /// `image` resampled to `side`² (PNG) — what the edit job is given.
    static func png(_ image: CGImage, side: Int) -> Data {
        let px = MaskCompositor.rgba(image, width: side, height: side)
        return MaskCompositor.png(MaskCompositor.image(rgba: px, width: side, height: side)!)!
    }

    static func loadAverage() -> String {
        var l = [Double](repeating: 0, count: 3)
        return getloadavg(&l, 3) == 3 ? String(format: "%.1f %.1f %.1f", l[0], l[1], l[2]) : "?"
    }

    /// `image` (a mask) resampled to `side`² as an 8-bit gray PNG.
    static func grayPNG(_ image: CGImage, side: Int) -> Data {
        MaskCompositor.png(MaskCompositor.image(gray: MaskCompositor.gray(image, width: side, height: side), width: side, height: side)!)!
    }

    static func log(_ line: String) {
        print(line)
        let dir = repo.appendingPathComponent("build/at/AT-033")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("real-legs.log")
        let stamped = "\(ISO8601DateFormatter().string(from: Date())) \(line)\n"
        if let h = try? FileHandle(forWritingTo: url) { h.seekToEndOfFile(); h.write(Data(stamped.utf8)); try? h.close() }
        else { try? Data(stamped.utf8).write(to: url) }
    }
}

@Suite(.serialized, .enabled(if: RealPhoto.enabled)) struct EditGoldenTests {
    var which: String { ProcessInfo.processInfo.environment["ANTICHAT_REAL_EDIT"] ?? "klein" }

    @Test func goldenEditsChangeTheNamedRegion() async throws {
        try #require(FileManager.default.isExecutableFile(atPath: RealPhoto.binary), "make build first (stages sd-server)")
        let set = which == "qwen" ? RealPhoto.qwenEdit() : RealPhoto.klein()
        try #require(RealPhoto.installed(set), "models of \(set.key) not in the dev cache")
        let side = which == "qwen" ? 1024 : 768
        let log = FileManager.default.temporaryDirectory.appendingPathComponent("sd-edit-\(UUID().uuidString).log").path
        let empty = FileManager.default.temporaryDirectory.appendingPathComponent("sd-empty-\(UUID().uuidString)").path
        let sup = SDServerSupervisor(config: .init(binary: RealPhoto.binary, logFile: log, modelDir: empty))
        defer { Task { await sup.stop() } }
        let load = try await sup.start(set)
        RealPhoto.log("EditGoldenTests \(set.key) \(side)² load \(String(format: "%.1f", load)) s args: \(await sup.lastArgs.joined(separator: " "))")
        let client = await sup.client
        var failures: [String] = []
        for g in try RealPhoto.goldens() {
            let src = try #require(RealPhoto.load(RealPhoto.sourceURL(g)))
            let mask = try #require(RealPhoto.load(RealPhoto.maskURL(g)))
            // The product's masked-edit path (ImageEditFlow.apply + EngineRuntime): klein = masked img2img at strength
            // 0.6 (init + mask_image), img-edit = reference picture; then the helper's feathered composite onto the source.
            let input = RealPhoto.png(src, side: side)
            let maskPNG = RealPhoto.grayPNG(mask, side: side)
            let (raw, secs) = which == "qwen"
                ? try await RealPhoto.run(client, prompt: g.instruction, size: side, steps: 4, seed: 42, refs: [input], loras: set.loras ?? [])
                : try await RealPhoto.run(client, prompt: g.instruction, size: side, steps: 4, seed: 42, initImage: input, mask: maskPNG,
                                          strength: 0.6)
            let png = try #require(MaskCompositor.compositePNG(source: input, engine: raw, mask: maskPNG))
            let out = try #require(MaskCompositor.decode(png))
            let srcAtSize = try #require(MaskCompositor.decode(input))
            let inside = MaskCompositor.meanAbsDiffInside(srcAtSize, out, mask: mask)
            let outside = MaskCompositor.meanAbsDiffOutside(srcAtSize, out, mask: mask)
            let outsideMax = MaskCompositor.maxAbsDiffOutside(srcAtSize, out, mask: mask)
            let pass = inside > 8 && outside <= 1 && outsideMax <= 1
            RealPhoto.log(String(format: "EditGoldenTests %@ %@ masked: inside %.1f/255 (bar > 8) outside mean %.3f max %d /255 (bar ≤ 1, beyond the %d-px dilate+feather band) %.1f s %@",
                                 set.key, g.id, inside, outside, outsideMax, MaskCompositor.dilation + MaskCompositor.feather, secs,
                                 pass ? "PASS" : "FAIL"))
            if !pass { failures.append(g.id) }
        }
        await sup.stop()
        #expect(failures.isEmpty, "golden edits failing the in-mask change or the outside-mask bar: \(failures)")
    }
}

@Suite(.serialized, .enabled(if: RealPhoto.enabled && ProcessInfo.processInfo.environment["ANTICHAT_REAL_EDIT"] == "qwen"))
struct ImageEditLaunchTests {
    static let badLines = ["vision disabled", "ignoring invalid Qwen Image model arg", "ignoring invalid reference image arg",
                           "ignoring unknown reference image arg"]

    @Test func testQwenEditVisionEnabled() async throws {
        let set = RealPhoto.qwenEdit()
        try #require(RealPhoto.installed(set), "img-edit set not in the dev cache")
        let log = FileManager.default.temporaryDirectory.appendingPathComponent("sd-qwen-\(UUID().uuidString).log").path
        let empty = FileManager.default.temporaryDirectory.appendingPathComponent("sd-empty-\(UUID().uuidString)").path
        let sup = SDServerSupervisor(config: .init(binary: RealPhoto.binary, logFile: log, modelDir: empty))
        defer { Task { await sup.stop() } }
        _ = try await sup.start(set)
        let args = await sup.lastArgs
        #expect(args.joined(separator: " ").contains("--model-args qwen_image_zero_cond_t=true"))
        #expect(args.contains("--llm_vision") && args.contains("--lora-model-dir"))
        #expect(RealPhoto.refPixels == 0 ? !args.contains("--ref-image-args")
                 : args.joined(separator: " ").contains("--ref-image-args vae_input_max_pixels=\(RealPhoto.refPixels)"))
        let g = try #require(try RealPhoto.goldens().first)
        let src = try #require(RealPhoto.load(RealPhoto.sourceURL(g)))
        _ = try await RealPhoto.run(await sup.client, prompt: g.instruction, size: 1024, steps: 4, seed: 42,
                                    refs: [RealPhoto.png(src, side: 1024)], loras: set.loras ?? [])
        await sup.stop()
        let text = (try? String(contentsOfFile: log, encoding: .utf8)) ?? ""
        let bad = Self.badLines.filter { text.contains($0) }
        let visionFailed = text.range(of: #"loading llm vision from .* failed"#, options: .regularExpression) != nil
        RealPhoto.log("ImageEditLaunchTests argv: \(args.joined(separator: " ")) bad=\(bad) visionFailed=\(visionFailed) log=\(log)")
        #expect(bad.isEmpty && !visionFailed, "server log: \(bad) visionFailed=\(visionFailed)")
    }
}

/// AT-NFR-P4 (instruction edit at the same resolution ≤ 1.5 × NFR-P1): warm sd-server, the same set, size and steps —
/// a create (no reference) vs an instruction edit (the source as a reference picture), 5 runs each after one warm-up;
/// medians and their ratio. Timing number: run only under `gpu-run.sh timing` (load average recorded with it).
@Suite(.serialized, .enabled(if: RealPhoto.enabled && ProcessInfo.processInfo.environment["ANTICHAT_PERF"] == "1"))
struct EditTimingTests {
    @Test func editVersusCreateAtTheSameResolution() async throws {
        let qwen = ProcessInfo.processInfo.environment["ANTICHAT_REAL_EDIT"] == "qwen"
        let set = qwen ? RealPhoto.qwenEdit() : RealPhoto.klein()
        try #require(RealPhoto.installed(set))
        // T1 cap 768² (S1/S2); `ANTICHAT_EDIT_SIDE=1024` = the T3 default (klein quick edit at S3/S4's 1024²).
        let side = Int(ProcessInfo.processInfo.environment["ANTICHAT_EDIT_SIDE"] ?? "") ?? (qwen ? 1024 : 768)
        let empty = FileManager.default.temporaryDirectory.appendingPathComponent("sd-empty-\(UUID().uuidString)").path
        let sup = SDServerSupervisor(config: .init(binary: RealPhoto.binary, logFile: nil, modelDir: empty))
        defer { Task { await sup.stop() } }
        _ = try await sup.start(set)
        let client = await sup.client
        let g = try #require(try RealPhoto.goldens().first)
        let ref = RealPhoto.png(try #require(RealPhoto.load(RealPhoto.sourceURL(g))), side: side)
        let maskPNG = RealPhoto.grayPNG(try #require(RealPhoto.load(RealPhoto.maskURL(g))), side: side)
        let loras = set.loras ?? []
        _ = try await RealPhoto.run(client, prompt: "a lighthouse at dusk", size: side, steps: 4, seed: 1, loras: loras)
        var create: [Double] = [], edit: [Double] = []
        for i in 0..<5 {
            create.append(try await RealPhoto.run(client, prompt: "a lighthouse at dusk", size: side, steps: 4, seed: Int64(10 + i), loras: loras).1)
            let (raw, t) = qwen
                ? try await RealPhoto.run(client, prompt: g.instruction, size: side, steps: 4, seed: Int64(10 + i), refs: [ref], loras: loras)
                : try await RealPhoto.run(client, prompt: g.instruction, size: side, steps: 4, seed: Int64(10 + i), initImage: ref,
                                          mask: maskPNG, strength: 0.6)
            // + the helper's feathered composite (part of every masked edit).
            let c0 = ContinuousClock.now
            _ = MaskCompositor.compositePNG(source: ref, engine: raw, mask: maskPNG)
            let cd = ContinuousClock.now - c0
            edit.append(t + Double(cd.components.seconds) + Double(cd.components.attoseconds) / 1e18)
        }
        await sup.stop()
        let mc = create.sorted()[2], me = edit.sorted()[2]
        RealPhoto.log(String(format: "EditTimingTests P4 %@ (%@) %d² create median %.2f s, edit median %.2f s, ratio %.2f (bar ≤ 1.5); load avg %@",
                             set.key, qwen ? "reference edit" : "masked img2img 0.6", side, mc, me, me / mc, RealPhoto.loadAverage()))
        #expect(me / mc <= 1.5)
    }
}

/// A-M9-T05-P4 (lead decision): blind A/B of the img-edit reference cap. For each golden source, one UNMASKED instruction
/// edit (the product's reference-edit path, no composite) with the cap under test (`ANTICHAT_EDIT_REF_PIXELS`, required)
/// and one with sd.cpp's 1 MP default (the product), same seed. D-006: every output passes the real
/// ChildSafetyCheck (MediaOutputGate, dev detectors) before anything is written; only allowed pictures are written.
/// Per pair the side (A/B) is random; the key goes to `<out>-key.json`, OUTSIDE the judged folder.
///   ANTICHAT_REAL_SD=1 ANTICHAT_REAL_EDIT=qwen ANTICHAT_EDIT_AB_OUT=<dir> ANTICHAT_FIXTURES=… gpu-run.sh shared -- …
@Suite(.serialized, .enabled(if: RealPhoto.enabled && ProcessInfo.processInfo.environment["ANTICHAT_EDIT_AB_OUT"] != nil))
struct EditRefCapABTests {
    static func gate() throws -> MediaOutputGate {
        let base = RealPhoto.models
        let nud = base.appending(path: "csc-nudity/onnx/model.onnx"), age = base.appending(path: "csc-age/mivolo_v2_age.onnx")
        let bins = base.appending(path: "csc-age-bins/model.safetensors")
        func sha(_ u: URL) throws -> String {
            SHA256.hash(data: try Data(contentsOf: u, options: .alwaysMapped)).map { String(format: "%02x", $0) }.joined()
        }
        let m = SafetyManifest(nudityPath: nud.path, agePath: age.path, ageBinsPath: bins.path,
                               sha256: ["csc-nudity": try sha(nud), "csc-age": try sha(age), "csc-age-bins": try sha(bins)], sizeBytes: 0)
        return MediaOutputGate(manifestProvider: { m })
    }

    @Test func unmaskedEditsAtTwoReferenceCaps() async throws {
        let out = URL(fileURLWithPath: ProcessInfo.processInfo.environment["ANTICHAT_EDIT_AB_OUT"]!)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let cap = RealPhoto.refPixels
        try #require(cap > 0, "ANTICHAT_EDIT_REF_PIXELS names the cap under test")
        let goldens = try RealPhoto.goldens()
        let side = 1024
        var outputs: [String: [Int: Data]] = [:]  // golden id → cap (0 = 1 MP default) → engine PNG, in memory
        var secs: [String: [Int: Double]] = [:]
        for c in [cap, 0] {
            let set = RealPhoto.qwenEdit(refPixels: c)
            try #require(RealPhoto.installed(set))
            let empty = FileManager.default.temporaryDirectory.appendingPathComponent("sd-empty-\(UUID().uuidString)").path
            let sup = SDServerSupervisor(config: .init(binary: RealPhoto.binary, logFile: nil, modelDir: empty))
            _ = try await sup.start(set)
            let client = await sup.client
            for g in goldens {
                let src = try #require(RealPhoto.load(RealPhoto.sourceURL(g)))
                let (raw, t) = try await RealPhoto.run(client, prompt: g.instruction, size: side, steps: 4, seed: 42,
                                                       refs: [RealPhoto.png(src, side: side)], loras: set.loras ?? [])
                outputs[g.id, default: [:]][c] = raw
                secs[g.id, default: [:]][c] = t
            }
            await sup.stop()
        }
        let gate = try Self.gate()
        var key: [String: Any] = ["cap_under_test": cap, "baseline": "sd.cpp default (1 MP)"]
        var rows: [[String: Any]] = []
        for g in goldens {
            let srcPNG = RealPhoto.png(try #require(RealPhoto.load(RealPhoto.sourceURL(g))), side: side)
            let input = try #require(MaskCompositor.decode(srcPNG))
            let mask = try #require(RealPhoto.load(RealPhoto.maskURL(g)))
            var row: [String: Any] = ["id": g.id]
            var allowed: [Int: Data] = [:]
            for c in [cap, 0] {
                guard let png = outputs[g.id]?[c], let img = MaskCompositor.decode(png) else { continue }
                let verdict = await gate.checkResult(img, job: "ab-\(g.id)-\(c)")
                row["gate_\(c)"] = "\(verdict)"
                guard verdict == .allow else { continue }
                allowed[c] = png
                // Numbers: drift of the region the instruction does not name (outside the golden mask) vs the source.
                row["outside_diff_\(c)"] = MaskCompositor.meanAbsDiffOutside(input, img, mask: mask)
                row["inside_diff_\(c)"] = MaskCompositor.meanAbsDiffInside(input, img, mask: mask)
                row["secs_\(c)"] = secs[g.id]?[c] ?? -1
            }
            rows.append(row)
            guard let capPNG = allowed[cap], let basePNG = allowed[0] else { continue }
            let capIsA = Bool.random()
            try (capIsA ? capPNG : basePNG).write(to: out.appendingPathComponent("\(g.id)-A.png"))
            try (capIsA ? basePNG : capPNG).write(to: out.appendingPathComponent("\(g.id)-B.png"))
            try srcPNG.write(to: out.appendingPathComponent("\(g.id)-source.png"))
            try Data(g.instruction.utf8).write(to: out.appendingPathComponent("\(g.id)-instruction.txt"))
            key[g.id] = capIsA ? "A=cap B=1MP" : "A=1MP B=cap"
        }
        await gate.release()
        key["rows"] = rows
        let keyURL = out.deletingLastPathComponent().appendingPathComponent(out.lastPathComponent + "-key.json")
        try JSONSerialization.data(withJSONObject: key, options: [.prettyPrinted, .sortedKeys]).write(to: keyURL)
        RealPhoto.log("EditRefCapABTests cap \(cap): \(rows)")
        #expect(rows.count == goldens.count)
    }
}
