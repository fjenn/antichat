//
//  UncaughtExceptionLogger.swift
//  osaurus
//
//  Captures NSException details to disk before AppKit kills the process
//

import Foundation

package enum UncaughtExceptionLogger {
    package static let logPath: String = {
        let base = (NSHomeDirectory() as NSString).appendingPathComponent(
            // ANTICHAT-PATCH: UP-OS-033 rebrand log subsystems, queue labels, Keychain service and temp/log directory names to app.antichat / AntiChat
            "Library/Logs/AntiChat"
            // ANTICHAT-PATCH-END
        )
        return (base as NSString).appendingPathComponent("last-crash-reason.log")
    }()

    package static func install() {
        try? FileManager.default.createDirectory(
            atPath: (logPath as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true
        )

        NSSetUncaughtExceptionHandler { exception in
            let timestamp = ISO8601DateFormatter().string(from: Date())
            let dump = """
                timestamp: \(timestamp)
                name:      \(exception.name.rawValue)
                reason:    \(exception.reason ?? "<nil>")
                userInfo:  \(String(describing: exception.userInfo))
                stack:
                \(exception.callStackSymbols.joined(separator: "\n"))
                """
            try? dump.write(
                toFile: UncaughtExceptionLogger.logPath,
                atomically: true,
                encoding: .utf8
            )
        }
    }
}
