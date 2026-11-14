// Standalone repro (Q-015 r5, evidence for `labelsHiddenSwitch` in tools/a11y/audit-ignores.yml): the XCUITest
// accessibility audit reports one "Parent/Child mismatch" with no element for every plain SwiftUI
// `.toggleStyle(.switch).labelsHidden()` Toggle on screen. A labels-hidden switch is exposed as a thin AppKit element
// (no AXFocused / AXCustomActions, an AXPath attribute) instead of SwiftUI's own node; the AX API shows a consistent
// tree (tools/a11y/repros/swiftui-control-actions.swift), so the mismatch is only visible to the audit, which also
// cannot resolve it to an element. Nothing AntiChat-specific is involved: a bare window, Form and Toggles.
//
// Build an app bundle (the audit needs one) and audit it from the UI-test runner:
//   tools/a11y/repros/make-repro-app.sh labels-hidden-switch-parentchild.swift /tmp/SwitchRepro.app app.antichat.repro.switch
//   A11Y_REPRO_APP=/tmp/SwitchRepro.app xcodebuild test-without-building … \
//     -only-testing:AntiChatUITests/AccessibilityAuditTests/testReproLabelsHiddenSwitch
// Arguments (launch arguments): `switches <n>` (labels-hidden switches), `shown <n>` (switches with their labels
// shown), `field 1` (a focused text field), `collapsed <n>` (labels-hidden switches inside a collapsed DisclosureGroup),
// `progress <n>` (linear ProgressViews), `chart 1` (a Swift Charts bar chart). The test audits several combinations and prints the element-less
// parentChild count for each. macOS 26.x result (2026-11-11): switches 0/1/3/5 → 0/1/3/5; shown 3 → 0; field 1 → 1;
// switches 2 + field 1 → 3. A focused SwiftUI TextField adds one element-less issue the same way.
import AppKit
import Charts
import SwiftUI

struct Root: View {
    let hidden: Int
    let shown: Int
    let field: Bool
    let collapsed: Int
    let progress: Int
    let chart: Bool
    @State private var open = false
    @State private var on = Array(repeating: true, count: 32)
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        Form {
            if field { TextField("Search", text: $text).focused($focused).accessibilityIdentifier("repro.field") }
            ForEach(0..<hidden, id: \.self) { i in
                HStack {
                    Text("Hidden \(i)")
                    Spacer()
                    Toggle("Hidden \(i)", isOn: $on[i]).toggleStyle(.switch).labelsHidden().accessibilityIdentifier("repro.hidden.\(i)")
                }
            }
            if collapsed > 0 {
                DisclosureGroup("Advanced", isExpanded: $open) {
                    ForEach(0..<collapsed, id: \.self) { i in
                        Toggle("Collapsed \(i)", isOn: $on[24 + i]).toggleStyle(.switch).labelsHidden()
                    }
                }
            }
            ForEach(0..<progress, id: \.self) { i in
                ProgressView(value: 0.3).progressViewStyle(.linear).frame(width: 120).controlSize(.small)
            }
            if chart {
                Chart { BarMark(x: .value("Size", 3), y: .value("Kind", "Models")); BarMark(x: .value("Size", 1), y: .value("Kind", "Chats")) }
                    .frame(height: 24)
            }
            ForEach(0..<shown, id: \.self) { i in
                Toggle("Shown \(i)", isOn: $on[16 + i]).toggleStyle(.switch).accessibilityIdentifier("repro.shown.\(i)")
            }
        }
        .formStyle(.grouped)
        .onAppear { focused = field }
    }
}

func arg(_ name: String) -> Int {
    let a = CommandLine.arguments
    guard let i = a.firstIndex(of: name), i + 1 < a.count else { return 0 }
    return Int(a[i + 1]) ?? 0
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 420, height: 560), styleMask: [.titled, .closable],
                      backing: .buffered, defer: false)
window.title = "Switch repro"
window.contentView = NSHostingView(rootView: Root(hidden: arg("switches"), shown: arg("shown"), field: arg("field") == 1, collapsed: arg("collapsed"),
                                              progress: arg("progress"), chart: arg("chart") == 1))
window.makeKeyAndOrderFront(nil)
app.activate()
app.run()
