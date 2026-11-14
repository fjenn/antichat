// M9.T05 NFR-U10 / NFR-U11 XCUITest perf legs (M1.T26b PalettePerfTests / LongChatOpenPerfTests) on the 10,000-chat
// fixture database (tools/fixtures/gen-chats.py --chats 10000 --long 1:1000 [--turns 500 default]: one chat of 500
// turns), a fresh copy per launch so no run sees another's writes:
//   paletteQuery  ⌘K query change → its chat results drawn (PaletteController; U10: p95 ≤ 200 ms for 10,000 chats)
//   chatOpen      open the 500-turn chat → its latest screen drawn (WindowState → ConversationView; U11: p95 ≤ 500 ms):
//                 per launch one cold open (from ⌘K) and one warm re-open (⌘N, then ⌘[ back to it)
// `make perf METRIC=U10 TIER=na FROM_LOG=<log>` / `METRIC=U11` judge the bars (PerfUITestSupport.swift).
import XCTest

enum BigDB {
    static var database: URL {
        if let p = PerfUI.env["ANTICHAT_BIG10K_DB"], !p.isEmpty { return URL(fileURLWithPath: p) }
        return PerfUI.repoRoot.appendingPathComponent("build/fixtures/big-10k.sqlite")
    }

    /// A throwaway container holding a copy of the 10,000-chat database.
    static func container() throws -> URL {
        try XCTSkipUnless(FileManager.default.fileExists(atPath: database.path),
                          "\(database.path) missing: python3 -I tools/fixtures/gen-chats.py --chats 10000 --long 1:1000 --out \(database.path)")
        let c = PerfUI.tempContainer("big10k")
        try FileManager.default.createDirectory(at: c, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: database, to: c.appendingPathComponent("antichat.sqlite"))
        return c
    }

    @MainActor
    static func launch(_ log: URL) throws -> XCUIApplication {
        PerfUI.launch(container: try container(), log: log, ["-OfflineOnly", "YES", "-SkipOnboarding", "YES"])
    }

    static let queries = ["pasta", "tax", "garden", "bike", "Swift", "Lisbon", "budget", "sourdough", "interview", "piano",
                          "marathon", "SQL", "network", "cover", "birthday", "climate", "Roman", "chess", "watercolor", "camera",
                          "zebracorn", "coffee", "houseplants", "spreadsheet", "photosynthesis"]
}

final class PalettePerfTests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    @MainActor
    func testPaletteQueryOnTenThousandChats() throws {
        let log = PerfUI.perfLog("U10")
        let before = PerfUI.intervals(log, "paletteQuery").count
        let app = try BigDB.launch(log)
        let rows = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'palette.row.chat.'"))
        var queries = 0
        // One palette session; each query replaces the previous one in the field (⌘A, ⌫, then the new words).
        app.typeKey("k", modifierFlags: .command)
        XCTAssertTrue(PerfUI.element(app, "palette").waitForExistence(timeout: 3), "palette")
        usleep(300_000)
        // Typing goes to the palette's own field (app-level typeText landed in the composer behind it).
        let field = PerfUI.element(app, "palette.field")
        XCTAssertTrue(field.waitForExistence(timeout: 3), "palette field")
        // M9.T05: the id is the TextField's own (UP-CP-006). On the kit's whole view the click hit its centre, a
        // result row, which opened that chat and closed the palette ("palette.field not found" at the first query).
        XCTAssertEqual(field.elementType, .textField, "palette.field is the search field itself")
        field.click()
        XCTAssertTrue(PerfUI.element(app, "palette").exists, "the click on the field kept the palette open")
        for i in 0..<PerfUI.runs {
            let q = BigDB.queries[i % BigDB.queries.count]
            if i > 0 {
                app.typeKey("a", modifierFlags: .command)
                app.typeKey(.delete, modifierFlags: [])
                usleep(300_000)
            }
            let seen = PerfUI.intervals(log, "paletteQuery").count
            field.typeText(q)
            XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 5), "no chat rows for \(q)")
            XCTAssertGreaterThan(PerfUI.waitIntervals(log, "paletteQuery", atLeast: seen + 1), seen, "no paletteQuery for \(q)")
            queries += 1
            usleep(400_000)  // the semantic rows (if any) merge in; the interval ended at the FTS rows
        }
        app.typeKey(.escape, modifierFlags: [])
        let n = PerfUI.waitIntervals(log, "paletteQuery", atLeast: before + queries) - before
        app.terminate()
        PerfUI.evidence("AT-NFR-U10", ["log": log.path, "queries": queries, "paletteQuery": n, "load": PerfUI.loadAverage()])
        // Each typed character is a query change; a settled query records one interval (its last change → its rows).
        XCTAssertGreaterThanOrEqual(n, queries, "at least one paletteQuery interval per query")
    }
}

final class LongChatOpenPerfTests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    @MainActor
    func testOpenFiveHundredTurnChat() throws {
        let log = PerfUI.perfLog("U11")
        let before = PerfUI.intervals(log, "chatOpen").count
        let launches = max(1, PerfUI.runs / 2)
        var opens = 0
        for _ in 0..<launches {
            let app = try BigDB.launch(log)
            app.typeKey("k", modifierFlags: .command)
            XCTAssertTrue(PerfUI.element(app, "palette").waitForExistence(timeout: 3), "palette")
            let field = PerfUI.element(app, "palette.field")
            XCTAssertTrue(field.waitForExistence(timeout: 3), "palette field")
            XCTAssertEqual(field.elementType, .textField, "palette.field is the search field itself")
            field.click()
            XCTAssertTrue(PerfUI.element(app, "palette").exists, "the click on the field kept the palette open")
            field.typeText("500 turns")
            // The 500-turn chat's row (title "<Topic> (500 turns)", gen-chats.py turns_chat).
            let row = app.descendants(matching: .any)
                .matching(NSPredicate(format: "identifier BEGINSWITH 'palette.row.chat.' AND label CONTAINS '500 turns'")).firstMatch
            XCTAssertTrue(row.waitForExistence(timeout: 5), "the 500-turn chat is not found by ⌘K")
            let start = PerfUI.intervals(log, "chatOpen").count
            row.click()  // cold: the chat's ConversationModel loads its visible path
            XCTAssertEqual(PerfUI.waitIntervals(log, "chatOpen", atLeast: start + 1, timeout: 10), start + 1, "cold open")
            opens += 1
            usleep(500_000)
            app.typeKey("n", modifierFlags: .command)
            usleep(800_000)
            app.typeKey("[", modifierFlags: .command)  // warm: back to the open chat
            XCTAssertEqual(PerfUI.waitIntervals(log, "chatOpen", atLeast: start + 2, timeout: 10), start + 2, "warm re-open")
            opens += 1
            app.terminate()
        }
        let n = PerfUI.intervals(log, "chatOpen").count - before
        PerfUI.evidence("AT-NFR-U11", ["log": log.path, "opens": opens, "chatOpen": n, "load": PerfUI.loadAverage()])
        XCTAssertEqual(n, opens, "one chatOpen interval per open")
    }
}
