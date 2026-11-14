// M3.T08 step 8 / AT-053 AC1 (unit leg): AudioDeviceCatalog with an injected provider — 0, 1 and 3 input devices,
// hot-plug republishes, a stored device that is gone resolves to the system default; the CoreAudio provider lists
// only devices with input streams (smoke: it never throws, names are non-empty).
//   make test-unit FILTER=AudioDeviceCatalogTests
import Foundation
import Testing
@testable import AntiChatPlatform

@MainActor
struct AudioDeviceCatalogTests {
    static func devices(_ n: Int) -> [AudioInputDevice] { (0 ..< n).map { AudioInputDevice(uid: "uid-\($0)", name: "Mic \($0)") } }

    @Test(arguments: [0, 1, 3])
    func listsTheProvidersDevices(_ n: Int) {
        let c = AudioDeviceCatalog(provider: StaticAudioDeviceProvider(Self.devices(n)))
        #expect(c.devices.count == n)
        #expect(c.defaultUID == (n == 0 ? nil : "uid-0"))
    }

    @Test func hotPlugRepublishes() async {
        let p = StaticAudioDeviceProvider(Self.devices(1))
        let c = AudioDeviceCatalog(provider: p)
        p.set(Self.devices(3))
        for _ in 0 ..< 100 where c.devices.count != 3 { await Task.yield() }
        #expect(c.devices.map(\.uid) == ["uid-0", "uid-1", "uid-2"])
        p.set([])
        for _ in 0 ..< 100 where !c.devices.isEmpty { await Task.yield() }
        #expect(c.devices.isEmpty)
    }

    @Test func goneDeviceFallsBackToSystemDefault() {
        let c = AudioDeviceCatalog(provider: StaticAudioDeviceProvider(Self.devices(2)))
        #expect(c.resolvedUID("") == nil)
        #expect(c.resolvedUID("uid-1") == "uid-1")
        #expect(c.resolvedUID("unplugged") == nil)
    }

    @Test func coreAudioListsInputDevicesOnly() {
        let p = CoreAudioDeviceProvider()
        let list = p.inputDevices()
        #expect(list.allSatisfy { !$0.uid.isEmpty && !$0.name.isEmpty })
        #expect(Set(list.map(\.uid)).count == list.count)
        let cancel = p.observe {}
        cancel()
    }
}
