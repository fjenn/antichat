import AntiChatEngineProtocol
import AntiChatFoundation
import AntiChatStorage
import Foundation
import GRDB

public struct RunPythonSummary: Codable, Sendable, Equatable {
    public var stdout: String
    public var stderr: String
    public var error: RunError?
    public var freshSession: Bool
    public var noticeKey: String?
    public var reasonKey: String?
    /// The jail names of this call's inputs (`in/<name>`; the attachment's display name, made path-safe).
    public var inputs: [String]?
    /// M9 review T1: this call's file cards, written by the host on this first line (the jailed code's stdout can only
    /// follow as later raw lines). `FileOutResult.parseAll` takes a run's cards from here only, and only those whose
    /// path lies inside `outputDir`.
    public var files: [FileOutResult]?
    /// The folder this call's outputs were saved into (the chat's media store).
    public var outputDir: String?
    public var linksToSettings: Bool { noticeKey == "sandbox.networkOff" }

    enum CodingKeys: String, CodingKey {
        case stdout, stderr, error
        case freshSession = "fresh_session"
        case noticeKey = "notice_key"
        case reasonKey = "reason_key"
        case inputs, files
        case outputDir = "output_dir"
    }
}

public enum RunPythonError: Error, Equatable {
    case invalidArguments
    case runtimeNotInstalled
    case attachmentNotFound(String)
    case service(String)
}

public struct RunPythonTool: Sendable {
    public static let name = "run_python"
    public static let parametersJSON = #"{"type":"object","properties":{"code":{"type":"string","description":"Python 3.13 code. Inputs are in in/; write deliverables to out/."},"inputs":{"type":"array","items":{"type":"string"},"description":"Names (or ids) of files attached in this chat; each is copied to in/<name>."},"purpose":{"type":"string","description":"Short user-facing analysis purpose."}},"required":["code"]}"#
    public static let description = "Run Python for local file analysis in the File tools sandbox. Globals persist within the chat. Read inputs from in/ and save figures and files to out/. Network is off unless the user enables it."

    public static func installedRuntimePath(debug: Bool = AppDatabase.isDebugBuild) -> String? {
        let root = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Application Support/\(AppDatabase.defaultContainerName(debug: debug))/Runtimes")
        let entries = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        return entries.filter {
            $0.lastPathComponent.hasPrefix("filetools-runtime@") &&
            FileManager.default.fileExists(atPath: $0.appending(path: "RUNTIME.json").path)
        }.sorted { $0.lastPathComponent < $1.lastPathComponent }.last?.path
    }

    /// Prepended to every cell (one line, so tracebacks stay one line off at most): the App Sandbox base profile
    /// refuses /etc/apache2/mime.types, which `mimetypes.init()` opens (openpyxl's save does) and which then raises
    /// PermissionError. The built-in table is enough; nothing outside the jail is read.
    public static let prelude = "import mimetypes as _ac_m; _ac_m.inited or (setattr(_ac_m, 'knownfiles', []), _ac_m.init()); del _ac_m\n"

    public typealias Runner = @Sendable (RunCode, [URL], URL) async throws -> (RunResult, [URL])
    public typealias Reset = @Sendable (String) async -> Void

    let runtimePath: @Sendable () throws -> String
    let runner: Runner
    let reset: Reset
    let reaper: SessionIdleReaper
    let memoryCap: Int64

    public init(runtimePath: @escaping @Sendable () throws -> String, client: FileToolsClient? = nil,
                reaper: SessionIdleReaper = SessionIdleReaper(), memoryCap: Int64 = FileToolsProtocol.memoryCapBytes) {
        let client = client ?? FileToolsClient()
        self.runtimePath = runtimePath
        self.runner = { request, inputs, output in try await client.run(request, inputs: inputs, outputDirectory: output, waitKey: TurnContext.toolCallID) }
        self.reset = { chatID in _ = try? await client.reset(chatID: chatID) }
        self.reaper = reaper
        self.memoryCap = memoryCap
    }

    init(runtimePath: @escaping @Sendable () throws -> String, runner: @escaping Runner, reset: @escaping Reset,
         reaper: SessionIdleReaper, memoryCap: Int64 = FileToolsProtocol.memoryCapBytes) {
        self.runtimePath = runtimePath
        self.runner = runner
        self.reset = reset
        self.reaper = reaper
        self.memoryCap = memoryCap
    }

