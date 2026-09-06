import SwiftUI
import UniformTypeIdentifiers
import GuitarCore

extension UTType {
    static let guitarget = UTType(exportedAs: "com.guitarget.score", conformingTo: .json)
}

/// The value owned by DocumentGroup. Failed reads never modify the original file.
struct GuitarScoreDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.guitarget, .json] }
    static var writableContentTypes: [UTType] { [.guitarget] }
    var score: GuitarScore
    init(score: GuitarScore = GuitarScore()) { self.score = score }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else { throw CocoaError(.fileReadCorruptFile) }
        score = try ScoreIO.decode(data)
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: try ScoreIO.encode(score))
    }
}
