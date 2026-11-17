// AT-238 (R-238) — M2.T24, UI half in-process (XCUITest InstallCardUITests is blocked here, Q-015):
//   - AC2: Install → progress → once verified the ORIGINAL request re-runs automatically in the same chat (no extra
//     user action): a new version of the reply whose create_image call runs and returns the scripted result;
//     the pending row is gone;
//   - AC3: an ineligible Mac's card reads "Video doesn't run well on this Mac (needs 24 GB memory)." with no button;
//   - [Not now] removes the card and the waiting request and answers the same reply in text (no media tool); a
//     reopened chat shows a waiting card again, also a button-less one (unavailable / coming soon);
//   - snapshots of every card state (offered, downloading, done, not available, disk short), light + dark.
// Re-record: SNAPSHOT_TESTING_RECORD=all make test-unit FILTER=InstallCardTests.
import AntiChatEngineProtocol
import AntiChatHarness
import AntiChatStorage
import AppKit
import Foundation
import SnapshotTesting
import SwiftUI
import Synchronization
import Testing
@testable import AntiChatDesign
@testable import AntiChatUI

/// The pack store: `install` starts a download that reports 40 %, then 80 %, then installed (one step per poll).
final class SteppingPacks: PackInstalling {
    let state: Mutex<[MediaPack: PackAvailability]>
    let steps = Mutex<[PackAvailability]>([])
    let installs = Mutex(0)
    init(_ s: [MediaPack: PackAvailability]) { state = Mutex(s) }
    func availability(_ pack: MediaPack) async -> PackAvailability {
        if let next = steps.withLock({ $0.isEmpty ? nil : $0.removeFirst() }) { state.withLock { $0[pack] = next } }
        return state.withLock { $0[pack] ?? .installed }
    }
    func install(_ pack: MediaPack) async -> PackInstallStart {
        installs.withLock { $0 += 1 }
        steps.withLock { $0 = [.installing(percent: 40), .installing(percent: 80), .installed] }
        return .started
    }
}

extension WindowSuites {
@MainActor
@Suite(.serialized, .isolatedSettings) struct InstallCardTests {
    /// The re-run's script: the forced create_image call, then a short answer.
    static let rerun = """
        {"t":"toolCallDone","id":"call_1","name":"create_image","args":"{\\"prompt\\":\\"a fox\\"}","delayMs":1}
        {"t":"turn"}
        {"t":"textDelta","v":"Done.","delayMs":1}
        """

