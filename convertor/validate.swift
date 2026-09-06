import Foundation

/// JSONL adapter around the exact document reader used by Guitarget.
/// Build with build_validator.sh; this file deliberately does not reimplement validation.
@main
enum GuitargetValidator {
    private struct Result: Encodable {
        var id: String?
        var path: String?
        var valid = false
        var errors: [String] = []
        var warnings: [String] = []
    }

    private struct RequestError: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }

    static func main() {
        let arguments = Array(CommandLine.arguments.dropFirst())
        do {
            if arguments == ["--stdin-jsonl"] {
                // readLine returns after each request, even while the sending process stays open.
                while let line = readLine(strippingNewline: true) {
                    try emit(validateRequest(Data(line.utf8)))
                }
            } else if arguments.count == 2, arguments[0] == "--paths-jsonl" {
                let manifest = URL(fileURLWithPath: arguments[1]).standardizedFileURL
                let handle = try FileHandle(forReadingFrom: manifest)
                defer { try? handle.close() }
                try forEachLine(in: handle) { line in
                    try emit(validatePath(line, relativeTo: manifest.deletingLastPathComponent()))
                }
            } else {
                writeError("Usage: validate --stdin-jsonl | --paths-jsonl <manifest.jsonl>\n")
                exit(64)
            }
        } catch {
            writeError("validate: \(error.localizedDescription)\n")
            exit(2)
        }
    }

    private static func validateRequest(_ line: Data) -> Result {
        var result = Result(id: "")
        do {
            let request = try object(from: line)
            guard let id = request["id"] as? String else { throw RequestError("Request requires a string id.") }
            result.id = id
            guard let score = request["score"] as? [String: Any] else { throw RequestError("Request requires a score JSON object.") }
            let data = try JSONSerialization.data(withJSONObject: score, options: [.fragmentsAllowed])
            validate(data, into: &result)
        } catch { result.errors = [error.localizedDescription] }
        return result
    }

    private static func validatePath(_ line: Data, relativeTo directory: URL) -> Result {
        var result = Result(path: "")
        do {
            let request = try object(from: line)
            guard let path = request["path"] as? String, !path.isEmpty else {
                throw RequestError("Manifest entry requires a nonempty string path.")
            }
            result.path = path
            let url = URL(fileURLWithPath: path, relativeTo: directory).standardizedFileURL
            validate(try Data(contentsOf: url), into: &result)
        } catch { result.errors = [error.localizedDescription] }
        return result
    }

    private static func validate(_ data: Data, into result: inout Result) {
        do {
            // Every accepted document goes through the app's full decoder and validator.
            let score = try ScoreIO.decode(data)
            result.valid = true
            // ScoreIO.decode discards warnings. In the current validator only ties can warn;
            // avoid a redundant full validation for documents with no ties.
            let hasTies = score.measures.contains { measure in
                measure.voices.contains { track in
                    track.events.contains { event in event.notes.contains { $0.tieToNext } }
                }
            }
            if hasTies {
                result.warnings = ScoreValidator.validate(score)
                    .filter { $0.severity == .warning }.map(describe)
            }
        } catch ScoreFileError.invalid(let issues) {
            result.errors = issues.filter { $0.severity == .error }.map(describe)
            result.warnings = issues.filter { $0.severity == .warning }.map(describe)
        } catch {
            result.errors = [error.localizedDescription]
        }
    }

    private static func describe(_ issue: ScoreIssue) -> String {
        guard let measure = issue.measureIndex else { return issue.message }
        let voice = issue.voice.map { " / \($0.rawValue)" } ?? ""
        return "小节 \(measure + 1)\(voice)：\(issue.message)"
    }

    private static func object(from data: Data) throws -> [String: Any] {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw RequestError("Each JSONL line must be a JSON object.")
        }
        return object
    }

    private static func emit(_ result: Result) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var line = try encoder.encode(result)
        line.append(0x0A)
        // Unbuffered line writes keep this suitable for a long-running subprocess.
        try FileHandle.standardOutput.write(contentsOf: line)
    }

    private static func writeError(_ message: String) {
        try? FileHandle.standardError.write(contentsOf: Data(message.utf8))
    }

    private static func forEachLine(in handle: FileHandle, body: (Data) throws -> Void) throws {
        var pending = Data()
        while let chunk = try handle.read(upToCount: 64 * 1024), !chunk.isEmpty {
            pending.append(chunk)
            var lineStart = pending.startIndex
            while let newline = pending[lineStart...].firstIndex(of: 0x0A) {
                try body(Data(pending[lineStart..<newline]))
                lineStart = pending.index(after: newline)
            }
            if lineStart != pending.startIndex { pending = Data(pending[lineStart...]) }
        }
        if !pending.isEmpty { try body(pending) }
    }
}
