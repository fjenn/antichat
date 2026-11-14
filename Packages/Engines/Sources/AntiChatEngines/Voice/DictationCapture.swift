// M3.T03 step 3 (R-050): where dictation audio comes from. Until M3.T09 lands the shared VPIO engine, `MicCapture`
// is a plain `AVAudioEngine.inputNode` tap at the hardware format, converted to 16 kHz mono Float32 with
// `VoiceAudioConverter` (dictation needs no echo cancellation; capture stays in the helper, AT-M0-05). Tests and
// ATs use `ScriptedVoice` instead (fixture WAVs at real-time pace; environment §5).
@preconcurrency import AVFoundation
import AudioToolbox
import CoreAudio
import Foundation
import Synchronization

public protocol AudioCaptureSource: AnyObject, Sendable {
    /// Starts delivering 16 kHz mono samples (any chunk size, capture order) on a background thread.
    func start(_ onSamples: @escaping @Sendable ([Float]) -> Void) throws
    func stop()
}

public final class MicCapture: AudioCaptureSource, @unchecked Sendable {
    private let engine = AVAudioEngine()
    private let running = Mutex(false)
    private let deviceUID: String?

    /// `deviceUID` = Settings › Voice › Microphone (M3.T08, R-053); nil or a device that is gone = the system default.
    public init(deviceUID: String? = nil) { self.deviceUID = deviceUID }

    public func start(_ onSamples: @escaping @Sendable ([Float]) -> Void) throws {
        let input = engine.inputNode
        if let deviceUID, var dev = Self.deviceID(uid: deviceUID), let unit = input.audioUnit {
            AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &dev,
                                 UInt32(MemoryLayout<AudioDeviceID>.size))
        }
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw NSError(domain: "AntiChat.voice", code: 1, userInfo: [NSLocalizedDescriptionKey: "no input device"])
        }
        let mono = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: format.sampleRate, channels: 1, interleaved: false)!
        let converter = VoiceAudioConverter(source: mono)
        input.installTap(onBus: 0, bufferSize: AVAudioFrameCount(format.sampleRate / 50), format: format) { buffer, _ in
            let b = format.channelCount == 1 ? buffer : VoiceAudioConverter.downmix(buffer)
            if let s = try? converter.convert(b), !s.isEmpty { onSamples(s) }
        }
        engine.prepare()
        do { try engine.start() } catch {
            input.removeTap(onBus: 0)  // M3 review P2-2: a failed start leaves no tap behind
            throw error
        }
        running.withLock { $0 = true }
    }

    public func stop() {
        guard running.withLock({ r in defer { r = false }; return r }) else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }

    /// CoreAudio device id of a device UID (`kAudioHardwarePropertyTranslateUIDToDevice`); nil when it is gone.
    static func deviceID(uid: String) -> AudioDeviceID? {
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

/// RMS level meter: one dBFS value per 1/30 s of audio (the DictationBar waveform, 30 Hz).
public struct LevelMeter: Sendable {
    public static let samplesPerTick = 16_000 / 30
    private var sum: Double = 0
    private var n = 0

    public init() {}

    public mutating func feed(_ samples: [Float]) -> [Float] {
        var out: [Float] = []
        for s in samples {
            sum += Double(s) * Double(s)
            n += 1
            if n == Self.samplesPerTick {
                let ms = sum / Double(n)
                out.append(ms > 0 ? Float(max(-100, 10 * log10(ms))) : -100)
                sum = 0
                n = 0
            }
        }
        return out
    }
}
