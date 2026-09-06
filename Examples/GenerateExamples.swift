// Regenerate from the repository root with:
// swiftc -swift-version 5 Sources/GuitarCore/*.swift Examples/GenerateExamples.swift -o /tmp/guitarget-examples
// /tmp/guitarget-examples
import Foundation

@main struct GenerateExamples {
    static func main() throws {
        let output = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Examples")
        let melodyFrets = [0,2,3,5,3,2,0,2]
        var fingerstyle = GuitarScore(title: "指弹示范 · 持续低音与八分旋律")
        fingerstyle.measures = (0..<2).map { bar in
            let melody = melodyFrets.enumerated().map { index, fret in
                ScoreEvent(startTick: index * 480, rhythm: Rhythm(.eighth), notes: [GuitarNote(string: 1, fret: fret + (bar == 1 ? 3 : 0))])
            }
            let bass = ScoreEvent(startTick: 0, rhythm: Rhythm(.whole), notes: [GuitarNote(string: 6, fret: 0, tieToNext: bar == 0)])
            return ScoreMeasure(voices: [VoiceTrack(voice: .melody, events: melody),VoiceTrack(voice: .bass, events: [bass])])
        }
        try ScoreIO.encode(fingerstyle).write(to: output.appendingPathComponent("Fingerstyle.guitarget"), options: .atomic)
        let techniques: [GuitarTechnique] = [.hammerOn,.pullOff,.slide,.bendHalf,.bendFull,.vibrato,.palmMute,.deadNote]
        let techniqueMeasures = techniques.map { technique in
            let target: Int? = technique == .pullOff ? 3 : [.hammerOn,.slide].contains(technique) ? 7 : nil
            let note = GuitarNote(string: 2, fret: 5, technique: technique, targetFret: target)
            return ScoreMeasure(voices: [VoiceTrack(voice: .melody, events: [ScoreEvent(startTick: 0, rhythm: Rhythm(.half), notes: [note])]), VoiceTrack(voice: .bass)])
        }
        try ScoreIO.encode(GuitarScore(title: "演奏技巧 · H P / 推弦 揉弦 闷音 死音", measures: techniqueMeasures)).write(to: output.appendingPathComponent("Techniques.guitarget"), options: .atomic)
        try ScoreIO.encode(MusicTheory.scaleExercise(root: .f, kind: .major, pattern: .c)).write(to: output.appendingPathComponent("F-Major.guitarget"), options: .atomic)
        print("Generated and validated Fingerstyle.guitarget, Techniques.guitarget, F-Major.guitarget")
    }
}
