import SwiftUI
import AppKit
import GuitarCore

struct ScoreLibraryView: View {
    @EnvironmentObject private var library: ScoreLibraryStore
    @Environment(\.newDocument) private var newDocument
    @Environment(\.openDocument) private var openDocument
    @State private var recentURLs: [URL] = []
    @State private var error: String?
    @State private var myLibraryVisible = false

    var body: some View {
        VStack(alignment:.leading,spacing:28) {
            LearningHeader(eyebrow:"05 / YOUR MUSIC",title:"写下，弹出，再听一次。",subtitle:"原生双声部六线谱。让旋律自由流动，让低音稳稳延续。")
            HStack(spacing:18) {
                Button { myLibraryVisible = true } label: {
                    libraryAction("我的曲库",subtitle:"\(library.entries.count) 份曲谱 · 歌词与原声",icon:"music.note.house",color:.orange)
                }.buttonStyle(.plain)
                Button { newDocument(GuitarScoreDocument()) } label: {
                    libraryAction("新建曲谱",subtitle:"4/4 · 80 BPM · 标准调弦",icon:"doc.badge.plus",color:.orange)
                }.buttonStyle(.plain)
                Button { NSDocumentController.shared.openDocument(nil) } label: {
                    libraryAction("打开曲谱",subtitle:"选择 .guitarget 文档",icon:"folder",color:.teal)
                }.buttonStyle(.plain)
            }
            LearningCard(title:"从一段指弹开始",icon:"music.note") {
                HStack(alignment:.center,spacing:24) {
                    Image(systemName:"guitars.fill").font(.system(size:48)).foregroundStyle(.orange).frame(width:72)
                    VStack(alignment:.leading,spacing:8) {
                        Text("第一首指弹 · 旋律与低音").font(.title3.bold())
                        Text("一个整小节低音，叠加八个八分旋律音。打开示例，试试独立修改两个声部。").foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("打开示例") { newDocument(GuitarScoreDocument(score:ExerciseBuilder.fingerstyle)) }.buttonStyle(.borderedProminent)
                }
            }
            LearningCard(title:"最近打开",icon:"clock") {
                if recentURLs.isEmpty {
                    Text("保存或打开曲谱后，会在这里显示。").foregroundStyle(.secondary).padding(.vertical,12)
                } else {
                    ForEach(recentURLs,id:\.self) { url in
                        Button {
                            Task { do { try await openDocument(at:url) } catch { self.error = error.localizedDescription } }
                        } label: {
                            HStack {
                                Image(systemName:"doc.richtext").foregroundStyle(.orange)
                                VStack(alignment:.leading,spacing:3) {
                                    Text(url.deletingPathExtension().lastPathComponent)
                                    Text(url.deletingLastPathComponent().path).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                                Spacer()
                                Image(systemName:"arrow.up.right").foregroundStyle(.tertiary)
                            }.padding(.vertical,5).contentShape(Rectangle())
                        }.buttonStyle(.plain)
                    }
                }
            }
            HStack(alignment:.top,spacing:24) {
                LearningCard(title:"鼠标 + 键盘",icon:"keyboard") {
                    Text("点击弦与时间位置 → 数字键输入品位 → 方向键移动。")
                    Text("0–24 品 · 附点 · 三连音 · 两个声部\n复制粘贴、撤销重做与原生保存均可用。").font(.callout).foregroundStyle(.secondary)
                }
                LearningCard(title:"开放的曲谱文件",icon:"curlybraces") {
                    Text(".guitarget 是带版本号的 JSON 文档。")
                    Text("AI 或脚本可按文档格式生成曲谱；打开时校验节奏、弦位和声部冲突。").font(.callout).foregroundStyle(.secondary)
                }
            }
        }
        .onAppear { recentURLs = NSDocumentController.shared.recentDocumentURLs }
        .sheet(isPresented: $myLibraryVisible) { MyScoreLibraryView() }
        .onReceive(NotificationCenter.default.publisher(for:NSApplication.didBecomeActiveNotification)) { _ in recentURLs = NSDocumentController.shared.recentDocumentURLs }
        .alert("无法打开曲谱",isPresented:Binding(get:{error != nil},set:{if !$0 { error = nil }})) { Button("好"){error=nil} } message:{Text(error ?? "")}
    }
    private func libraryAction(_ title:String,subtitle:String,icon:String,color:Color)->some View {
        HStack(spacing:18) {
            Image(systemName:icon).font(.system(size:28)).foregroundStyle(color).frame(width:40)
            VStack(alignment:.leading,spacing:6) {
                Text(title).font(.title3.bold())
                Text(subtitle).font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName:"arrow.right").foregroundStyle(.secondary)
        }.padding(24).frame(maxWidth:.infinity).background(color.opacity(0.08),in:RoundedRectangle(cornerRadius:16))
    }
}
