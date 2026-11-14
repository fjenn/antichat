// ApprovalCard (components.md §3, S-24; M1.T16 step 7; NFR-SEC4/SEC5 groundwork): a tool call with a side effect
// (write/send/delete) waits here. Tool icon, `approve.title` ("{action}"), the call's arguments as labelled lines
// (VQ-M10: "Channel  general" / "Text  Lunch is at noon.", as ChatGPT's and Claude's connector confirmations read;
// the raw JSON sits behind `approve.details`), [Allow once] [Always allow] [Deny]; with untrusted tool output in
// context the `approve.untrusted` warning shows and [Always allow] is not offered (PermissionGate.offersAlwaysAllow).
// States: pending (buttons) → allowed / denied (the ActivityLine above takes over); a Stop while pending expires it.
import AntiChatDesign
import AntiChatHarness
import AntiChatTools
import SwiftUI

public struct ApprovalCardView: View {
    let request: ToolApprovalRequest
    let onAnswer: (ApprovalAnswer) -> Void
    @State private var showArguments = false

    public init(request: ToolApprovalRequest, onAnswer: @escaping (ApprovalAnswer) -> Void) {
        self.request = request
        self.onAnswer = onAnswer
    }

    private var icon: String {
        switch request.sideEffect {
        case .read: "eye"
        case .write: "square.and.pencil"
        case .send: "paperplane"
        case .delete: "trash"
        }
    }

    private var fields: [Field] { Self.fields(request.argumentsJSON) }

