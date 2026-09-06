import XCTest
@testable import GuitarCore

final class TunerEngineTests: XCTestCase {
    private func sample(_ frequency: Double, _ time: Double, confidence: Double = 0.99, rms: Double = 0.08) -> PitchObservation {
        PitchObservation(timestamp: time, frequency: frequency, cents: 37, confidence: confidence, rms: rms, isStable: false)
    }

    func testTuningPresetsKeepStringOrderAndEnharmonicNames() {
        XCTAssertEqual(TunerPreset.standard.midiNotes, [64, 59, 55, 50, 45, 40])
        XCTAssertEqual(TunerPreset.dropD.midiNotes, [64, 59, 55, 50, 45, 38])
        XCTAssertEqual(TunerPreset.dadgad.midiNotes, [62, 57, 55, 50, 45, 38])
        XCTAssertEqual(TunerPreset.openG.midiNotes, [62, 59, 55, 50, 43, 38])
        XCTAssertEqual(TunerPreset.openD.midiNotes, [62, 57, 54, 50, 45, 38])
        XCTAssertEqual(TunerPreset.openE.midiNotes, [64, 59, 56, 52, 47, 40])
        XCTAssertEqual(TunerPreset.halfStepDown.midiNotes, TunerPreset.standard.midiNotes.map { $0 - 1 })
        XCTAssertEqual(TunerPreset.halfStepDown.noteName(string: 3), "G♭3")
        XCTAssertEqual(TunerPreset.openE.noteName(string: 3), "G♯3")
        XCTAssertEqual(TunerPreset.dadgad.lowToHighNames, "D2  A2  D3  G3  A3  D4")
    }

    func testReferencePitchRecomputesEveryTargetAndIgnoresObservationCents() {
        let settings = TunerConfiguration(mode: .lockedString, lockedString: 5, referenceA4: 432)
        XCTAssertEqual(settings.stringTarget(5)!.frequency, 108, accuracy: 0.000001)
        XCTAssertEqual(TunerConfiguration(preset: .dropD).stringTarget(6)!.frequency, 73.41619198, accuracy: 0.000001)
        for preset in TunerPreset.allCases {
            for string in 1...6 {
                let normal = TunerConfiguration(preset: preset).stringTarget(string)!.frequency
                let changed = TunerConfiguration(preset: preset, referenceA4: 442).stringTarget(string)!.frequency
                XCTAssertEqual(changed / normal, 442 / 440, accuracy: 0.00000001)
            }
        }
        var engine = TunerEngine(configuration: settings)
        engine.receive(sample(108, 1), now: 1.05, captureActive: true)
        XCTAssertEqual(engine.reading!.cents!, 0, accuracy: 0.00001)
        engine.receive(sample(110, 1.1), now: 1.15, captureActive: true)
        XCTAssertEqual(engine.reading!.cents!, 31.7666536, accuracy: 0.0001)
    }

    func testChromaticModeUsesSelectedReferenceForItsNearestNote() {
        var engine = TunerEngine(configuration: TunerConfiguration(mode: .chromatic, referenceA4: 432))
        engine.receive(sample(440, 2), now: 2.05, captureActive: true)
        XCTAssertEqual(engine.reading?.detectedMIDI, 69)
        XCTAssertEqual(engine.reading?.target?.name, "A4")
        XCTAssertNil(engine.reading?.target?.string)
        XCTAssertEqual(engine.reading!.cents!, 31.7666536, accuracy: 0.0001)
    }

    func testAutomaticModeMatchesOpenStringsWithoutFoldingOctaves() {
        for preset in TunerPreset.allCases {
            let settings = TunerConfiguration(preset: preset)
            for string in 1...6 {
                var engine = TunerEngine(configuration: settings)
                engine.receive(sample(settings.stringTarget(string)!.frequency, 2), now: 2.04, captureActive: true)
                XCTAssertEqual(engine.reading?.target?.string, string, "\(preset), string \(string)")
                XCTAssertEqual(engine.reading!.cents!, 0, accuracy: 0.000001)
            }
        }
        var engine = TunerEngine(configuration: TunerConfiguration(mode: .lockedString, lockedString: 6))
        engine.receive(sample(164.813778456, 3), now: 3.05, captureActive: true)
        XCTAssertEqual(engine.reading?.detectedMIDI, 52)
        XCTAssertEqual(engine.reading?.target?.string, 6)
        XCTAssertEqual(engine.reading!.cents!, 1200, accuracy: 0.00001)
        XCTAssertFalse(engine.reading!.isInTune)
    }

    func testOutOfOpenStringRangeKeepsMeasuredNoteButDoesNotInventTarget() {
        var engine = TunerEngine()
        engine.receive(sample(880, 3), now: 3.05, captureActive: true)
        XCTAssertEqual(engine.reading?.detectedMIDI, 81)
        XCTAssertEqual(engine.reading?.frequency, 880)
        XCTAssertNil(engine.reading?.target)
        XCTAssertNil(engine.reading?.cents)
        XCTAssertFalse(engine.reading!.isStable)
        XCTAssertTrue(engine.history.isEmpty)
    }

