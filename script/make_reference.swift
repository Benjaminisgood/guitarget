import AVFoundation
import Foundation

// Development fixture only; the application does not invoke this script.
let destination = URL(fileURLWithPath: CommandLine.arguments[1])
let seconds = Double(CommandLine.arguments.dropFirst(2).first ?? "60")!
let rate = 48000.0
let format = AVAudioFormat(standardFormatWithSampleRate:rate,channels:1)!
let count = Int(seconds * rate)
let buffer = AVAudioPCMBuffer(pcmFormat:format,frameCapacity:AVAudioFrameCount(count))!
buffer.frameLength = buffer.frameCapacity
for i in 0..<count {
    let fade = min(1,Double(i)/(rate*0.015),Double(count-i-1)/(rate*0.015))
    buffer.floatChannelData![0][i] = Float(0.22 * max(0,fade) * sin(2 * .pi * 440 * Double(i)/rate))
}
var file: AVAudioFile? = try AVAudioFile(forWriting:destination,settings:format.settings)
try file!.write(from:buffer)
file = nil // Close the WAV and flush its frame count before this top-level script exits.
