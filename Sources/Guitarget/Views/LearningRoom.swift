import SwiftUI
import AppKit
import GuitarAudio
import GuitarCore

enum LearningSection: String, CaseIterable, Identifiable {
    case fretboard = "指板", scales = "音阶", caged = "CAGED", triads = "三和弦"
    case chords = "和弦库", tuner = "调音器", ensemble = "合奏", chordPractice = "和弦练习", scores = "曲谱"
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .fretboard: return "guitars"
        case .scales: return "music.note.list"
        case .caged: return "square.grid.2x2"
        case .triads: return "triangle"
        case .chords: return "rectangle.grid.3x2"
        case .tuner: return "tuningfork"
        case .ensemble: return "waveform"
        case .chordPractice: return "ear.badge.checkmark"
        case .scores: return "doc.richtext"
        }
    }
    var subtitle: String {
        switch self {
        case .fretboard: return "认识每一个音"
        case .scales: return "连接五种指型"
        case .caged: return "形状与和弦"
        case .triads: return "听见调内和声"
        case .chords: return "查找适合的按法"
        case .tuner: return "听准每一根弦"
        case .ensemble: return "跟着和声即兴"
        case .chordPractice: return "看、听、记住和弦"
        case .scores: return "写下你的音乐"
        }
    }
}

struct LearningRoom: View {
    let audio: AudioService
    @State private var section: LearningSection? = .fretboard

    var body: some View {
        VStack(spacing: 0) {
            NavigationSplitView {
                VStack(alignment: .leading, spacing: 0) {
                    VStack(alignment: .leading, spacing: 6) {
                        Label("Guitarget", systemImage: "guitars.fill").font(.system(size: 22, weight: .bold, design: .rounded))
                        Text("从一个音，到一首歌").font(.caption).foregroundStyle(.secondary)
                    }.padding(.horizontal,20).padding(.top,22).padding(.bottom,26)
                    List(LearningSection.allCases, selection: $section) { item in
                        Label {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(item.rawValue)
                                Text(item.subtitle).font(.caption2).foregroundStyle(.secondary)
                            }.padding(.vertical,5)
                        } icon: { Image(systemName: item.icon).foregroundStyle(.orange) }.tag(item)
                    }.listStyle(.sidebar)
                    VStack(alignment: .leading, spacing: 8) {
                        Text("STEEL STRING / 6").font(.system(size: 10, weight: .medium, design: .monospaced)).tracking(1)
                        Text("标准调弦 · A4 = 440 Hz").font(.caption)
                        Text("E  A  D  G  B  E").font(.system(size: 11, design: .monospaced))
                    }.foregroundStyle(.secondary).padding(20)
                }.navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 250)
            } detail: {
                ScrollView {
                    Group {
                        switch section ?? .fretboard {
                        case .fretboard: FretboardLesson(audio: audio)
                        case .scales: ScaleLesson(audio: audio)
                        case .caged: CAGEDLesson(audio: audio)
                        case .triads: TriadsLesson(audio: audio)
                        case .chords: ChordLibraryLesson(audio: audio)
                        case .tuner: TunerLesson(audio: audio)
                        case .ensemble: EnsembleLesson(audio: audio)
                        case .chordPractice: ChordPracticeLesson(audio: audio)
                        case .scores: ScoreLibraryView()
                        }
                    }.padding(30).frame(maxWidth: 1500, alignment: .leading).frame(maxWidth: .infinity, alignment: .topLeading)
                }.navigationTitle(section?.rawValue ?? "指板")
            }
            Divider()
            AudioStatusBar(audio: audio)
        }
        .tint(.orange)
    }
}

struct RootPicker: View {
    @Binding var root: PitchClass
    var body: some View {
        Picker("根音", selection: $root) {
            ForEach(PitchClass.allCases, id: \.self) { Text($0.displayName).tag($0) }
        }.frame(width: 140)
    }
}

struct PatternPicker: View {
    @Binding var pattern: ScalePattern?
    var body: some View {
        Picker("指型", selection: $pattern) {
            Text("全指板").tag(nil as ScalePattern?)
            ForEach(ScalePattern.allCases, id: \.self) { Text($0.title).tag(Optional($0)) }
        }.pickerStyle(.segmented).frame(maxWidth: 580)
    }
}
