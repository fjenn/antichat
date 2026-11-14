// Settings → Voice (M3.T08, R-053, settings-map §5; P-media-04: rows after Osaurus `Views/Voice/TTSModeSettingsTab.swift`
// / `VoiceSetupTab.swift`, ported): Microphone (System default + the CoreAudio input devices, a live level meter while
// the section is visible), Spoken language (Auto-detect + Parakeet's 25 ∪ WhisperKit's languages), Voice (≥ 6 voices
// with [Preview]), Speed (0.75×–1.5×, step 0.05), Conversation mode (Hands-free / Push-to-talk), then Recent
// recordings (M3.T03). Every change is written at once (Defaults) and read at the next utterance (VoicePreferences).
import AntiChatDesign
import AntiChatEngineProtocol
import AntiChatHarness
import AntiChatPlatform
import AntiChatStorage
import Defaults
import SwiftUI

struct VoiceSection: View {
    /// nil = no app database (previews, snapshot hosts): the list is empty.
    nonisolated(unsafe) static var database: AppDatabase?

    @Default(.voiceInputDevice) private var inputDevice
    @Default(.voiceSpokenLanguage) private var spokenLanguage
    @Default(.voiceID) private var voiceID
    @Default(.voiceRate) private var rate
    @Default(.voiceMode) private var mode
    @Default(.voiceDuckOthers) private var duckOthers
    @State private var devices: AudioDeviceCatalog
    @State private var meter: InputLevelMeter
    private let voices: [VoiceChoice]
    private let readAloud: ReadAloudController
    private let dictationActive: @MainActor () -> Bool

    @MainActor
    init(devices: AudioDeviceCatalog? = nil, meter: InputLevelMeter? = nil, voices: [VoiceChoice]? = nil,
         readAloud: ReadAloudController = .shared, dictationActive: (@MainActor () -> Bool)? = nil) {
        let host = Self.host
        _devices = State(initialValue: devices ?? host.devices())
        _meter = State(initialValue: meter ?? InputLevelMeter(permitted: host.meterPermitted))
        self.voices = voices ?? VoiceChoice.available(packReady: VoiceAvailability.shared.packState == .ready,
                                                      spokenLanguage: Defaults[.voiceSpokenLanguage], system: host.systemVoices)
        self.readAloud = readAloud
        self.dictationActive = dictationActive ?? host.micInUse
    }

    /// Where the section's live inputs come from; snapshot / unit tests swap in fixed ones (no CoreAudio, no mic).
    struct Host {
        var devices: @MainActor () -> AudioDeviceCatalog = { .live() }
        var systemVoices: () -> [(id: String, name: String, language: String)] = SystemVoices.list
        /// Never prompts: the system's own grant too, not only the app's view of it (faked in UI tests; Q-015 r4).
        var meterPermitted: @MainActor () -> Bool = {
            PermissionCenter.shared.microphone == .granted && InputLevelMeter.systemGranted()
        }
        /// A dictation or call holds the mic anywhere in the app (M3 review P2-5); snapshot hosts fix it.
        var micInUse: @MainActor () -> Bool = { VoiceCalls.shared.micInUse }
    }

    @MainActor static var host = Host()

    // A dictation or voice session in any window holds the microphone (`VoiceCalls.micInUse`, app-wide; M3 review
    // P2-5): the meter stops and says "In use", and starts again when the mic is free, while the section is shown.

    var body: some View {
        Section {
            microphoneRow
            languageRow
        }
        Section {
            voiceRow
            speedRow
            modeRow
            duckingRow
        }
        RecentRecordingsView(model: RecentRecordingsModel(store: Self.database.map(RecordingStore.standard)))
            .onAppear { meter.start(deviceUID: devices.resolvedUID(inputDevice), allowed: !dictationActive()) }
            .onDisappear { meter.stop() }
            .onChange(of: inputDevice) { _, uid in meter.start(deviceUID: devices.resolvedUID(uid), allowed: !dictationActive()) }
            .onChange(of: dictationActive()) { _, busy in
                if busy { meter.stop() } else { meter.start(deviceUID: devices.resolvedUID(inputDevice), allowed: true) }
            }
    }

