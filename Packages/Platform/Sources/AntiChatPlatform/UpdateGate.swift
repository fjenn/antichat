// M2.T02 step 5 (R-297, P-platform-08): Sparkle's package hook. Sparkle downloads with its own NSURLSession
// (SPUDownloader.m), which no Swift injection reaches, so the gate is applied at the decision points: an update
// check, and the release download, happen only while the `updates` category is on. Full Sparkle wiring is M10
// (G-060); the updater is created with this delegate.
import Foundation
import AntiChatNetwork
import Sparkle

public final class UpdateGateDelegate: NSObject, SPUUpdaterDelegate {
    private let policy: NetworkPolicyStore

    public init(policy: NetworkPolicyStore = .shared) { self.policy = policy }

    public func updater(_ updater: SPUUpdater, mayPerform updateCheck: SPUUpdateCheck) throws {
        guard policy.isEnabled(.updates) else { throw NetworkGate.blocked(.updates) }
    }

    public func updater(_ updater: SPUUpdater, shouldProceedWithUpdate updateItem: SUAppcastItem,
                        updateCheck: SPUUpdateCheck) throws {
        guard policy.isEnabled(.updates) else { throw NetworkGate.blocked(.updates) }
    }

    public func updater(_ updater: SPUUpdater, shouldDownloadReleaseNotesForUpdate updateItem: SUAppcastItem) -> Bool {
        policy.isEnabled(.updates)
    }
}
