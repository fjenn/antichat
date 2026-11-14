// M5.T10 step 1 / step 6 (R-040 AC1, R-043 AC1; G-045; P-shell-13 reused; AT-040 AC1 `$XINT …/VideoIntentTests`):
//   * prototype data: `video_create` / `video_from_image` utterances in all six router languages, thresholds fitted on
//     the M2.T23 calibration split of router-300 (the frozen dataset's sha256; the 200 held-out rows never fitted);
//   * threshold logic (PreRouter.top on synthetic margins): a video margin above its threshold routes to video, a
//     near-tie with a picture is never "confident" (decisiveGap), below threshold stays chat;
//   * the image-attached → I2V rule and "the last image" (VideoRoute), the intent kinds (countdown rule, R-290 AC2);
//   * @realModels (`ANTICHAT_REAL_ROUTER=1`, the dev `embed` model through the XPC helper; NOT run in unit gates):
//     video prompts in six languages → a video route; the same request with an image attached → I2V.
//   make test-unit FILTER=VideoIntentTests
import AntiChatEngineProtocol
import AntiChatFoundation
import CryptoKit
import Foundation
import Testing
@testable import AntiChatHarness

@Suite struct VideoIntentTests {
    static let languages = ["en", "de", "es", "fr", "nl", "pt"]

    static var fixtures: URL {
        ProcessInfo.processInfo.environment["ANTICHAT_FIXTURES"].map { URL(fileURLWithPath: $0) }
            ?? StreamPersisterTests.repoRoot.appendingPathComponent("fixtures")
    }

    // MARK: prototypes + thresholds (no model)

    @Test func videoPrototypesInSixLanguages() throws {
        let p = try #require(RoutePrototypes.bundled)
        for route in [Route.videoCreate, .videoFromImage] {
            let langs = try #require(p.file.routes[route.rawValue], "\(route.rawValue) prototypes")
            for l in Self.languages {
                #expect((langs[l]?.count ?? 0) >= 20, "\(route.rawValue)/\(l): \(langs[l]?.count ?? 0) utterances")
            }
            #expect(p.rows.filter { $0.route == route }.count >= 120)
            #expect(route.tools == [CreateVideoToolName.name], "both video routes expose create_video")
        }
    }

    @Test func thresholdsFittedOnTheFrozenCalibrationSplit() throws {
        let p = try #require(RoutePrototypes.bundled)
        let url = Self.fixtures.appendingPathComponent("prompts/router-300.jsonl")
        let data = try #require(FileManager.default.contents(atPath: url.path), "router-300 missing (ANTICHAT_FIXTURES)")
        let sha = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        #expect(p.file.datasetSHA256 == sha, "thresholds fitted on the frozen router-300")
        for route in [Route.videoCreate, .videoFromImage] {
            let t = try #require(p.file.thresholds[route.rawValue], "\(route.rawValue) fitted")
            #expect(t.low > 0 && t.high >= t.low)
        }
        // The split: 100 calibration rows (the only rows fit.py reads, `set == calib`), 200 held-out test rows, disjoint.
        let split = try #require(FileManager.default.contents(atPath: Self.fixtures.appendingPathComponent("prompts/router-300.split.json").path))
        let o = try #require(try JSONSerialization.jsonObject(with: split) as? [String: Any])
        let calib = Set(o["calib"] as? [String] ?? []), test = Set(o["test"] as? [String] ?? [])
        #expect(calib.count == 100 && test.count == 200 && calib.isDisjoint(with: test))
    }

    @Test func thresholdLogicRoutesVideo() throws {
        let p = try #require(RoutePrototypes.bundled)
        let th = p.thresholds, gap = p.file.decisiveGap ?? 0
        let vc = th[.videoCreate]!
        func scores(_ video: Float, image: Float = 0.30, chat: Float = 0.30) -> [Route: Float] {
            var s = Dictionary(uniqueKeysWithValues: Route.intents.map { ($0, Float(0.1)) })
            s[.chat] = chat
            s[.videoCreate] = video
            s[.imageCreate] = image
            return s
        }
        // Clearly above the video threshold, nothing else close → video, confident.
        let (top, confident) = PreRouter.top(scores(0.30 + vc.high + 0.05), thresholds: th, decisiveGap: gap)
        #expect(top == .videoCreate && confident)
        // Below the threshold → chat (no forced tool).
        #expect(PreRouter.top(scores(0.30 + vc.low * 0.5), thresholds: th, decisiveGap: gap).0 == nil)
        // A near-tie with a picture (same excess over each threshold) is never confident.
        let ic = th[.imageCreate]!
        let tie = scores(0.30 + vc.high + 0.02, image: 0.30 + ic.low + vc.high - vc.low + 0.02 - gap / 2)
        #expect(PreRouter.top(tie, thresholds: th, decisiveGap: gap).1 == false)
    }

    // MARK: VideoRoute (no model)

    @Test func imageAttachedStartsImageToVideo() {
        let f = VideoRoute.Facts(routeTop: .videoCreate, userText: "make a short clip of this", attachedImageIDs: ["att-1", "att-2"])
        let c = VideoRoute.choose(f)
        #expect(c.mode == .i2v && c.sourceImageID == "att-2", "the newest attached picture is the source (R-040 AC1)")
        #expect(c.intent == .namedVideo)
        // No picture → text-to-video.
        let t = VideoRoute.choose(VideoRoute.Facts(routeTop: .videoCreate, userText: "make a clip of waves"))
        #expect(t.mode == .t2v && t.sourceImageID == nil)
    }