    // MARK: Rows

    private var microphoneRow: some View {
        SettingsItem("voiceInputDevice") {
            HStack(spacing: Spacing.space3) {
                if devices.devices.isEmpty {
                    Text(CopyKey("set.voice.noDevices"))
                        .foregroundStyle(Color.textSecondary)
                        .probeID("settings.voice.noDevices")
                } else {
                    LevelMeterView(level: meter.level, enabled: meter.isRunning)
                        .accessibilityLabel(Text(CopyKey("set.voice.level")))
                        .probeID("settings.voice.levelMeter")
                    if !meter.isRunning, dictationActive() {
                        Text(CopyKey("set.voice.inUse")).typeStyle(.caption).foregroundStyle(Color.textSecondary)
                    }
                }
                Picker(selection: $inputDevice) {
                    Text(CopyKey("set.voice.systemDefault")).tag("")
                    ForEach(devices.devices) { d in Text(verbatim: d.name).tag(d.uid) }
                    // A stored device that is unplugged stays selectable (it is used again when it returns).
                    if !inputDevice.isEmpty, !devices.devices.contains(where: { $0.uid == inputDevice }) {
                        Text(verbatim: inputDevice).tag(inputDevice)
                    }
                } label: { Text(CopyKey("set.voice.microphone")) }
                    .pickerStyle(.menu)
                    .fixedSize()
                    .disabled(devices.devices.isEmpty)
                    .accessibilityShowMenu()  // M9.T03: AXShowMenu, as on AppKit pop-up buttons
                    .probeID("settings.control.voiceInputDevice")
            }
        }
    }

    private var languageRow: some View {
        SettingsItem("voiceSpokenLanguage") {
            Picker(selection: $spokenLanguage) {
                Text(CopyKey("set.voice.autoDetect")).tag("auto")
                Divider()
                ForEach(SpokenLanguageChoice.all, id: \.code) { l in Text(verbatim: l.name).tag(l.code) }
            } label: { Text(CopyKey("set.voice.language")) }
                .pickerStyle(.menu)
                .fixedSize()
                .accessibilityShowMenu()  // M9.T03: AXShowMenu, as on AppKit pop-up buttons
                .probeID("settings.control.voiceSpokenLanguage")
        }
    }

    private var voiceRow: some View {
        SettingsItem("voiceID", description: CopyKey("set.voice.voice.note")) {
            HStack(spacing: Spacing.space2) {
                Picker(selection: Binding(get: { VoiceChoice.selected(voiceID, in: voices) }, set: { voiceID = $0 })) {
                    ForEach(voices) { v in Text(verbatim: v.label).tag(v.id) }
                } label: { Text(CopyKey("set.voice.voice")) }
                    .pickerStyle(.menu)
                    .fixedSize()
                    .accessibilityShowMenu()  // M9.T03: AXShowMenu, as on AppKit pop-up buttons
                    .probeID("settings.control.voiceID")
                Button {
                    readAloud.toggle(id: VoiceChoice.previewID, text: CopyKey("set.voice.previewText").string(),
                                     voiceID: VoiceChoice.selected(voiceID, in: voices), rate: rate, purpose: .preview)
                } label: {
                    Label { Text(CopyKey("set.voice.preview")) } icon: {
                        Image(systemName: readAloud.speakingID == VoiceChoice.previewID ? "stop.fill" : "play.fill")
                    }
                }
                .probeID("settings.voice.preview")
            }
        }
    }

