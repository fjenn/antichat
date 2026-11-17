// M8.T03 step 1 (R-242 AC2, R-060 AC1; IS-12): the inline memory line. A `memory` tool step that wrote something shows
// `act.memory` "Memory updated ▸" on its ActivityLine; expanded, one row per event: topic chip + text + [Undo]
// (`memory.undo`), which calls MemoryStore.undo and turns the row into `memory.undone`. Reads ("Used memory ▸") come
// from the reply's provenance. No toast. The store is the app database's (set once at launch).
import AntiChatDesign
import AntiChatHarness
import AntiChatKnowledge
import AntiChatStorage
import SwiftUI

public enum MemoryNotice {
    /// The app database's memory store (nil in hosts without one: the line then shows without Undo).
    nonisolated(unsafe) public static var store: MemoryStore?

    static func isMemory(_ a: ToolActivity) -> Bool { a.tool == MemoryTool.name && a.kind == .tool }

    static func eventIDs(_ a: ToolActivity) -> [String] { a.result.map(MemoryToolExecutor.eventIDs(inResult:)) ?? [] }

    static func label(_ a: ToolActivity) -> CopyText? {
        guard a.state == .done, !eventIDs(a).isEmpty else { return nil }
        return CopyText(CopyKey("act.memory"))
    }

    struct Row: Identifiable, Equatable {
        var id: String  // event id
        var topic: String
        var text: String
        var undone: Bool
    }

    static func rows(_ ids: [String], store: MemoryStore?) -> [Row] {
        guard let store else { return [] }
        return ids.compactMap { id in
            try? store.database.read { db -> Row? in
                guard let e = try MemoryEvent.fetchOne(db, key: id), let item = try MemoryItem.fetchOne(db, key: e.itemID) else { return nil }
                let topic = try String.fetchOne(db, sql: "SELECT name FROM memory_topic WHERE id = ?", arguments: [item.topicID]) ?? ""
                return Row(id: id, topic: topic, text: item.text, undone: e.undoneAt != nil)
            } ?? nil
        }
    }
}

extension MemoryNotice {
    /// "Used memory ▸" rows: the frozen snapshot's items the reply read (provenance `memoryReads`), topic + text.
    /// Items deleted since are skipped (the line hides when none is left).
    static func readRows(_ itemIDs: [String], store: MemoryStore?) -> [Row] {
        guard let store, !itemIDs.isEmpty else { return [] }
        return (try? store.database.read { db in
            try itemIDs.compactMap { id -> Row? in
                guard let item = try MemoryItem.fetchOne(db, key: id) else { return nil }
                let topic = try String.fetchOne(db, sql: "SELECT name FROM memory_topic WHERE id = ?", arguments: [item.topicID]) ?? ""
                return Row(id: id, topic: topic, text: item.text, undone: false)
            }
        }) ?? []
    }
}

/// M8.T03 step 1: `act.memoryRead` "Used memory ▸" above the reply; expanded, the snapshot items it used (read-only).
struct MemoryReadLine: View {
    let rows: [MemoryNotice.Row]
    @State private var expanded: Bool

    init(itemIDs: [String], store: MemoryStore? = MemoryNotice.store) {
        self.init(rows: MemoryNotice.readRows(itemIDs, store: store))
    }

    /// Fixed rows (snapshot tests).
    init(rows: [MemoryNotice.Row], expanded: Bool = false) {
        self.rows = rows
        _expanded = State(initialValue: expanded)
    }