    public var body: some View {
        VStack(alignment: .leading, spacing: Spacing.space2) {
            HStack(spacing: Spacing.space2) {
                Image(systemName: icon).foregroundStyle(Color.textSecondary)
                // M7.T13 (R-265): a skill script asks with `skills.scriptApproval`.
                Text(request.tool == RunSkillScriptTool.name ? CopyText(CopyKey("skills.scriptApproval"))
                     : CopyText(CopyKey("approve.title"), ["action": Self.actionName(request.tool)]))
                    .typeStyle(.headline)
                    .foregroundStyle(Color.textPrimary)
                    .accessibilityIdentifier("approvalTitle")
            }
            if request.untrusted {
                HStack(alignment: .firstTextBaseline, spacing: Spacing.space2) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(Color.warning)
                        .accessibilityHidden(true)
                    Text(CopyText(CopyKey("approve.untrusted")))
                        .typeStyle(.subhead)
                        .foregroundStyle(Color.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, Spacing.space2)
                .padding(.vertical, Spacing.space1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: Radius.sm, style: .continuous).fill(Color.warning.opacity(0.12)))
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("approvalUntrusted")
                .probeID("approvalUntrusted")
            }
            if !fields.isEmpty {
                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: Spacing.space3, verticalSpacing: Spacing.space1) {
                    ForEach(fields) { f in
                        GridRow {
                            Text(verbatim: f.label)
                                .typeStyle(.subhead)
                                .foregroundStyle(Color.textSecondary)
                                .gridColumnAlignment(.leading)
                            Text(verbatim: f.value)
                                .typeStyle(.subhead)
                                .foregroundStyle(Color.textPrimary)
                                .lineLimit(4)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .padding(Spacing.space2)
                .background(RoundedRectangle(cornerRadius: Radius.sm, style: .continuous).fill(Color.surfaceSunken))
                .accessibilityIdentifier("approvalFields")
            }
            Button {
                withAnimation(.easeOut(duration: 0.15)) { showArguments.toggle() }
            } label: {
                HStack(spacing: Spacing.space1) {
                    Text(CopyText(CopyKey("approve.details")))
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .rotationEffect(.degrees(showArguments ? 90 : 0))
                }
                .typeStyle(.footnote)
                .foregroundStyle(Color.textSecondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("approvalDetails")
            if showArguments {
                Text(verbatim: Self.prettyJSON(request.argumentsJSON))
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(Color.textSecondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(Spacing.space2)
                    .background(RoundedRectangle(cornerRadius: Radius.sm, style: .continuous).fill(Color.surfaceSunken))
                    .accessibilityIdentifier("approvalArguments")
            }
            HStack(spacing: Spacing.space2) {
                Button { onAnswer(.allowOnce) } label: { Text(CopyText(CopyKey("approve.allowOnce"))) }
                    .buttonStyle(PrimaryButtonStyle())
                    .accessibilityIdentifier("approveAllowOnce")
                    .probeID("approveAllowOnce")
                if PermissionGate.offersAlwaysAllow(tool: request.tool, untrusted: request.untrusted) {
                    Button { onAnswer(.always) } label: { Text(CopyText(CopyKey("approve.always"))) }
                        .buttonStyle(.bordered)
                        .accessibilityIdentifier("approveAlways")
                        .probeID("approveAlways")
                }
                Button(role: .cancel) { onAnswer(.deny) } label: { Text(CopyText(CopyKey("approve.deny"))) }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("approveDeny")
                    .probeID("approveDeny")
            }
            .controlSize(.regular)
            .padding(.top, Spacing.space1)
        }
        .padding(Spacing.space3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(
            RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
                .strokeBorder(Color.borderControl, lineWidth: Stroke.control))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("approvalCard")
        .probeID("approvalCard")
    }
}

#Preview("ApprovalCard") {
    VStack(spacing: Spacing.space6) {
        ApprovalCardView(request: ToolApprovalRequest(id: "1", tool: "write_note", argumentsJSON: #"{"text":"Buy milk"}"#,
                                                      sideEffect: .write, untrusted: false), onAnswer: { _ in })
        ApprovalCardView(request: ToolApprovalRequest(id: "2", tool: "write_note", argumentsJSON: #"{"text":"Buy milk"}"#,
                                                      sideEffect: .write, untrusted: true), onAnswer: { _ in })
    }
    .padding(Spacing.space7)
    .frame(width: 560)
    .background(Color.surfaceCanvas)
}

extension ApprovalCardView {
    /// M9.T08 (vq-inject capture): the card names the action as people read it, matching its activity line —
    /// `team_chat_send_message` → "Team Chat · Send message", `write_note` → "Write note" — never the raw tool id.
    static func actionName(_ tool: String) -> String {
        guard let d = MCPTools.shared.descriptor(named: tool) else { return ActivityLineView.readableName(tool) }
        return "\(d.serverName) · \(ActivityLineView.readableName(d.toolName))"
    }

    /// One labelled argument line ("Channel" · "general").
    struct Field: Identifiable, Equatable {
        let label: String
        let value: String
        var id: String { label }
    }

    /// VQ-M10 S-24: the call's top-level arguments as people read them, in the order the model wrote them: the key in
    /// sentence case (`channel_id` / `channelId` → "Channel id"), a scalar or a list of scalars as its value. Nested
    /// objects and empty values stay in Details only; at most `limit` lines. Not a JSON object → no lines.
    static func fields(_ json: String, limit: Int = 6) -> [Field] {
        guard let data = json.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return [] }
        func at(_ key: String) -> String.Index { json.range(of: "\"\(key)\"")?.lowerBound ?? json.endIndex }
        let order = object.keys.sorted { a, b in at(a) == at(b) ? a < b : at(a) < at(b) }
        var out: [Field] = []
        for key in order {
            guard out.count < limit, let value = scalarText(object[key]), !value.isEmpty else { continue }
            out.append(Field(label: label(key), value: value))
        }
        return out
    }

    static func label(_ key: String) -> String {
        var words = ""
        for (i, ch) in key.enumerated() {
            if ch == "_" || ch == "-" { words.append(" "); continue }
            if ch.isUppercase, i > 0, words.last != " " { words.append(" ") }
            words.append(contentsOf: ch.lowercased())
        }
        let trimmed = words.trimmingCharacters(in: .whitespaces)
        return trimmed.prefix(1).uppercased() + trimmed.dropFirst()
    }

    private static func scalarText(_ value: Any?) -> String? {
        switch value {
        case let s as String: return s.trimmingCharacters(in: .whitespacesAndNewlines)
        case let n as NSNumber:
            return CFGetTypeID(n) == CFBooleanGetTypeID() ? (n.boolValue ? "true" : "false") : n.stringValue
        case let list as [Any]:
            let items = list.compactMap { scalarText($0) }
            return items.count == list.count ? items.joined(separator: ", ") : nil
        default: return nil
        }
    }

    /// The raw arguments, indented (falls back to the text as given).
    static func prettyJSON(_ json: String) -> String {
        guard let data = json.data(using: .utf8), let object = try? JSONSerialization.jsonObject(with: data),
              let pretty = try? JSONSerialization.data(withJSONObject: object,
                                                        options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]),
              let text = String(data: pretty, encoding: .utf8) else { return json }
        return text
    }
}
