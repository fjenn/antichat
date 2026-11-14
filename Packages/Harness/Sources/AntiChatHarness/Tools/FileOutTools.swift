// M6.T09/T10 (R-273): `create_document`, `create_spreadsheet` and `export_table` in the tool registry. Local and offline: no download, no process, no network (the
// DOCX writer runs in RenderHost's locked WebView). Side effect `.read` (Always allow): it only adds a file to the
// app's own store, never touches the user's files; the result is our own summary text (trusted). The call runs on the
// calling chat's store (`ToolCallStore.database`, set by TurnController; incognito = its in-memory store + a temp dir)
// and records the reply's message id as `created_by_message_id`.
import AntiChatFoundation
import AntiChatStorage
import AntiChatTools
import Foundation

/// `revises` must name a file of the calling chat (M6.T10, R-273 AC4).
func revisesCheck(_ store: ArtifactStore?) -> (String?) -> String? {
    { revises in
        guard let store else { return revises == nil ? nil : "$.revises: no chat store" }
        return VersioningService(store: store).problem(revises: revises, chatID: TurnContext.chatID)
    }
}

/// AT-273 (xlsx-18 follow-up): a spec problem found while the call runs is the repair text (`{"repair": true, …}`), so
/// the tool loop treats it like a validation error (the repair turn with an example, a forced retry); a render or store
/// failure stays a plain error.
func fileOutRunError(_ e: FileOutError) -> ToolRunError {
    if case .invalidSpec(let problems) = e { return ToolRunError(CreateDocumentTool.repairText(problems)) }
    return ToolRunError(e.description)
}

/// AT-273: what the file-out normaliser may look at for the running call (TurnContext + the chat's store).
func adjustContext(_ store: ArtifactStore?, refs: DataRefStore? = nil) -> FileOutAdjustContext {
    let chat = TurnContext.chatID ?? ""
    return FileOutAdjustContext(
        userText: TurnContext.userText, attachedImages: store?.attachedImages(chatID: chat) ?? [],
        imageExists: { ref in store?.imageData(ref: ref, chatID: chat) != nil },
        dataRefs: refs?.all(chatID: chat).map(\.id) ?? [])
}

/// AT-273 / AT-275: a file-out tool's tolerant rewrite (`adjust`), the wrong-tool check (the user asked for a format
/// another file tool writes → never a file of the other format) and the repair hint (a valid example; the next step
/// must call the tool again).
func fileOutHooks(_ tool: inout RegisteredTool, store fixed: ArtifactStore?, refs: DataRefStore? = nil,
                  normalize: @escaping @Sendable (String, FileOutAdjustContext) -> FileOutAdjusted) {
    let name = tool.name
    let store: @Sendable () -> ArtifactStore? = { fixed ?? ToolCallStore.database.map { FileOutTools.Stores.shared.store(for: $0) } }
    tool.adjust = { raw in
        let r = normalize(raw, adjustContext(store(), refs: refs))
        return (r.json, r.notes)
    }
    let check = tool.validate
    tool.validate = { args in
        (FileOutNormalizer.wrongToolProblem(tool: name, userText: TurnContext.userText).map { [$0] } ?? []) + (check?(args) ?? [])
    }
    tool.repairHint = { args, problem in
        let ctx = adjustContext(store(), refs: refs)
        if let want = FileOutNormalizer.requestedFormat(ctx.userText), FileOutNormalizer.tool(for: want) != name,
           problem.contains("call \(FileOutNormalizer.tool(for: want)) instead") {
            let other = FileOutNormalizer.tool(for: want)
            return (FileOutNormalizer.repairExample(tool: other, argumentsJSON: "{\"format\":\"\(want)\"}", ctx: ctx), other)
        }
        return (FileOutNormalizer.repairExample(tool: name, argumentsJSON: args, ctx: ctx), name)
    }
}

/// The chat database a tool call runs against (TurnController sets it around validate + run).
public enum ToolCallStore {
    @TaskLocal public static var database: AppDatabase?
}

public enum FileOutTools {
    /// Media stores per database (one temp dir per incognito store for the session's life).
    final class Stores: @unchecked Sendable {
        static let shared = Stores()
        private let lock = NSLock()
        private var byDB: [ObjectIdentifier: ArtifactStore] = [:]
        /// Stores closed with their incognito session (weakly held: a reused identifier of a gone store never matches).
        private var closed: [ObjectIdentifier: Weak] = [:]
        private struct Weak { weak var db: AppDatabase? }

