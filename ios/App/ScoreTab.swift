import SwiftUI
import GuitarAudio
import GuitarCore

/// Document-backed score library: the same LocalScoreLibrary storage the macOS app uses,
/// rooted in the iOS app's Documents directory and seeded with the starter scores.
@MainActor
final class IOSScoreStore: ObservableObject {
    @Published private(set) var entries: [LocalScoreLibraryEntry] = []
    @Published var message: String?
    let rootURL: URL
    private var storage: LocalScoreLibrary?

    init() {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        rootURL = documents.appendingPathComponent("Guitarget").appendingPathComponent("MyLibrary")
        let isNew = !FileManager.default.fileExists(atPath: rootURL.appendingPathComponent("library.json").path)
        do {
            let library = try LocalScoreLibrary(rootURL: rootURL)
            storage = library
            if isNew { for score in StarterScores.all { _ = try library.importScore(score) } }
            entries = library.entries
        } catch { message = error.localizedDescription }
    }

    func refresh() {
        guard let storage else { return }
        do { try storage.reload(); entries = storage.entries }
        catch { message = error.localizedDescription }
    }

    func score(for id: UUID) -> GuitarScore? {
        guard let storage else { return nil }
        do { return try ScoreIO.decode(Data(contentsOf: storage.scoreURL(for: id))) }
        catch { message = error.localizedDescription; return nil }
    }

    @discardableResult
    func add(_ score: GuitarScore) -> UUID? {
        guard let storage else { return nil }
        do { let entry = try storage.importScore(score); refresh(); return entry.id }
        catch { message = error.localizedDescription; return nil }
    }

    func remove(_ id: UUID) {
        guard let storage else { return }
        do { try storage.remove(id: id); refresh() }
        catch { message = error.localizedDescription }
    }
}

struct ScoreTab: View {
    @StateObject private var store = IOSScoreStore()
    @EnvironmentObject private var audio: AudioService

    var body: some View {
        NavigationStack {
            List {
                if let message = store.message {
                    Section("提示") { Text(message).font(.caption).foregroundStyle(.secondary) }
                }
                Section("我的曲谱") {
                    if store.entries.isEmpty {
                        Text("还没有曲谱。下方示例可一键保存。").font(.caption).foregroundStyle(.secondary)
                    }
                    ForEach(store.entries) { entry in
                        NavigationLink(value: entry.id) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(entry.title).font(.body)
                                Text(entry.createdAt, style: .date).font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .onDelete { indexes in indexes.map { store.entries[$0].id }.forEach(store.remove) }
                }
                Section("内置示例") {
                    ForEach(Array(StarterScores.all.enumerated()), id: \.offset) { _, score in
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(score.title).font(.body)
                                Text(summary(score)).font(.caption2).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button {
                                store.add(score)
                                store.message = "已保存《\(score.title)》到我的曲谱。"
                            } label: { Image(systemName: "square.and.arrow.down") }
                            .buttonStyle(.borderless)
                        }
                    }
                }
            }
            .navigationTitle("曲谱库")
            .navigationDestination(for: UUID.self) { id in
                if let entry = store.entry(id: id), let score = store.score(for: id) {
                    ScoreDetail(entry: entry, score: score)
                } else {
                    Text("曲谱不可用").foregroundStyle(.secondary)
                }
            }
            .onAppear { store.refresh() }
        }
    }

    private func summary(_ score: GuitarScore) -> String {
        let events = score.measures.reduce(0) { total, measure in
            total + measure.voices.reduce(0) { $0 + $1.events.count }
        }
        return "\(score.measures.count) 小节 · \(events) 个音符事件 · \(Int(score.bpm)) BPM · \(score.timeSignature.title)"
    }
}

private extension IOSScoreStore {
    func entry(id: UUID) -> LocalScoreLibraryEntry? { entries.first { $0.id == id } }
}

/// Playback transport over AudioService's score renderer.
struct ScoreDetail: View {
    let entry: LocalScoreLibraryEntry
    let score: GuitarScore
    @EnvironmentObject private var audio: AudioService
    @State private var speed = 1.0
    @State private var metronome = false
    private let owner = "iOS 曲谱回放"

    private var isMine: Bool { audio.ownerID == owner }
    private var progress: Double {
        guard score.totalTicks > 0 else { return 0 }
        return max(0, min(1, Double(audio.currentTick) / Double(score.totalTicks)))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                IOSHeader(eyebrow: "SCORE / PLAYBACK", title: score.title, subtitle: "\(score.measures.count) 小节 · \(Int(score.bpm)) BPM · \(score.timeSignature.title)")
                IOSCard(title: "回放", icon: "play.circle") {
                    ProgressView(value: progress)
                    HStack {
                        Text("\(audio.currentTick) / \(score.totalTicks) tick").font(.caption).monospacedDigit().foregroundStyle(.secondary)
                        Spacer()
                        Text(String(format: "%.2f×", speed)).font(.caption).monospacedDigit().foregroundStyle(.secondary)
                    }
                    HStack(spacing: 10) {
                        Button {
                            if audio.isPlaying && isMine { audio.pause() }
                            else if audio.isPaused && isMine { audio.resume() }
                            else { audio.speed = speed; audio.metronomeEnabled = metronome; audio.play(score: score, owner: owner) }
                        } label: {
                            Label(audio.isPlaying && isMine ? "暂停" : (audio.isPaused && isMine ? "继续" : "演奏"),
                                  systemImage: audio.isPlaying && isMine ? "pause.fill" : "play.fill")
                        }
                        .buttonStyle(.borderedProminent)
                        Button { audio.stop() } label: { Label("停止", systemImage: "stop.fill") }
                            .buttonStyle(.bordered)
                            .disabled(!(audio.isPlaying || audio.isPaused))
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        Text("速度").font(.caption).foregroundStyle(.secondary)
                        Slider(value: $speed, in: 0.5...1.5, step: 0.05)
                            .onChange(of: speed) { _, value in if isMine { audio.speed = value } }
                        Toggle("节拍器", isOn: $metronome)
                            .font(.caption)
                            .onChange(of: metronome) { _, value in if isMine { audio.metronomeEnabled = value } }
                    }
                    Text(audio.status).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                }
                IOSCard(title: "小节内容", icon: "list.number") {
                    ForEach(Array(score.measures.enumerated()), id: \.element.id) { index, measure in
                        let melody = measure.voices.first { $0.voice == .melody }?.events ?? []
                        let bass = measure.voices.first { $0.voice == .bass }?.events ?? []
                        VStack(alignment: .leading, spacing: 4) {
                            Text("第 \(index + 1) 小节 · 旋律 \(melody.count) · 低音 \(bass.count)")
                                .font(.caption.weight(.medium))
                            Text(notesText(melody)).font(.caption2).foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 2)
                    }
                }
            }
            .padding(16)
        }
        .navigationTitle(entry.title)
        .navigationBarTitleDisplayMode(.inline)
        .onDisappear { if isMine { audio.stop() } }
    }

    private func notesText(_ events: [ScoreEvent]) -> String {
        let names = events.prefix(12).flatMap { event in
            event.notes.map { note in
                let midi = note.string >= 1 && note.string <= 6 ? score.tuning[note.string - 1] + note.fret : 0
                return "\(MusicTheory.noteName(midi: midi))(\(note.string)弦\(note.fret)品)"
            }
        }
        return names.isEmpty ? "（空）" : names.joined(separator: " ") + (events.count > 12 ? " …" : "")
    }
}
