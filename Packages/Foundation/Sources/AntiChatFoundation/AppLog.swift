// AppLog facade (architecture.md §7.2, P-platform-09): os.Logger per category (subsystem `app.antichat`) plus a
// per-process CocoaLumberjack file log once `bootstrap` ran. Privacy: messages are developer text only. Prompt,
// response, file and audio content is never logged (callers pass ids, sizes and codes, never content).
import CocoaLumberjackSwift
import Foundation
import os

public enum AppLog {
    public enum Category: String, Sendable, CaseIterable {
        case ui, harness, engine, sched, net, store, catalog, download, media, voice, tools, relay, update
    }

    public enum Level: Sendable { case debug, info, notice, error, fault }

    public static let subsystem = "app.antichat"

    public static func logger(_ category: Category) -> Logger {
        Logger(subsystem: subsystem, category: category.rawValue)
    }

    private static let fileLog = OSAllocatedUnfairLock<DDLog?>(initialState: nil)

    /// Adds the per-process file logger (`<directory>/<process>-*.log`, 5 files × 5 MB). Idempotent.
    public static func bootstrap(process: String, directory: URL) {
        fileLog.withLock { log in
            guard log == nil else { return }
            let l = DDLog()
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let manager = DDLogFileManagerDefault(logsDirectory: directory.path)
            manager.maximumNumberOfLogFiles = 5
            let file = DDFileLogger(logFileManager: manager)
            file.maximumFileSize = 5 * 1024 * 1024
            file.rollingFrequency = 24 * 3600
            l.add(file, with: .all)
            log = l
            _ = process  // file names come from the bundle id; `process` is kept for the caller's clarity
        }
    }

    /// Logs developer text (never content). Mirrors to the file log after `bootstrap`.
    public static func log(_ category: Category, _ level: Level = .info, _ message: String) {
        let l = logger(category)
        if isRedacting, contentCategories.contains(category) {
            // M1.T20 category-level redaction: the unified log keeps the line private, the file log drops it.
            switch level {
            case .debug: l.debug("\(message, privacy: .private)")
            case .info: l.info("\(message, privacy: .private)")
            case .notice: l.notice("\(message, privacy: .private)")
            case .error: l.error("\(message, privacy: .private)")
            case .fault: l.fault("\(message, privacy: .private)")
            }
            return
        }
        switch level {
        case .debug: l.debug("\(message, privacy: .public)")
        case .info: l.info("\(message, privacy: .public)")
        case .notice: l.notice("\(message, privacy: .public)")
        case .error: l.error("\(message, privacy: .public)")
        case .fault: l.fault("\(message, privacy: .public)")
        }
        guard let dd = fileLog.withLock({ $0 }) else { return }
        let flag: DDLogFlag =
            switch level {
            case .debug: .debug
            case .info, .notice: .info
            case .error: .error
            case .fault: .error
            }
        let line = "[\(category.rawValue)] \(message)"
        dd.log(asynchronous: true, message: DDLogMessage("\(line)", level: .all, flag: flag, context: 0, file: #file, function: #function, line: #line, tag: nil, timestamp: nil))
    }

    // MARK: Incognito redaction (M1.T20, R-090; IncognitoGuards guard 7)

    /// True inside an incognito request's task tree: the helper runs each `ChatRequest` with
    /// `AppLog.$incognito.withValue(request.incognito)`. Unstructured `Task {}` children inherit it.
    @TaskLocal public static var incognito = false

    private static let incognitoSessions = OSAllocatedUnfairLock(initialState: 0)

    /// The app process: an incognito session opened (balanced by `endIncognitoSession`). While any is open the
    /// whole process redacts, so a line about another chat can never carry incognito detail by accident.
    public static func beginIncognitoSession() { incognitoSessions.withLock { $0 += 1 } }

    public static func endIncognitoSession() { incognitoSessions.withLock { $0 = max(0, $0 - 1) } }

    /// Open incognito sessions in this process (tests, probes).
    public static var openIncognitoSessions: Int { incognitoSessions.withLock { $0 } }

    /// Redaction is on: an incognito task, or an incognito session open in this process.
    public static var isRedacting: Bool { incognito || openIncognitoSessions > 0 }

    /// Categories whose lines can carry chat-derived detail (engine/tool error text, tool names, previews). While
    /// redacting, their lines go to the unified log as `.private` only and never to the file log.
    public static let contentCategories: Set<Category> = [.ui, .harness, .engine, .store, .tools, .media, .voice]

    /// Content-bearing developer text (raw model output previews and the like): dropped entirely while redacting,
    /// in every category; otherwise logged like `log`.
    public static func content(_ category: Category, _ level: Level = .debug, _ message: @autoclosure () -> String) {
        guard !isRedacting else { return }
        // One file-log line per content entry (review fix): a multi-line preview must not leave unmarked lines.
        let flat = message().replacingOccurrences(of: "\r", with: "\\r").replacingOccurrences(of: "\n", with: "\\n")
        log(category, level, "\(contentMarker) \(flat)")
    }

    /// M8.T09: marks content lines in the file log; Export logs drops them unless "Include chat content" is ticked.
    public static let contentMarker = "[content]"
}
