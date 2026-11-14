import Foundation

public struct OutputHarvester: Sendable {
    public init() {}

    public func harvest(_ files: [URL], chatID: String, messageID: String?, store: ArtifactStore) throws -> [SavedArtifact] {
        try files.map { url in
            let ext = url.pathExtension.lowercased()
            let kind = ext == "png" ? "chart" : ext
            return try store.save(chatID: chatID, kind: kind, filename: url.lastPathComponent,
                                  data: try Data(contentsOf: url), specJSON: nil, messageID: messageID)
        }
    }

    public func harvestAndDescribe(_ files: [URL], chatID: String, messageID: String?, store: ArtifactStore) throws -> [String] {
        try harvestCards(files, chatID: chatID, messageID: messageID, store: store).map(\.text)
    }

    /// Each saved file's card and its text for the model (`FileOutResult.text`).
    public func harvestCards(_ files: [URL], chatID: String, messageID: String?,
                             store: ArtifactStore) throws -> [(card: FileOutResult, text: String)] {
        try harvest(files, chatID: chatID, messageID: messageID, store: store).map { saved in
            let versions = saved.version > 1 ? VersioningService(store: store).versions(of: saved.artifactID) : []
            return (FileOutResult.card(saved, format: saved.kind, pages: nil, versions: versions),
                    FileOutResult.text(saved, format: saved.kind, pages: nil, versions: versions))
        }
    }
}
