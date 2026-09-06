import Foundation
import XCTest
@testable import GuitarCore

final class StarterScoresTests: XCTestCase {
    func testStarterScoresArePlayableCompleteAndRoundTrip() throws {
        let scores = StarterScores.all
        XCTAssertEqual(scores.count, 6)
        XCTAssertEqual(Set(scores.map(\.title)).count, scores.count)
        for score in scores {
            XCTAssertEqual(ScoreValidator.validate(score), [], score.title)
            XCTAssertEqual(try ScoreIO.decode(ScoreIO.encode(score)), score, score.title)
            XCTAssertFalse(ScoreScheduler.notes(score).isEmpty, score.title)
            for measure in score.measures {
                XCTAssertEqual(ScoreScheduler.restGaps(in: measure, voice: .melody,
                    capacity: score.timeSignature.ticks), [], score.title)
            }
        }
    }

    func testScaleUsesAnAscendingAndDescendingCOctave() {
        let score = StarterScores.all[1]
        XCTAssertEqual(ScoreScheduler.notes(score).map(\.midi),
            [48,50,52,53,55,57,59,60,59,57,55,53,52,50,48])
        XCTAssertEqual(ScoreScheduler.notes(score).last?.durationTicks, 1920)
    }

    func testClassicalThemesMatchReferenceMelodiesAndRhythms() {
        let scores = StarterScores.all
        let twinkle = scores[3]
        XCTAssertEqual(ScoreScheduler.notes(twinkle).map(\.midi), [
            48,48,55,55,57,57,55, 53,53,52,52,50,50,48,
            55,55,53,53,52,52,50, 55,55,53,53,52,52,50,
            48,48,55,55,57,57,55, 53,53,52,52,50,50,48
        ])
        XCTAssertEqual(ScoreScheduler.notes(scores[4]).map(\.midi), [
            52,52,53,55,55,53,52,50,48,48,50,52,52,50,50,
            52,52,53,55,55,53,52,50,48,48,50,52,50,48,48
        ])
        XCTAssertEqual(scores[4].measures[3].events(for: .melody).map { $0.rhythm.ticks },
            [1440,480,1920])
        XCTAssertEqual(ScoreScheduler.notes(scores[5]).suffix(6).map(\.midi), [48,43,48,48,43,48])
    }

    func testLyricsStayAlignedToEverySungNote() {
        for index in [3,5] {
            let events = StarterScores.all[index].measures.flatMap { $0.events(for: .melody) }
            XCTAssertTrue(events.allSatisfy { $0.lyric?.isEmpty == false })
        }
        let firstPhrase = StarterScores.all[3].measures.prefix(2).flatMap { $0.events(for: .melody) }
        XCTAssertEqual(firstPhrase.compactMap(\.lyric), ["Twin-", "kle,", "twin-", "kle,", "lit-", "tle", "star,"])
    }

    func testExampleFilesMatchBundledContent() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let folder = root.appendingPathComponent("Examples/MyLibrary")
        let filenames = ["01-Chromatic.guitarget", "02-C-Major-Scale.guitarget", "03-Arpeggio.guitarget",
                         "04-Twinkle-Twinkle.guitarget", "05-Ode-to-Joy.guitarget", "06-Frere-Jacques.guitarget"]
        for (filename, score) in zip(filenames, StarterScores.all) {
            let decoded = try ScoreIO.decode(Data(contentsOf: folder.appendingPathComponent(filename)))
            XCTAssertTrue(decoded.hasSameContent(as: score), filename)
        }
    }
}