        /// M4 review P1-2: the store for `db`, or nil once `db` was closed (an incognito session ended): a late result
        /// of that session never gets a fresh media root, so nothing of it is written anywhere.
        func openStore(for db: AppDatabase) -> ArtifactStore? {
            let isClosed = lock.withLock { closed[ObjectIdentifier(db)]?.db === db }
            return isClosed ? nil : store(for: db)
        }

        func store(for db: AppDatabase, mediaRoot: URL? = nil) -> ArtifactStore {
            lock.withLock {
                if let s = byDB[ObjectIdentifier(db)] { return s }
                let s = ArtifactStore.forDatabase(db, mediaRoot: mediaRoot)
                byDB[ObjectIdentifier(db)] = s
                return s
            }
        }
        func close(_ db: AppDatabase) {
            lock.withLock {
                byDB[ObjectIdentifier(db)] = nil
                closed = closed.filter { $0.value.db != nil }
                closed[ObjectIdentifier(db)] = Weak(db: db)
            }
        }
        /// Tests: a store with its own media root for `db` (never the dev container).
        func install(_ store: ArtifactStore, for db: AppDatabase) {
            lock.withLock { byDB[ObjectIdentifier(db)] = store }
        }
    }

    /// `store` overrides the per-database media store (tests).
    public static func createDocument(store fixed: ArtifactStore? = nil) -> RegisteredTool {
        var tool = RegisteredTool(
            name: CreateDocumentTool.name, description: FileOutSchemas.createDocumentDescription,
            parametersJSON: FileOutSchemas.createDocumentJSON, sideEffect: .read, outputIsUntrusted: false,
            validate: { args in
                let store = fixed ?? ToolCallStore.database.map { Stores.shared.store(for: $0) }
                return CreateDocumentTool.problems(argumentsJSON: args, imageExists: { ref in store?.imageData(ref: ref, chatID: TurnContext.chatID ?? "") != nil },
                                                   revisesProblem: revisesCheck(store))
            },
            run: { args in
                guard let chat = TurnContext.chatID,
                      let store = fixed ?? ToolCallStore.database.map({ Stores.shared.store(for: $0) }) else {
                    throw ToolRunError("create_document runs inside a chat turn only.")
                }
                let message = TurnContext.requestID
                do {
                    return try await CreateDocumentTool.run(argumentsJSON: args, chatID: chat, messageID: message, store: store)
                } catch let e as FileOutError {
                    throw fileOutRunError(e)
                }
            })
        fileOutHooks(&tool, store: fixed, normalize: FileOutNormalizer.document)
        return tool
    }

    /// M6.T11: `create_presentation` (PPTX, four themes).
    public static func createPresentation(store fixed: ArtifactStore? = nil) -> RegisteredTool {
        var tool = RegisteredTool(
            name: CreatePresentationTool.name, description: PresentationSchemas.description,
            parametersJSON: PresentationSchemas.json, sideEffect: .read, outputIsUntrusted: false,
            validate: { args in
                let store = fixed ?? ToolCallStore.database.map { Stores.shared.store(for: $0) }
                return CreatePresentationTool.problems(argumentsJSON: args, imageExists: { store?.imageData(ref: $0, chatID: TurnContext.chatID ?? "") != nil },
                                                       revisesProblem: revisesCheck(store))
            },
            run: { args in
                guard let chat = TurnContext.chatID,
                      let store = fixed ?? ToolCallStore.database.map({ Stores.shared.store(for: $0) }) else {
                    throw ToolRunError("create_presentation runs inside a chat turn only.")
                }
                let message = TurnContext.requestID
                do {
                    return try await CreatePresentationTool.run(argumentsJSON: args, chatID: chat, messageID: message, store: store)
                } catch let e as FileOutError {
                    throw fileOutRunError(e)
                }
            })
        fileOutHooks(&tool, store: fixed, normalize: FileOutNormalizer.presentation)
        return tool
    }

