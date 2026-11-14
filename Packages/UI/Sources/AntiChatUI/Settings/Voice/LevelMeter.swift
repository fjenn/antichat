// M3.T08 step 2 (R-053 AC1): the Microphone row's live level meter — RMS of a lightweight input tap on the chosen
// device, only while Settings › Voice is visible, only with the microphone permission granted (it never prompts), and
// never while a dictation / voice session holds the microphone (known failure mode: the row says "In use").
// Plus the system voice list for Basic voice (AVSpeechSynthesisVoice; the helper speaks with the same identifiers).
@preconcurrency import AVFoundation
import AntiChatDesign
import AntiChatPlatform
import AudioToolbox
import CoreAudio
import Observation
import SwiftUI

/// The meter's AVAudioEngine. Not Sendable itself: it is only ever touched on `InputLevelMeter.queue`; the main actor
/// just holds the box.
final class LevelMeterEngine: @unchecked Sendable {
    let engine = AVAudioEngine()
}

@MainActor @Observable
final class InputLevelMeter {
    /// 0…1 (−60 dBFS … 0 dBFS).
    private(set) var level: Double = 0
    private(set) var isRunning = false
    @ObservationIgnored private var engine: LevelMeterEngine?
    /// Bumped by every start / stop: an engine that comes up after a newer call is torn down, and a level from an old
    /// tap is dropped.
    @ObservationIgnored private var generation = 0
    private let permitted: @MainActor () -> Bool

    /// Q-015 r4: the engine is built and started on this queue, never on the main thread. `AVAudioEngine.inputNode`
    /// binds the HAL device synchronously and waits on coreaudiod; a slow or consent-pending HAL froze the whole app
    /// for over a minute when Settings › Voice opened (spindump: VoiceSection.onAppear → InputLevelMeter.start →
    /// `-[AVAudioEngine inputNode]` → `_dispatch_sync_f_slow`; DictationTests.testRecentRecordingsList "main thread busy").
    nonisolated private static let queue = DispatchQueue(label: "app.antichat.settings.levelMeter", qos: .userInitiated)

    /// The meter never prompts (R-053): besides the app's view of the permission (faked in UI tests), the system must
    /// really have granted the microphone, or touching the input node asks for it.
    nonisolated static func systemGranted() -> Bool { AVCaptureDevice.authorizationStatus(for: .audio) == .authorized }

    init(permitted: @escaping @MainActor () -> Bool = {
        PermissionCenter.shared.microphone == .granted && InputLevelMeter.systemGranted()
    }) {
        self.permitted = permitted
    }

    func start(deviceUID: String?, allowed: Bool) {
        stop()
        guard allowed, permitted() else { return }
        let gen = generation
        let deliver: @MainActor @Sendable (Double) -> Void = { [weak self] v in
            guard let self, self.generation == gen else { return }
            self.level = v
        }
        Self.queue.async {
            let box = Self.startEngine(deviceUID: deviceUID, tap: Self.tapBlock(deliver))
            Task { @MainActor [weak self] in
                guard let box else { return }
                guard let self, self.generation == gen else {
                    Self.queue.async { Self.teardown(box) }
                    return
                }
                self.engine = box
                self.isRunning = true
            }
        }
    }

    /// On `queue`: the input node bound to `deviceUID`, its level tap installed, the engine started (nil: no input).
    nonisolated private static func startEngine(deviceUID: String?, tap: @escaping AVAudioNodeTapBlock) -> LevelMeterEngine? {
        let box = LevelMeterEngine()
        let input = box.engine.inputNode
        if let deviceUID, var id = deviceID(deviceUID), let unit = input.audioUnit {
            AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &id,
                                 UInt32(MemoryLayout<AudioDeviceID>.size))
        }
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { return nil }
        input.installTap(onBus: 0, bufferSize: AVAudioFrameCount(format.sampleRate / 20), format: format, block: tap)
        do {
            try box.engine.start()
            return box
        } catch {
            input.removeTap(onBus: 0)
            return nil
        }
    }

    nonisolated private static func teardown(_ box: LevelMeterEngine) {
        box.engine.inputNode.removeTap(onBus: 0)
        box.engine.stop()
    }

    /// The level tap, built outside the main actor; `deliver` is hopped to the main actor. The tap runs on the audio
    /// render thread: its block must not inherit this class's main-actor isolation (Swift 6 asserts the executor on
    /// entry and traps; found by the M9 accessibility probe opening Settings › Voice).
    nonisolated static func tapBlock(_ deliver: @escaping @MainActor @Sendable (Double) -> Void) -> AVAudioNodeTapBlock {
        { buffer, _ in
            guard let ch = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return }
            var sum: Float = 0
            for i in 0 ..< Int(buffer.frameLength) { sum += ch[i] * ch[i] }
            let db = 10 * log10(max(1e-10, Double(sum / Float(buffer.frameLength))))
            let v = min(1, max(0, (db + 60) / 60))
            Task { @MainActor in deliver(v) }
        }
    }

    func stop() {
        generation += 1
        guard let box = engine else { return }
        engine = nil
        isRunning = false
        level = 0
        Self.queue.async { Self.teardown(box) }
    }

    nonisolated private static func deviceID(_ uid: String) -> AudioDeviceID? {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslateUIDToDevice,
                                              mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var cf = uid as CFString
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = withUnsafeMutablePointer(to: &cf) { p in
            AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, UInt32(MemoryLayout<CFString>.size), p, &size, &id)
        }
        return status == noErr && id != kAudioObjectUnknown ? id : nil
    }
}

/// Twelve segments, filled to `level`; dimmed when the meter is not running.
struct LevelMeterView: View {
    var level: Double
    var enabled: Bool
    private let segments = 12

    var body: some View {
        HStack(spacing: 2) {
            ForEach(0 ..< segments, id: \.self) { i in
                RoundedRectangle(cornerRadius: 1)
                    .fill(enabled && Double(i) < level * Double(segments) ? Color.accentColor : Color.textSecondary.opacity(0.25))
                    .frame(width: 4, height: 12)
            }
        }
        // M9.T03: a level indicator, not an unnamed "Unknown role" group of bars (the audit on Settings › Voice). The
        // caller's label (`set.voice.level`) names it; the value is the level in percent. A ProgressView, not a Gauge:
        // SwiftUI gives a Gauge representation no role either (AXUnknown); a ProgressView is an AXProgressIndicator.
        .accessibilityRepresentation {
            ProgressView(value: enabled ? min(max(level, 0), 1) : 0) { Text(CopyKey("set.voice.level")) }
                .accessibilityValue(Text(verbatim: "\(Int((enabled ? level : 0) * 100))%"))
        }
    }
}

enum SystemVoices {
    /// Every installed system voice (identifier, name, BCP-47 language), best quality first.
    static func list() -> [(id: String, name: String, language: String)] {
        AVSpeechSynthesisVoice.speechVoices()
            .sorted { ($0.quality.rawValue, $1.name) > ($1.quality.rawValue, $0.name) }
            .map { (id: $0.identifier, name: $0.name, language: $0.language) }
    }
}
