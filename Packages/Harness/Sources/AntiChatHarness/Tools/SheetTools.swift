// M6.T08 (R-272): `query_data` in the tool registry — local, read-only (Always allow by default), offline. The call runs
// on the calling chat's DuckDB store (`TurnContext.chatID`, set by TurnController around every tool call); the turn
// offers the tool only once the chat has a loaded sheet (`SheetSessions`). DuckDB errors, guard rejections and the
// 10 s timeout come back as the tool error the model sees (one retry per the tool-loop rules) and on the activity line.
import AntiChatFoundation
import AntiChatTools
import Foundation

public enum SheetTools {
    public static func queryData(sessions: SheetSessions = .shared, refs: DataRefStore = .shared) -> RegisteredTool {
        RegisteredTool(name: QueryDataTool.name, description: QueryDataTool.description,
                       parametersJSON: QueryDataTool.parametersJSON, sideEffect: .read, outputIsUntrusted: true) { args in
            // Retain the loaded store itself: an LRU eviction must not replace it with an empty database mid-query (#5).
            guard let chat = TurnContext.chatID, let loaded = sessions.store(chatID: chat) else {
                throw ToolRunError(QueryDataError.noTables.description)
            }
            guard let a = try? JSONDecoder().decode(QueryDataTool.Arguments.self, from: Data(args.utf8)),
                  !a.sql.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ToolRunError("query_data needs {\"sql\": \"SELECT …\"}.")
            }
            do {
                let r = try await QueryDataTool.run(sql: a.sql, store: loaded.store, chatID: chat, refs: refs)
                let files = QueryDataTool.files(in: r.sql, tables: loaded.tables)
                return QueryDataTool.resultText(r, file: files.isEmpty ? nil : files.joined(separator: ", "))
            } catch let e as QueryDataError {
                throw ToolRunError(e.description)
            } catch {
                throw ToolRunError("SQL error: \(error)")
            }
        }
    }
}