    var body: some View {
        if !rows.isEmpty {
            VStack(alignment: .leading, spacing: Spacing.space1) {
                Button {
                    withAnimation(.easeOut(duration: 0.15)) { expanded.toggle() }
                } label: {
                    HStack(spacing: Spacing.space2) {
                        Image(systemName: "brain").foregroundStyle(Color.textSecondary)
                        Text(CopyKey("act.memoryRead")).typeStyle(.subhead).foregroundStyle(Color.textSecondary)
                        Image(systemName: expanded ? "chevron.down" : "chevron.right")
                            .font(.caption2).foregroundStyle(Color.textTertiary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("memoryReadLine")
                .probeID("memoryReadLine")
                if expanded {
                    VStack(alignment: .leading, spacing: Spacing.space1) {
                        ForEach(rows) { MemoryNoticeRow(row: $0, onUndo: nil) }
                    }
                    .padding(.leading, Spacing.space5)
                }
            }
        }
    }
}

/// M8.T03 step 7: the proposed state — `memory.propose` "Remember this? "{fact}"" with [Dismiss] [Save].
struct MemorySuggestionCard: View {
    let id: String
    let text: String
    let onDismiss: () -> Void
    let onSave: () -> Void

    var body: some View {
        HStack(spacing: Spacing.space3) {
            Image(systemName: "brain").foregroundStyle(Color.textSecondary)
            Text(CopyText(CopyKey("memory.propose"), ["fact": text])).typeStyle(.body)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: Spacing.space2)
            Button(action: onDismiss) { Text(CopyKey("memory.dismiss")) }
                .probeID("memory.suggestion.dismiss.\(id)")
            Button(action: onSave) { Text(CopyKey("memory.save")) }
                .buttonStyle(PrimaryButtonStyle())
                .probeID("memory.suggestion.save.\(id)")
        }
    }
}

/// One memory row: topic chip + text, then [Undo] (saved), `memory.undone` (undone) or nothing (read-only).
struct MemoryNoticeRow: View {
    /// A topic as people read it: models name topics like `measurement_preference` (owner 2026-11-17: no raw tags).
    static func readable(_ topic: String) -> String {
        let words = topic.replacingOccurrences(of: "_", with: " ").replacingOccurrences(of: "-", with: " ")
            .trimmingCharacters(in: .whitespaces)
        return words.prefix(1).uppercased() + words.dropFirst()
    }

    let row: MemoryNotice.Row
    let onUndo: (() -> Void)?

    var body: some View {
        HStack(spacing: Spacing.space2) {
            Text(verbatim: Self.readable(row.topic))
                .typeStyle(.caption)
                .padding(.horizontal, Spacing.space2).padding(.vertical, 2)
                .background(Capsule().fill(Color.surfaceSunken))
            Text(verbatim: row.text).typeStyle(.callout).foregroundStyle(Color.textPrimary)
            Spacer(minLength: Spacing.space2)
            if row.undone {
                Text(CopyKey("memory.undone")).typeStyle(.caption).foregroundStyle(Color.textTertiary)
            } else if let onUndo {
                Button(action: onUndo) { Text(CopyKey("memory.undo")) }
                    .buttonStyle(.link)
                    .probeID("memory.undo.\(row.id)")
            }
        }
    }
}

struct MemoryNoticeView: View {
    let eventIDs: [String]
    /// Fixed rows (snapshot tests) show [Undo] without a store.
    private let fixed: Bool
    @State private var rows: [MemoryNotice.Row] = []

    init(eventIDs: [String]) {
        self.eventIDs = eventIDs
        fixed = false
    }

    init(rows: [MemoryNotice.Row]) {
        eventIDs = rows.map(\.id)
        fixed = true
        _rows = State(initialValue: rows)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.space1) {
            ForEach(rows) { r in
                MemoryNoticeRow(row: r, onUndo: undo(r))
            }
        }
        .onAppear { if !fixed { rows = MemoryNotice.rows(eventIDs, store: MemoryNotice.store) } }
        .accessibilityElement(children: .contain)  // own ids for the children (Q-015)
        .probeID("memoryNotice")
    }

    private func undo(_ r: MemoryNotice.Row) -> (() -> Void)? {
        if fixed { return {} }
        guard let store = MemoryNotice.store else { return nil }
        return {
            try? store.undo(eventID: r.id)
            rows = MemoryNotice.rows(eventIDs, store: store)
        }
    }
}
