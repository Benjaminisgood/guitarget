import AppKit
import Foundation
import GuitarCore

private struct ReferenceAudioCheckFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// Exercise managed local attachments and native playback without using the user's library.
@MainActor
func runReferenceAudioChecks(sourceURL: URL) async throws -> String {
    func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw ReferenceAudioCheckFailure(message: message) }
    }

    let files = FileManager.default
    let sourceData = try Data(contentsOf: sourceURL)
    let scratch = files.temporaryDirectory.appendingPathComponent("Guitarget-ReferenceAudioCheck-\(UUID().uuidString)", isDirectory: true)
    try files.createDirectory(at: scratch, withIntermediateDirectories: true)
    defer { try? files.removeItem(at: scratch) }

    let incoming = scratch.appendingPathComponent("incoming.wav")
    try files.copyItem(at: sourceURL, to: incoming)
    let libraryRoot = scratch.appendingPathComponent("Library", isDirectory: true)
    let store = ScoreLibraryStore(rootURL: libraryRoot)
    try expect(store.isAvailable && store.error == nil, "原声音频检查无法创建隔离曲库：\(store.error ?? "未知错误")")
    guard let id = store.add(GuitarScore(title: "原声音频原生检查")) else {
        throw ReferenceAudioCheckFailure(message: "原声音频检查无法添加曲谱：\(store.error ?? "未知错误")")
    }
    store.bindAudio(id, from: incoming)
    try expect(store.error == nil, "原声音频绑定失败：\(store.error ?? "未知错误")")
    guard let managedAudio = try store.audioURL(for: id) else {
        throw ReferenceAudioCheckFailure(message: "绑定后曲库没有管理音频文件")
    }
    let canonicalLibraryRoot = libraryRoot.resolvingSymlinksInPath().standardizedFileURL
    try expect(managedAudio.standardizedFileURL.path.hasPrefix(canonicalLibraryRoot.path + "/"), "绑定音频没有复制到隔离曲库")
    try expect(managedAudio.standardizedFileURL != incoming.standardizedFileURL, "绑定音频仍引用导入源文件")

    // Remove only our disposable incoming copy, then reload persisted metadata.
    try files.removeItem(at: incoming)
    let persistedData = try Data(contentsOf: managedAudio)
    try expect(persistedData == sourceData, "删除导入副本后曲库管理的音频内容改变")
    let reopened = ScoreLibraryStore(rootURL: libraryRoot)
    try expect(reopened.error == nil && reopened.entry(id: id) != nil, "重新打开曲库后曲谱或音频绑定丢失")
    guard let reopenedAudio = try reopened.audioURL(for: id) else {
        throw ReferenceAudioCheckFailure(message: "重新打开曲库后无法取得绑定音频")
    }
    try expect(reopenedAudio.standardizedFileURL == managedAudio.standardizedFileURL, "重新打开曲库后绑定音频路径改变")

    let player = ReferenceAudioPlayer(volume: 0)
    defer { player.stop() }
    player.toggle(id: id, url: reopenedAudio)
    try expect(player.error == nil && player.isPlaying && player.entryID == id, "原声音频播放器未开始播放：\(player.error ?? "未知错误")")
    try expect(player.duration > 0.5, "原声音频测试输入必须超过半秒")
    // The UI time publisher runs every 0.2 seconds; allow one update to arrive.
    try await Task.sleep(for: .milliseconds(300))
    try expect(player.isPlaying && player.currentTime > 0, "原声音频播放时钟没有推进")
    player.toggle(id: id, url: reopenedAudio)
    try expect(!player.isPlaying && player.entryID == id, "原声音频暂停未保留当前曲目")
    let middle = player.duration / 2
    player.seek(middle)
    try expect(abs(player.currentTime - middle) < 0.05 && !player.isPlaying, "暂停时定位原声音频失败")
    player.stop()
    try expect(!player.isPlaying && player.entryID == nil && player.currentTime == 0 && player.duration == 0,
               "原声音频停止后状态没有清空")

    let nativeMusicURL = URL(string: "musics://music.apple.com")!
    guard let musicApp = NSWorkspace.shared.urlForApplication(toOpen: nativeMusicURL) else {
        throw ReferenceAudioCheckFailure(message: "这台 Mac 未注册 Apple Music 原生链接处理应用")
    }
    try expect(musicApp.lastPathComponent == "Music.app" && Bundle(url: musicApp)?.bundleIdentifier == "com.apple.Music",
               "Apple Music 原生链接没有指向系统音乐应用")
    let sourceAfterCheck = try Data(contentsOf: sourceURL)
    try expect(sourceAfterCheck == sourceData, "原声音频检查改变了提供的源文件")
    return "原声音频：绑定后删除导入副本仍可重开；静音播放时钟、暂停、定位与停止通过；Apple Music 原生链接指向 Music.app；源文件保持一致"
}