    /// M6.T10: `create_spreadsheet` (XLSX / CSV) — rows or a query result's data_ref.
    public static func createSpreadsheet(store fixed: ArtifactStore? = nil, refs: DataRefStore = .shared) -> RegisteredTool {
        var tool = RegisteredTool(
            name: CreateSpreadsheetTool.name, description: SpreadsheetSchemas.createDescription,
            parametersJSON: SpreadsheetSchemas.createJSON, sideEffect: .read, outputIsUntrusted: false,
            validate: { args in
                let chat = TurnContext.chatID ?? ""
                let store = fixed ?? ToolCallStore.database.map { Stores.shared.store(for: $0) }
                return CreateSpreadsheetTool.problems(argumentsJSON: args, refs: { refs.get(chatID: chat, id: $0) },
                                                      chatRefs: refs.all(chatID: chat), revisesProblem: revisesCheck(store))
            },
            run: { args in
                guard let chat = TurnContext.chatID,
                      let store = fixed ?? ToolCallStore.database.map({ Stores.shared.store(for: $0) }) else {
                    throw ToolRunError("create_spreadsheet runs inside a chat turn only.")
                }
                do {
                    return try CreateSpreadsheetTool.run(argumentsJSON: args, chatID: chat, messageID: TurnContext.requestID,
                                                         store: store, refs: { refs.get(chatID: chat, id: $0) })
                } catch let e as FileOutError {
                    throw fileOutRunError(e)
                }
            })
        fileOutHooks(&tool, store: fixed, refs: refs, normalize: FileOutNormalizer.spreadsheet)
        return tool
    }

    /// M6.T10: `export_table` — a query_data result as a CSV / XLSX file.
    public static func exportTable(store fixed: ArtifactStore? = nil, refs: DataRefStore = .shared) -> RegisteredTool {
        RegisteredTool(
            name: ExportTableTool.name, description: SpreadsheetSchemas.exportDescription,
            parametersJSON: SpreadsheetSchemas.exportJSON, sideEffect: .read, outputIsUntrusted: false,
            validate: { args in
                let chat = TurnContext.chatID ?? ""
                let store = fixed ?? ToolCallStore.database.map { Stores.shared.store(for: $0) }
                return ExportTableTool.problems(argumentsJSON: args, refs: { refs.get(chatID: chat, id: $0) },
                                                revisesProblem: revisesCheck(store))
            },
            run: { args in
                guard let chat = TurnContext.chatID,
                      let store = fixed ?? ToolCallStore.database.map({ Stores.shared.store(for: $0) }) else {
                    throw ToolRunError("export_table runs inside a chat turn only.")
                }
                do {
                    return try ExportTableTool.run(argumentsJSON: args, chatID: chat, messageID: TurnContext.requestID,
                                                   store: store, refs: { refs.get(chatID: chat, id: $0) })
                } catch let e as FileOutError {
                    throw fileOutRunError(e)
                }
            })
    }

    /// M6.T12: `create_chart` — a Vega-Lite chart rendered headless (SVG + PNG); file data only through `data_ref`.
    public static func createChart(store fixed: ArtifactStore? = nil, refs: DataRefStore = .shared,
                                   sessions: SheetSessions = .shared) -> RegisteredTool {
        var tool = RegisteredTool(
            name: CreateChartTool.name, description: ChartSchemas.description,
            parametersJSON: ChartSchemas.json, sideEffect: .read, outputIsUntrusted: false,
            validate: { args in
                let chat = TurnContext.chatID ?? ""
                let store = fixed ?? ToolCallStore.database.map { Stores.shared.store(for: $0) }
                return CreateChartTool.problems(argumentsJSON: args, refs: { refs.get(chatID: chat, id: $0) },
                                                chatRefs: refs.all(chatID: chat),
                                                tableColumns: sessions.tables(chatID: chat).map { $0.columns.map(\.name) },
                                                revisesProblem: revisesCheck(store))
            },
            run: { args in
                guard let chat = TurnContext.chatID,
                      let store = fixed ?? ToolCallStore.database.map({ Stores.shared.store(for: $0) }) else {
                    throw ToolRunError("create_chart runs inside a chat turn only.")
                }
                do {
                    return try await CreateChartTool.run(argumentsJSON: args, chatID: chat, messageID: TurnContext.requestID,
                                                         store: store, refs: { refs.get(chatID: chat, id: $0) },
                                                         chatRefs: refs.all(chatID: chat))
                } catch let e as FileOutError {
                    throw fileOutRunError(e)
                }
            })
        tool.normalize = { CreateChartTool.normalized($0) }
        return tool
    }
}
