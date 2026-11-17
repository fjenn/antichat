import AntiChatDesign
import AntiChatHarness
import AntiChatTools
import Foundation
import SwiftUI

enum RunPythonActivity {
    static func isRun(_ activity: ToolActivity) -> Bool {
        activity.kind == .tool && activity.tool == RunPythonTool.name
    }

    /// The tools that run code in a File tools slot (A-M6-T21a (a)).
    static func usesSandbox(_ activity: ToolActivity) -> Bool {
        activity.kind == .tool && (activity.tool == RunPythonTool.name || activity.tool == EditOfficeFileTool.name)
    }

    /// True while the call waits for a free sandbox (every slot runs another chat's code): `sandbox.waiting`.
    static func isWaiting(_ activity: ToolActivity) -> Bool {
        usesSandbox(activity) && (activity.state == .running || activity.state == .awaitingApproval) && FileToolsSlots.isWaiting(activity.id)
    }

    static func summary(_ activity: ToolActivity) -> RunPythonSummary? {
        guard let line = activity.result?.split(separator: "\n", maxSplits: 1).first else { return nil }
        return try? JSONDecoder().decode(RunPythonSummary.self, from: Data(line.utf8))
    }

    static func purpose(_ activity: ToolActivity) -> String {
        let object = (try? JSONSerialization.jsonObject(with: Data(activity.argumentsJSON.utf8))) as? [String: Any]
        return object?["purpose"] as? String ?? "files"
    }

    /// "Analysing {file} · {seconds} s" (`act.analysing`): seconds since the call started while it runs, the
    /// call's wall time once it ended without a notice or a file.
    static func label(_ activity: ToolActivity, now: Date = Date()) -> CopyText? {
        let seconds = Int((activity.seconds ?? now.timeIntervalSince(activity.startedAt)).rounded())
        if activity.state == .running || activity.state == .awaitingApproval {
            return CopyText(CopyKey("act.analysing"), ["file": purpose(activity), "seconds": "\(max(0, seconds))"])
        }
        if let summary = summary(activity), let key = summary.noticeKey {
            return CopyText(CopyKey(key), summary.reasonKey.map { ["reason": CopyKey($0).string()] } ?? [:])
        }
        if let result = activity.result.flatMap({ FileOutResult.parse($0) }) {
            return CopyText(CopyKey("act.created"), ["filename": result.file])
        }
        if activity.state == .done {
            return CopyText(CopyKey("act.analysing"), ["file": purpose(activity), "seconds": "\(max(0, seconds))"])
        }
        // A failed step reads plainly, in the user's words (never "Run python didn't work").
        if activity.state == .failed { return CopyText(CopyKey("act.analyse.failed")) }
        return nil
    }
}

struct RunPythonOutputCards: View {
    let activity: ToolActivity

    var body: some View {
        let results = activity.result.map { FileOutResult.parseAll($0) } ?? []
        ForEach(Array(results.enumerated()), id: \.offset) { index, result in
            let single = singleActivity(result)
            if result.format == "chart" {
                ChartActivityCard(activity: single)
            } else {
                FileOutActivityCard(activity: single, onTryAgain: nil)
            }
        }
    }

    func singleActivity(_ result: FileOutResult) -> ToolActivity {
        var single = activity
        single.result = (try? JSONEncoder().encode(result)).map { String(decoding: $0, as: UTF8.self) }
        return single
    }
}
