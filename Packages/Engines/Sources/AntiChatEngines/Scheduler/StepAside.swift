// M2.T13 step 1 (R-206 AC2 media part, NFR-M3; P-shell-11 RL-005 rule 5). Media step-aside choreography, design port
// of AtomicBot-ai/Atomic-Chat@29b01d8 web-app/src/lib/diffusion/arbiter.ts (MIT): `acquireGpuForDiffusion` unloads
// the chat sessions that do not coexist with the diffusion set, keeps embeddings when they fit and evicts voice last;
// `releaseGpuForChat` gives the GPU back (here lazily: the chat model reloads at the next user message, R-236).
// Differences: "coexist" = Σ effective footprints ≤ B (E.2.7 arithmetic, never live free memory); the open chat's KV
// prefix is snapshotted before its model goes (PromptCacheSnapshot; never for incognito); a leased model is never a
// victim. On T3+ media is co-resident whenever it fits (no eviction).
// `FeatureFlag.mediaStepAside` off = the safe path: every chat model unloads before a media job, fit or not.
import AntiChatEngineProtocol
import Foundation

public enum StepAside {
    /// Victim rank for a media job (0 = goes first): idle job models, then the chat LLMs (the second variant first),
    /// then search models (kept when they fit), then voice (evicted last).
    public static func rank(_ role: ResidencyRole) -> Int {
        switch role {
        case .image, .video, .csamCheck: 0
        case .secondChat: 1
        case .chat: 2
        case .rerank, .embed: 3
        case .tts: 4
        case .stt: 5
        }
    }

    public struct Plan: Sendable, Equatable {
        /// In unload order.
        public var victims: [String]
        /// Chat models among the victims: their KV prefix is snapshotted before the unload.
        public var chatVictims: [String]
        /// Media fits beside what stays.
        public var fits: Bool
    }

    public static func plan(entries: [ResidentEntry], mediaBytes: UInt64, budget: UInt64, stepAside: Bool = true) -> Plan {
        let chats = entries.filter { $0.role == .chat || $0.role == .secondChat }
        if !stepAside {
            // Safe path: the LLM always goes; everything else by the same rule as below.
            var rest = plan(entries: entries.filter { !chats.map(\.key).contains($0.key) }, mediaBytes: mediaBytes, budget: budget)
            let idleChats = chats.filter { $0.refCount == 0 }.map(\.key)
            rest.victims = idleChats + rest.victims
            rest.chatVictims = idleChats
            return rest
        }
        guard budget > 0 else { return Plan(victims: [], chatVictims: [], fits: true) }
        var victims: [String] = []
        func used() -> UInt64 { entries.filter { !victims.contains($0.key) }.reduce(0) { $0 + $1.bytes } }
        let ordered = entries.sorted {
            let ra = rank(EvictionPolicy.effectiveRole($0, in: entries)), rb = rank(EvictionPolicy.effectiveRole($1, in: entries))
            return ra != rb ? ra < rb : ($0.lastUsed, $0.key) < ($1.lastUsed, $1.key)
        }
        for e in ordered where used() + mediaBytes > budget && e.refCount == 0 { victims.append(e.key) }
        let chatKeys = Set(chats.map(\.key))
        return Plan(victims: victims, chatVictims: victims.filter { chatKeys.contains($0) }, fits: used() + mediaBytes <= budget)
    }
}
