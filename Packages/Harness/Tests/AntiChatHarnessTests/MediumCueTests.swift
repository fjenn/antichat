// AT-238 (R-238 AC1) pack precision — M2.T26 fix: the install card names the medium the request asked for. Over
// fixtures/prompts/media-100.jsonl: (1) no cue ever contradicts the label (also over router-300, the frozen
// calibration set, as a held-out check); (2) worst case — the router picks the OTHER medium on every row (the
// AT-238 2026-11-03 failure: "create an animation of …" → Photo card) — the card still names the labelled medium on
// ≥ 98/100; the misses are rows without any medium word ("render a futuristic city skyline at dawn, wide shot",
// "Mal mir eine Weltkarte …"), where the router's choice must stand; (3) the model calling the wrong media tool shows
// the requested pack's card; a chip wins over the words.
import AntiChatEngineProtocol
import Foundation
import Testing
@testable import AntiChatHarness

@Suite struct MediumCueTests {
    struct Row: Decodable { var id: String; var text: String; var label: String; var attachment: String? }

    static func rows(_ name: String) throws -> [Row]? {
        let root = ProcessInfo.processInfo.environment["ANTICHAT_FIXTURES"].map { URL(fileURLWithPath: $0) }
            ?? StreamPersisterTests.repoRoot.appendingPathComponent("fixtures")
        let url = root.appendingPathComponent("prompts/\(name).jsonl")
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try String(contentsOf: url, encoding: .utf8).split(separator: "\n")
            .map { try JSONDecoder().decode(Row.self, from: Data($0.utf8)) }
    }

    static func medium(_ label: String) -> MediaPack? {
        label.hasPrefix("video") ? .video : label.hasPrefix("image") ? .photo : nil
    }

    @Test(arguments: ["media-100", "router-300"])
    func noCueContradictsTheLabel(_ set: String) throws {
        let rows = try #require(try Self.rows(set), "fixtures/prompts/\(set).jsonl missing (ANTICHAT_FIXTURES)")
        let wrong = rows.compactMap { r -> String? in
            guard let m = Self.medium(r.label), let cue = MediumCue.medium(r.text, hasImage: r.attachment == "image"),
                  cue != m else { return nil }
            return "\(r.id) \(r.label) → \(cue)"
        }
        #expect(wrong.isEmpty, "\(wrong)")
    }

    @Test func cardNamesTheLabelledMediumEvenWhenTheRouterPicksTheOtherOne() throws {
        let rows = try #require(try Self.rows("media-100"), "fixtures/prompts/media-100.jsonl missing (ANTICHAT_FIXTURES)")
        #expect(rows.count == 100)
        var hits = 0, misses: [String] = []
        for r in rows {
            let m = try #require(Self.medium(r.label))
            let has = r.attachment == "image"
            let wrongTop: Route = m == .video ? (has ? .imageEdit : .imageCreate) : (has ? .videoFromImage : .videoCreate)
            let d = RouteDecision(top: MediumCue.resolve(wrongTop, text: r.text, hasImage: has), confident: true)
            if InstallCardPolicy.pack(for: d) == m { hits += 1 } else { misses.append(r.id) }
        }
        #expect(hits >= 98, "pack == labelled medium on \(hits)/100; misses \(misses)")
        // Every video request names its medium (the 7 AT-238 misses were all video → Photo).
        let videoMisses = misses.filter { id in rows.first { $0.id == id }.map { Self.medium($0.label) == .video } ?? false }
        #expect(videoMisses.isEmpty, "\(videoMisses)")
    }

    @Test func cuesAndNonCues() {
        #expect(MediumCue.medium("create an animation of a hummingbird", hasImage: false) == .video)
        #expect(MediumCue.medium("Genera un clip de una playa tropical", hasImage: false) == .video)
        #expect(MediumCue.medium("Laat deze foto bewegen, de vlag moet wapperen", hasImage: true) == .video)
        #expect(MediumCue.medium("Anime cette photo de cascade", hasImage: true) == .video)
        #expect(MediumCue.medium("Convierte esta foto en estilo anime", hasImage: true) == .photo)
        #expect(MediumCue.medium("draw the cover art for a video game", hasImage: false) == .photo)
        #expect(MediumCue.medium("what's the weather like?", hasImage: false) == nil)
        // Only swaps between media routes; never turns a non-media route into one.
        #expect(MediumCue.resolve(.webNeeded, text: "find a video of cats", hasImage: false) == .webNeeded)
        #expect(MediumCue.resolve(nil, text: "a video of cats", hasImage: false) == nil)
        #expect(MediumCue.resolve(.imageCreate, text: "a video of cats", hasImage: false) == .videoCreate)
        #expect(MediumCue.resolve(.videoCreate, text: "make this photo look old", hasImage: true) == .imageEdit)
    }

