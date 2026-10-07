import SwiftUI
import AVFoundation
import GuitarAudio
import GuitarCore

struct RootView: View {
    @EnvironmentObject private var audio: AudioService
    @State private var tab = 0

    var body: some View {
        TabView(selection: $tab) {
            TunerTab().tabItem { Label("调音", systemImage: "tuningfork") }.tag(0)
            ChordTab().tabItem { Label("和弦", systemImage: "guitars") }.tag(1)
            ScoreTab().tabItem { Label("曲谱", systemImage: "music.note.list") }.tag(2)
            PracticeTab().tabItem { Label("练习", systemImage: "figure.strengthtraining.traditional") }.tag(3)
        }
        .safeAreaInset(edge: .bottom) { CaptureBar() }
    }
}

/// Shared capture switch. iOS only offers the microphone; system-audio taps are macOS only.
struct CaptureBar: View {
    @EnvironmentObject private var audio: AudioService

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 12) {
                Circle()
                    .fill(audio.isCapturing ? Color.green : (audio.isStartingCapture ? Color.yellow : Color.secondary.opacity(0.4)))
                    .frame(width: 9, height: 9)
                VStack(alignment: .leading, spacing: 2) {
                    Text(audio.isCapturing ? "正在采集 · \(audio.inputDevices.first?.name ?? "麦克风")" : audio.status)
                        .font(.caption).lineLimit(2)
                    LevelBar(level: audio.isCapturing ? audio.inputLevel : 0)
                }
                Spacer(minLength: 8)
                Button(audio.isCapturing ? "停止" : (audio.isStartingCapture ? "启动中" : "开始采集")) {
                    if audio.isCapturing || audio.isStartingCapture {
                        audio.stopCapture()
                    } else {
                        audio.source = .input
                        audio.startCapture()
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(audio.isStartingCapture)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
    }
}
