import XCTest
@testable import GuitarCore

final class LocalScoreLibraryTests: XCTestCase {
    private var temporaryDirectory: URL!
    private var root: URL { temporaryDirectory.appendingPathComponent("library", isDirectory: true) }

    override func setUpWithError() throws {
        temporaryDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("guitarget-library-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try FileManager.default.removeItem(at: temporaryDirectory) }

    private func audio(named name: String = "original.wav", bytes: String = "audio contents") throws -> URL {
        let url = temporaryDirectory.appendingPathComponent(name)
        try Data(bytes.utf8).write(to: url)
        return url
    }

    private func editManifest(_ change: (inout [String: Any]) -> Void) throws {
        let url = root.appendingPathComponent("library.json")
        var value = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        change(&value)
        try JSONSerialization.data(withJSONObject: value, options: .sortedKeys).write(to: url, options: .atomic)
    }

    func testSpacedRootWithoutDirectoryHintImportsAndReloadsStarterScores() throws {
        // Match the default Application Support/Guitarget QA/MyLibrary construction.
        let spacedRoot = temporaryDirectory.appendingPathComponent("Application Support")
            .appendingPathComponent("Guitarget QA").appendingPathComponent("MyLibrary")
        let library = try LocalScoreLibrary(rootURL: spacedRoot)
        for score in StarterScores.all { try library.importScore(score) }
        let reopened = try LocalScoreLibrary(rootURL: spacedRoot)
        XCTAssertEqual(reopened.entries.count, StarterScores.all.count)
        for entry in reopened.entries {
            XCTAssertNoThrow(try reopened.scoreURL(for: entry.id))
        }
    }

    func testImportsIndependentCopiesAndPersistsMetadataAfterReload() throws {
        let library = try LocalScoreLibrary(rootURL: root)
        let score = GuitarScore(title: "基本功")
        let source = temporaryDirectory.appendingPathComponent("practice.guitarget")
        try ScoreIO.encode(score).write(to: source)
        let item = try library.importFile(at: source)
        XCTAssertEqual(item.title, score.title)
        XCTAssertEqual(try ScoreIO.decode(Data(contentsOf: library.scoreURL(for: item.id))), score)
        try library.rename(id: item.id, title: "  每日练习  ")
        try library.setNotes(id: item.id, notes: "先以 60 BPM 练习")
        try FileManager.default.removeItem(at: source)

        let reopened = try LocalScoreLibrary(rootURL: root)
        XCTAssertEqual(reopened.entries.count, 1)
        XCTAssertEqual(reopened.entry(id: item.id)?.title, "每日练习")
        XCTAssertEqual(reopened.entry(id: item.id)?.notes, "先以 60 BPM 练习")
        XCTAssertEqual(reopened.entry(id: item.id)?.createdAt, item.createdAt)
        XCTAssertEqual(try ScoreIO.decode(Data(contentsOf: reopened.scoreURL(for: item.id))), score)
        XCTAssertThrowsError(try reopened.rename(id: item.id, title: " \n "))
        XCTAssertEqual(reopened.entry(id: item.id)?.title, "每日练习")
    }

    func testAudioCopySurvivesOriginalMoveAndDeletionAndCanBeReplaced() throws {
        let library = try LocalScoreLibrary(rootURL: root)
        let item = try library.importScore(GuitarScore())
        let source = try audio()
        try library.bindAudio(id: item.id, from: source)
        let managed = try XCTUnwrap(library.audioURL(for: item.id))
        XCTAssertNotEqual(source, managed)
        let moved = temporaryDirectory.appendingPathComponent("moved.wav")
        try FileManager.default.moveItem(at: source, to: moved)
        try FileManager.default.removeItem(at: moved)
        try library.reload()
        XCTAssertEqual(try Data(contentsOf: managed), Data("audio contents".utf8))
        XCTAssertEqual(library.entry(id: item.id)?.originalAudioName, "original.wav")

        let replacement = try audio(named: "new.mp3", bytes: "new audio")
        try library.bindAudio(id: item.id, from: replacement)
        XCTAssertFalse(FileManager.default.fileExists(atPath: managed.path))
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(library.audioURL(for: item.id))), Data("new audio".utf8))
        try library.unbindAudio(id: item.id)
        XCTAssertNil(try library.audioURL(for: item.id))
        XCTAssertNil(library.entry(id: item.id)?.originalAudioName)
        XCTAssertTrue(FileManager.default.fileExists(atPath: replacement.path))
        XCTAssertNil(try LocalScoreLibrary(rootURL: root).audioURL(for: item.id))
    }

