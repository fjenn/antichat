// M3.T08 step 1 (R-053 AC1; P-media-04, ported from Osaurus `Managers/SpeechService.swift:189-320` CoreAudio discovery):
// the input devices for Settings › Voice › Microphone. `kAudioHardwarePropertyDevices` filtered to devices with input
// streams, plus the default input device; listeners on both properties republish on hot-plug / default change.
// The provider is injected (tests: 0 / 1 / 3 devices, hot-plug; `-FakeAudioDevices none|a,b` in DEBUG runs).
import AntiChatFoundation
import CoreAudio
import Foundation
import Observation

public struct AudioInputDevice: Sendable, Hashable, Identifiable {
    public var uid: String
    public var name: String
    public var id: String { uid }
    public init(uid: String, name: String) {
        self.uid = uid
        self.name = name
    }
}

/// Where the device list comes from (CoreAudio, or a test double).
public protocol AudioDeviceProvider: AnyObject, Sendable {
    func inputDevices() -> [AudioInputDevice]
    func defaultInputUID() -> String?
    /// Calls `onChange` (any thread) whenever the device list or the default input changes; returns a cancel.
    func observe(_ onChange: @escaping @Sendable () -> Void) -> @Sendable () -> Void
}

@MainActor @Observable
public final class AudioDeviceCatalog {
    public private(set) var devices: [AudioInputDevice] = []
    public private(set) var defaultUID: String?
    private let provider: any AudioDeviceProvider
    @ObservationIgnored nonisolated(unsafe) private var cancel: (@Sendable () -> Void)?

    public init(provider: any AudioDeviceProvider) {
        self.provider = provider
        refresh()
        cancel = provider.observe { [weak self] in
            Task { @MainActor in self?.refresh() }
        }
    }

    /// The real CoreAudio catalog, or the `-FakeAudioDevices` list in DEBUG.
    public static func live() -> AudioDeviceCatalog {
        #if DEBUG || ANTICHAT_PERF_HARNESS
        if let names = LaunchOptions.current.fakeAudioDevices {
            return AudioDeviceCatalog(provider: StaticAudioDeviceProvider(names.map { AudioInputDevice(uid: "fake.\($0)", name: $0) }))
        }
        #endif
        return AudioDeviceCatalog(provider: CoreAudioDeviceProvider())
    }

    deinit { cancel?() }

    public func refresh() {
        devices = provider.inputDevices()
        defaultUID = provider.defaultInputUID()
    }

    /// The UID dictation should capture from for a stored setting ("" = system default → nil): a device that is gone
    /// falls back to the system default.
    public func resolvedUID(_ stored: String) -> String? {
        guard !stored.isEmpty, devices.contains(where: { $0.uid == stored }) else { return nil }
        return stored
    }
}

/// A fixed list (tests, `-FakeAudioDevices`); `set` simulates a hot-plug.
public final class StaticAudioDeviceProvider: AudioDeviceProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var list: [AudioInputDevice]
    private var handlers: [UUID: @Sendable () -> Void] = [:]

    public init(_ devices: [AudioInputDevice]) { list = devices }

    public func inputDevices() -> [AudioInputDevice] { lock.withLock { list } }
    public func defaultInputUID() -> String? { lock.withLock { list.first?.uid } }

    public func set(_ devices: [AudioInputDevice]) {
        let hs = lock.withLock { list = devices; return Array(handlers.values) }
        hs.forEach { $0() }
    }

    public func observe(_ onChange: @escaping @Sendable () -> Void) -> @Sendable () -> Void {
        let id = UUID()
        lock.withLock { handlers[id] = onChange }
        return { [weak self] in self?.lock.withLock { _ = self?.handlers.removeValue(forKey: id) } }
    }
}

/// CoreAudio: every device with ≥ 1 input stream; listeners on the device list and the default input.
public final class CoreAudioDeviceProvider: AudioDeviceProvider, @unchecked Sendable {
    public init() {}

    private static func address(_ selector: AudioObjectPropertySelector,
                                scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    public func inputDevices() -> [AudioInputDevice] {
        var addr = Self.address(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.compactMap { id in
            guard Self.hasInput(id), let uid = Self.string(id, kAudioDevicePropertyDeviceUID),
                  let name = Self.string(id, kAudioObjectPropertyName) else { return nil }
            return AudioInputDevice(uid: uid, name: name)
        }
    }

    public func defaultInputUID() -> String? {
        var addr = Self.address(kAudioHardwarePropertyDefaultInputDevice)
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id) == noErr, id != 0
        else { return nil }
        return Self.string(id, kAudioDevicePropertyDeviceUID)
    }

    public func observe(_ onChange: @escaping @Sendable () -> Void) -> @Sendable () -> Void {
        let queue = DispatchQueue(label: "AntiChat.AudioDeviceCatalog")
        let block: @Sendable (UInt32, UnsafePointer<AudioObjectPropertyAddress>) -> Void = { _, _ in onChange() }
        let selectors = [kAudioHardwarePropertyDevices, kAudioHardwarePropertyDefaultInputDevice]
        for s in selectors {
            var addr = Self.address(s)
            AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, queue, block)
        }
        return {
            for s in selectors {
                var addr = Self.address(s)
                AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, queue, block)
            }
        }
    }

    private static func hasInput(_ id: AudioDeviceID) -> Bool {
        var addr = address(kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeInput)
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr && size > 0
    }

    private static func string(_ id: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> String? {
        var addr = address(selector)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value) == noErr, let v = value else { return nil }
        return v.takeRetainedValue() as String
    }
}
