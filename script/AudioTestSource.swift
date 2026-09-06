import Foundation
import AVFoundation

// A separate native process for system-tap isolation checks. Playback requires no capture permission.
guard CommandLine.arguments.count == 2 else { exit(2) }
do {
    let player = try AVAudioPlayer(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
    player.prepareToPlay()
    guard player.play() else { exit(3) }
    while player.isPlaying { RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.025)) }
} catch {
    FileHandle.standardError.write(Data(error.localizedDescription.utf8))
    exit(1)
}
