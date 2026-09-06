import SwiftUI
import AppKit
import UniformTypeIdentifiers
import GuitarCore

struct MyScoreLibraryView: View {
    @EnvironmentObject private var library: ScoreLibraryStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openDocument) private var openDocument
    @State private var selection: UUID?
    @State private var search = ""
    @State private var importing = false
    @State private var removing: LocalScoreLibraryEntry?

    init(selectedID: UUID? = nil) { _selection = State(initialValue: selectedID) }
    private var filtered: [LocalScoreLibraryEntry] {
        library.entries.filter { search.isEmpty || $0.title.localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                Label("我的曲库", systemImage: "music.note.house").font(.title2.bold())
                Text("\(library.entries.count) 份曲谱 · 本地保存").foregroundStyle(.secondary)
                Spacer()
                Button("完成") { dismiss() }.keyboardShortcut(.cancelAction)
            }.padding(20)
            Divider()
            HStack(spacing: 12) {
                TextField("搜索曲谱", text: $search).textFieldStyle(.roundedBorder).frame(maxWidth: 300)
                Spacer()
                Button { importing = true } label: { Label("导入曲谱", systemImage: "square.and.arrow.down") }
                Button {
                    if let id = library.add(GuitarScore()) { selection = id; open(id) }
                } label: { Label("新建曲谱", systemImage: "plus") }
            }.padding(.horizontal, 20).padding(.vertical, 12).disabled(!library.isAvailable)
            Divider()
            HSplitView {
                Group {
                    if filtered.isEmpty {
                        ContentUnavailableView(search.isEmpty ? "曲库还没有曲谱" : "没有匹配的曲谱", systemImage: "music.note.list",
                                               description: Text(search.isEmpty ? "导入 .guitarget 文件，或新建一份曲谱。" : "试试其他名称。"))
                    } else {
                        List(filtered, selection: $selection) { entry in
                            Label {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(entry.title).lineLimit(2)
                                    Text(attachmentDescription(entry)).font(.caption).foregroundStyle(.secondary)
                                }.padding(.vertical, 5)
                            } icon: { Image(systemName: "doc.richtext").foregroundStyle(.orange) }
                                .tag(entry.id)
                                .contextMenu {
                                    Button("打开曲谱") { open(entry.id) }
                                    Button("从曲库移除…", role: .destructive) { removing = entry }
                                }
                        }.listStyle(.inset)
                    }
                }.frame(minWidth: 250, idealWidth: 300, maxWidth: 360)
                if let entry = library.entry(id: selection), filtered.contains(where: { $0.id == entry.id }) {
                    LibraryScoreDetailView(entry: entry, open: { open(entry.id) }, remove: { removing = entry })
                        .id(entry.id).frame(minWidth: 440, maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ContentUnavailableView("选择一份曲谱", systemImage: "doc.richtext", description: Text("管理名称、绑定原声音频或 Apple Music 歌曲。"))
                        .frame(minWidth: 440, maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            Divider()
            HStack {
                Text("导入会保存副本；在曲库中打开并保存，修改会留在这里。").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("在 Finder 中显示") { NSWorkspace.shared.open(library.rootURL) }.font(.caption)
            }.padding(14)
        }
        .frame(minWidth: 880, idealWidth: 980, minHeight: 640, idealHeight: 730)
        .onAppear {
            library.reload()
            if selection == nil { selection = library.entries.first?.id }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.guitarget, .json], allowsMultipleSelection: true) { result in
            switch result {
            case .success(let urls): if let id = library.importFiles(urls) { search = ""; selection = id }
            case .failure(let error): library.error = error.localizedDescription
            }
        }
        .alert("曲库操作未完成", isPresented: Binding(get: { library.error != nil }, set: { if !$0 { library.error = nil } })) {
            Button("好") { library.error = nil }
        } message: { Text(library.error ?? "") }
        .confirmationDialog("从我的曲库移除这份曲谱？", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }), titleVisibility: .visible) {
            Button("移除曲谱和曲库内音频副本", role: .destructive) {
                if let entry = removing {
                    library.remove(entry.id)
                    if library.entry(id: entry.id) == nil { selection = library.entries.first?.id }
                }
                removing = nil
            }
        } message: { Text("“\(removing?.title ?? "")”会从曲库移除。原先导入的源文件仍保留。") }
    }

    private func attachmentDescription(_ entry: LocalScoreLibraryEntry) -> String {
        var labels: [String] = []
        if entry.localAudioFilename != nil { labels.append("本地音频") }
        if entry.appleMusicURL != nil { labels.append("Apple Music") }
        return labels.isEmpty ? "可绑定伴奏与原声" : labels.joined(separator: " · ")
    }
    private func open(_ id: UUID) {
        do {
            let url = try library.scoreURL(for: id)
            Task {
                do { try await openDocument(at: url); dismiss() }
                catch { library.error = error.localizedDescription }
            }
        } catch { library.error = error.localizedDescription }
    }
}

