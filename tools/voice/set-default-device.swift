// M3.T12 (AT-280 AC1/AC3): print or set the default input / output device (CoreAudio).
//   swift tools/voice/set-default-device.swift list
//   swift tools/voice/set-default-device.swift get input|output
//   swift tools/voice/set-default-device.swift set input|output <device name or UID>
//   swift tools/voice/set-default-device.swift builtin      # built-in mic + speakers; exit 2 if headphones are on
import CoreAudio
import Foundation

func prop<T>(_ id: AudioObjectID, _ sel: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal, into v: inout T) -> Bool {
    var a = AudioObjectPropertyAddress(mSelector: sel, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    var size = UInt32(MemoryLayout<T>.size)
    return AudioObjectGetPropertyData(id, &a, 0, nil, &size, &v) == noErr
}
func string(_ id: AudioObjectID, _ sel: AudioObjectPropertySelector) -> String {
    var s: Unmanaged<CFString>?
    var a = AudioObjectPropertyAddress(mSelector: sel, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    guard AudioObjectGetPropertyData(id, &a, 0, nil, &size, &s) == noErr, let s else { return "" }
    return s.takeRetainedValue() as String
}
func devices() -> [AudioObjectID] {
    var a = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size)
    var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
    AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size, &ids)
    return ids
}
func channels(_ id: AudioObjectID, _ scope: AudioObjectPropertyScope) -> Int {
    var a = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(id, &a, 0, nil, &size) == noErr, size > 0 else { return 0 }
    let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: 16)
    defer { raw.deallocate() }
    guard AudioObjectGetPropertyData(id, &a, 0, nil, &size, raw) == noErr else { return 0 }
    let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
    return list.reduce(0) { $0 + Int($1.mNumberChannels) }
}
func transport(_ id: AudioObjectID) -> UInt32 { var t: UInt32 = 0; _ = prop(id, kAudioDevicePropertyTransportType, into: &t); return t }
func dataSource(_ id: AudioObjectID) -> UInt32 { var d: UInt32 = 0; _ = prop(id, kAudioDevicePropertyDataSource, scope: kAudioDevicePropertyScopeOutput, into: &d); return d }
func selector(_ which: String) -> AudioObjectPropertySelector {
    which == "input" ? kAudioHardwarePropertyDefaultInputDevice : kAudioHardwarePropertyDefaultOutputDevice
}
func current(_ which: String) -> AudioObjectID {
    var id = AudioObjectID(0); _ = prop(AudioObjectID(kAudioObjectSystemObject), selector(which), into: &id); return id
}
func set(_ which: String, _ id: AudioObjectID) -> Bool {
    var v = id
    var a = AudioObjectPropertyAddress(mSelector: selector(which), mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    return AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, UInt32(MemoryLayout<AudioObjectID>.size), &v) == noErr
}
let args = CommandLine.arguments.dropFirst()
switch args.first {
case "list":
    for d in devices() {
        print("\(string(d, kAudioDevicePropertyDeviceUID))\t\(string(d, kAudioObjectPropertyName))\tin=\(channels(d, kAudioDevicePropertyScopeInput))\tout=\(channels(d, kAudioDevicePropertyScopeOutput))\ttransport=\(String(format: "%08x", transport(d)))")
    }
case "get":
    let d = current(args.dropFirst().first ?? "output")
    print("\(string(d, kAudioDevicePropertyDeviceUID))\t\(string(d, kAudioObjectPropertyName))")
case "set":
    let which = Array(args)[1], want = Array(args)[2]
    guard let d = devices().first(where: { string($0, kAudioDevicePropertyDeviceUID) == want || string($0, kAudioObjectPropertyName) == want }),
          set(which, d) else { FileHandle.standardError.write("no such device: \(want)\n".data(using: .utf8)!); exit(1) }
    print("default \(which) = \(string(d, kAudioObjectPropertyName))")
case "builtin":
    let builtIn = devices().filter { transport($0) == kAudioDeviceTransportTypeBuiltIn }
    guard let mic = builtIn.first(where: { channels($0, kAudioDevicePropertyScopeInput) > 0 }),
          let spk = builtIn.first(where: { channels($0, kAudioDevicePropertyScopeOutput) > 0 }) else {
        print("no built-in microphone / speakers"); exit(1)
    }
    if dataSource(spk) == 0x6864_706E { print("headphones are plugged into the built-in jack: not run"); exit(2) }
    guard set("input", mic), set("output", spk) else { print("could not set the default devices"); exit(1) }
    print("default input = \(string(mic, kAudioObjectPropertyName)); default output = \(string(spk, kAudioObjectPropertyName))")
default:
    print("usage: set-default-device.swift list | get input|output | set input|output <name|uid> | builtin"); exit(64)
}
