// M2.T20 visual QA renders (vq-01 § step 4, vq-02 § starter label): S-04 with every ProgressRow state (waiting, n %,
// Checking, Ready, Paused — no internet, Didn't finish. Retry) and the Evil row; the composer with `starter.quick`,
// `starter.upgraded`, `model.usingLighter` and the ModeSwitch's `evil.downloading` line, Light and Dark; the first-chat
// chips (R-201 AC7). Full-window PNGs go to ANTICHAT_ONB_SHOTS (not committed references).
import AntiChatFoundation
import AntiChatHarness
import AntiChatPlatform
import AppKit
import SwiftUI
import Testing
@testable import AntiChatDesign
@testable import AntiChatUI

extension WindowSuites {
@MainActor
@Suite(.serialized, .isolatedSettings) struct Step4SnapshotTests {
    typealias Look = ComposerSnapshotTests.Look

    static func status(_ rows: [(String, SetupProgress.RowState, Double)], starter: Bool) -> SetupStatus {
        let s = SetupStatus()
        s.progress = SetupProgress(rows: rows.map { .init(group: $0.0, state: $0.1, bytesDone: Int64($0.2 * 1000), bytesTotal: 1000) },
                                   starterReady: starter, tierReady: false, tierPercent: 40, starterFraction: starter ? 1 : 0.3,
                                   evilRemainingBytes: 0, evilVerifying: false)
        return s
    }

    @Test func step4States() {
        let cases: [(String, [(String, SetupProgress.RowState, Double)], Bool)] = [
            ("waiting", [("chat", .downloading(percent: 12), 0.12), ("voice", .waiting, 0), ("photo", .waiting, 0), ("evil", .waiting, 0)], false),
            ("starterReady", [("chat", .downloading(percent: 46), 0.46), ("voice", .checking, 1), ("photo", .downloading(percent: 8), 0.08),
                              ("evil", .waiting, 0)], true),
            ("pausedFailed", [("chat", .ready, 1), ("voice", .paused, 0.5), ("photo", .failed, 0.3), ("evil", .waiting, 0)], true),
            ("allReady", [("chat", .ready, 1), ("voice", .ready, 1), ("photo", .ready, 1), ("evil", .ready, 1)], true),
        ]
        for (name, rows, starter) in cases {
            for look in Look.allCases {
                let m = OnboardingModelTests.model(.T1)
                m.evilOn = true
                m.step = .preparing
                let st = Self.status(rows, starter: starter)
                let img = OnboardingSnapshotTests.render(OnboardingFlow(model: m, status: st), size: CGSize(width: 1280, height: 800), look: look)
                OnboardingSnapshotTests.write(img, "step4-\(name)-\(look.rawValue)")
                #expect(img.size.width == 1280)
            }
        }
        // Footer counts Ready rows; Back on step 4 returns to step 3 (M10 visual QA, onboarding_page4); Open chat is
        // always allowed.
        let m = OnboardingModelTests.model(.T1)
        m.step = .preparing
        m.back()
        #expect(m.step == .evil)
        m.step = .preparing
        var finished = false
        m.onFinish = { finished = true }
        m.next()
        #expect(finished)
    }

    @Test func composerStarterAndEvilLines() {
        let cases: [(String, StarterLabelModel, CopyText?)] = [
            ("quick", .quick(percent: 37), nil),
            ("upgraded", .upgraded, nil),
            ("lighter", .lighter, nil),
            ("evilDownloading", .quick(percent: 80), CopyText(CopyKey("evil.downloading"), ["minutes": "6"])),
        ]
        for (name, label, evil) in cases {
            for look in Look.allCases {
                let c = ComposerModel(evilEnabled: evil != nil)
                c.starterLabel = label
                c.evilUnavailableLine = evil
                let img = ComposerSnapshotTests.render(c, look: look)
                OnboardingSnapshotTests.write(img, "composer-\(name)-\(look.rawValue)")
                #expect(img.size.height > 52)
            }
        }
    }

    @Test func firstChatChipsFollowChosenPacks() {
        let chat = StarterSuggestions.chips(packs: [.chat])
        #expect(chat.count == 3)
        #expect(chat.first?.key.rawValue == "sugg.personal")
        #expect(!chat.contains { $0.pack == .voice })
        let voice = StarterSuggestions.chips(packs: [.chat, .voice, .photo])
        #expect(voice.map(\.key.rawValue) == ["sugg.personal", "sugg.voice", "sugg.image"])
        let d = UserDefaults.inMemory()
        StarterSuggestions.onboardingFinished(packs: [.chat, .voice], defaults: d)
        #expect(StarterSuggestions.chosenPacks(defaults: d) == [.chat, .voice])
        #expect(StarterSuggestions.consumeFirstChat(defaults: d))
        #expect(!StarterSuggestions.consumeFirstChat(defaults: d))
    }
}
}