    struct Arguments: Decodable {
        var code: String
        var inputs: [String]?
        var purpose: String?
    }

    public func run(argumentsJSON: String, chatID: String, messageID: String?, database: AppDatabase,
                    store: ArtifactStore) async throws -> String {
        guard let args = try? JSONDecoder().decode(Arguments.self, from: Data(argumentsJSON.utf8)), !args.code.isEmpty else {
            throw RunPythonError.invalidArguments
        }
        let runtime = try runtimePath()
        guard !runtime.isEmpty else { throw RunPythonError.runtimeNotInstalled }
        let inputs = try inputFiles(args.inputs ?? [], chatID: chatID, database: database)
        let out = FileManager.default.temporaryDirectory.appending(path: "run-python-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: out) }
        let request = RunCode(chatID: chatID, code: Self.prelude + args.code,
                              inputs: inputs.map { .init(name: $0.name) },
                              runtimePath: runtime, memoryCapBytes: memoryCap)
        let (result, files) = try await runner(request, inputs.map(\.url), out)
        await reaper.touch(chatID: chatID, clock: ContinuousClock()) { [reset] in await reset(chatID) }
        if let serviceError = result.serviceError { throw RunPythonError.service(serviceError) }
        let notice = SandboxNotice.for(result)
        // M9 review T1: only files the client copied into this run's own output folder are saved (and become cards).
        let produced = files.filter { FileOutResult.isInside($0.path, folder: out.path) }
        let cards = try OutputHarvester().harvestCards(produced, chatID: chatID, messageID: messageID, store: store)
        let summary = RunPythonSummary(stdout: result.stdout, stderr: result.stderr, error: result.error,
                                       freshSession: result.freshSession, noticeKey: notice?.key, reasonKey: notice?.reasonKey,
                                       inputs: inputs.isEmpty ? nil : inputs.map { "in/" + $0.name },
                                       files: cards.map(\.card), outputDir: store.mediaRoot.path)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var lines = [String(decoding: try encoder.encode(summary), as: UTF8.self)]
        lines += cards.map(\.text)
        if produced.isEmpty {
            if !result.stdout.isEmpty { lines.append(result.stdout) }
            if !result.stderr.isEmpty { lines.append(result.stderr) }
            if let error = result.error { lines.append(error.traceback ?? "\(error.type): \(error.message)") }
            if let notice { lines.append(notice.reasonKey.map { "\(notice.key): \($0)" } ?? notice.key) }
        }
        return lines.joined(separator: "\n")
    }

    /// One input: the media-store file (opened read-only by the client) and its name inside the jail.
    struct Input: Equatable { var url: URL; var name: String }

    /// A display name as a single safe jail component (`Jail.safeName` rules: no slash/colon/NUL, no leading dot or
    /// whitespace, ≤ 255 bytes); duplicates get " (2)", " (3)" … before the extension.
    static func jailName(_ display: String, taken: inout Set<String>) -> String {
        var base = display.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: ":", with: "_")
            .replacingOccurrences(of: "\0", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
        while base.hasPrefix(".") { base.removeFirst() }
        if base.isEmpty { base = "input" }
        while base.utf8.count > 200 { base.removeLast() }
        var name = base, n = 2
        let ext = (base as NSString).pathExtension, stem = (base as NSString).deletingPathExtension
        while taken.contains(name) { name = ext.isEmpty ? "\(stem) (\(n))" : "\(stem) (\(n)).\(ext)"; n += 1 }
        taken.insert(name)
        return name
    }

    func inputFiles(_ ids: [String], chatID: String, database: AppDatabase) throws -> [Input] {
        var taken = Set<String>()
        return try ids.map { id in
            let row = try database.read { db in
                try Row.fetchOne(db, sql: """
                    SELECT b.path, a.display_name FROM attachment a
                    JOIN file_blob b ON b.id = a.blob_id
                    JOIN message m ON m.id = a.message_id
                    WHERE m.chat_id = ? AND (a.id = ? OR a.display_name = ?)
                    ORDER BY (a.id = ?) DESC, a.created_at DESC LIMIT 1
                    """, arguments: [chatID, id, id, id])
            }
            guard let row, let path = row["path"] as? String else { throw RunPythonError.attachmentNotFound(id) }
            let display = (row["display_name"] as? String) ?? URL(fileURLWithPath: path).lastPathComponent
            return Input(url: URL(fileURLWithPath: path), name: Self.jailName(display, taken: &taken))
        }
    }
}
