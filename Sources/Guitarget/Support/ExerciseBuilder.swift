import Foundation
import GuitarCore

extension ExerciseBuilder {
    static var fingerstyle: GuitarScore {
        var measures: [ScoreMeasure] = []
        for bassFret in [0,3,5,0] {
            let melody = [0,3,0,2,0,3,2,0].enumerated().map { index, fret in
                ScoreEvent(startTick:index*480,rhythm:Rhythm(.eighth),notes:[GuitarNote(string:index%2 == 0 ? 1:2,fret:fret)])
            }
            let bass = ScoreEvent(startTick:0,rhythm:Rhythm(.whole),notes:[GuitarNote(string:6,fret:bassFret)])
            measures.append(ScoreMeasure(voices:[VoiceTrack(voice:.melody,events:melody),VoiceTrack(voice:.bass,events:[bass])]))
        }
        return GuitarScore(title:"第一首指弹 · 旋律与低音",measures:measures)
    }
}