    func testAppleMusicLinksPersistAndRejectOtherHostsAndSchemes() throws {
        let library = try LocalScoreLibrary(rootURL: root)
        let item = try library.importScore(GuitarScore())
        let link = "https://music.apple.com/cn/album/test/123456?i=123457"
        try library.setAppleMusicURL(id: item.id, url: " \(link) ")
        XCTAssertEqual(try LocalScoreLibrary(rootURL: root).entry(id: item.id)?.appleMusicURL, link)
        for invalid in ["file:///tmp/music", "http://music.apple.com/us/song/test/1", "https://music.apple.com.evil.test/us/song/test/1",
                        "https://music.apple.com@evil.test/us/song/test/1", "https://music.apple.com/us/artist/test/1",
                        "https://music.apple.com/", "https://music.apple.com/us/song/test/not-an-id"] {
            XCTAssertThrowsError(try library.setAppleMusicURL(id: item.id, url: invalid))
            XCTAssertEqual(library.entry(id: item.id)?.appleMusicURL, link)
        }
        try library.setAppleMusicURL(id: item.id, url: "https://music.apple.com/us/song/123457")
        try library.setAppleMusicURL(id: item.id, url: nil)
        XCTAssertNil(library.entry(id: item.id)?.appleMusicURL)
    }