private struct LibraryScoreDetailView: View {
    @EnvironmentObject private var library: ScoreLibraryStore
    let entry: LocalScoreLibraryEntry
    let open: () -> Void
    let remove: () -> Void
    @State private var title: String
    @State private var musicLink: String
    @State private var importingAudio = false
    @State private var exporting = false
    @State private var score: GuitarScore?
    @State private var loadError: String?

    init(entry: LocalScoreLibraryEntry, open: @escaping () -> Void, remove: @escaping () -> Void) {
        self.entry = entry; self.open = open; self.remove = remove
        _title = State(initialValue: entry.title)
        _musicLink = State(initialValue: entry.appleMusicURL ?? "")
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 10) {
                    Text(entry.title).font(.title2.bold()).textSelection(.enabled)
                    if let score {
                        let hasLyrics = score.measures.contains { $0.voices.contains { $0.events.contains { !($0.lyric ?? "").isEmpty } } }
                        Text("\(score.measures.count) 小节 · \(score.timeSignature.title) · \(Int(score.bpm)) BPM\(hasLyrics ? " · 含歌词" : "")")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    if let loadError { Text(loadError).font(.callout).foregroundStyle(.red) }
                    HStack {
                        Button("打开曲谱", action: open).buttonStyle(.borderedProminent)
                        Button("导出曲谱…") { loadScore(); exporting = score != nil }.disabled(score == nil)
                    }
                }
                GroupBox("曲库名称") {
                    HStack {
                        TextField("名称", text: $title).textFieldStyle(.roundedBorder).onSubmit { library.rename(entry.id, title: title) }
                        Button("重命名") { library.rename(entry.id, title: title) }.disabled(title == entry.title)
                    }.padding(8)
                }
                GroupBox("原声音频 · 本地文件") {
                    VStack(alignment: .leading, spacing: 12) {
                        if entry.localAudioFilename != nil {
                            ReferenceAudioControls(entry: entry, player: library.referenceAudio)
                        } else {
                            Text("绑定自己的录音或伴奏，边看谱边播放。").foregroundStyle(.secondary)
                        }
                        HStack {
                            Button(entry.localAudioFilename == nil ? "选择音频文件…" : "更换音频…") { importingAudio = true }
                            if entry.localAudioFilename != nil {
                                Button("解除绑定", role: .destructive) { library.unbindAudio(entry.id) }
                            }
                        }
                        Text("支持系统可解码的 MP3、M4A、WAV、AIFF 等音频。副本存入曲库，移动源文件后仍可播放。")
                            .font(.caption).foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
                }
                GroupBox("Apple Music") {
                    VStack(alignment: .leading, spacing: 12) {
                        TextField("粘贴 music.apple.com 歌曲或专辑链接", text: $musicLink)
                            .textFieldStyle(.roundedBorder)
                        HStack {
                            Button("保存链接") { library.bindAppleMusic(entry.id, url: musicLink) }
                                .disabled(musicLink == (entry.appleMusicURL ?? ""))
                            if entry.appleMusicURL != nil {
                                Button("在“音乐”中打开") { library.openAppleMusic(entry) }
                                Button("解除绑定") { library.bindAppleMusic(entry.id, url: ""); musicLink = "" }
                            }
                        }
                        Text("从 Apple Music 的“分享 → 复制链接”粘贴。打开后在原生“音乐”应用中播放；完整播放取决于账号和曲目可用性。")
                            .font(.caption).foregroundStyle(.secondary)
                    }.padding(8)
                }
                Text("原声独立播放，使用系统输出设备；谱面变速、循环和跟练不会自动同步原声。曲库名称不改变谱内标题，标题可在编辑器中修改。")
                    .font(.caption).foregroundStyle(.secondary)
                Divider()
                Button("从曲库移除…", role: .destructive, action: remove)
            }.padding(24)
        }
        .onAppear { loadScore() }
        .fileImporter(isPresented: $importingAudio, allowedContentTypes: [.audio]) { result in
            switch result {
            case .success(let url): library.bindAudio(entry.id, from: url)
            case .failure(let error): library.error = error.localizedDescription
            }
        }
        .fileExporter(isPresented: $exporting, document: score.map { GuitarScoreDocument(score: $0) }, contentType: .guitarget, defaultFilename: entry.title) { result in
            if case .failure(let error) = result { library.error = error.localizedDescription }
        }
    }
    private func loadScore() {
        do { score = try ScoreIO.decode(Data(contentsOf: library.scoreURL(for: entry.id))); loadError = nil }
        catch { score = nil; loadError = "无法读取曲谱：\(error.localizedDescription)" }
    }
}
