import Foundation
import Combine

final class DocStore: ObservableObject {

    struct LoadedArticle: Identifiable {
        let id: String
        let meta: DocArticle
        let sectionTitle: String
        let blocks: [MDBlock]
        let headings: [MDHeading]
        let plain: String
        let readingMinutes: Int
    }

    struct SnippetSegment: Equatable {
        let text: String
        let isMatch: Bool
    }

    struct SearchHit: Identifiable {
        let id: String
        let rank: Int
        let order: Int
        let article: DocArticle
        let sectionTitle: String
        let readingMinutes: Int
        let segments: [SnippetSegment]
        let matchCount: Int
        let matchedTitle: Bool
    }

    @Published private(set) var articles: [LoadedArticle] = []
    private var index: [String: LoadedArticle] = [:]
    private var order: [String: Int] = [:]

    init() {
        load()
    }

    func load() {
        var loaded: [LoadedArticle] = []
        for meta in DocCatalog.articles {
            guard let url = Bundle.main.url(forResource: meta.file, withExtension: "md"),
                  let text = try? String(contentsOf: url, encoding: .utf8) else {
                continue
            }
            let blocks = MarkdownParser.parse(text)
            let plain = MarkdownParser.plainText(blocks)
            loaded.append(LoadedArticle(
                id: meta.id,
                meta: meta,
                sectionTitle: DocCatalog.sectionTitle(for: meta.id),
                blocks: blocks,
                headings: MarkdownParser.headings(in: blocks),
                plain: plain,
                readingMinutes: Self.readingMinutes(for: plain)
            ))
        }
        articles = loaded
        index = Dictionary(uniqueKeysWithValues: loaded.map { ($0.id, $0) })
        order = Dictionary(uniqueKeysWithValues: loaded.enumerated().map { ($1.id, $0) })
    }

    func article(_ id: String) -> LoadedArticle? {
        index[id]
    }

    func readingMinutes(_ id: String) -> Int? {
        index[id]?.readingMinutes
    }

    var totalReadingMinutes: Int {
        articles.reduce(0) { $0 + $1.readingMinutes }
    }

    var totalCharacters: Int {
        articles.reduce(0) { $0 + $1.plain.count }
    }

    func search(_ query: String) -> [SearchHit] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return [] }
        var hits: [SearchHit] = []
        for article in articles {
            var rank = 9
            var matchedTitle = false
            if article.meta.title.range(of: q, options: .caseInsensitive) != nil {
                rank = 0
                matchedTitle = true
            } else if article.headings.contains(where: { $0.text.range(of: q, options: .caseInsensitive) != nil }) {
                rank = 1
            }
            let plainRange = article.plain.range(of: q, options: .caseInsensitive)
            if plainRange != nil, rank == 9 {
                rank = 2
            }
            guard rank < 9 else { continue }
            let count = countOccurrences(of: q, in: article.plain) + (matchedTitle ? 1 : 0)
            hits.append(SearchHit(
                id: article.id,
                rank: rank,
                order: order[article.id] ?? 99,
                article: article.meta,
                sectionTitle: article.sectionTitle,
                readingMinutes: article.readingMinutes,
                segments: snippetSegments(plain: article.plain, range: plainRange, fallback: article.meta.summary),
                matchCount: count,
                matchedTitle: matchedTitle
            ))
        }
        return hits.sorted { lhs, rhs in
            if lhs.rank != rhs.rank { return lhs.rank < rhs.rank }
            return lhs.order < rhs.order
        }
    }

    private func snippetSegments(plain: String, range: Range<String.Index>?, fallback: String) -> [SnippetSegment] {
        guard let range else {
            return [SnippetSegment(text: fallback, isMatch: false)]
        }
        let lowerOffset = plain.distance(from: plain.startIndex, to: range.lowerBound)
        let upperOffset = plain.distance(from: plain.startIndex, to: range.upperBound)
        let cleaned = plain.replacingOccurrences(of: "\n", with: " ")
        guard let lower = cleaned.index(cleaned.startIndex, offsetBy: lowerOffset, limitedBy: cleaned.endIndex),
              let upper = cleaned.index(cleaned.startIndex, offsetBy: upperOffset, limitedBy: cleaned.endIndex) else {
            return [SnippetSegment(text: fallback, isMatch: false)]
        }
        let matchRange = lower..<upper
        let beforeWindow = 22
        let afterWindow = 42
        let start = cleaned.index(matchRange.lowerBound, offsetBy: -beforeWindow, limitedBy: cleaned.startIndex) ?? cleaned.startIndex
        let end = cleaned.index(matchRange.upperBound, offsetBy: afterWindow, limitedBy: cleaned.endIndex) ?? cleaned.endIndex
        var segments: [SnippetSegment] = []
        let prefix = String(cleaned[start..<matchRange.lowerBound])
        let suffix = String(cleaned[matchRange.upperBound..<end])
        if !prefix.isEmpty {
            segments.append(SnippetSegment(text: (start == cleaned.startIndex ? "" : "…") + prefix, isMatch: false))
        } else if start != cleaned.startIndex {
            segments.append(SnippetSegment(text: "…", isMatch: false))
        }
        segments.append(SnippetSegment(text: String(cleaned[matchRange]), isMatch: true))
        if !suffix.isEmpty {
            segments.append(SnippetSegment(text: suffix + (end == cleaned.endIndex ? "" : "…"), isMatch: false))
        } else if end != cleaned.endIndex {
            segments.append(SnippetSegment(text: "…", isMatch: false))
        }
        return segments
    }

    private func countOccurrences(of query: String, in text: String) -> Int {
        var count = 0
        var searchStart = text.startIndex
        while searchStart < text.endIndex,
              let r = text.range(of: query, options: .caseInsensitive, range: searchStart..<text.endIndex) {
            count += 1
            guard !r.isEmpty else { break }
            searchStart = r.upperBound
        }
        return count
    }

    static func readingMinutes(for text: String) -> Int {
        var cjk = 0
        var words = 0
        var inWord = false
        for scalar in text.unicodeScalars {
            if MarkdownParser.isCJKScalar(scalar) {
                cjk += 1
                inWord = false
            } else if CharacterSet.alphanumerics.contains(scalar) {
                if !inWord {
                    words += 1
                    inWord = true
                }
            } else {
                inWord = false
            }
        }
        let total = cjk + words
        return max(1, Int((Double(total) / 420.0).rounded(.up)))
    }
}