    func testRemovalDeletesOnlyManagedCopies() throws {
        let library = try LocalScoreLibrary(rootURL: root)
        let score = GuitarScore(title: "source")
        let sourceScore = temporaryDirectory.appendingPathComponent("source.guitarget")
        try ScoreIO.encode(score).write(to: sourceScore)
        let item = try library.importFile(at: sourceScore)
        let sourceAudio = try audio()
        try library.bindAudio(id: item.id, from: sourceAudio)
        let managedDirectory = try library.scoreURL(for: item.id).deletingLastPathComponent()
        try library.remove(id: item.id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: managedDirectory.path))
        XCTAssertEqual(try ScoreIO.decode(Data(contentsOf: sourceScore)), score)
        XCTAssertEqual(try Data(contentsOf: sourceAudio), Data("audio contents".utf8))
        XCTAssertTrue(try LocalScoreLibrary(rootURL: root).entries.isEmpty)
        XCTAssertThrowsError(try library.scoreURL(for: item.id))
    }

    func testCorruptOrMissingManifestAndScoreAreNeverReseeded() throws {
        let library = try LocalScoreLibrary(rootURL: root)
        let item = try library.importScore(GuitarScore())
        let manifest = root.appendingPathComponent("library.json")
        let original = try Data(contentsOf: manifest)
        try Data("broken".utf8).write(to: manifest)
        XCTAssertThrowsError(try LocalScoreLibrary(rootURL: root))
        XCTAssertThrowsError(try library.reload())
        XCTAssertThrowsError(try library.rename(id: item.id, title: "must not overwrite corrupt manifest"))
        XCTAssertEqual(library.entries, [item])
        XCTAssertEqual(try Data(contentsOf: manifest), Data("broken".utf8))
        try FileManager.default.removeItem(at: manifest)
        XCTAssertThrowsError(try LocalScoreLibrary(rootURL: root))
        XCTAssertThrowsError(try library.reload())
        XCTAssertFalse(FileManager.default.fileExists(atPath: manifest.path))
        try original.write(to: manifest)
        let score = try library.scoreURL(for: item.id)
        try Data("invalid score".utf8).write(to: score)
        XCTAssertEqual(try LocalScoreLibrary(rootURL: root).entries, [item])
        XCTAssertThrowsError(try library.scoreURL(for: item.id))
        XCTAssertEqual(try Data(contentsOf: score), Data("invalid score".utf8))
    }

    func testMissingAudioRemainsVisibleAndCanBeUnboundOrReplaced() throws {
        let library = try LocalScoreLibrary(rootURL: root)
        let item = try library.importScore(GuitarScore())
        let source = try audio()
        try library.bindAudio(id: item.id, from: source)
        try FileManager.default.removeItem(at: XCTUnwrap(library.audioURL(for: item.id)))
        let reopened = try LocalScoreLibrary(rootURL: root)
        XCTAssertEqual(reopened.entries.count, 1)
        XCTAssertEqual(reopened.entry(id: item.id)?.originalAudioName, "original.wav")
        XCTAssertThrowsError(try reopened.audioURL(for: item.id))
        try reopened.unbindAudio(id: item.id)
        XCTAssertNil(try reopened.audioURL(for: item.id))

        try reopened.bindAudio(id: item.id, from: source)
        try FileManager.default.removeItem(at: XCTUnwrap(reopened.audioURL(for: item.id)))
        try reopened.bindAudio(id: item.id, from: source)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(reopened.audioURL(for: item.id))), Data("audio contents".utf8))
    }

    func testMissingScoreDirectoryCanBeRemovedWithoutReseeding() throws {
        let library = try LocalScoreLibrary(rootURL: root)
        let item = try library.importScore(GuitarScore())
        let directory = try library.scoreURL(for: item.id).deletingLastPathComponent()
        try FileManager.default.removeItem(at: directory)
        let reopened = try LocalScoreLibrary(rootURL: root)
        XCTAssertEqual(reopened.entries, [item])
        XCTAssertThrowsError(try reopened.scoreURL(for: item.id))
        try reopened.remove(id: item.id)
        XCTAssertTrue(try LocalScoreLibrary(rootURL: root).entries.isEmpty)
    }

    func testStaleInstanceCannotOverwriteChangesFromAnotherInstance() throws {
        let library = try LocalScoreLibrary(rootURL: root)
        let item = try library.importScore(GuitarScore())
        let other = try LocalScoreLibrary(rootURL: root)
        try other.rename(id: item.id, title: "another window")
        XCTAssertThrowsError(try library.rename(id: item.id, title: "stale change"))
        XCTAssertEqual(library.entry(id: item.id)?.title, item.title)
        try library.reload()
        XCTAssertEqual(library.entry(id: item.id)?.title, "another window")
    }

    func testUntrustedManifestRejectsDuplicateIDsAndAudioPathTraversal() throws {
        let library = try LocalScoreLibrary(rootURL: root)
        let item = try library.importScore(GuitarScore())
        let original = try Data(contentsOf: root.appendingPathComponent("library.json"))
        try editManifest { manifest in
            let entries = manifest["entries"] as! [[String: Any]]
            manifest["entries"] = entries + entries
        }
        XCTAssertThrowsError(try LocalScoreLibrary(rootURL: root))
        try original.write(to: root.appendingPathComponent("library.json"))
        let outside = try audio()
        try editManifest { manifest in
            var entries = manifest["entries"] as! [[String: Any]]
            entries[0]["localAudioFilename"] = "../../original.wav"
            manifest["entries"] = entries
        }
        XCTAssertThrowsError(try library.reload())
        XCTAssertEqual(library.entries, [item])
        XCTAssertEqual(try Data(contentsOf: outside), Data("audio contents".utf8))
    }

    func testSymlinkEntryCannotEscapeLibraryDuringReadOrRemoval() throws {
        let library = try LocalScoreLibrary(rootURL: root)
        let item = try library.importScore(GuitarScore())
        let managed = try library.scoreURL(for: item.id).deletingLastPathComponent()
        let external = temporaryDirectory.appendingPathComponent("external", isDirectory: true)
        try FileManager.default.moveItem(at: managed, to: external)
        try FileManager.default.createSymbolicLink(at: managed, withDestinationURL: external)
        XCTAssertThrowsError(try library.scoreURL(for: item.id))
        XCTAssertThrowsError(try library.remove(id: item.id))
        XCTAssertThrowsError(try library.reload())
        XCTAssertTrue(FileManager.default.fileExists(atPath: external.appendingPathComponent("score.guitarget").path))
        XCTAssertEqual(library.entries, [item])
    }

    func testFailedManifestWritesRollBackImportRemovalAndAudioBinding() throws {
        let library = try LocalScoreLibrary(rootURL: root)
        let item = try library.importScore(GuitarScore())
        let managedScore = try library.scoreURL(for: item.id)
        let manifest = root.appendingPathComponent("library.json")
        let original = try Data(contentsOf: manifest)
        try FileManager.default.removeItem(at: manifest)
        try FileManager.default.createDirectory(at: manifest, withIntermediateDirectories: false)
        XCTAssertThrowsError(try library.importScore(GuitarScore(title: "failed import")))
        XCTAssertThrowsError(try library.rename(id: item.id, title: "failed rename"))
        XCTAssertThrowsError(try library.remove(id: item.id))
        let source = try audio()
        XCTAssertThrowsError(try library.bindAudio(id: item.id, from: source))
        XCTAssertEqual(library.entries, [item])
        XCTAssertTrue(FileManager.default.fileExists(atPath: managedScore.path))
        XCTAssertNil(try library.audioURL(for: item.id))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: managedScore.deletingLastPathComponent().path), ["score.guitarget"])
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: root.path)), Set([item.id.uuidString, "library.json"]))
        try FileManager.default.removeItem(at: manifest)
        try original.write(to: manifest)
        XCTAssertEqual(try LocalScoreLibrary(rootURL: root).entries, [item])
    }
}
