import Foundation

public struct LocalScoreLibraryEntry: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var title: String
    public var createdAt: Date
    public var localAudioFilename: String?
    public var originalAudioName: String?
    public var appleMusicURL: String?
    public var notes: String?

    public init(id: UUID = UUID(), title: String, createdAt: Date = Date(), localAudioFilename: String? = nil,
                originalAudioName: String? = nil, appleMusicURL: String? = nil, notes: String? = nil) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.localAudioFilename = localAudioFilename
        self.originalAudioName = originalAudioName
        self.appleMusicURL = appleMusicURL
        self.notes = notes
    }
}

public enum LocalScoreLibraryError: LocalizedError {
    case entryNotFound
    case invalidTitle
    case unsupportedAudio
    case invalidAppleMusicURL
    case invalidStorage(String)

    public var errorDescription: String? {
        switch self {
        case .entryNotFound: return "这份曲谱已不在我的曲库中。"
        case .invalidTitle: return "曲谱名称不能为空。"
        case .unsupportedAudio: return "请选择 WAV、AIFF、MP3、M4A、AAC、CAF 或 FLAC 音频文件。"
        case .invalidAppleMusicURL: return "请粘贴 https://music.apple.com 上的歌曲或专辑链接。"
        case .invalidStorage(let detail): return "无法读取或保存我的曲库：\(detail)"
        }
    }
}

/// A local collection of independent score and audio copies. Keep one instance per library root.
/// Score documents can be edited directly at `scoreURL(for:)`; metadata updates preserve those edits.
public final class LocalScoreLibrary {
    private struct Manifest: Codable {
        var version = 1
        var entries: [LocalScoreLibraryEntry]
    }

    public let rootURL: URL
    public private(set) var entries: [LocalScoreLibraryEntry] = []
    private let files = FileManager.default
    private static let audioExtensions: Set<String> = ["wav", "wave", "aif", "aiff", "mp3", "m4a", "aac", "caf", "flac", "alac"]
    private var manifestURL: URL { rootURL.appendingPathComponent("library.json") }

