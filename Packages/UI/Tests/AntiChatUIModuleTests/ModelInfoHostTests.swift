// AT-234 leg (2) in process (M1.T25b, R-234 AC2; the XCUITest form App/UITests/ModelInfoTests.swift is committed but
// not run here, Q-015). On the ScriptedEngine and an in-memory database through the window's ChatSessions: after 10
// turns (one interrupted by Stop, one regenerate) every reply's Model info carries exactly the stored row's model id,
// model sha, mode, sampling and tok/s, all non-null; the ⋯ menu lists Model info only with Advanced "Show model info"
// on (default off, `-showModelInfo` override); display formatting; popover snapshot (Light/Dark).
//   make test-unit FILTER=ModelInfoHostTests
// Re-record the snapshot: SNAPSHOT_TESTING_RECORD=all make test-unit FILTER=ModelInfoHostTests
import AntiChatEngineProtocol
import AntiChatFoundation
import AntiChatHarness
import AntiChatStorage
import AppKit
import Defaults
import Foundation
import SnapshotTesting
import SwiftUI
import Testing
@testable import AntiChatDesign
@testable import AntiChatUI

extension WindowSuites {
@MainActor
@Suite(.serialized, .isolatedSettings) struct ModelInfoHostTests {
    static let script = (0..<60).map { #"{"t":"textDelta","v":" w\#($0)","delayMs":15}"# }.joined(separator: "\n")

    private func waitIdle(_ m: ConversationModel) async {
        for _ in 0..<1000 where m.isGenerating || [.pending, .streaming].contains(m.messages.last?.status) {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    @Test func tenRepliesShowTheirStoredProvenance() async throws {
        // A script file, so model_sha is the script's sha256 (ModelManifestSHA, A-M1-T25a b).
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("modelinfo-\(UUID().uuidString).jsonl")
        try Self.script.write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: file) }
        let env = ChatEnvironment(
            database: try AppDatabase.inMemory(),
            engine: InProcessScriptedEngine(script: try EngineScript(text: Self.script)),
            slot: { .scripted(file.path, key: "inline") })
        let sessions = ChatSessions(environment: env)
        let m = sessions.model(for: StorageID.make())
        var replies: [String] = []
        for i in 0..<9 {
            #expect(m.send("question \(i)"))
            if i == 4 {  // interrupted: Stop mid-stream
                for _ in 0..<2000 where m.receivedText(of: m.messages.last?.id ?? "").count < 8 {
                    try? await Task.sleep(for: .milliseconds(5))
                }
                m.stop()
            }
            await waitIdle(m)
            replies.append(try #require(m.messages.last?.id))
        }
        m.regenerate(try #require(m.messages.last?.id))  // turn 10: a regenerate
        await waitIdle(m)
        replies.append(try #require(m.messages.last?.id))
        #expect(Set(replies).count == 10)

        for (i, id) in replies.enumerated() {
            let record = try #require(try MessageRepository(env.database).message(id), "row \(i)")
            if i == 4 { #expect(record.status == .interrupted, "turn 5 interrupted") }
            let info = try #require(m.modelInfo(id), "model info \(i)")
            // Same values as the database row …
            #expect(info == ModelInfo(modelID: record.modelID, provenance: record.provenance), "row \(i)")
            // … and every R-234 field present.
            #expect(info.modelID == "inline", "row \(i)")
            #expect(info.modelSHA?.count == 64, "row \(i) sha")
            #expect(info.mode == .normal)
            #expect(!info.sampling.isEmpty && info.samplingLine != nil, "row \(i) sampling")
            #expect((info.tokPerS ?? 0) > 0, "row \(i) tok/s")
            #expect(info.speedText != nil && info.shortSHA?.count == 12)
        }
        // A user message has no Model info.
        #expect(m.modelInfo(try #require(m.messages.first?.id)) == nil)
    }

    @Test func menuItemOnlyWithTheAdvancedToggle() {
        let reply = ConversationModel.Message(id: "a", role: .assistant, text: "Done.", status: .done,
                                              createdAt: Date(timeIntervalSince1970: 1_793_000_000))
        #expect(ActionBar.moreItems(reply, showModelInfo: false) == [.timestamp, .branch])
        #expect(ActionBar.moreItems(reply, showModelInfo: true) == [.timestamp, .branch, .modelInfo])
        var versions = reply
        versions.versionCount = 2
        #expect(ActionBar.moreItems(versions, showModelInfo: true) == [.timestamp, .branch, .versions, .modelInfo])
        // Default off; the launch override wins over the setting either way.
        #expect(Defaults.Keys.showModelInfo.defaultValue == false)
        #expect(ModelInfoSetting.isEnabled(setting: false, options: LaunchOptions()) == false)
        #expect(ModelInfoSetting.isEnabled(setting: true, options: LaunchOptions()) == true)
        #expect(ModelInfoSetting.isEnabled(setting: false, options: LaunchOptions.parse(["-showModelInfo", "YES"])) == true)
        #expect(ModelInfoSetting.isEnabled(setting: true, options: LaunchOptions.parse(["-showModelInfo", "NO"])) == false)
    }

    static let sample = ModelInfo(modelID: "chat-0.8b", provenance: MessageProvenance(
        modelSHA: "3f1c2a9be04d7781c5e0aa31f2b9c6d4e8f7a6b5c4d3e2f1a0b9c8d7e6f5a4b3", mode: .normal,
        sampling: ["temperature": 0.7, "top_p": 0.8, "top_k": 20, "max_tokens": 4096, "reasoning": 0],
        tokPerS: 41.27, tokPerSSource: "engine"))

    @Test func displayFormatting() {
        let info = Self.sample
        #expect(info.shortSHA == "3f1c2a9be04d")
        #expect(info.samplingLine?.replacingOccurrences(of: "\u{00A0}", with: " ")
                == "temperature 0.7 · top_p 0.8 · top_k 20 · max_tokens 4096 · reasoning 0")
        #expect(info.speedText?.string == "41.3 tok/s")
        #expect(info.modeText?.string == "Normal")
        var estimate = info
        estimate.tokPerSEstimated = true
        #expect(estimate.speedText?.string == "41.3 tok/s (estimated)")
        let empty = ModelInfo(modelID: nil, provenance: nil)
        #expect(empty.shortSHA == nil && empty.samplingLine == nil && empty.speedText == nil && empty.modeText == nil)
        #expect(ModelInfo.number(0.05) == "0.05" && ModelInfo.number(1.5) == "1.5" && ModelInfo.number(42) == "42")
    }

    @Test func popoverSnapshot() {
        for look in ResponseActionsSnapshotTests.Look.allCases {
            assertSnapshot(of: ResponseActionsSnapshotTests.render(ModelInfoPopover(info: Self.sample), width: 320, look: look),
                           as: .image(precision: 1, perceptualPrecision: 0.98),
                           named: "ModelInfoPopover-\(look.rawValue)", testName: "modelInfo")
        }
    }
}
}  // extension WindowSuites