    /// Soak dry run 2: the words back a media route (card / forced re-ask allowed) only when they name a medium or an
    /// art style, or an image is attached to an edit / animate route. Name requests near the "logo for my coffee shop"
    /// prototype never do.
    @Test func confirmsMediaOnlyWhenTheWordsBackIt() {
        #expect(!MediumCue.confirmsMedia("Suggest a name for a small bakery that sells sourdough.", hasImage: false, top: .imageCreate))
        #expect(!MediumCue.confirmsMedia("Name three classic cocktails made with gin, one line each.", hasImage: false, top: .imageCreate))
        #expect(!MediumCue.confirmsMedia("Suggest a name for a small bakery that sells sourdough.", hasImage: false, top: .videoCreate))
        #expect(!MediumCue.confirmsMedia("Wie viel kostet das noch mal mit Steuern?", hasImage: false, top: .imageCreate))  // filler "mal"
        #expect(!MediumCue.confirmsMedia(nil, hasImage: false, top: .imageCreate))
        #expect(MediumCue.confirmsMedia("Draw me a cat wearing a tiny astronaut helmet", hasImage: false, top: .imageCreate))
        #expect(MediumCue.confirmsMedia("Can you make a logo for my bakery?", hasImage: false, top: .imageCreate))
        #expect(MediumCue.confirmsMedia("a cozy cabin in snowy woods at dusk, watercolor", hasImage: false, top: .imageCreate))
        #expect(MediumCue.confirmsMedia("pixel art of a tiny lighthouse on a cliff", hasImage: false, top: .imageCreate))
        #expect(MediumCue.confirmsMedia("ein Fuchs im Herbstwald, fotorealistisch", hasImage: false, top: .imageCreate))
        #expect(MediumCue.confirmsMedia("mal mir bitte einen Comic-Hasen", hasImage: false, top: .imageCreate))
        #expect(MediumCue.confirmsMedia("render a futuristic city skyline at dawn", hasImage: false, top: .imageCreate))
        #expect(MediumCue.confirmsMedia("please erase the guy on the left", hasImage: true, top: .imageEdit))
        #expect(MediumCue.confirmsMedia("bring it to life", hasImage: true, top: .videoFromImage))
        #expect(!MediumCue.confirmsMedia("please erase the guy on the left", hasImage: false, top: .imageEdit))
        #expect(MediumCue.confirmsMedia("what's the weather like?", hasImage: false, top: .webNeeded))  // non-media: n/a
    }

    /// Recall of the confirmation over the labelled sets: every media-100 row and ≥ 129 of router-300's 130 media rows
    /// (the miss: "Ik wil een achtergrond voor mijn laptop …", which still reaches the model with create_image offered).
    @Test func labelledMediaRequestsConfirm() throws {
        let media = try #require(try Self.rows("media-100"), "fixtures/prompts/media-100.jsonl missing (ANTICHAT_FIXTURES)")
        let router = try #require(try Self.rows("router-300"), "fixtures/prompts/router-300.jsonl missing (ANTICHAT_FIXTURES)")
        func misses(_ rows: [Row]) -> [String] {
            rows.compactMap { r -> String? in
                guard let top = Route(rawValue: r.label), top.isMedia else { return nil }
                return MediumCue.confirmsMedia(r.text, hasImage: r.attachment == "image", top: top) ? nil : r.id
            }
        }
        #expect(misses(media).isEmpty, "\(misses(media))")
        #expect(misses(router).count <= 1, "\(misses(router))")
    }

    /// The tool-call path (T24 step 4): the model calls create_image for a clip request → the Video card.
    @Test func wrongMediaToolCallShowsTheRequestedPacksCard() async throws {
        let script = """
            {"t":"toolCallDone","id":"call_1","name":"create_image","args":"{\\"prompt\\":\\"snow\\"}","delayMs":1}
            {"t":"turn"}
            {"t":"textDelta","v":"Here you go!","delayMs":1}
            """
        let engine = CountingEngine(InProcessScriptedEngine(script: try EngineScript(text: script)))
        let off = try await RouterStubs.router(enabled: false)
        let t = InstallCardPolicyTests()
        let (c, log, _, _) = try await t.controller(engine, packs: FakePacks(InstallCardPolicyTests.notInstalled), router: off)
        _ = try await t.send(c, log, "I want a little video of snow falling on a quiet village at night")
        #expect(await c.lastInstallCard?.pack == .video)
    }

    @Test func chipWinsOverTheWords() async throws {
        let engine = TextOnlyEngine()
        let t = InstallCardPolicyTests()
        let (c, log, _, _) = try await t.controller(engine, packs: FakePacks(InstallCardPolicyTests.notInstalled))
        await c.setChips(["image"])
        _ = try await t.send(c, log, "a poster for my video channel")
        #expect(await c.lastInstallCard?.pack == .photo)
    }
}
