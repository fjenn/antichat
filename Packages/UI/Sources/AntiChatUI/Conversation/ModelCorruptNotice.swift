// M9.T08 R3 (screens.md S-25 "Corrupt model: Re-download"; copy-deck `model.corrupt` + `model.corrupt.redownload`;
// NFR-S5; AntiChatError `model.corrupt` recovery `.redownload`): a reply that ended with `model.corrupt` shows "This
// model file is damaged." with [Re-download ({size})] — not [Retry], which would load the same damaged file again.
// {size} is only the bad files (Repair.redownloadBytes, as the load gate measured them); when the view checks clean
// (the engine itself reported the fault) it is the model's catalog size. The button evicts the model, runs
// `Repair.run` (re-hash, re-fetch the bad blobs, rebuild the view) and then retries the turn.
import AntiChatDesign
import AntiChatFoundation
import AntiChatHarness
import AntiChatPlatform
import SwiftUI

/// The repair the notice (and Settings › Storage's Repair) runs.
@MainActor
enum ModelRepair {
    /// The re-download size of `modelID` (nil: no store or catalog on this launch, e.g. tests).
    static func bytes(modelID: String) async -> Int64? {
        guard let coordinator = DownloadsLaunch.coordinator else { return nil }
        let models = coordinator.models
        let catalogBytes = CatalogLaunch.shared?.snapshot.catalog?.models[modelID]?.totalBytes
        return await Task.detached(priority: .utility) {
            redownloadBytes(problems: Repair.check(modelID, models: models), measured: { Repair.redownloadBytes($0, models: models, id: modelID) },
                            catalogBytes: catalogBytes)
        }.value
    }

    /// The bad files' size, else (nothing measurable is wrong on disk) the whole model's catalog size.
    nonisolated static func redownloadBytes(problems: [Repair.Problem], measured: ([Repair.Problem]) -> Int64,
                                            catalogBytes: Int64?) -> Int64? {
        let bad = problems.isEmpty ? 0 : measured(problems)
        return bad > 0 ? bad : catalogBytes
    }

    /// Evicts `modelID` from the helper and repairs its view; true when the repair ran without an error.
    static func run(modelID: String) async -> Bool {
        guard let catalog = CatalogLaunch.shared?.snapshot.catalog, let model = catalog.models[modelID],
              let coordinator = DownloadsLaunch.coordinator else { return false }
        return await Task.detached(priority: .utility) {
            _ = await EngineClient.evictConnected([modelID])
            do {
                _ = try await Repair.run(model, catalogVersion: catalog.catalogVersion, coordinator: coordinator)
                return true
            } catch {
                AppLog.log(.store, .error, "repair of \(modelID) failed: \(error)")
                return false
            }
        }.value
    }
}

/// `model.corrupt` in place of the reply, with [Re-download ({size})].
struct ModelCorruptNotice: View {
    let modelID: String
    let onRepaired: () -> Void
    /// No store or catalog on this launch (nothing to measure or repair): [Retry] as before.
    let onRetry: () -> Void
    /// Snapshot tests pin the size (no store in the test process).
    var fixedBytes: Int64?
    @State private var bytes: Int64?
    @State private var repairing = false
    @State private var measured = false

    private var size: Int64? { fixedBytes ?? bytes }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.space2) {
            ErrorInline(AntiChatError(.modelCorrupt))
            if let size {
                Button {
                    repairing = true
                    Task {
                        let ok = await ModelRepair.run(modelID: modelID)
                        repairing = false
                        if ok { onRepaired() }
                    }
                } label: {
                    Text(CopyText(CopyKey("model.corrupt.redownload"), ["size": DownloadAskSheet.size(size)]))
                }
                .buttonStyle(PrimaryButtonStyle())
                .controlSize(.regular)
                .disabled(repairing)
                .accessibilityIdentifier("model.corrupt.redownload")
            } else if measured {
                Button(action: onRetry) { Text(CopyText(CopyKey("msg.retry"))) }
                    .buttonStyle(PrimaryButtonStyle())
                    .controlSize(.regular)
                    .accessibilityIdentifier("messageRetry")
            }
        }
        .task(id: modelID) {
            guard fixedBytes == nil else { return }
            bytes = await ModelRepair.bytes(modelID: modelID)
            measured = true
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("model.corrupt")
    }
}
