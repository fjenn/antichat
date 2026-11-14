// M5.T09 (R-044 AC1/AC2, AT-044 AC1 unit leg; hardware-tiers §4.4; P-media-12): the presets per tier × speed class
// (T2-S1 "Shown-lite": 480p Short text-to-video only, no image-to-video; T2-S2+ 720p Short; T3 720p Short; T4 720p
// Medium with 1080p and Medium allowed), shape validity for every model a job can run on (Wan2.2 FastMetal: sides ×32,
// 4k+1 frames; LTX: sides ×64, 8k+1 frames), Advanced overrides within the tier's limits, and the scaled estimate.
//   make test-unit FILTER=VideoPresetsTests
import Foundation
import Testing
@testable import AntiChatHarness

@Suite("VideoPresetsTests") struct VideoPresetsTests {
    static let table = VideoPresetsTable.bundled
    static let classes = ["S1", "S2", "S3", "S4"]

    @Test func everyEligibleTierHasAnEntry() {
        for tier in ["T2", "T3", "T4"] {
            for s in Self.classes { #expect(Self.table.entry(tier: tier, speedClass: s) != nil, "\(tier)-\(s)") }
        }
        for tier in ["T0", "T1"] {
            for s in Self.classes {
                #expect(VideoPresets.options(tier: tier, speedClass: s, mode: .t2v) == nil, "\(tier): video needs 24 GB")
            }
        }
    }

    @Test func t2S1IsShownLite() throws {
        let o = try #require(VideoPresets.options(tier: "T2", speedClass: "S1", mode: .t2v))
        #expect(o.lite && o.lengths == [.short] && o.resolution == "480p" && o.defaultLength == .short)
        #expect(VideoPresets.options(tier: "T2", speedClass: "S1", mode: .i2v) == nil, "no image-to-video on T2-S1")
        let spec = try #require(VideoPresets.resolve(tier: "T2", speedClass: "S1", mode: .t2v, model: "vid-5b"))
        #expect(spec.width == 832 && spec.height == 480 && spec.frames == 73 && spec.fps == 24 && spec.steps == 3)
        #expect(VideoPresets.resolve(tier: "T2", speedClass: "S1", mode: .t2v, model: "vid-5b", length: .medium)?.length == .short,
                "Medium is not offered: falls back to Short")
        let adv = VideoAdvanced(resolution: "720p")
        #expect(VideoPresets.resolve(tier: "T2", speedClass: "S1", mode: .t2v, model: "vid-5b", advanced: adv)?.resolution == "480p",
                "Advanced cannot exceed the tier")
    }

    @Test func defaultsPerTier() throws {
        for s in ["S2", "S3", "S4"] {
            let o = try #require(VideoPresets.options(tier: "T2", speedClass: s, mode: .t2v))
            #expect(o.resolution == "720p" && o.lengths == [.short] && !o.lite, "T2-\(s)")
            #expect(VideoPresets.options(tier: "T2", speedClass: s, mode: .i2v)?.resolution == "480p")
        }
        for s in Self.classes {
            let t3 = try #require(VideoPresets.options(tier: "T3", speedClass: s, mode: .t2v))
            #expect(t3.resolution == "720p" && t3.lengths == [.short], "T3-\(s)")
            let t4 = try #require(VideoPresets.options(tier: "T4", speedClass: s, mode: .t2v))
            #expect(t4.resolution == "720p" && t4.lengths == [.short, .medium] && t4.defaultLength == .medium, "T4-\(s)")
            #expect(t3.shapes == [.square, .portrait, .landscape] && t3.defaultShape == .landscape)
        }
        let t3 = try #require(VideoPresets.resolve(tier: "T3", speedClass: "S4", mode: .t2v, model: "vid-5b"))
        #expect(t3.width == 1280 && t3.height == 704 && t3.frames == 81 && VideoPlan.seconds(t3.seconds) == "3.4")
        let t4 = try #require(VideoPresets.resolve(tier: "T4", speedClass: "S4", mode: .t2v, model: "vid-5b"))
        #expect(t4.frames == 121 && VideoPlan.seconds(t4.seconds) == "5" && t4.resolution == "720p")
        #expect(t4.width == 1280 && t4.height == 704 && t4.steps == 3, "A-M5-13: Wan2.2-TI2V-5B's native 720p × 121 f")
        #expect(Self.table.tiers.filter { $0.tier == "T4" }.allSatisfy { $0.t2vModel == "vid-5b" })
        #expect(!Self.table.models.contains { $0.key == "vid-14b" }, "A-M5-13: vid-14b is not a catalog model")
    }

    @Test func shapesAreValidForEveryModelOnEveryTier() throws {
        var n = 0
        for e in Self.table.tiers {
            for model in ["vid-5b", "vid-i2v", "vid-ltx", "vid-unknown"] {
                let mode: VideoMode = model == "vid-i2v" ? .i2v : .t2v
                let advanced: [VideoAdvanced] = [.none] + e.resolutions.map { VideoAdvanced(resolution: $0) }
                    + [VideoAdvanced(seconds: 2), VideoAdvanced(seconds: 4), VideoAdvanced(seconds: 10), VideoAdvanced(steps: 9)]
                for adv in advanced {
                    for length in VideoLength.allCases {
                        for shape in VideoShape.allCases {
                            guard let spec = VideoPresets.resolve(tier: e.tier, speedClass: e.speedClass, mode: mode, model: model,
                                                                  length: length, shape: shape, advanced: adv) else {
                                #expect(mode == .i2v && e.lite, "only I2V on Shown-lite is not offered")
                                continue
                            }
                            n += 1
                            #expect(VideoPresets.isValid(spec), "\(e.tier)-\(e.speedClass) \(model) \(length) \(shape) \(adv): \(spec)")
                            #expect(spec.frames <= e.maxFrames)
                            #expect(e.lengths.contains(spec.length))
                            #expect((mode == .t2v ? e.resolutions : e.i2vResolutions).contains(spec.resolution))
                            let r = Self.table.rule(model)
                            #expect((r.stepsMin...r.stepsMax).contains(spec.steps))
                            if model == "vid-ltx" {
                                #expect(spec.width % 64 == 0 && spec.height % 64 == 0 && (spec.frames - 1) % 8 == 0)
                            } else if model != "vid-unknown" {
                                #expect(spec.width % 32 == 0 && spec.height % 32 == 0 && (spec.frames - 1) % 4 == 0)
                            }
                            switch shape {
                            case .square: #expect(spec.width == spec.height)
                            case .portrait: #expect(spec.height > spec.width)
                            case .landscape: #expect(spec.width > spec.height)
                            }
                        }
                    }
                }
            }
        }
        #expect(n > 1000)
    }

    @Test func ltxSnapsTo64AndShapesKeepTheirAspect() throws {
        // 480p's 480 side is not a multiple of 64: LTX gets 512 (×64), Wan2.2 keeps 480 (×32).
        let wan = try #require(VideoPresets.resolve(tier: "T3", speedClass: "S4", mode: .t2v, model: "vid-5b",
                                                    shape: .portrait, advanced: VideoAdvanced(resolution: "480p")))
        #expect(wan.width == 480 && wan.height == 832)
        let ltx = try #require(VideoPresets.resolve(tier: "T3", speedClass: "S4", mode: .t2v, model: "vid-ltx",
                                                    shape: .portrait, advanced: VideoAdvanced(resolution: "480p")))
        #expect(ltx.width == 512 && ltx.height == 832 && ltx.steps == 11)
        #expect(VideoPresets.snapSide(1920, multiple: 64) == 1920 && VideoPresets.snapSide(1950, multiple: 64) == 1920)
        #expect(VideoPresets.snapFrames(97, step: 8, max: 241) == 97 && VideoPresets.snapFrames(99, step: 8, max: 241) == 97)
        #expect(VideoPresets.snapFrames(300, step: 4, max: 241) == 241 && VideoPresets.snapFrames(1, step: 4, max: 241) == 5)
    }

    @Test func advancedOverridesStayWithinTheTier() throws {
        let steps1 = try #require(VideoPresets.resolve(tier: "T3", speedClass: "S4", mode: .t2v, model: "vid-5b",
                                                       advanced: VideoAdvanced(steps: 1)))
        #expect(steps1.steps == 1)
        #expect(VideoPresets.resolve(tier: "T3", speedClass: "S4", mode: .t2v, model: "vid-5b",
                                     advanced: VideoAdvanced(steps: 50))?.steps == 3, "clamped to the model's range")
        #expect(VideoPresets.resolve(tier: "T3", speedClass: "S4", mode: .i2v, model: "vid-i2v",
                                     advanced: VideoAdvanced(steps: 1))?.steps == 20, "steps apply to the tier's T2V model only")
        let long = try #require(VideoPresets.resolve(tier: "T3", speedClass: "S4", mode: .t2v, model: "vid-5b",
                                                     advanced: VideoAdvanced(seconds: 10)))
        #expect(long.frames == 121, "bounded by T3's max_frames")
        let t4 = try #require(VideoPresets.resolve(tier: "T4", speedClass: "S4", mode: .t2v, model: "vid-5b",
                                                   advanced: VideoAdvanced(resolution: "1080p", seconds: 8)))
        #expect(t4.width == 1920 && t4.height == 1088 && t4.frames == 193 && VideoPresets.isValid(t4))
        #expect(VideoPresets.resolve(tier: "T3", speedClass: "S4", mode: .t2v, model: "vid-5b",
                                     advanced: VideoAdvanced(resolution: "1080p"))?.resolution == "720p", "1080p is T4 only")
    }

    @Test func estimateEqualsTheMeasuredRowForDefaultsAndScalesOtherwise() throws {
        let speed = VideoSpeedTable.bundled
        let d = try #require(VideoPresets.resolve(tier: "T2", speedClass: "S1", mode: .t2v, model: "vid-5b"))
        let e = try #require(VideoPresets.estimate(d, speedClass: "S1", budgetGB: 24, table: speed))
        let base = try #require(VideoEstimator.estimate(preset: "t2v-480p-short", speedClass: "S1", budgetGB: 24, table: speed))
        #expect(abs(e.seconds - base.seconds) < 1e-9, "the default preset is the measured clip")
        let sq = try #require(VideoPresets.resolve(tier: "T2", speedClass: "S1", mode: .t2v, model: "vid-5b", shape: .square))
        let es = try #require(VideoPresets.estimate(sq, speedClass: "S1", budgetGB: 24, table: speed))
        #expect(abs(es.tStepS - base.tStepS * Double(640 * 640) / Double(832 * 480)) < 1e-9)
        let med = try #require(VideoPresets.resolve(tier: "T4", speedClass: "S4", mode: .t2v, model: "vid-5b"))
        let em = try #require(VideoPresets.estimate(med, speedClass: "S4", budgetGB: 96, table: speed))
        let b720 = try #require(speed.row(speedClass: "S4", preset: "t2v-720p-short"))
        #expect(abs(em.tStepS - b720.tStepS * Double(31) / Double(21)) < 1e-9, "121 frames = 31 latent frames vs 21")
        #expect(VideoPresets.estimate(med, speedClass: "S9", budgetGB: 96, table: speed) == nil)
        let i2v = try #require(VideoPresets.resolve(tier: "T3", speedClass: "S4", mode: .i2v, model: "vid-i2v"))
        #expect(VideoPresets.basePreset(for: i2v, speedClass: "S4")?.key == "i2v-480p-short")
        let unmeasured = try #require(VideoPresets.resolve(tier: "T4", speedClass: "S4", mode: .t2v, model: "vid-unknown"))
        #expect(VideoPresets.estimate(unmeasured, speedClass: "S4", budgetGB: 96) == nil, "no row for an unmeasured model")
    }

    @Test func yamlMatchesBundledJSON() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let yaml = try String(contentsOf: root.appendingPathComponent("catalog/video-presets.yaml"), encoding: .utf8)
        var obj: [String: Any] = [:]
        var section = ""
        for line in yaml.split(separator: "\n").map(String.init) where !line.hasPrefix("#") {
            if line.hasPrefix("  - ") {
                var list = obj[section] as? [Any] ?? []
                list.append(try JSONSerialization.jsonObject(with: Data(line.dropFirst(4).utf8)))
                obj[section] = list
            } else if let colon = line.firstIndex(of: ":") {
                section = String(line[..<colon])
                let rest = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                if !rest.isEmpty { obj[section] = try JSONSerialization.jsonObject(with: Data(rest.utf8), options: .fragmentsAllowed) }
            }
        }
        let decoded = try JSONDecoder().decode(VideoPresetsTable.self, from: JSONSerialization.data(withJSONObject: obj))
        #expect(decoded == VideoPresetsTable.bundled)
        #expect(!decoded.tiers.isEmpty)
    }
}
