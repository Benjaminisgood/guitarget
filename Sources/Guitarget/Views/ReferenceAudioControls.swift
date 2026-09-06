import SwiftUI
import GuitarCore

struct ReferenceAudioControls: View {
    @EnvironmentObject private var library: ScoreLibraryStore
    let entry: LocalScoreLibraryEntry
    @ObservedObject var player: ReferenceAudioPlayer
    private var isCurrent: Bool { player.entryID == entry.id }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 10) {
                Button {
                    do {
                        if let url = try library.audioURL(for: entry.id) { player.toggle(id: entry.id, url: url) }
                    } catch { player.error = error.localizedDescription }
                } label: {
                    Label(isCurrent && player.isPlaying ? "暂停原声" : "播放原声", systemImage: isCurrent && player.isPlaying ? "pause.fill" : "play.fill")
                }
                Button { player.stop() } label: { Image(systemName: "stop.fill") }.disabled(!isCurrent).help("停止原声")
                Text(entry.originalAudioName ?? "本地音频").font(.callout).lineLimit(1).help(entry.originalAudioName ?? "本地音频")
                Spacer(minLength: 0)
            }
            if isCurrent {
                HStack {
                    Text(time(player.currentTime)).monospacedDigit()
                    Slider(value: Binding(get: { player.currentTime }, set: player.seek), in: 0...max(1, player.duration))
                        .accessibilityLabel("原声播放进度")
                    Text(time(player.duration)).monospacedDigit()
                }.font(.caption).foregroundStyle(.secondary)
            }
        }
        .alert("无法播放原声", isPresented: Binding(get: { player.error != nil }, set: { if !$0 { player.error = nil } })) {
            Button("好") { player.error = nil }
        } message: { Text(player.error ?? "") }
    }
    private func time(_ value: TimeInterval) -> String {
        let seconds = Int(max(0, value))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}
