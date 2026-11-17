import AntiChatEngineProtocol
import AntiChatFoundation
import AntiChatStorage
import AntiChatTools
import Foundation
import Synchronization

public enum FileToolsTools {
    /// A-M6-T21a (a): File tools slots that run code at once (one chat per slot container; more chats wait with
    /// `sandbox.waiting`). Every tier gets at least 2, so a second chat's run always answers while one chat's code burns
    /// its 60 s (AT-NFR-SEC3's bystander condition has no tier exception). T0: 2 × 1 GB cap; T1: 2 × 2 GB; T2+: 3 × 2 GB.
    /// Each run is capped at 2 threads (A-M6-07), so 2 slots use at most 4 of a base chip's 8 cores and 3 slots 6 of a
    /// Pro/Max chip's 10+. The caps are per-run maxima, not reservations (A-M6-T21a has the memory reasoning).
    public static func slotCount(for tier: DeviceTier) -> Int {
        switch tier {
        case .t0, .t1: 2
        case .t2, .t3, .t4: 3
        }
    }

    static let createNames = [CreateDocumentTool.name, CreateSpreadsheetTool.name, CreatePresentationTool.name,
                              CreateChartTool.name, ExportTableTool.name]

    /// Set by the app (FileToolsAutoInstall): fetches the File tools runtime when it is missing and answers whether
    /// code can run now. With it set, `run_python` is offered before the runtime is on disk and its first call waits
    /// for the install instead of failing with `sandbox.notInstalled` (no button to find in Settings first).
    public static let ensureRuntime = Mutex<(@Sendable () async -> Bool)?>(nil)

    public static func runPython(store fixed: ArtifactStore? = nil, database fixedDB: AppDatabase? = nil,
                                 tier: @escaping @Sendable () -> DeviceTier = { .t1 }) -> RegisteredTool {
        let reaper = SessionIdleReaper.shared
        let tool = RunPythonTool(runtimePath: {
            guard let path = RunPythonTool.installedRuntimePath() else { throw RunPythonError.runtimeNotInstalled }
            return path
        }, client: FileToolsClient(defaults: ToolDefaults.store), reaper: reaper,
        memoryCap: tier() == .t0 ? FileToolsProtocol.memoryCapBytesT0 : FileToolsProtocol.memoryCapBytes)
        return RegisteredTool(
            name: RunPythonTool.name, description: RunPythonTool.description,
            parametersJSON: RunPythonTool.parametersJSON, sideEffect: .read, outputIsUntrusted: true,
            run: { args in
                guard let chat = TurnContext.chatID,
                      let database = fixedDB ?? ToolCallStore.database,
                      let store = fixed ?? ToolCallStore.database.map({ FileOutTools.Stores.shared.store(for: $0) }) else {
                    throw ToolRunError("run_python runs inside a chat turn only.")
                }
                do {
                    if RunPythonTool.installedRuntimePath() == nil, let ensure = ensureRuntime.withLock({ $0 }) {
                        _ = await ensure()  // first use: the turn waits here while File tools arrives
                    }
                    return try await tool.run(argumentsJSON: args, chatID: chat, messageID: TurnContext.requestID,
                                              database: database, store: store)
                } catch let error as RunPythonError {
                    switch error {
                    case .invalidArguments: throw ToolRunError("run_python needs a non-empty code string.")
                    case .runtimeNotInstalled: throw ToolRunError("sandbox.notInstalled")
                    case .attachmentNotFound(let id): throw ToolRunError("No attachment \(id) in this chat.")
                    case .service(let message): throw ToolRunError(message)
                    }
                } catch let error as FileToolsSlots.SlotError {
                    throw ToolRunError(sandboxUnavailable("\(error)"))
                } catch let error as FileToolsClientError {
                    throw ToolRunError(sandboxUnavailable("\(error)"))
                }
            })
    }

    /// The sandbox itself did not answer (not an error in the code). The model is told not to pass off a guess as the
    /// run's result: after `wipeFailed` it answered a standard deviation with made-up numbers (2026-11-16).
    static func sandboxUnavailable(_ detail: String) -> String {
        "The code did not run: the sandbox is not available right now (\(detail)). Do not call run_python again in this "
            + "reply and do not present a result as if the code had run. Tell the user the analysis could not be run and "
            + "they can try again; work it out by hand only if it is simple, and say that you did."
    }

