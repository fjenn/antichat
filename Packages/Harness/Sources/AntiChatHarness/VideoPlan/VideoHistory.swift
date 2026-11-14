// M5.T08 step 3 (R-046 AC2, G-046; P-media-12 design port of atomic-chat-core@6c7e9e8 `src/diffusion/video-history.ts`,
// written from the description): local recalibration. The history factor of a preset is the median of
// actual ÷ estimated over its last 5 finished runs on this Mac, 1.0 until 5 runs exist. Runs live in
// `video_run_history` (migration v31); an incognito job never writes a row (cross-task contract 5).
import AntiChatStorage
import Foundation
import GRDB

public enum VideoHistory {
    /// Runs needed before the history changes an estimate, and the window the median is taken over.
    public static let window = 5

    public struct Run: Sendable, Equatable {
        public var presetKey: String
        public var speedClass: String
        /// What the estimator said before the job (without history: the factor must not feed on itself).
        public var estimatedS: Double
        public var actualS: Double
        public var createdAt: Date
        public init(presetKey: String, speedClass: String, estimatedS: Double, actualS: Double, createdAt: Date = Date()) {
            self.presetKey = presetKey; self.speedClass = speedClass; self.estimatedS = estimatedS; self.actualS = actualS
            self.createdAt = createdAt
        }
    }

    /// median(actual / estimated) of the newest `window` valid runs of `preset`; 1.0 with fewer than `window`.
    public static func factor(_ runs: [Run], preset: String) -> Double {
        let mine = runs.filter { $0.presetKey == preset && $0.estimatedS > 0 && $0.actualS > 0 }
            .sorted { $0.createdAt > $1.createdAt }.prefix(window)
        guard mine.count == window else { return 1.0 }
        return median(mine.map { $0.actualS / $0.estimatedS })
    }

    static func median(_ xs: [Double]) -> Double {
        let s = xs.sorted()
        guard !s.isEmpty else { return 1.0 }
        return s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2
    }
}

/// `video_run_history` reads and writes.
public struct VideoHistoryStore: Sendable {
    public let database: AppDatabase
    public init(_ database: AppDatabase) { self.database = database }

    /// Records a finished job. Incognito: nothing is written (returns false).
    @discardableResult
    public func record(_ run: VideoHistory.Run, incognito: Bool) throws -> Bool {
        guard !incognito else { return false }
        try database.write { db in
            try db.execute(sql: """
                INSERT INTO video_run_history (id, preset_key, speed_class, estimated_s, actual_s, created_at)
                VALUES (?, ?, ?, ?, ?, ?)
                """, arguments: [UUID().uuidString, run.presetKey, run.speedClass, run.estimatedS, run.actualS,
                                 run.createdAt.timeIntervalSince1970])
        }
        return true
    }

    /// The newest `limit` runs of `preset` (newest first).
    public func recent(preset: String, limit: Int = VideoHistory.window) -> [VideoHistory.Run] {
        (try? database.read { db in
            try Row.fetchAll(db, sql: """
                SELECT * FROM video_run_history WHERE preset_key = ? ORDER BY created_at DESC LIMIT ?
                """, arguments: [preset, limit]).map {
                VideoHistory.Run(presetKey: $0["preset_key"], speedClass: $0["speed_class"], estimatedS: $0["estimated_s"],
                                 actualS: $0["actual_s"], createdAt: Date(timeIntervalSince1970: $0["created_at"]))
            }
        }) ?? []
    }
}
