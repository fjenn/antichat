// The app's document-search embedder (attachment excerpts M6.T02, project files and project retrieval M8.T04/T05),
// late-bound per database: the composition root attaches the helper's `embed` (+ T2+ `rerank`) once the engine exists
// (`AppRetrievalWiring.attach`); every consumer reads it at use time, so a model installed after launch is picked up.
// An in-memory database (incognito, tests) never gets one: incognito never embeds (R-247).
// Before this, nothing attached a document embedder in the app, so in-app document and project search was
// keyword-only while the benches (which pass one explicitly) were green.
import AntiChatStorage
import Foundation
import Synchronization

public final class DocumentEmbedding: Sendable {
    private let database: AppDatabase
    private let inner = Mutex<(any Embedder)?>(nil)
    private static let byDatabase = Mutex<[ObjectIdentifier: DocumentEmbedding]>([:])

    /// The one registry of a database (it keeps the database alive, so the identifier is never reused).
    public static func `for`(_ database: AppDatabase) -> DocumentEmbedding {
        byDatabase.withLock { map in
            if let r = map[ObjectIdentifier(database)] { return r }
            let r = DocumentEmbedding(database: database)
            map[ObjectIdentifier(database)] = r
            return r
        }
    }

    private init(database: AppDatabase) { self.database = database }

    public func attach(_ embedder: (any Embedder)?) { inner.withLock { $0 = embedder } }

    /// The attached embedder; nil before the composition root attaches one and always for an in-memory database.
    public var embedder: (any Embedder)? { database.isInMemory ? nil : inner.withLock { $0 } }
}
