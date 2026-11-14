// M6.T21 close review #5, lead ruling (c), A-M6-T21a (a): per-chat isolation through File tools service slots, on the
// real signed slot services (`make test-integration-stub FILTER=FileToolsSlotTests`). Each test uses its own
// FileToolsSlots leaser over the dev slot ids with an explicit capacity.
//   - a chat in one slot gets EPERM on every path of another slot's chat (kernel: another container);
//   - a lease moves only after the slot was wiped: the new chat sees nothing of the old one, the old chat starts fresh;
//   - with two other chats running code, a third chat's run still answers within 2 s (AT-NFR-SEC3 bystander);
//   - beyond the capacity a chat waits, listed as waiting (`sandbox.waiting`), and then runs in the freed slot.
import AntiChatEngineProtocol
import AntiChatTools
import Foundation
import XCTest

final class FileToolsSlotTests: XCTestCase {
    override func setUpWithError() throws { try FileToolsIT.requireDevBuild() }

    func secretFile() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appending(path: "ft-slot-\(UUID().uuidString.prefix(6))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let secret = dir.appending(path: "secret.txt")
        try "chat A's upload".write(to: secret, atomically: true, encoding: .utf8)
        return secret
    }

    func testAChatInOneSlotCannotReadAnotherSlotsChat() async throws {
        let slots = FileToolsSlots(capacity: 3)
        let client = FileToolsClient(network: false, slots: slots)
        let secret = try secretFile()
        defer { try? FileManager.default.removeItem(at: secret.deletingLastPathComponent()) }
        let (ra, _) = try await FileToolsIT.run(client, chat: "slot-a", "import os, json; open('out/result.txt', 'w').write('a'); print(json.dumps({'jail': os.getcwd(), 'in': open('in/secret.txt').read()}))", inputs: [secret])
        let ja = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(ra.stdout.utf8)) as? [String: Any], ra.stdout)
        XCTAssertEqual(ja["in"] as? String, "chat A's upload")
        let jailA = try XCTUnwrap(ja["jail"] as? String)
        let containerA = String(jailA[..<(jailA.range(of: "/Data/scratch/")?.lowerBound ?? jailA.endIndex)])
        let b = try await FileToolsIT.probe(client, chat: "slot-b", FileToolsIT.prelude + """
        A = \(String(reflecting: jailA)); C = \(String(reflecting: containerA))
        res = {}
        for p in [A + "/in/secret.txt", A + "/out/result.txt"]:
            res["read py " + p] = py_read(p); res["read c " + p] = c_read(p)
        for d in [A, A + "/in", C + "/Data/scratch", C + "/Data", C]:
            res["list " + d] = py_list(d)
        for p in [A + "/in/planted.py", C + "/Data/scratch/planted.txt"]:
            res["write c " + p] = c_write(p)
        res["siblings"] = ",".join(sorted(os.listdir("..")))
        print(json.dumps(res))
        """)
        let slotA = await slots.holding("slot-a")?.slot, slotB = await slots.holding("slot-b")?.slot
        XCTAssertNotNil(slotA); XCTAssertNotNil(slotB)
        XCTAssertNotEqual(slotA, slotB, "two chats with free slots never share one")
        XCTAssertEqual(b["siblings"] as? String, "slot-b")
        for (k, v) in b where k != "siblings" { XCTAssertEqual(v as? String, "EPERM", "\(k): chat B must not reach chat A's slot") }
        // Chat A's files are still there for chat A (the denial is not an absence).
        let (ra2, _) = try await FileToolsIT.run(client, chat: "slot-a", "print(open('in/secret.txt').read())")
        XCTAssertFalse(ra2.freshSession)
        XCTAssertEqual(ra2.stdout.trimmingCharacters(in: .whitespacesAndNewlines), "chat A's upload")
        var ev = b; ev["slot a"] = slotA; ev["slot b"] = slotB; ev["jail a"] = jailA
        FileToolsIT.evidence("AT-018", "slots-cross-read.json", String(decoding: try JSONSerialization.data(withJSONObject: ev, options: [.prettyPrinted, .sortedKeys]), as: UTF8.self))
        for c in ["slot-a", "slot-b"] { try await client.reset(chatID: c) }
    }

    func testALeaseMovesOnlyAfterTheSlotIsWiped() async throws {
        let slots = FileToolsSlots(capacity: 1)
        let client = FileToolsClient(network: false, slots: slots)
        let secret = try secretFile()
        defer { try? FileManager.default.removeItem(at: secret.deletingLastPathComponent()) }
        let (ra, _) = try await FileToolsIT.run(client, chat: "lease-a", """
        import os
        open("out/result.txt", "w").write("a"); open("tmp/note.txt", "w").write("a")
        open("../lease-a-planted.txt", "w").write("a")   # the scratch folder itself is writable; the wipe deletes it
        open("../../lease-a-shared.txt", "w").write("a")  # so is the folder all instances share; no instance owns this
        print(open("in/secret.txt").read())
        """, inputs: [secret])
        XCTAssertNil(ra.error, ra.error?.traceback ?? "")
        let j = try await FileToolsIT.probe(client, chat: "lease-b", """
        import json, os
        print(json.dumps({"siblings": sorted(os.listdir("..")), "a_in": os.path.exists("../lease-a/in/secret.txt"),
                          "a_planted": os.path.exists("../lease-a-planted.txt"),
                          "a_shared": os.path.exists("../../lease-a-shared.txt")}))
        """)
        let heldB = await slots.holding("lease-b")?.slot, heldA = await slots.holding("lease-a")
        XCTAssertEqual(heldB, 1)
        XCTAssertNil(heldA, "the lease moved")
        XCTAssertEqual(j["siblings"] as? [String], ["lease-b"], "\(j)")
        XCTAssertEqual(j["a_in"] as? Bool, false)
        XCTAssertEqual(j["a_planted"] as? Bool, false)
        XCTAssertEqual(j["a_shared"] as? Bool, false)
        // The old chat comes back to a wiped slot: a fresh interpreter and no files of its own either.
        let (ra2, _) = try await FileToolsIT.run(client, chat: "lease-a", "import os; print(os.path.exists('in/secret.txt'), os.listdir('..'))")
        XCTAssertTrue(ra2.freshSession)
        XCTAssertEqual(ra2.stdout.trimmingCharacters(in: .whitespacesAndNewlines), "False ['lease-a']")
        // A killed run's jail goes with its session (review #6), inside the slot too.
        let (rk, _) = try await FileToolsIT.run(client, chat: "lease-a", "open('out/left.txt','w').write('x')\nwhile True: pass", timeout: 2)
        XCTAssertEqual(rk.killedReason, .timeout)
        let ack = try await FileToolsClient(serviceName: FileToolsProtocol.slotServiceName(1, network: false)).resetAck(chatID: "lease-a")
        XCTAssertTrue(ack.scratchEmpty)
        let wiped = try await FileToolsClient(serviceName: FileToolsProtocol.slotServiceName(1, network: false)).resetAck(chatID: "x", wipeSlot: true)
        XCTAssertTrue(wiped.scratchEmpty)
    }

    func testBystanderAnswersWhileTwoOtherChatsRunCode() async throws {
        let slots = FileToolsSlots(capacity: 3)
        let client = FileToolsClient(network: false, slots: slots)
        let busy = (1...2).map { i in Task { try await FileToolsIT.run(client, chat: "busy-\(i)", "while True: pass", timeout: 12).0 } }
        try await Task.sleep(for: .seconds(4))
        let t0 = Date()
        let (r, _) = try await FileToolsIT.run(client, chat: "bystander", "print(6 * 7)")
        let answered = Date().timeIntervalSince(t0)
        XCTAssertEqual(r.stdout, "42\n")
        XCTAssertLessThan(answered, 2.0, "a third chat must answer within 2 s while two others run code")
        let held = await [slots.holding("busy-1")?.slot, slots.holding("busy-2")?.slot, slots.holding("bystander")?.slot]
        XCTAssertEqual(Set(held.compactMap { $0 }).count, 3, "\(held)")
        for b in busy { let rb = try await b.value; XCTAssertEqual(rb.killedReason, .timeout) }
        let load = FileToolsIT.shell("/usr/bin/uptime", []).trimmingCharacters(in: .whitespacesAndNewlines)
        FileToolsIT.evidence("AT-NFR-SEC3", "slots-bystander.json", "{\"answer_s\": \(answered), \"other_chats_busy\": 2, \"slots\": \(held.map { $0.map(String.init) ?? "null" }), \"uptime\": \(String(reflecting: load))}\n")
        for c in ["busy-1", "busy-2", "bystander"] { try await client.reset(chatID: c) }
    }

    func testBeyondTheCapacityAChatWaitsWithTheWaitingState() async throws {
        let slots = FileToolsSlots(capacity: 1)
        let client = FileToolsClient(network: false, slots: slots)
        let rt = try await FileToolsIT.runtime()
        let busy = Task { try await FileToolsIT.run(client, chat: "cap-a", "while True: pass", timeout: 6).0 }
        try await Task.sleep(for: .seconds(2))
        let out = FileManager.default.temporaryDirectory.appending(path: "ft-cap-\(UUID().uuidString.prefix(6))")
        let waiting = Task {
            try await client.run(RunCode(chatID: "cap-b", code: "print('b')", runtimePath: rt.path), outputDirectory: out, waitKey: "it-call-b").0
        }
        var sawWaiting = false
        for _ in 0..<100 where !sawWaiting { sawWaiting = FileToolsSlots.isWaiting("it-call-b"); try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(sawWaiting, "the call is listed as waiting for a free sandbox")
        let ra = try await busy.value
        XCTAssertEqual(ra.killedReason, .timeout)
        let rb = try await waiting.value
        XCTAssertEqual(rb.stdout, "b\n")
        XCTAssertFalse(FileToolsSlots.isWaiting("it-call-b"))
        let heldCapB = await slots.holding("cap-b")?.slot
        XCTAssertEqual(heldCapB, 1)
        try await client.reset(chatID: "cap-b")
    }
}
