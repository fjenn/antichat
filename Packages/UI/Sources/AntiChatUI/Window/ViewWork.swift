// NFR-U2 (send ack ≤ 16 ms): which of the window's views a change re-evaluates. The window-level views a send could
// reach (MainWindow, the sidebar, the composer and its parts, the conversation column) note their body evaluations
// here in DEBUG builds; SendAckWindowWorkTests counts them over a send's ack frame. Nothing is recorded in Release.
#if DEBUG
enum ViewWork {
    /// View bodies evaluated since the last reset, by name.
    nonisolated(unsafe) static var evaluated: [String] = []
}
#endif