    public init(rootURL: URL) throws {
        guard rootURL.isFileURL else { throw LocalScoreLibraryError.invalidStorage("曲库需要本地文件夹。") }
        let requestedRoot = rootURL.standardizedFileURL
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: requestedRoot.path, isDirectory: &isDirectory) {
            guard isDirectory.boolValue else { throw LocalScoreLibraryError.invalidStorage("曲库位置不是文件夹。") }
        } else {
            try FileManager.default.createDirectory(at: requestedRoot, withIntermediateDirectories: true)
        }
        self.rootURL = requestedRoot.resolvingSymlinksInPath().standardizedFileURL
        try checkRoot()
        if files.fileExists(atPath: manifestURL.path) {
            try reload()
        } else {
            let contents = try files.contentsOfDirectory(at: self.rootURL, includingPropertiesForKeys: nil)
            guard contents.isEmpty else { throw LocalScoreLibraryError.invalidStorage("library.json 丢失；现有文件已保留。") }
            try writeManifest([], creating: true)
        }
    }

    public func entry(id: UUID) -> LocalScoreLibraryEntry? { entries.first { $0.id == id } }

    public func reload() throws {
        try checkRoot()
        let manifest = try readManifest()
        try validate(manifest.entries)
        entries = manifest.entries
    }

    @discardableResult
    public func importScore(_ score: GuitarScore, title: String? = nil) throws -> LocalScoreLibraryEntry {
        let data = try ScoreIO.encode(score)
        let item = LocalScoreLibraryEntry(title: try validTitle(title ?? score.title))
        try checkRoot()
        let directory = directoryURL(item.id)
        try files.createDirectory(at: directory, withIntermediateDirectories: false)
        do {
            try data.write(to: directory.appendingPathComponent("score.guitarget"), options: .atomic)
            try writeManifest(entries + [item])
        } catch {
            try? files.removeItem(at: directory)
            throw error
        }
        return item
    }

    @discardableResult
    public func importFile(at url: URL) throws -> LocalScoreLibraryEntry {
        try importScore(ScoreIO.decode(Data(contentsOf: url)))
    }

    public func rename(id: UUID, title: String) throws {
        var updated = try requiredEntry(id)
        updated.title = try validTitle(title)
        try replace(updated)
    }

    public func setNotes(id: UUID, notes: String?) throws {
        var updated = try requiredEntry(id)
        updated.notes = nonempty(notes)
        try replace(updated)
    }

    public func remove(id: UUID) throws {
        _ = try requiredEntry(id)
        try checkRoot()
        if !pathExists(directoryURL(id)) {
            try writeManifest(entries.filter { $0.id != id })
            return
        }
        let directory = try checkedDirectory(id)
        // Stage removal inside the managed root so a failed manifest write can restore the entry.
        let removedDirectory = rootURL.appendingPathComponent(".removed-\(UUID().uuidString)", isDirectory: true)
        try files.moveItem(at: directory, to: removedDirectory)
        do {
            try writeManifest(entries.filter { $0.id != id })
        } catch {
            do { try files.moveItem(at: removedDirectory, to: directory) }
            catch { throw LocalScoreLibraryError.invalidStorage("移除未完成，曲谱保留在 \(removedDirectory.lastPathComponent)。") }
            throw error
        }
        // The manifest change is complete; an OS cleanup failure must not report a failed removal.
        try? files.removeItem(at: removedDirectory)
    }

    public func bindAudio(id: UUID, from url: URL) throws {
        var updated = try requiredEntry(id)
        guard url.isFileURL, Self.audioExtensions.contains(url.pathExtension.lowercased()) else {
            throw LocalScoreLibraryError.unsupportedAudio
        }
        let source = url.resolvingSymlinksInPath().standardizedFileURL
        try checkRegularFile(source)
        let directory = try checkedDirectory(id)
        let previousAudio = try existingAudioForCleanup(updated)
        let filename = "audio-\(UUID().uuidString).\(url.pathExtension.lowercased())"
        let destination = directory.appendingPathComponent(filename)
        updated.localAudioFilename = filename
        updated.originalAudioName = url.lastPathComponent
        do {
            try files.copyItem(at: source, to: destination)
            try replace(updated)
        } catch {
            try? files.removeItem(at: destination)
            throw error
        }
        if let previousAudio { try? files.removeItem(at: previousAudio) }
    }

    public func unbindAudio(id: UUID) throws {
        var updated = try requiredEntry(id)
        let previousAudio = try existingAudioForCleanup(updated)
        updated.localAudioFilename = nil
        updated.originalAudioName = nil
        try replace(updated)
        if let previousAudio { try? files.removeItem(at: previousAudio) }
    }

    public func setAppleMusicURL(id: UUID, url: String?) throws {
        var updated = try requiredEntry(id)
        updated.appleMusicURL = try Self.validAppleMusicURL(url)
        try replace(updated)
    }

    public func scoreURL(for id: UUID) throws -> URL {
        _ = try requiredEntry(id)
        let url = try checkedDirectory(id).appendingPathComponent("score.guitarget")
        try checkRegularFile(url)
        _ = try ScoreIO.decode(Data(contentsOf: url))
        return url
    }

    public func audioURL(for id: UUID) throws -> URL? {
        let item = try requiredEntry(id)
        let directory = try checkedDirectory(id)
        guard let filename = item.localAudioFilename else { return nil }
        try validateAudioFilename(filename)
        let url = directory.appendingPathComponent(filename)
        try checkRegularFile(url)
        return url
    }

    private func replace(_ item: LocalScoreLibraryEntry) throws {
        guard let index = entries.firstIndex(where: { $0.id == item.id }) else { throw LocalScoreLibraryError.entryNotFound }
        var proposed = entries
        proposed[index] = item
        try writeManifest(proposed)
    }

    private func writeManifest(_ proposed: [LocalScoreLibraryEntry], creating: Bool = false) throws {
        try checkRoot()
        if !creating {
            let current = try readManifest()
            guard current.entries == entries else {
                throw LocalScoreLibraryError.invalidStorage("曲库已被其他窗口修改，请刷新曲库后重试。")
            }
        }
        try validate(proposed)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(Manifest(entries: proposed)).write(to: manifestURL, options: .atomic)
        entries = proposed
    }

    private func readManifest() throws -> Manifest {
        try checkRegularFile(manifestURL)
        let manifest: Manifest
        do {
            manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: manifestURL))
        } catch {
            throw LocalScoreLibraryError.invalidStorage("library.json 内容损坏：\(error.localizedDescription)")
        }
        guard manifest.version == 1 else { throw LocalScoreLibraryError.invalidStorage("不支持曲库版本 \(manifest.version)。") }
        return manifest
    }

    private func validate(_ proposed: [LocalScoreLibraryEntry]) throws {
        guard Set(proposed.map(\.id)).count == proposed.count else {
            throw LocalScoreLibraryError.invalidStorage("曲库存在重复的曲谱 ID。")
        }
        for item in proposed {
            _ = try validTitle(item.title)
            guard item.createdAt.timeIntervalSinceReferenceDate.isFinite else {
                throw LocalScoreLibraryError.invalidStorage("曲谱创建时间无效。")
            }
            _ = try Self.validAppleMusicURL(item.appleMusicURL)
            if let filename = item.localAudioFilename {
                try validateAudioFilename(filename)
            } else if item.originalAudioName != nil {
                throw LocalScoreLibraryError.invalidStorage("音频信息不完整。")
            }
            // Keep missing or damaged media visible so the user can remove or repair its entry.
            // Existing managed paths must still be real directories/files, never symbolic links.
            if pathExists(directoryURL(item.id)) {
                let directory = try checkedDirectory(item.id)
                let score = directory.appendingPathComponent("score.guitarget")
                if pathExists(score) { try checkRegularFile(score) }
                if let filename = item.localAudioFilename {
                    let audio = directory.appendingPathComponent(filename)
                    if pathExists(audio) { try checkRegularFile(audio) }
                }
            }
        }
    }

    private func existingAudioForCleanup(_ item: LocalScoreLibraryEntry) throws -> URL? {
        try checkRoot()
        guard let filename = item.localAudioFilename else { return nil }
        try validateAudioFilename(filename)
        guard pathExists(directoryURL(item.id)) else { return nil }
        let url = try checkedDirectory(item.id).appendingPathComponent(filename)
        guard pathExists(url) else { return nil }
        try checkRegularFile(url)
        return url
    }

    private func pathExists(_ url: URL) -> Bool {
        // attributesOfItem observes dangling symlinks as well as reachable regular files.
        (try? files.attributesOfItem(atPath: url.path)) != nil
    }

    private func requiredEntry(_ id: UUID) throws -> LocalScoreLibraryEntry {
        guard let item = entry(id: id) else { throw LocalScoreLibraryError.entryNotFound }
        return item
    }

    private func directoryURL(_ id: UUID) -> URL { rootURL.appendingPathComponent(id.uuidString, isDirectory: true) }

    private func checkRoot() throws {
        let values = try rootURL.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true,
              rootURL.resolvingSymlinksInPath().standardizedFileURL.path == rootURL.path else {
            throw LocalScoreLibraryError.invalidStorage("曲库文件夹已移动或被替换。")
        }
    }

    private func checkedDirectory(_ id: UUID) throws -> URL {
        try checkRoot()
        let url = directoryURL(id)
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        // File URLs can differ only in their directory hint/trailing slash. Compare canonical
        // filesystem paths so a root from appendingPathComponent("MyLibrary") is accepted too.
        guard values.isDirectory == true, values.isSymbolicLink != true,
              url.resolvingSymlinksInPath().standardizedFileURL.deletingLastPathComponent().path == rootURL.path else {
            throw LocalScoreLibraryError.invalidStorage("曲谱文件夹不在受管理的曲库内。")
        }
        return url
    }

    private func checkRegularFile(_ url: URL) throws {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw LocalScoreLibraryError.invalidStorage("\(url.lastPathComponent) 不是可读取的普通文件。")
        }
    }

    private func validateAudioFilename(_ filename: String) throws {
        let extensionURL = URL(fileURLWithPath: filename)
        let basename = extensionURL.deletingPathExtension().lastPathComponent
        guard !filename.contains("/"), !filename.contains("\\"),
              filename == extensionURL.lastPathComponent,
              Self.audioExtensions.contains(extensionURL.pathExtension),
              basename.hasPrefix("audio-"), UUID(uuidString: String(basename.dropFirst(6))) != nil else {
            throw LocalScoreLibraryError.invalidStorage("音频文件名无效。")
        }
    }

    private func validTitle(_ title: String) throws -> String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw LocalScoreLibraryError.invalidTitle }
        return trimmed
    }

    private func nonempty(_ text: String?) -> String? {
        guard let value = text?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }

    private static func validAppleMusicURL(_ text: String?) throws -> String? {
        guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        guard let components = URLComponents(string: text), components.scheme?.lowercased() == "https",
              components.host?.lowercased() == "music.apple.com", components.user == nil,
              components.password == nil, components.port == nil, let url = components.url else {
            throw LocalScoreLibraryError.invalidAppleMusicURL
        }
        let path = components.path.split(separator: "/").map(String.init)
        guard path.contains("song") || path.contains("album"),
              let identifier = path.last, !identifier.isEmpty,
              identifier.unicodeScalars.allSatisfy({ (48...57).contains($0.value) }) else {
            throw LocalScoreLibraryError.invalidAppleMusicURL
        }
        return url.absoluteString
    }
}
