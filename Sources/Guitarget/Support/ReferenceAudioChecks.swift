import AppKit
import Foundation
import GuitarCore
import GuitarAudio

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
    let audio = AudioService.shared
    defer { player.stop(); audio.stop() }
    let firstOwner = "reference-check.first", secondOwner = "reference-check.second"
    try expect(player.prepare(id: id, url: reopenedAudio, owner: firstOwner), "选择原声音频失败：\(player.error ?? "未知错误")")
    try expect(!player.isPlaying && player.entryID == id && player.ownerID == firstOwner && player.currentTime == 0,
               "选择原声音频时意外开始播放或丢失窗口归属")
    player.play()
    try expect(player.error == nil && player.isPlaying && player.entryID == id, "原声音频播放器未开始播放：\(player.error ?? "未知错误")")
    try expect(player.duration > 0.5, "原声音频测试输入必须超过半秒")
    // Allow the UI clock to publish at least one native playback update.
    try await Task.sleep(for: .milliseconds(300))
    try expect(player.isPlaying && player.currentTime > 0, "原声音频播放时钟没有推进")
    player.pause()
    try expect(!player.isPlaying && player.entryID == id, "原声音频暂停未保留当前曲目")
    let middle = player.duration / 2
    player.seek(middle)
    try expect(abs(player.currentTime - middle) < 0.05 && !player.isPlaying, "暂停时定位原声音频失败")
    player.setRate(0.75)
    try expect(player.rate == 0.75, "原声音频没有接受播放变速")
    player.play()
    // A silent score still exercises the real shared output engine and arbiter.
    audio.preview(notes: [], owner: "reference-check.synth")
    try expect(audio.isPlaying && !player.isPlaying && player.entryID == id && player.ownerID == firstOwner,
               "曲谱试听没有立即暂停原声并保留其曲目和窗口归属")
    try expect(abs(player.currentTime - middle) < 0.15, "其他音频接管时丢失了原声位置")
    player.play()
    try expect(player.isPlaying && !audio.isPlaying && audio.isPaused,
               "原声恢复时没有立即暂停曲谱试听")
    audio.resume()
    try expect(audio.isPlaying && !player.isPlaying, "已暂停的曲谱恢复时与原声同时播放")
    player.restart()
    try expect(player.isPlaying && !audio.isPlaying && player.currentTime < 0.1,
               "原声重新播放时没有回到开头或暂停曲谱")
    player.seek(middle)
    try expect(player.prepare(id: id, url: reopenedAudio, owner: secondOwner), "原声无法转移到第二个窗口")
    try expect(!player.isPlaying && player.ownerID == secondOwner && abs(player.currentTime - middle) < 0.15,
               "切换窗口归属时没有暂停并保留原声位置")
    player.toggle(id: id, url: reopenedAudio, owner: secondOwner)
    try expect(player.isPlaying, "同一窗口的原声切换按钮没有恢复播放")
    player.toggle(id: id, url: reopenedAudio, owner: secondOwner)
    try expect(!player.isPlaying, "同一窗口的原声切换按钮没有暂停播放")
    player.setRate(1)
    player.seek(max(0, player.duration - 0.08))
    try expect(player.play(), "原声临近结尾时无法恢复播放：\(player.error ?? "未知错误")")
    // AVAudioPlayer must drain its output buffer, then the 100 ms presentation
    // timer must observe completion. Wait for that condition within a bound;
    // a fixed 250 ms sleep depends on audio-device latency and main-run-loop load.
    let endDeadline = ProcessInfo.processInfo.systemUptime + 3
    while (player.isPlaying || abs(player.currentTime - player.duration) >= 0.05),
          ProcessInfo.processInfo.systemUptime < endDeadline {
        try await Task.sleep(for: .milliseconds(50))
    }
    try expect(!player.isPlaying && abs(player.currentTime - player.duration) < 0.05,
               "原声播放结束后没有保留终点进度：isPlaying=\(player.isPlaying)，currentTime=\(player.currentTime)，duration=\(player.duration)，rate=\(player.rate)，error=\(player.error ?? "无")")
    player.play()
    try expect(player.isPlaying && player.currentTime < 0.1, "原声播放结束后无法从开头重新播放")
    player.stop()
    try expect(!player.isPlaying && player.entryID == nil && player.ownerID == nil && player.currentTime == 0 && player.duration == 0,
               "原声音频停止后状态没有清空")

    let nativeMusicURL = URL(string: "musics://music.apple.com")!
    guard let musicApp = NSWorkspace.shared.urlForApplication(toOpen: nativeMusicURL) else {
        throw ReferenceAudioCheckFailure(message: "这台 Mac 未注册 Apple Music 原生链接处理应用")
    }
    try expect(musicApp.lastPathComponent == "Music.app" && Bundle(url: musicApp)?.bundleIdentifier == "com.apple.Music",
               "Apple Music 原生链接没有指向系统音乐应用")
    let sourceAfterCheck = try Data(contentsOf: sourceURL)
    try expect(sourceAfterCheck == sourceData, "原声音频检查改变了提供的源文件")
    return "原声音频：绑定后删除导入副本仍可重开；选择不自动播放；时钟、暂停、定位、变速、结束与重播通过；原声与曲谱互斥且接管保留位置；跨窗口切换会暂停；Apple Music 原生链接指向 Music.app；源文件保持一致"
}