    @Test func lastImageIsTheSourceInSixLanguages() {
        let phrases = ["Animate the last image", "Mach ein Video aus dem letzten Bild", "Anima la última imagen",
                       "Anime la dernière image", "Animeer de laatste afbeelding", "Anime a última imagem"]
        for p in phrases {
            #expect(VideoRoute.refersToLastImage(p), "\(p)")
            let c = VideoRoute.choose(VideoRoute.Facts(routeTop: .videoFromImage, userText: p, lastImageID: "art-9"))
            #expect(c.mode == .i2v && c.sourceImageID == "art-9", "\(p)")
        }
        #expect(!VideoRoute.refersToLastImage("make a video of the sea"))
        // Without a reference the chat's last picture is never used.
        #expect(VideoRoute.choose(VideoRoute.Facts(routeTop: .videoCreate, userText: "a clip of a train", lastImageID: "art-9")).mode == .t2v)
    }

    @Test func animateAndCallSourcesWin() {
        let chips = [VideoRoute.chipID, VideoRoute.animateChip("art-3")]
        let a = VideoRoute.choose(VideoRoute.Facts(chips: chips, userText: "Animate", attachedImageIDs: ["att-1"]), callSourceImageID: "x")
        #expect(a.mode == .i2v && a.sourceImageID == "art-3" && a.intent == .animate, "Animate's picture and intent")
        let m = VideoRoute.choose(VideoRoute.Facts(userText: "a clip"), callSourceImageID: "art-5")
        #expect(m.mode == .i2v && m.sourceImageID == "art-5", "the model's source_image_id")
        #expect(VideoRoute.animateSource(chips: ["animate:"]) == nil)
    }

    @Test func intentKinds() {
        #expect(VideoRoute.intent(VideoRoute.Facts(chips: ["video"], userText: "the sea")) == .createVideoChip)
        #expect(VideoRoute.intent(VideoRoute.Facts(routeTop: .videoCreate, userText: "the sea moving")) == .namedVideo)
        #expect(VideoRoute.intent(VideoRoute.Facts(userText: "Fais une vidéo de la mer")) == .namedVideo, "a video word")
        #expect(VideoRoute.intent(VideoRoute.Facts(userText: "show me the ocean at sunset")) == .inferred)
        #expect(!VideoPlanPolicy.Intent.inferred.isExplicit && VideoPlanPolicy.Intent.animate.isExplicit)
    }

    // MARK: @realModels (gated; not run in unit gates)

    static let videoPrompts: [(String, String)] = [
        ("en", "Make a short video of waves crashing on a beach"), ("de", "Erstelle ein kurzes Video von einem Zug im Schnee"),
        ("es", "Hazme un clip corto de un perro corriendo por la playa"), ("fr", "Fais une courte vidéo d'une montgolfière au lever du soleil"),
        ("nl", "Maak een kort filmpje van een kat die met een bal speelt"), ("pt", "Faz um vídeo curto de fogos de artifício sobre um lago"),
    ]

    @Test(.tags(.realModels), .enabled(if: ProcessInfo.processInfo.environment["ANTICHAT_REAL_ROUTER"] == "1"))
    func realRouterSendsVideoPromptsToVideo() async throws {
        let router = try await Self.realRouter()
        for (lang, text) in Self.videoPrompts {
            let d = await router.decide(userText: text, hasImage: false, chips: [], tools: [], tier: .t3)
            #expect(d.top?.isVideo == true, "\(lang): \(text) → \(String(describing: d.top))")
            let i = await router.decide(userText: text, hasImage: true, chips: [], tools: [], tier: .t3)
            #expect(i.top?.isVideo == true, "\(lang) + image → \(String(describing: i.top))")
            let c = VideoRoute.choose(VideoRoute.Facts(routeTop: i.top, userText: text, attachedImageIDs: ["att"]))
            #expect(c.mode == .i2v, "\(lang): image + video request → I2V")
        }
    }

    /// The bundled prototypes over the dev `embed` model through the XPC helper (as `antichat-bench router`).
    static func realRouter() async throws -> PreRouter {
        let client = EngineClient(appBuild: "video-intent-tests")
        let models = ProcessInfo.processInfo.environment["ANTICHAT_DEV_CACHE"].map { URL(fileURLWithPath: $0).appendingPathComponent("Models") }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/AntiChat-Dev/Models")
        let view = models.appendingPathComponent("installs/embed")
        let dir = FileManager.default.fileExists(atPath: view.path) ? view : models.appendingPathComponent("embed")
        let slot = ModelSlot(engine: .mlx, key: "embed", path: dir.path, footprintBytes: 1_000_000_000)
        let embedder = HelperEmbedder(engine: client, embedSlot: { slot })
        let protos = try #require(RoutePrototypes.bundled)
        let scorer = RouteScorer(prototypes: protos, embedding: embedder,
                                 cacheDirectory: FileManager.default.temporaryDirectory.appendingPathComponent("video-intent-router"))
        _ = await scorer.prepare()
        var router = PreRouter(scorer: scorer, enabled: { true })
        router.sendBudget = nil
        return router
    }
}

extension Tag {
    @Tag static var realModels: Self
}

/// The tool name the video routes expose (CreateVideoTool lives in AntiChatTools).
enum CreateVideoToolName { static let name = "create_video" }
