// Settings → Voice → Recent recordings (M3.T03 step 7; R-050 AC4, settings-map §5): the newest 20 dictations
// (RecordingStore), each with its transcript, date and length; ▶ plays it (AVAudioPlayer), Delete removes the row and
// its file. Incognito dictations are never here (nothing was stored). M3.T08 builds the rest of the Voice section.
@preconcurrency import AVFoundation
import AntiChatDesign
import AntiChatStorage
import SwiftUI

@MainActor
@Observable
final class RecentRecordingsModel {
    private(set) var recordings: [RecordingRecord] = []
    private(set) var playingID: String?
    @ObservationIgnored private var player: AVAudioPlayer?
    @ObservationIgnored let store: RecordingStore?

    init(store: RecordingStore?) { self.store = store }

    func reload() { recordings = (try? store?.all()) ?? [] }

    func toggle(_ r: RecordingRecord) {
        if playingID == r.id {
            player?.stop()
            playingID = nil
            return
        }
        guard let url = try? store?.fileURL(r), let p = try? AVAudioPlayer(contentsOf: url) else { return }
        player?.stop()
        player = p
        p.play()
        playingID = r.id
    }

    func delete(_ r: RecordingRecord) {
        if playingID == r.id { player?.stop(); playingID = nil }
        try? store?.delete(id: r.id)
        reload()
    }
}

struct RecentRecordingsView: View {
    @State var model: RecentRecordingsModel

    var body: some View {
        Section {
            if model.recordings.isEmpty {
                Text(CopyKey("set.voice.recordings.empty"))
                    .typeStyle(.callout)
                    .foregroundStyle(Color.textSecondary)
                    .accessibilityIdentifier("recordings.empty")
            } else {
                ForEach(model.recordings) { r in
                    RecordingRow(recording: r, playing: model.playingID == r.id,
                                 onPlay: { model.toggle(r) }, onDelete: { model.delete(r) })
                }
            }
        } header: {
            // Q-015 r5: the identifiers sit on the header. On the Section (not a container) they replaced every child's
            // own: each row read `recordings` instead of `recording.row` (AX dump), and the empty line lost its id.
            Text(CopyKey("set.voice.recordings"))
                .probeID("settings.row.voice.recordings")
                .accessibilityIdentifier("recordings")
        }
        .id("voice.recordings")
        .onAppear { model.reload() }
    }
}

struct RecordingRow: View {
    let recording: RecordingRecord
    let playing: Bool
    let onPlay: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: Spacing.space3) {
            Button(action: onPlay) {
                Image(systemName: playing ? "stop.fill" : "play.fill").frame(width: 20)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(Text(CopyKey(playing ? "a11y.recording.stop" : "a11y.recording.play")))  // M9.T01
            .accessibilityIdentifier("recording.play")
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: recording.transcript)
                    .typeStyle(.callout)
                    .foregroundStyle(Color.textPrimary)
                    .lineLimit(2)
                Text(verbatim: "\(recording.createdAt.formatted(date: .abbreviated, time: .shortened)) · \(Elapsed.format(Double(recording.durationMs) / 1000))")
                    .typeStyle(.caption)
                    .foregroundStyle(Color.textTertiary)
            }
            Spacer(minLength: 0)
            Button(role: .destructive, action: onDelete) { Text(CopyKey("set.voice.recordings.delete")) }
                .buttonStyle(.borderless)
                .accessibilityIdentifier("recording.delete")
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("recording.row")
    }
}
