// M2.T06 step 4 (R-222 AC1): the selector's output, per pack × mode × role. Consumers: onboarding (sizes, T18),
// Capabilities (T07/T21), the install queue (T09) and the scheduler (T12). Model names live here and in Advanced
// only — default UI strings never show them (R-222 AC1, NoModelNamesUITests).
import Foundation

public enum ModelPack: String, Codable, Sendable, CaseIterable, Comparable {
    case chat, voice, photo, video
    public static func < (a: Self, b: Self) -> Bool { allCases.firstIndex(of: a)! < allCases.firstIndex(of: b)! }

    /// The one "shipped packs" switch (lead decision B, M2 review): a pack not in this set is shown "Coming soon" in
    /// onboarding step 2, Settings › Capabilities and the install cards — not tickable, not counted in any size, never
    /// enqueued. Each pack's milestone adds it here: Voice → M3, Photo → M4, Video → M5. Chat (+ Evil) always ships.
    #if ANTICHAT_TRYOUT_PREVIEW
    /// Owner try-out preview only (`make build-tryout`, which compiles with ANTICHAT_TRYOUT_PREVIEW): every pack on,
    /// so the owner can test the later milestones early. Never a release build: build-release.sh refuses the flag
    /// with Developer ID signing or release keys, and `tools/ci/tryout-guard.py` (make audit) checks that
    /// `make build-release` never sets it.
    public static let shipped: Set<ModelPack> = [.chat, .voice, .photo, .video]
    #else
    public static let shipped: Set<ModelPack> = [.chat, .voice, .photo, .video]  // Voice: M3.T14; Photo: M4.T16; Video: M5.T14
    #endif

    public var isShipped: Bool { Self.shipped.contains(self) }
}

public enum ModelMode: String, Codable, Sendable, CaseIterable, Comparable {
    case normal, evil
    public static func < (a: Self, b: Self) -> Bool { allCases.firstIndex(of: a)! < allCases.firstIndex(of: b)! }
}

/// `model_override {pack, mode, model_id}` (Advanced, T07): wins when it still fits, or always with
/// "Allow loads above the memory budget".
public struct ModelOverride: Codable, Sendable, Equatable {
    public var pack: ModelPack
    public var mode: ModelMode
    public var modelID: String
    public init(pack: ModelPack, mode: ModelMode, modelID: String) { self.pack = pack; self.mode = mode; self.modelID = modelID }
}

public struct SelectionSlot: Codable, Sendable, Equatable {
    public enum Note: String, Codable, Sendable { case contextLowered, steppedDown, overrideUsed, overrideIgnored, revokedReplaced }
    public var pack: ModelPack
    public var mode: ModelMode
    public var role: String
    /// The default model, nil when the slot is unavailable (`reason`).
    public var modelID: String?
    /// Every id the slot installs (the pack list and each entry's `requires`).
    public var installIDs: [String]
    public var ctx: Int?
    public var fit: FitClass?
    public var reason: String?
    public var notes: [Note]
    /// R-298: kept on the internal disk and never removed outside Advanced (the starter on T0–T2).
    public var keepInternal: Bool

    public init(pack: ModelPack, mode: ModelMode, role: String, modelID: String?, installIDs: [String], ctx: Int?, fit: FitClass?,
                reason: String?, notes: [Note], keepInternal: Bool) {
        self.pack = pack; self.mode = mode; self.role = role; self.modelID = modelID; self.installIDs = installIDs; self.ctx = ctx
        self.fit = fit; self.reason = reason; self.notes = notes; self.keepInternal = keepInternal
    }
}

public struct Selection: Codable, Sendable, Equatable {
    public var cellKey: String
    public var speedClass: SpeedClass
    public var slots: [SelectionSlot]

    public func slot(_ pack: ModelPack, _ mode: ModelMode = .normal, role: String? = nil) -> SelectionSlot? {
        slots.first { $0.pack == pack && $0.mode == mode && (role == nil ? $0.role == pack.rawValue || $0.role == "chat" : $0.role == role) }
    }

    public var chatFast: SelectionSlot? { slots.first { $0.role == "chat_fast" } }
    public var title: SelectionSlot? { slots.first { $0.role == "title" } }

    /// The ids to download for the given packs and modes (on-demand roles and unavailable slots excluded).
    public func installIDs(packs: Set<ModelPack>, modes: Set<ModelMode>, onDemand: Set<String> = []) -> Set<String> {
        Set(slots.filter { packs.contains($0.pack) && modes.contains($0.mode) && !onDemand.contains($0.role) }.flatMap(\.installIDs))
    }
}

extension ModelOverride {
    /// Stored overrides → selector input. A row naming an unknown pack/mode is dropped; an unknown model id is
    /// kept and ignored by the selector (E.2.3 step 5, "ignored if its model id is unknown").
    public static func load(_ records: [ModelOverrideRecordLike]) -> [ModelOverride] {
        records.compactMap { r in
            guard let p = ModelPack(rawValue: r.pack), let m = ModelMode(rawValue: r.mode) else { return nil }
            return ModelOverride(pack: p, mode: m, modelID: r.modelID)
        }
    }
}

/// The fields of `ModelOverrideRecord` the selector needs (Storage's record conforms in AntiChatPlatform).
public protocol ModelOverrideRecordLike {
    var pack: String { get }
    var mode: String { get }
    var modelID: String { get }
}

extension SelectionSlot.Note {
    /// The user-facing notice for a note, when it has one (copy deck).
    public var copyKey: String? {
        switch self {
        case .contextLowered: "model.contextLowered"
        case .revokedReplaced: "model.revoked"
        default: nil
        }
    }
}

extension Selection {
    public struct ChatRoute: Sendable, Equatable {
        public var modelID: String?
        public var noticeKey: String?
    }

    /// R-298 / E.2.6 [Move…] step 3: with the external Models drive missing, Normal chat falls back to the starter
    /// kept on the internal disk (`model.drive.missing`); Evil has no stand-in (R-227) and only shows the notice.
    public func chatRoute(mode: ModelMode, modelsDriveConnected: Bool) -> ChatRoute {
        let chat = slot(.chat, mode, role: "chat")
        if modelsDriveConnected { return ChatRoute(modelID: chat?.modelID, noticeKey: nil) }
        if mode == .normal, let fast = chatFast, fast.keepInternal, let id = fast.modelID {
            return ChatRoute(modelID: id, noticeKey: "model.drive.missing")
        }
        return ChatRoute(modelID: nil, noticeKey: "model.drive.missing")
    }
}
