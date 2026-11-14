// antichat-storage-torture (M1.T04 step 6, R-208 AC5 internal gate): a test-only writer that CrashInjectionTests
// starts and kills with SIGKILL at a random moment. It runs the real write paths without pause: new chats, user
// turns, assistant replies streamed with part upserts every 50 ms, regenerates and edits (siblings), version
// switches and branch copies. Prints `ready` once its first transaction committed.
//
// Usage: antichat-storage-torture --db <path> [--interval-ms 50] [--seed <n>]
import AntiChatStorage
import Foundation

struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {  // SplitMix64
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

func argument(_ name: String) -> String? {
    let args = CommandLine.arguments
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    return args[i + 1]
}

guard let path = argument("--db") else {
    FileHandle.standardError.write(Data("usage: antichat-storage-torture --db <path> [--interval-ms 50] [--seed n]\n".utf8))
    exit(64)
}
let interval = UInt32(argument("--interval-ms").flatMap(UInt32.init) ?? 50) * 1000
var rng = SeededGenerator(state: argument("--seed").flatMap(UInt64.init) ?? UInt64.random(in: 0...UInt64.max))
let words = ["alpha", "bravo", "charlie", "delta", "echo", "fox", "golf", "hotel", "india", "juliet", "kilo", "lima"]
@MainActor func sentence(_ n: Int) -> String { (0..<n).map { _ in words.randomElement(using: &rng)! }.joined(separator: " ") }

do {
    let database = try AppDatabase.onDisk(at: URL(fileURLWithPath: path))
    let tree = MessageTree(database)
    let chats = ChatRepository(database)
    let messages = MessageRepository(database)
    try messages.markInterruptedAfterCrash()  // what the app does at launch
    print("ready")
    fflush(stdout)

    /// Streams an assistant reply into `messageID`: grows a text part (and sometimes a reasoning part) every tick.
    func stream(_ messageID: String) throws {
        var text = ""
        let withReasoning = Bool.random(using: &rng)
        for tick in 0..<Int.random(in: 3...20, using: &rng) {
            text += (text.isEmpty ? "" : " ") + sentence(Int.random(in: 2...12, using: &rng))
            var parts: [(idx: Int, part: PartContent)] = [(withReasoning ? 1 : 0, .text(text))]
            if withReasoning { parts.append((0, PartContent(kind: .reasoning, body: "thinking \(tick)"))) }
            try messages.flush(messageID, parts: parts)
            usleep(interval)
        }
        try messages.finish(
            messageID, status: .done,
            usage: MessageUsage(promptTokens: Int.random(in: 10...4000, using: &rng), completionTokens: text.count / 4),
            provenance: MessageProvenance(modelSHA: "sha256-torture", mode: .normal, sampling: ["temperature": 0.7],
                                          tokPerS: 42))
    }

    while true {
        let existing = try chats.sidebar(limit: 20)
        let chatID: String
        if existing.isEmpty || Int.random(in: 0..<4, using: &rng) == 0 {
            chatID = try chats.create(title: sentence(3)).id
        } else {
            chatID = existing.randomElement(using: &rng)!.id
        }
        let path = try tree.visiblePath(chatID)
        switch Int.random(in: 0..<10, using: &rng) {
        case 0...5:  // a new turn at the leaf
            let user = try tree.append(chatID: chatID, parentID: path.last?.id, role: .user, parts: [.text(sentence(8))])
            let reply = try tree.append(chatID: chatID, parentID: user.id, role: .assistant, status: .streaming)
            try stream(reply.id)
        case 6:  // regenerate the last reply
            if let last = path.last(where: { $0.role == .assistant }) {
                let reply = try tree.insertSibling(of: last.id, status: .streaming)
                try stream(reply.id)
            }
        case 7:  // edit a user message, then answer it
            if let user = path.filter({ $0.role == .user }).randomElement(using: &rng) {
                let edited = try tree.insertSibling(of: user.id, parts: [.text("edited " + sentence(5))])
                let reply = try tree.append(chatID: chatID, parentID: edited.id, role: .assistant, status: .streaming)
                try stream(reply.id)
            }
        case 8:  // switch to another version
            if let node = path.randomElement(using: &rng) {
                let siblings = try tree.siblings(of: node.id)
                try tree.setActive(siblings.randomElement(using: &rng)!.id)
            }
        default:  // branch in a new chat
            if let node = path.randomElement(using: &rng) { try tree.branchCopy(upTo: node.id, title: "branch") }
        }
    }
} catch {
    FileHandle.standardError.write(Data("antichat-storage-torture: \(error)\n".utf8))
    exit(1)
}
