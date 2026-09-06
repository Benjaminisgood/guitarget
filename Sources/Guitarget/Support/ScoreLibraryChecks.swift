import Foundation
import GuitarCore

@MainActor
func runScoreLibraryChecks() throws -> String {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("guitarget app library \(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = ScoreLibraryStore(rootURL: root)
    guard store.entries.count == 6, store.error == nil else {
        throw LibraryUIError("首次曲库初始化失败：\(store.entries.count) 份，\(store.error ?? "无错误信息")")
    }
    let id = store.entries[0].id
    let url = try store.scoreURL(for: id)
    guard store.entry(for: url)?.id == id else { throw LibraryUIError("曲库文档路径匹配失败") }
    try Data("broken".utf8).write(to: url)
    store.remove(id)
    guard store.entries.count == 5, store.error == nil else { throw LibraryUIError("无法移除损坏的曲库条目") }
    let reopened = ScoreLibraryStore(rootURL: root)
    guard reopened.entries.count == 5, reopened.error == nil else { throw LibraryUIError("重新打开曲库不应重新添加已移除曲目") }
    return "曲库：首次加入六份练习谱、文档匹配、损坏条目移除及重启持久化"
}
