import SwiftUI
import AppKit
import AVFoundation
import GuitarCore

@MainActor
final class ScoreLibraryStore: ObservableObject {
    @Published private(set) var entries: [LocalScoreLibraryEntry] = []
    @Published var error: String?
    let referenceAudio = ReferenceAudioPlayer()
    let rootURL: URL
    private var storage: LocalScoreLibrary?

    init(rootURL: URL? = nil) {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        // A QA bundle gets its own library, away from the user's saved scores.
        let folder = Bundle.main.bundleIdentifier == "com.guitarget.qa" ? "Guitarget QA" : "Guitarget"
        self.rootURL = rootURL ?? support.appendingPathComponent(folder).appendingPathComponent("MyLibrary")
        let isNew = !FileManager.default.fileExists(atPath: self.rootURL.appendingPathComponent("library.json").path)
        do {
            let library = try LocalScoreLibrary(rootURL: self.rootURL)
            storage = library
            if isNew {
                for score in StarterScores.all { _ = try library.importScore(score) }
            }
            entries = library.entries
        } catch { self.error = error.localizedDescription }
    }

    var isAvailable: Bool { storage != nil }
    func entry(for fileURL: URL?) -> LocalScoreLibraryEntry? {
        guard let fileURL else { return nil }
        return entries.first { entry in
            managedScoreURL(for: entry.id).standardizedFileURL == fileURL.standardizedFileURL
        }
    }
    private func managedScoreURL(for id: UUID) -> URL {
        (storage?.rootURL ?? rootURL).appendingPathComponent(id.uuidString).appendingPathComponent("score.guitarget")
    }
    func entry(id: UUID?) -> LocalScoreLibraryEntry? { entries.first { $0.id == id } }
    func scoreURL(for id: UUID) throws -> URL { try requireStorage().scoreURL(for: id) }
    func audioURL(for id: UUID) throws -> URL? { try requireStorage().audioURL(for: id) }

    @discardableResult
    func add(_ score: GuitarScore) -> UUID? {
        do {
            let entry = try requireStorage().importScore(score)
            refresh(); return entry.id
        } catch { self.error = error.localizedDescription; return nil }
    }

    @discardableResult
    func importFiles(_ urls: [URL]) -> UUID? {
        var lastID: UUID?
        var failures: [String] = []
        for url in urls {
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            do { lastID = try requireStorage().importFile(at: url).id }
            catch { failures.append("\(url.lastPathComponent)：\(error.localizedDescription)") }
        }
        refresh()
        if !failures.isEmpty { error = failures.joined(separator: "\n") }
        return lastID
    }

    func rename(_ id: UUID, title: String) {
        perform { try $0.rename(id: id, title: title) }
    }
    func remove(_ id: UUID) {
        do {
            let url = managedScoreURL(for: id)
            if NSDocumentController.shared.document(for: url) != nil {
                error = "这份曲谱正在编辑。请先保存并关闭它的文档窗口，再从曲库移除。"
                return
            }
            if referenceAudio.entryID == id { referenceAudio.stop() }
            try requireStorage().remove(id: id)
            refresh()
        } catch { self.error = error.localizedDescription }
    }
    func bindAudio(_ id: UUID, from url: URL) {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        do {
            // Check decodability before replacing a working attachment.
            let probe = try AVAudioPlayer(contentsOf: url)
            guard probe.duration > 0 else { throw LibraryUIError("音频没有可播放的内容。") }
            try requireStorage().bindAudio(id: id, from: url)
            if referenceAudio.entryID == id { referenceAudio.stop() }
            refresh()
        } catch { self.error = "无法绑定音频：\(error.localizedDescription)" }
    }
    func unbindAudio(_ id: UUID) {
        perform { try $0.unbindAudio(id: id) }
        if referenceAudio.entryID == id { referenceAudio.stop() }
    }
    func bindAppleMusic(_ id: UUID, url: String) {
        perform { try $0.setAppleMusicURL(id: id, url: url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : url) }
    }
    func openAppleMusic(_ entry: LocalScoreLibraryEntry) {
        guard let link = entry.appleMusicURL, var components = URLComponents(string: link),
              components.scheme?.lowercased() == "https", components.host?.lowercased() == "music.apple.com" else { return }
        // Music.app declares musics: as its native secure URL scheme.
        components.scheme = "musics"
        components.host = "music.apple.com"
        guard let url = components.url, NSWorkspace.shared.open(url) else {
            error = "无法打开“音乐”应用。请确认这台 Mac 已安装 Apple Music。"; return
        }
    }
    func reload() {
        perform { try $0.reload() }
    }
    private func requireStorage() throws -> LocalScoreLibrary {
        guard let storage else { throw LibraryUIError("曲库尚未成功载入。请检查本地目录后重新打开应用。") }
        return storage
    }
    private func perform(_ operation: (LocalScoreLibrary) throws -> Void) {
        do { try operation(requireStorage()); refresh() }
        catch { self.error = error.localizedDescription }
    }
    private func refresh() { entries = storage?.entries ?? [] }
}

struct LibraryUIError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
