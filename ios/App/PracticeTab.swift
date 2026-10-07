import SwiftUI
import GuitarAudio
import GuitarCore

/// Chord-change drill built from GuitarCore's practice deck, with synthesis previews and
/// live recognition feedback so the player can check the shape they just fretted.
struct PracticeTab: View {
    @EnvironmentObject private var audio: AudioService
    @State private var roots: Set<PitchClass> = [.c, .a, .g, .e, .d]
    @State private var kinds: Set<ChordKind> = [.major, .minor]
    @State private var rounds = 12
    @State private var cards: [ChordPracticeCard] = []
    @State private var index = 0
    @State private var message = "选择根音与类型，生成一组换和弦练习。"
    @State private var fluent = 0
    @State private var slow = 0
    private let owner = "iOS 和弦练习"

    private var card: ChordPracticeCard? { cards.indices.contains(index) ? cards[index] : nil }
    private var heard: String { audio.chordFrame?.chord.label ?? "—" }
    private var matches: Bool {
        guard let card, let heard = audio.chordFrame?.chord.definition else { return false }
        return heard == card.chord
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    IOSHeader(eyebrow: "PRACTICE / CHORD CHANGES", title: "换和弦练习。",
                              subtitle: "看卡片按好指法，再对照实时识别结果。")
                    setupCard
                    if let card { drillCard(card) } else { emptyState }
                }
                .padding(16)
            }
            .navigationTitle("练习")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private var setupCard: some View {
        IOSCard(title: "练习设置", icon: "dial.medium") {
            VStack(alignment: .leading, spacing: 8) {
                Text("根音").font(.caption).foregroundStyle(.secondary)
                chipBar(items: PitchClass.allCases, selected: roots, label: \.displayName) { item in
                    toggle(item, in: &roots)
                }
                Text("类型").font(.caption).foregroundStyle(.secondary)
                chipBar(items: ChordKind.allCases.filter { $0 == .major || $0 == .minor }, selected: kinds, label: \.title) { item in
                    toggle(item, in: &kinds)
                }
                HStack {
                    Text("轮数 \(rounds)").font(.caption).monospacedDigit()
                    Slider(value: Binding(get: { Double(rounds) }, set: { rounds = Int($0) }), in: 4...24, step: 2)
                }
                Button {
                    generate()
                } label: { Label(cards.isEmpty ? "生成练习" : "重新生成", systemImage: "shuffle") }
                    .buttonStyle(.borderedProminent)
                Text(message).font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    private func chipBar<Item: Identifiable & Hashable>(items: [Item], selected: Set<Item>, label: KeyPath<Item, String>,
                                                          action: @escaping (Item) -> Void) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(items) { item in
                    Button { action(item) } label: {
                        Text(item[keyPath: label])
                            .font(.caption)
                            .padding(.horizontal, 10).padding(.vertical, 5)
                            .background(selected.contains(item) ? Color.orange.opacity(0.25) : Color(UIColor.tertiarySystemFill),
                                        in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func toggle<Item: Hashable>(_ item: Item, in set: inout Set<Item>) {
        if set.contains(item) { if set.count > 1 { set.remove(item) } } else { set.insert(item) }
    }

    private func drillCard(_ card: ChordPracticeCard) -> some View {
        IOSCard(title: "第 \(index + 1) / \(cards.count) 张 · \(card.chord.name)", icon: "hand.point.up.left") {
            HStack(alignment: .center, spacing: 16) {
                FretDots(frets: card.voicing.frets, fingers: card.voicing.fingers)
                VStack(alignment: .leading, spacing: 3) {
                    Text(card.chord.noteNames.joined(separator: " · ")).font(.subheadline)
                    Text("\(card.voicing.soundingStrings) 根弦 · 最低 \(card.voicing.lowestFret) 品")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
            }
            HStack(spacing: 10) {
                Button { audio.preview(notes: card.voicing.notes, owner: owner, strum: true) } label: {
                    Label("示范扫弦", systemImage: "speaker.wave.2")
                }
                Button { audio.previewSequence(notes: card.voicing.notes, owner: owner, secondsPerNote: 0.4) } label: {
                    Label("逐音", systemImage: "list.bullet")
                }
                Spacer()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text("识别到").font(.caption).foregroundStyle(.secondary)
                    Text(heard).font(.headline)
                    if matches {
                        Label("正确", systemImage: "checkmark.circle.fill")
                            .font(.caption).foregroundStyle(.green)
                    } else if audio.isCapturing {
                        Text("再按稳一点").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                if !audio.isCapturing {
                    Text("开始采集后，这里会显示你实际弹出的和弦。").font(.caption2).foregroundStyle(.secondary)
                }
            }
            .padding(10)
            .background(matches ? Color.green.opacity(0.12) : Color(UIColor.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 12))
            HStack(spacing: 10) {
                Button { rate(fluent: true) } label: { Label("顺畅 \(fluent)", systemImage: "checkmark") }
                Button { rate(fluent: false) } label: { Label("生疏 \(slow)", systemImage: "arrow.counterclockwise") }
                Spacer()
                Button { next() } label: { Label(index + 1 < cards.count ? "下一个" : "重新开始", systemImage: "forward.fill") }
                    .buttonStyle(.borderedProminent)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }

    private var emptyState: some View {
        IOSCard(title: "开始练习", icon: "sparkles") {
            Text("生成一组卡片后，这里会显示指法、示范音与实时识别结果。")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func generate() {
        var random = SystemRandomNumberGenerator()
        do {
            cards = try ChordPracticeDeck.make(roots: Array(roots), kinds: Array(kinds), rounds: rounds, using: &random)
            index = 0; fluent = 0; slow = 0
            message = "共 \(cards.count) 张卡片，按顺序换和弦。"
        } catch {
            cards = []; message = error.localizedDescription
        }
    }

    private func rate(fluent value: Bool) {
        if value { fluent += 1 } else { slow += 1 }
        next()
    }

    private func next() {
        guard !cards.isEmpty else { return }
        index = (index + 1) % cards.count
        if index == 0 { message = "已完成一轮：顺畅 \(fluent) · 生疏 \(slow)。" }
        audio.stop()
    }
}
