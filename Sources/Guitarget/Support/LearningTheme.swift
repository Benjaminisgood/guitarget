import SwiftUI
import GuitarCore

enum LearningTheme {
    static let root = Color.orange
    static let note = Color.teal
    static let blue = Color.indigo
}

struct LearningHeader: View {
    let eyebrow: String
    let title: String
    let subtitle: String
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(eyebrow.uppercased()).font(.system(size: 11, weight: .semibold, design: .monospaced)).tracking(2.5).foregroundStyle(.secondary)
            Text(title).font(.system(size: 32, weight: .bold, design: .rounded))
            Text(subtitle).font(.system(size: 14)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct LearningCard<Content: View>: View {
    var title: String
    var icon: String
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label(title, systemImage: icon).font(.headline)
            content
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(.separator.opacity(0.35)))
    }
}

struct LegendDot: View {
    let color: Color
    let text: String
    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(text).font(.caption).foregroundStyle(.secondary)
        }
    }
}

func noteName(_ midi: Int, flats: Bool = false, octave: Bool = true) -> String {
    let names = flats ? ["C","D♭","D","E♭","E","F","G♭","G","A♭","A","B♭","B"] : ["C","C♯","D","D♯","E","F","F♯","G","G♯","A","A♯","B"]
    return names[((midi % 12) + 12) % 12] + (octave ? "\(midi / 12 - 1)" : "")
}

func intervalName(_ semitones: Int) -> String {
    ["1","♭2","2","♭3","3","4","♭5","5","♭6","6","♭7","7"][((semitones % 12) + 12) % 12]
}
