import SwiftUI
import GuitarAudio

/// iOS entry point. The audio graph itself lives in GuitarAudio's AudioService, which
/// configures the shared AVAudioSession for capture and playback on this platform.
@main
struct GuitargetIOSApp: App {
    private let audio = AudioService.shared

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(audio)
                .tint(.orange)
        }
    }
}
