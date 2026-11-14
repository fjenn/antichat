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

    private static func defaultOutputDevice() -> AudioDeviceID? {
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
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
