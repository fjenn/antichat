// R-291 AC2 (M4.md copy `job.interrupted` "Interrupted · Restart", `job.restart`): a picture job cut off by an app quit,
// a crash or a helper exit is `lost`. Its card offers Restart (not the failed card's Retry, which makes the turn again):
// the same request runs again as a new job (`MediaJobQueue.restart`), the card follows it, and the finished picture is
// stored as the call's artifact exactly as the tool would have stored it; the call's activity and tool result in the
// reply are rewritten with the new outcome, so the reloaded chat shows the picture.
import AntiChatEngineProtocol
import AntiChatStorage
import AntiChatTools
import Foundation
import GRDB

public extension ImageTools {
    /// Restarts lost job `job` of the call `activity` (reply `messageID`, card key `callKey`) on `queue`; waits for the
    /// new job and returns the call's new outcome (also written to the reply's parts).
    static func restartInterrupted(job: String, queue: MediaJobQueue, activity: ToolActivity, messageID: String?,
                                   callKey: String) async -> ImageTurnPolicy.Outcome {
        let db = queue.store
        guard let old = try? await queue.row(job) else { return .failed(code: "interrupted") }
        let chatID = old.chatID
        let new: String
        do { new = try await queue.restart(job, callID: callKey) } catch { return .failed(code: "interrupted") }
        let end = await queue.finished(new)
        let outcome: ImageTurnPolicy.Outcome
        switch end.state {
        case .done:
            outcome = await ToolCallStore.$database.withValue(db) {
                guard let row = try? await queue.row(new),
                      let req = try? JSONDecoder().decode(ImageRequest.self, from: Data(row.specJSON.utf8)),
                      let call = try? ImageRequestBuilder.parse(activity.argumentsJSON, tool: activity.tool),
                      let path = end.resultPath else { return .failed(code: "save") }
                let sourceRef = activity.tool == EditImageTool.name
                    ? call.sourceImageID.flatMap { ImageEditFlow.resolve($0, database: db, chatID: chatID) } : nil
                let target = ImageEditFlow.saveTarget(sourceRef)
                guard let saved = saveArtifact(path: path, req: req, call: call, chatID: chatID, revises: target.revises,
                                               parentVersion: target.parent) else {
                    await queue.discardFiles(new)
                    return .failed(code: "save")
                }
                await queue.resultStored(new, at: saved.path)
                return .done(imageID: saved.artifactID, width: req.width, height: req.height, path: saved.path)
            }
        case .blocked: outcome = .notShown
        case .failed where end.errorCode == MediaJobQueue.safetyMissingCode: outcome = .safetyMissing(sizeBytes: 0)
        case .cancelled: outcome = .failed(code: "cancelled")
        case .lost: outcome = .failed(code: "interrupted")
        default: outcome = .failed(code: end.errorCode ?? "failed")
        }
        if let messageID { try? ToolActivityParts.rewrite(activityID: activity.id, messageID: messageID, result: outcome.resultJSON, in: db) }
        return outcome
    }
}

/// Rewrites one finished call's stored parts (its `activity` line and its `tool_result`) with a new result.
enum ToolActivityParts {
    static func rewrite(activityID: String, messageID: String, result: String, in database: AppDatabase) throws {
        try database.write { db in
            let parts = try MessageRepository.parts(of: messageID, db: db)
            for var part in parts where part.kind == .activity {
                guard var a = ToolActivity(partBody: part.body), a.id == activityID else { continue }
                a.result = result
                a.state = .done
                part.body = a.partBody
                try part.update(db)
            }
            // The model's copy of the result: exactly this call's, never another step's that reused the call id.
            guard let i = resultIndex(activityID: activityID, in: parts),
                  var o = (try? JSONSerialization.jsonObject(with: Data(parts[i].body.utf8))) as? [String: Any] else { return }
            o["result"] = MediaToolResult.forModel(name: o["name"] as? String ?? "", result: result)
            guard let data = try? JSONSerialization.data(withJSONObject: o, options: [.sortedKeys]) else { return }
            var part = parts[i]
            part.body = String(decoding: data, as: UTF8.self)
            try part.update(db)
        }
    }

    /// M9 review H2: the index of the `tool_result` part of the call shown as activity `activityID`. Engines reuse call
    /// ids across steps (MLXAdapter: `call_<n>` in every step), so the id alone names several results. A result stored
    /// with its activity key (`"activity"`) matches on it (the last one: a repaired call's line is taken over by the
    /// retry). An older result without the key: the n-th result with the base id, n from the key's "#n" suffix
    /// (`uniqueActivityKey` numbers repeats in step order, the first has no suffix).
    static func resultIndex(activityID: String, in parts: [MessagePartRecord]) -> Int? {
        let pieces = activityID.split(separator: "#", maxSplits: 1).map(String.init)
        let base = pieces.first ?? activityID
        let ordinal = pieces.count == 2 ? Int(pieces[1]) ?? 1 : 1
        var tagged: Int?
        var legacy: [Int] = []
        for (i, p) in parts.enumerated() where p.kind == .toolResult {
            guard let o = (try? JSONSerialization.jsonObject(with: Data(p.body.utf8))) as? [String: Any] else { continue }
            if let key = o["activity"] as? String {
                if key == activityID { tagged = i }
            } else if o["id"] as? String == base {
                legacy.append(i)
            }
        }
        if let tagged { return tagged }
        return legacy.indices.contains(ordinal - 1) ? legacy[ordinal - 1] : nil
    }
}
