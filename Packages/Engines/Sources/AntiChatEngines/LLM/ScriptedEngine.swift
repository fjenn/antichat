// ScriptedEngine in the helper (M1.T05 step 6): the `EngineAdapter` wrapper around `EngineScriptPlayer`
// (AntiChatEngineProtocol/EngineScript.swift, shared with the app's in-process replay). Selected per request by
// `ModelSlot.engine == .scripted` (`ModelSlot.path` = the JSONL script): launchd starts the XPC service
// without the app's launch arguments, so `-UseScriptedEngine` cannot reach the helper (A-M1-T05a).
// `{"t":"crash"}` kills the helper process (`_exit(70)`), which is what the restart tests need.
import AntiChatEngineProtocol
import AntiChatFoundation
import Darwin
import Foundation

public actor ScriptedEngine: EngineAdapter {
    public nonisolated let kind = EngineKind.scripted
    public private(set) var loadedKey: String?
    private var players: [String: EngineScriptPlayer] = [:]
    private let onCrash: @Sendable () -> Void

    /// `onCrash` defaults to killing the process; unit tests pass a recorder.
    public init(onCrash: (@Sendable () -> Void)? = nil) {
        self.onCrash = onCrash ?? { Darwin._exit(70) }
    }

    /// Parses (and caches) the script; the simulated load time lives in the script's `load` step.
    @discardableResult
    public func load(_ slot: ModelSlot) async throws -> Double {
        _ = try player(slot.path)
        loadedKey = slot.key
        return 0
    }

    public func unload() async {
        loadedKey = nil
        players.removeAll()
    }

    func player(_ path: String) throws -> EngineScriptPlayer {
        if let p = players[path] { return p }
        let script: EngineScript
        do {
            script = try EngineScript(contentsOf: URL(fileURLWithPath: path))
        } catch {
            throw AntiChatError(.modelCorrupt, detail: "script \(path): \(error)")
        }
        let p = EngineScriptPlayer(script: script)
        players[path] = p
        return p
    }

    public func capabilities(_ path: String) throws -> EngineCapabilities {
        try player(path).script.capabilities
    }

    public func generate(_ request: ChatRequest, context: GenerationContext) async throws -> AsyncStream<AdapterOutput> {
        let p = try player(request.modelSlot.path)
        let crash = onCrash
        return AsyncStream(bufferingPolicy: .unbounded) { cont in
            let task = Task {
                await p.play(request) { out in
                    switch out {
                    case .engine(let e): cont.yield(.event(e))
                    case .lifecycle(let l): cont.yield(.lifecycle(l))
                    case .crash: crash()
                    }
                }
                cont.finish()
            }
            cont.onTermination = { _ in task.cancel() }
        }
    }
}