    func testStabilityComesFromSeveralFreshMeasuredFrequencies() {
        var engine = TunerEngine(configuration: TunerConfiguration(mode: .lockedString, lockedString: 5))
        engine.receive(PitchObservation(timestamp: 4, frequency: 110, confidence: 0.99, rms: 0.08, isStable: true), now: 4.03, captureActive: true)
        XCTAssertFalse(engine.reading!.isStable, "One detector stability flag is not a history measurement")
        for index in 1...3 {
            let time = 4 + Double(index) * 0.1
            engine.receive(sample(110, time), now: time + 0.03, captureActive: true)
        }
        XCTAssertTrue(engine.reading!.isStable)
        XCTAssertTrue(engine.reading!.isInTune)
        XCTAssertEqual(engine.reading!.spreadCents!, 0, accuracy: 0.00001)
        engine.receive(sample(110 * pow(2, 20.0 / 1200), 4.4), now: 4.43, captureActive: true)
        XCTAssertFalse(engine.reading!.isStable, "A 20-cent change must invalidate the stable state")
    }

    func testRepeatedOrOutOfOrderTimestampsCannotCreateStability() {
        var engine = TunerEngine(configuration: TunerConfiguration(mode: .chromatic))
        engine.receive(sample(440, 5), now: 5.02, captureActive: true)
        for index in 1...4 { engine.receive(sample(440, 5), now: 5 + Double(index) * 0.08, captureActive: true) }
        XCTAssertEqual(engine.history.count, 1)
        XCTAssertFalse(engine.reading!.isStable)
        engine.receive(sample(220, 4.99), now: 5.33, captureActive: true)
        XCTAssertEqual(engine.reading?.frequency, 440)
    }

    func testStaleSilenceAndStoppedCaptureClearLiveReadings() {
        var engine = TunerEngine(configuration: TunerConfiguration(mode: .chromatic))
        engine.receive(sample(440, 6), now: 6.03, captureActive: true)
        engine.advance(now: 6.451, captureActive: true)
        XCTAssertNil(engine.reading)
        XCTAssertEqual(engine.history.count, 1, "Historical samples remain labelled as history, not live readings")
        engine.receive(sample(440, 6.5), now: 6.52, captureActive: true)
        engine.receive(nil, now: 6.54, captureActive: true)
        XCTAssertNil(engine.reading)
        engine.receive(sample(440, 6.6), now: 6.62, captureActive: true)
        engine.advance(now: 6.65, captureActive: false)
        XCTAssertNil(engine.reading)
        XCTAssertTrue(engine.history.isEmpty)
        engine.receive(sample(440, 6.7), now: 6.72, captureActive: false)
        XCTAssertNil(engine.reading)
    }

    func testInvalidUnreliableAndFutureSamplesDoNotDisplayPitch() {
        let cases = [sample(.nan, 8), sample(.infinity, 8), sample(0, 8), sample(440, 8, confidence: 0.7),
                     sample(440, 8, confidence: .nan), sample(440, 8, rms: 0.001), sample(440, 8, rms: .nan), sample(440, 9)]
        for observation in cases {
            var engine = TunerEngine()
            engine.receive(observation, now: 8.02, captureActive: true)
            XCTAssertNil(engine.reading)
            XCTAssertTrue(engine.history.isEmpty)
        }
    }

    func testConfigurationChangeResetsOldReferenceHistory() {
        var engine = TunerEngine(configuration: TunerConfiguration(mode: .chromatic))
        engine.receive(sample(440, 10), now: 10.02, captureActive: true)
        engine.configure(TunerConfiguration(mode: .chromatic, preset: .dadgad, referenceA4: 442))
        XCTAssertNil(engine.reading)
        XCTAssertTrue(engine.history.isEmpty)
        engine.receive(sample(442, 10.1), now: 10.13, captureActive: true)
        XCTAssertEqual(engine.reading!.cents!, 0, accuracy: 0.000001)
        XCTAssertEqual(TunerConfiguration(referenceA4: .nan).referenceA4, 440)
        XCTAssertEqual(TunerConfiguration(referenceA4: 1000).referenceA4, 480)
    }

    func testAutomaticTargetHysteresisAndTargetChangeResetStability() {
        var engine = TunerEngine()
        engine.receive(sample(MusicTheory.frequency(midi: 56.98), 12), now: 12.03, captureActive: true)
        XCTAssertEqual(engine.reading?.target?.string, 3)
        engine.receive(sample(MusicTheory.frequency(midi: 57.02), 12.1), now: 12.13, captureActive: true)
        XCTAssertEqual(engine.reading?.target?.string, 3, "A tiny midpoint crossing should not flicker between targets")
        engine.receive(sample(MusicTheory.frequency(midi: 59), 12.2), now: 12.23, captureActive: true)
        XCTAssertEqual(engine.reading?.target?.string, 2)
        XCTAssertEqual(engine.reading?.stableDuration, 0)
        engine.advance(now: 21, captureActive: true)
        XCTAssertTrue(engine.history.isEmpty)
    }
}