    func make(_ packs: SteppingPacks, script: String = Self.rerun) throws -> (ConversationModel, ChatEnvironment, ToolRegistry) {
        let db = try AppDatabase.inMemory()
        let image = RegisteredTool(name: "create_image", description: "Create a picture.",
                                   parametersJSON: #"{"type":"object","properties":{"prompt":{"type":"string"}},"required":["prompt"]}"#,
                                   outputIsUntrusted: false) { _ in #"{"status":"done","image":"scripted.png"}"# }  // ScriptedImageEngine stand-in
        let registry = ToolRegistry([ScriptedTools.getTime(), image])
        let env = ChatEnvironment(
            database: db, engine: InProcessScriptedEngine(script: try EngineScript(text: script)),
            tools: ToolRuntime(registry: registry, permissions: ToolPermissionStore(db), policy: .forTier(.t1), selection: .standard,
                               tier: { .t1 }),
            packs: packs, slot: { .scripted("inline") })
        let m = ConversationModel(environment: env)
        m.installPollInterval = .milliseconds(5)
        return (m, env, registry)
    }

    func wait(_ until: () -> Bool) async {
        for _ in 0..<1000 where !until() { try? await Task.sleep(for: .milliseconds(10)) }
    }

    @Test func installThenTheOriginalRequestRunsAgain() async throws {
        let packs = SteppingPacks([.photo: .installable(bytes: 6_400_000_000, minutes: 17)])
        let (m, env, registry) = try make(packs)
        m.chipIDs = ["image"]
        m.send("a fox in the snow")
        await wait { m.messages.last?.installCard != nil && !m.isGenerating }
        let first = try #require(m.messages.last)
        #expect(first.installCard?.state == .offered(bytes: 6_400_000_000, minutes: 17))
        #expect(registry.invocations(of: "create_image") == 0)
        #expect(PendingRequestStore(env.database).pending(chatID: m.chatID).count == 1)
        m.chipIDs = []  // the re-run must not depend on the composer still holding the chip
        m.installFromCard(first.id)
        await wait { registry.invocations(of: "create_image") == 1 && !m.isGenerating && m.messages.last?.status == .done }
        #expect(packs.installs.withLock { $0 } == 1)
        let reply = try #require(m.messages.last)
        #expect(reply.id != first.id && reply.version == 2)  // a new version of the same reply: the original request
        #expect(m.messages.count == 2 && m.messages[0].text == "a fox in the snow")
        #expect(reply.installCard == nil && reply.activities.contains { $0.tool == "create_image" && $0.state == .done })
        #expect(PendingRequestStore(env.database).pending(chatID: m.chatID).isEmpty)
    }

    @Test func notNowAndReopen() async throws {
        let packs = SteppingPacks([.video: .installable(bytes: 18_000_000_000, minutes: 48)])
        let (m, env, registry) = try make(packs, script: #"{"t":"textDelta","v":"Waves roll in and break on the sand.","delayMs":1}"#)
        m.chipIDs = ["video"]
        m.send("waves on a beach")
        await wait { m.messages.last?.installCard != nil && !m.isGenerating }
        let id = try #require(m.messages.last?.id)
        // Reopened: the waiting request shows its card again.
        let reopened = ConversationModel(environment: env, chatID: m.chatID)
        await wait { reopened.messages.last?.installCard != nil }
        #expect(reopened.messages.last?.installCard?.pack == .video)
        m.dismissInstallCard(id)
        #expect(m.messages.last?.installCard == nil)
        #expect(PendingRequestStore(env.database).pending(chatID: m.chatID).isEmpty)
        // [Not now] answers the same reply in text (never an empty bubble), with no media tool run; the chip stays in
        // the composer for the next message.
        await wait { m.messages.last?.status == .done && !(m.messages.last?.text.isEmpty ?? true) && !m.isGenerating }
        let reply = try #require(m.messages.last)
        #expect(reply.id == id && reply.text == "Waves roll in and break on the sand." && reply.installCard == nil)
        #expect(m.messages.count == 2 && reply.versionCount <= 1)
        #expect(registry.invocations(of: "create_image") == 0 && m.chipIDs == ["video"])
    }

    /// A button-less card (this Mac can't run Video) is remembered too: a reopened chat shows the card, not an empty row.
    @Test func unavailableCardSurvivesReopen() async throws {
        let packs = SteppingPacks([.video: .unavailable(reason: "needs 24 GB memory")])
        let (m, env, _) = try make(packs)
        m.chipIDs = ["video"]
        m.send("waves on a beach")
        await wait { m.messages.last?.installCard != nil && !m.isGenerating }
        #expect(m.messages.last?.installCard?.state == .unavailable(reason: "needs 24 GB memory"))
        let reopened = ConversationModel(environment: env, chatID: m.chatID)
        await wait { reopened.messages.last?.installCard != nil }
        #expect(reopened.messages.last?.installCard?.state == .unavailable(reason: "needs 24 GB memory"))
        #expect(reopened.messages.last?.installCard?.hasButtons == false)
    }

    @Test func ineligibleCardText() {
        let card = InstallCard(pack: .video, state: .unavailable(reason: "needs 24 GB memory"))
        #expect(InstallCardView.text(card).string == "Video doesn't run well on this Mac (needs 24 GB memory).")
        #expect(!card.hasButtons)
        let offered = InstallCard(pack: .photo, state: .offered(bytes: 6_400_000_000, minutes: 17))
        #expect(InstallCardView.text(offered).string == "Images isn't installed. Install it (6.4 GB, ~17 min) and I'll make your image.")
    }

    /// PackRow state → card availability (the reason reads lower-case inside the sentence).
    @Test func capabilitiesMapping() {
        #expect(CapabilitiesPackInstaller.availability(.notAvailable(reason: CopyText(CopyKey("onb.pack.dimmed.ram"), ["gb": "24"])),
                                                       installed: false) == .unavailable(reason: "needs 24 GB memory"))
        #expect(CapabilitiesPackInstaller.availability(.ready(bytesOnDisk: 1), installed: true) == .installed)
        #expect(CapabilitiesPackInstaller.availability(.downloading(percent: 30, paused: false), installed: false) == .installing(percent: 30))
        #expect(CapabilitiesPackInstaller.availability(.off(downloadBytes: 6_000_000_000), installed: false)
            == .installable(bytes: 6_000_000_000, minutes: CapabilitiesPackInstaller.minutes(6_000_000_000)))
    }

    @Test func snapshots() {
        let states: [(String, InstallCard)] = [
            ("offered", InstallCard(pack: .photo, state: .offered(bytes: 6_400_000_000, minutes: 17))),
            ("downloading", InstallCard(pack: .photo, state: .downloading(percent: 42))),
            ("done", InstallCard(pack: .photo, state: .done)),
            ("unavailable", InstallCard(pack: .video, state: .unavailable(reason: "needs 24 GB memory"))),
            ("diskShort", InstallCard(pack: .video, state: .diskShort(gbNeeded: 12))),
        ]
        for (name, card) in states {
            for look in ComposerSnapshotTests.Look.allCases {
                assertSnapshot(of: EvilSnapshotTests.render(InstallCardView(card: card), look: look, width: 560),
                               as: .image(precision: 1, perceptualPrecision: 0.98), named: "\(name)-\(look.rawValue)",
                               testName: "installCard")
            }
        }
    }
}
}
