// M3.T12 step 3 (R-280): the conversation's output route from the default output device — headphones (Bluetooth,
// a headset, the built-in jack's headphone data source) never need echo cancellation; aggregate / virtual /
// HDMI / DisplayPort / AirPlay outputs are devices VPIO cannot cancel; everything else (built-in speakers, USB
// speakers) is `speakers`. `-FakeAudioRoute <route>` (DEBUG, through `VoiceSessionStart.fakeAudio`) overrides it.
import CoreAudio
import Foundation

public enum VoiceAudioRouteProbe {
    public static func current() -> VoiceAudioRoute {
        guard let device = defaultOutputDevice() else { return .speakers }
        return route(transport: transportType(device), dataSource: dataSource(device), name: deviceName(device))
    }

    /// The classification (pure; tests).
    public static func route(transport: UInt32?, dataSource: UInt32?, name: String?) -> VoiceAudioRoute {
        switch transport {
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE:
            return .headphones
        case kAudioDeviceTransportTypeAggregate, kAudioDeviceTransportTypeVirtual, kAudioDeviceTransportTypeHDMI,
             kAudioDeviceTransportTypeDisplayPort, kAudioDeviceTransportTypeAirPlay:
            return .noEchoCancellation
        case kAudioDeviceTransportTypeBuiltIn:
            // 'hdpn': the built-in jack's headphones data source.
            return dataSource == 0x6864_706E ? .headphones : .speakers
        default:
            let n = (name ?? "").lowercased()
            return n.contains("headphone") || n.contains("headset") || n.contains("airpods") ? .headphones : .speakers
        }
    }

    /// The built-in mic's UID when the default input is a Bluetooth device: a headset's mic would switch the headset
    /// to its call profile (narrowband playback) for the whole conversation. nil = keep the default input.
    public static func builtInMicUIDIfBluetoothInput() -> String? {
        guard let input = defaultDevice(kAudioHardwarePropertyDefaultInputDevice) else { return nil }
        return preferredInputUID(defaultInputTransport: transportType(input), builtInInputUID: builtInInputUID())
    }

    /// The choice (pure; tests).
    public static func preferredInputUID(defaultInputTransport: UInt32?, builtInInputUID: String?) -> String? {
        switch defaultInputTransport {
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: builtInInputUID
        default: nil
        }
    }

    private static func builtInInputUID() -> String? {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(0)
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr else { return nil }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids) == noErr else { return nil }
        for id in ids where transportType(id) == kAudioDeviceTransportTypeBuiltIn {
            var streams = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams, mScope: kAudioDevicePropertyScopeInput,
                                                     mElement: kAudioObjectPropertyElementMain)
            var bytes = UInt32(0)
            guard AudioObjectGetPropertyDataSize(id, &streams, 0, nil, &bytes) == noErr, bytes > 0 else { continue }
            var uid: Unmanaged<CFString>?
            var uidSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            var uidAddr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceUID, mScope: kAudioObjectPropertyScopeGlobal,
                                                     mElement: kAudioObjectPropertyElementMain)
            if AudioObjectGetPropertyData(id, &uidAddr, 0, nil, &uidSize, &uid) == noErr, let uid { return uid.takeRetainedValue() as String }
        }
        return nil
    }

    private static func defaultOutputDevice() -> AudioDeviceID? { defaultDevice(kAudioHardwarePropertyDefaultOutputDevice) }

    private static func defaultDevice(_ selector: AudioObjectPropertySelector) -> AudioDeviceID? {
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var addr = AudioObjectPropertyAddress(mSelector: selector,
                                              mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id)
        return status == noErr && id != 0 ? id : nil
    }

    private static func uint32(_ device: AudioDeviceID, _ selector: AudioObjectPropertySelector,
                               scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> UInt32? {
        var value = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        var addr = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectHasProperty(device, &addr) else { return nil }
        return AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &value) == noErr ? value : nil
    }

    private static func transportType(_ device: AudioDeviceID) -> UInt32? { uint32(device, kAudioDevicePropertyTransportType) }

    private static func dataSource(_ device: AudioDeviceID) -> UInt32? {
        uint32(device, kAudioDevicePropertyDataSource, scope: kAudioDevicePropertyScopeOutput)
    }

    private static func deviceName(_ device: AudioDeviceID) -> String? {
        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var addr = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName, mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &name) == noErr, let name else { return nil }
        return name.takeRetainedValue() as String
    }
}