    /// M6.T20 (R-276): `edit_office_file`, registered whenever the registry has File tools; it runs code only when the
    /// runtime is installed AND Run code is on, else it answers with the offer card (AC2). Offered per turn by
    /// OfficeEditIntent (an attached DOCX/XLSX/PPTX + an edit request).
    public static func editOffice(store fixed: ArtifactStore? = nil, database fixedDB: AppDatabase? = nil,
                                  runtimePath: (@Sendable () -> String?)? = nil, client: FileToolsClient? = nil,
                                  tier: @escaping @Sendable () -> DeviceTier = { .t1 }) -> RegisteredTool {
        let path: @Sendable () -> String? = runtimePath ?? {
            ToolDefaults.bool(ToolDefaults.runCodeEnabled) ? RunPythonTool.installedRuntimePath() : nil
        }
        let tool = EditOfficeFileTool(runtimePath: path, client: client ?? FileToolsClient(defaults: ToolDefaults.store),
                                      memoryCap: tier() == .t0 ? FileToolsProtocol.memoryCapBytesT0 : FileToolsProtocol.memoryCapBytes)
        return RegisteredTool(
            name: EditOfficeFileTool.name, description: EditOfficeFileTool.description,
            parametersJSON: EditOfficeFileTool.parametersJSON, sideEffect: .read, outputIsUntrusted: true,
            run: { args in
                guard let chat = TurnContext.chatID,
                      let database = fixedDB ?? ToolCallStore.database,
                      let store = fixed ?? ToolCallStore.database.map({ FileOutTools.Stores.shared.store(for: $0) }) else {
                    throw ToolRunError("edit_office_file runs inside a chat turn only.")
                }
                do {
                    return try await tool.run(argumentsJSON: args, chatID: chat, messageID: TurnContext.requestID,
                                              database: database, store: store)
                } catch let error as EditOfficeFileError {
                    switch error {
                    case .invalidArguments: throw ToolRunError("edit_office_file needs {\"file\": <attached file name>, \"code\": <python>}.")
                    case .fileNotFound(let f): throw ToolRunError("No attached file \(f) in this chat.")
                    case .notOffice(let f): throw ToolRunError("\(f) is not a Word, Excel or PowerPoint file.")
                    case .noOutput(let f): throw ToolRunError("The code did not save out/\(f). Load in/\(f), change it and save it to out/\(f).")
                    case .originalChanged(let f):
                        AppLog.log(.harness, .error, "edit_office_file: original of \(f) changed (S0)")
                        throw ToolRunError("The original \(f) changed during the edit; nothing was saved.")
                    case .service(let m): throw ToolRunError(m)
                    }
                }
            })
    }

    @discardableResult
    public static func install(into registry: ToolRegistry, tier: @escaping @Sendable () -> DeviceTier) -> [NSObjectProtocol] {
        ToolDefaults.registerDefaults()
        @Sendable func sync() {
            let slots = slotCount(for: tier())
            Task { await FileToolsSlots.shared.configure(capacity: slots) }
            if ToolDefaults.bool(ToolDefaults.createFilesEnabled) {
                registry.register(FileOutTools.createDocument())
                registry.register(FileOutTools.createSpreadsheet())
                registry.register(FileOutTools.createPresentation())
                registry.register(FileOutTools.createChart())
                registry.register(FileOutTools.exportTable())
            } else {
                createNames.forEach(registry.unregister)
            }
            registry.register(editOffice(tier: tier))  // M6.T20: offer card without File tools, in-place edit with
            let installed = RunPythonTool.installedRuntimePath() != nil
            let onDemand = !installed && tier() != .t0 && ensureRuntime.withLock { $0 != nil }
            if (ToolDefaults.bool(ToolDefaults.runCodeEnabled) && installed) || onDemand {
                registry.register(runPython(tier: tier))
            } else {
                registry.unregister(RunPythonTool.name)
            }
        }
        sync()
        let defaultsObserver = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification,
                                                                      object: ToolDefaults.store, queue: nil) { _ in sync() }
        let runtimeObserver = NotificationCenter.default.addObserver(forName: .init(ToolDefaults.runtimeDidChangeNotification),
                                                                     object: nil, queue: nil) { _ in sync() }
        return [defaultsObserver, runtimeObserver]
    }
}
