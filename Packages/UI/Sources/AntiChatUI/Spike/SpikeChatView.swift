// SpikeChatView (M0.T04 step 6; shown with `-SpikeUI YES`). Spike only: a text field, Send/Stop, a
// transcript and a status line. On XPC invalidation it shows the `engine.restarted` copy
// ("The AI engine restarted." + [Retry]) and reconnects. Real chat UI = M1 (G-001/G-002).
import AntiChatEngineProtocol
import AntiChatHarness
import Observation
import SwiftUI

@MainActor @Observable
public final class SpikeChatModel {
    public struct Turn: Identifiable {
        public let id = UUID()
        public var role: String
        public var text: String
    }

    public var turns: [Turn] = []
    public var input = ""
    public var status = "Not connected"
    public var streaming = false
    public var showRestarted = false
    public var lastAckPID: Int32 = 0
    private var lastPrompt = ""
    private var currentID: UUID?
    private var streamTask: Task<Void, Never>?
    let client = EngineClient()
    let slot: ModelSlot

    public init(slot: ModelSlot) {
        self.slot = slot
        client.onInvalidated = { [weak self] in
            Task { @MainActor in self?.engineDied() }
        }
    }

    public func connect() async {
        do {
            let ack = try await client.connect()
            lastAckPID = ack.helperPID
            status = "Engine ready (pid \(ack.helperPID))"
            Self.log("helloAck pid=\(ack.helperPID)")
        } catch {
            status = "Engine unavailable"
        }
    }

    func engineDied() {
        Self.log("invalidated")
        showRestarted = true
        streaming = false
        status = "Reconnecting…"
        Task {
            // launchd restarts the helper on the first message of the new session (NFR-S4).
            for _ in 0..<50 {
                do {
                    let ack = try await client.connect(timeout: .seconds(2))
                    lastAckPID = ack.helperPID
                    status = "Engine ready (pid \(ack.helperPID))"
                    Self.log("helloAck pid=\(ack.helperPID) after-restart")
                    return
                } catch {
                    try? await Task.sleep(for: .milliseconds(100))
                }
            }
            status = "Engine unavailable"
        }
    }

    public func send() {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        input = ""
        start(prompt: text)
    }

    public func retry() {
        showRestarted = false
        if !lastPrompt.isEmpty { start(prompt: lastPrompt) }
    }

    func start(prompt: String) {
        lastPrompt = prompt
        turns.append(Turn(role: "user", text: prompt))
        turns.append(Turn(role: "assistant", text: ""))
        let idx = turns.count - 1
        let req = ChatRequest(
            modelSlot: slot, messages: [ChatMessage(role: .user, content: prompt)],
            sampling: Sampling(temperature: 0.7, topP: 0.95, maxTokens: 1024))
        currentID = req.requestID
        streaming = true
        let stream = client.chatBatches(req)
        streamTask = Task {
            for await batch in stream {
                for item in batch.items {
                    switch item {
                    case .engine(.textDelta(let s)): turns[idx].text += s
                    case .lifecycle(.loadState(let st)): status = "Model \(st.rawValue)"
                    case .engine(.error(let err)):
                        if err.is(.engineRestarted) { showRestarted = true } else { status = "Error: \(err.fullCode)" }
                    case .engine(.done): streaming = false
                    default: break
                    }
                }
            }
            streaming = false
        }
    }

    public func stop() {
        if let id = currentID { client.cancel(id) }
    }

    static func log(_ s: String) {
        // Timestamped lines for the restart measurement (tools/m0/at-m0-04.sh reads them).
        let line = "\(Date().timeIntervalSince1970) \(s)\n"
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("antichat-spikeui.log")
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile()
            h.write(Data(line.utf8))
            try? h.close()
        } else {
            try? Data(line.utf8).write(to: url)
        }
    }
}

public struct SpikeChatView: View {
    @State var model: SpikeChatModel
    @FocusState private var focused: Bool

    public init(model: SpikeChatModel) { _model = State(initialValue: model) }

    public var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(model.turns) { t in
                        Text(t.text.isEmpty && t.role == "assistant" ? "…" : t.text)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: t.role == "user" ? .trailing : .leading)
                            .padding(8)
                            .background(t.role == "user" ? Color.secondary.opacity(0.15) : .clear, in: .rect(cornerRadius: 8))
                    }
                    if model.showRestarted {
                        HStack {
                            // copy key engine.restarted
                            Text("The AI engine restarted.")
                            Button("Retry") { model.retry() }
                                .accessibilityIdentifier("spike.retry")
                        }
                        .accessibilityElement(children: .contain)  // own ids for the children (Q-015)
                        .accessibilityIdentifier("spike.restarted")
                    }
                }
                .padding()
            }
            .accessibilityIdentifier("spike.transcript")
            Divider()
            HStack {
                TextField("Message", text: $model.input)
                    .textFieldStyle(.roundedBorder)
                    .focused($focused)
                    .onSubmit { model.send() }
                    .accessibilityIdentifier("spike.input")
                if model.streaming {
                    Button("Stop") { model.stop() }.accessibilityIdentifier("spike.stop")
                } else {
                    Button("Send") { model.send() }.accessibilityIdentifier("spike.send")
                }
            }
            .padding()
            Text(model.status)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding([.horizontal, .bottom])
                .accessibilityIdentifier("spike.status")
        }
        .task {
            focused = true
            #if DEBUG
            Self.installKillHook(model)
            #endif
            await model.connect()
        }
    }

    #if DEBUG
    /// Q-015 r5 (SpikeRestartTests, NFR-S4): the sandboxed UI test runner can neither list nor signal other processes
    /// (pkill exits 3; libproc finds no helper), so the test asks the app, which is the helper's client, to SIGKILL the
    /// helper it is connected to (the `HelloAck` pid, as SpikeProbe does). Distributed notification without userInfo
    /// (a sandboxed sender's userInfo is dropped). DEBUG only; never a pid of 0 (that signals the process group).
    @MainActor private static var killObserver: NSObjectProtocol?
    public static let killEngineHook = Notification.Name("app.antichat.test.spikeKillEngine")

    @MainActor private static func installKillHook(_ model: SpikeChatModel) {
        guard killObserver == nil else { return }
        killObserver = DistributedNotificationCenter.default().addObserver(forName: killEngineHook, object: nil, queue: .main) { [weak model] _ in
            MainActor.assumeIsolated {
                guard let pid = model?.lastAckPID, pid > 0 else { return }
                kill(pid_t(pid), SIGKILL)  // the same as `pkill -9 -f AntiChatEngine`, for this app's helper only
            }
        }
    }
    #endif
}