    private var speedRow: some View {
        SettingsItem("voiceRate") {
            HStack(spacing: Spacing.space2) {
                Slider(value: $rate, in: 0.75 ... 1.5, step: 0.05) { Text(CopyKey("set.voice.speed")) }
                    .labelsHidden()
                    .frame(width: 160)
                    // Q-015 r3: VoiceOver reads the speed as shown ("1.5×", not the slider's raw 1.5). The visible
                    // value text beside it is hidden from accessibility; the slider carries the value once.
                    .accessibilityValue(Text(CopyText(CopyKey("set.voice.speedValue"), ["rate": VoiceChoice.rateLabel(rate)])))
                    .probeID("settings.control.voiceRate")
                Text(CopyText(CopyKey("set.voice.speedValue"), ["rate": VoiceChoice.rateLabel(rate)]))
                    .monospacedDigit()
                    .frame(minWidth: 44, alignment: .trailing)
                    .accessibilityHidden(true)
                    .probeID("settings.value.voiceRate")
            }
        }
    }

    private var modeRow: some View {
        SettingsItem("voiceMode") {
            Picker(selection: $mode) {
                Text(CopyKey("set.voice.handsFree")).tag("handsFree")
                Text(CopyKey("set.voice.pushToTalk")).tag("pushToTalk")
            } label: { Text(CopyKey("set.voice.mode")) }
                .pickerStyle(.menu)
                .fixedSize()
                .accessibilityShowMenu()  // M9.T03: AXShowMenu, as on AppKit pop-up buttons
                .probeID("settings.control.voiceMode")
        }
    }

    /// M3.T12 (R-280 AC3): other apps' audio during a conversation (read at each conversation start).
    private var duckingRow: some View {
        SettingsItem("voiceDuckOthers") {
            Toggle(isOn: $duckOthers) { Text(CopyKey("set.voice.ducking")) }
                .toggleStyle(.accessibleSwitch)
                .probeID("settings.control.voiceDuckOthers")
        }
    }
}

/// One entry of the Voice picker.
struct VoiceChoice: Identifiable, Hashable {
    var id: String
    var label: String
    var language: String

    static let previewID = "settings.voice.preview"

    /// Kokoro's voices with the verified Voice pack; otherwise the system voices of the spoken language, then English
    /// ones (R-053 needs ≥ 6 in the picker, not per language — the M3.T08 interpretation).
    static func available(packReady: Bool, spokenLanguage: String,
                          system: () -> [(id: String, name: String, language: String)] = SystemVoices.list) -> [VoiceChoice] {
        if packReady {
            return KokoroVoices.english.map { VoiceChoice(id: $0.id, label: "\($0.name) (\($0.language))", language: $0.language) }
        }
        let lang = spokenLanguage == "auto" || spokenLanguage.isEmpty
            ? (Locale.current.language.languageCode?.identifier ?? "en") : spokenLanguage
        let all = system()
        let own = all.filter { $0.language.hasPrefix(lang) }
        let english = lang == "en" ? [] : all.filter { $0.language.hasPrefix("en") }
        return (own + english).map { VoiceChoice(id: $0.id, label: "\($0.name) (\($0.language))", language: $0.language) }
    }

    /// The stored id if it is in the list, else the first voice ("first of ≥ 6", settings-map §5).
    static func selected(_ stored: String, in voices: [VoiceChoice]) -> String {
        voices.contains { $0.id == stored } ? stored : (voices.first?.id ?? stored)
    }

    /// "1×", "1.25×" (two decimals at most, no trailing zeros).
    static func rateLabel(_ r: Double) -> String {
        let s = String(format: "%.2f", (r * 20).rounded() / 20)
        var t = s
        while t.hasSuffix("0") { t.removeLast() }
        if t.hasSuffix(".") { t.removeLast() }
        return t
    }
}

/// The Spoken language list in the UI language (R-053 AC1: the list itself is independent of it).
struct SpokenLanguageChoice {
    var code: String
    var name: String

    static var all: [SpokenLanguageChoice] {
        SpokenLanguages.all.map { code in
            let name = Locale.current.localizedString(forLanguageCode: code == "jw" ? "jv" : code) ?? code
            return SpokenLanguageChoice(code: code, name: name.prefix(1).uppercased() + name.dropFirst())
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}
