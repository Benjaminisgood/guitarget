import Foundation

public enum MDAlignment: Equatable {
    case leading, center, trailing
}

public indirect enum MDInline: Equatable {
    case text(String)
    case code(String)
    case bold([MDInline])
    case italic([MDInline])
    case link([MDInline], url: String)
}

public struct MDListItem: Equatable {
    public var content: [MDInline]
    public var children: [MDListItem]
    public var childrenOrdered: Bool

    public init(content: [MDInline], children: [MDListItem], childrenOrdered: Bool) {
        self.content = content
        self.children = children
        self.childrenOrdered = childrenOrdered
    }
}

public indirect enum MDBlock: Equatable {
    case heading(level: Int, content: [MDInline], anchor: String)
    case paragraph([MDInline])
    case codeBlock(language: String?, code: String)
    case bulletList([MDListItem])
    case orderedList([MDListItem])
    case table(header: [[MDInline]], alignments: [MDAlignment], rows: [[[MDInline]]])
    case quote([MDBlock])
    case thematicBreak
}

public struct MDHeading: Identifiable, Equatable {
    public var id: String { anchor }
    public let level: Int
    public let text: String
    public let anchor: String
}

private struct RawListItem {
    var indent: Int
    var ordered: Bool
    var text: String
}

public enum MarkdownParser {

    public static func parse(_ source: String) -> [MDBlock] {
        let lines = source.components(separatedBy: "\n")
        var blocks: [MDBlock] = []
        var anchorCounter = 0
        var i = 0
        while i < lines.count {
            let raw = lines[i]
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { i += 1; continue }

            if trimmed.hasPrefix("```") {
                let language = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                var codeLines: [String] = []
                i += 1
                while i < lines.count, !lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                    codeLines.append(lines[i])
                    i += 1
                }
                i = min(i + 1, lines.count)
                blocks.append(.codeBlock(language: language.isEmpty ? nil : language,
                                         code: codeLines.joined(separator: "\n")))
                continue
            }

            if trimmed.hasPrefix("#") {
                let level = trimmed.prefix(while: { $0 == "#" }).count
                let rest = trimmed.dropFirst(level)
                if level >= 1, level <= 6, rest.isEmpty || rest.first == " " {
                    let text = rest.trimmingCharacters(in: .whitespaces)
                    blocks.append(.heading(level: level,
                                           content: parseInlines(text),
                                           anchor: "sec-\(anchorCounter)"))
                    anchorCounter += 1
                    i += 1
                    continue
                }
            }

            if trimmed == "---" || trimmed == "***" || trimmed == "___" {
                blocks.append(.thematicBreak)
                i += 1
                continue
            }

            if trimmed.hasPrefix(">") {
                var quoteLines: [String] = []
                while i < lines.count {
                    let t = lines[i].trimmingCharacters(in: .whitespaces)
                    if t.hasPrefix(">") {
                        var content = t.dropFirst()
                        if content.first == " " { content = content.dropFirst() }
                        quoteLines.append(String(content))
                        i += 1
                        continue
                    }
                    if t.isEmpty, i + 1 < lines.count,
                       lines[i + 1].trimmingCharacters(in: .whitespaces).hasPrefix(">") {
                        quoteLines.append("")
                        i += 1
                        continue
                    }
                    break
                }
                blocks.append(.quote(parse(quoteLines.joined(separator: "\n"))))
                continue
            }

            if trimmed.hasPrefix("|"), i + 1 < lines.count,
               isSeparatorRow(lines[i + 1].trimmingCharacters(in: .whitespaces)) {
                let headerCells = cellStrings(trimmed).map { parseInlines($0) }
                let alignments = separatorAlignments(lines[i + 1].trimmingCharacters(in: .whitespaces))
                i += 2
                var rows: [[[MDInline]]] = []
                while i < lines.count {
                    let t = lines[i].trimmingCharacters(in: .whitespaces)
                    guard t.hasPrefix("|") else { break }
                    rows.append(cellStrings(t).map { parseInlines($0) })
                    i += 1
                }
                blocks.append(.table(header: headerCells, alignments: alignments, rows: rows))
                continue
            }

            if listMarker(raw) != nil {
                var rawItems: [RawListItem] = []
                while i < lines.count {
                    let line = lines[i]
                    let t = line.trimmingCharacters(in: .whitespaces)
                    if t.isEmpty {
                        if i + 1 < lines.count,
                           listMarker(lines[i + 1]) != nil || isContinuation(lines[i + 1]) {
                            i += 1
                            continue
                        }
                        break
                    }
                    if let marker = listMarker(line) {
                        rawItems.append(marker)
                        i += 1
                    } else if isContinuation(line), let last = rawItems.indices.last {
                        rawItems[last].text = smartJoin([rawItems[last].text, t])
                        i += 1
                    } else {
                        break
                    }
                }
                guard let first = rawItems.first else { i += 1; continue }
                var index = 0
                let items = buildItems(rawItems, index: &index, indent: first.indent)
                blocks.append(first.ordered ? .orderedList(items) : .bulletList(items))
                continue
            }

            var paragraphLines: [String] = []
            while i < lines.count {
                let line = lines[i]
                let t = line.trimmingCharacters(in: .whitespaces)
                if t.isEmpty || t.hasPrefix("#") || t.hasPrefix("```") || t.hasPrefix(">")
                    || t == "---" || t == "***" || t == "___" || listMarker(line) != nil {
                    break
                }
                if t.hasPrefix("|"), i + 1 < lines.count,
                   isSeparatorRow(lines[i + 1].trimmingCharacters(in: .whitespaces)) {
                    break
                }
                paragraphLines.append(t)
                i += 1
            }
            guard !paragraphLines.isEmpty else { i += 1; continue }
            blocks.append(.paragraph(parseInlines(smartJoin(paragraphLines))))
        }
        return blocks
    }

    public static func parseInlines(_ text: String) -> [MDInline] {
        var scanner = InlineScanner(text)
        return scanner.run(until: nil)
    }

    public static func headings(in blocks: [MDBlock], levels: Set<Int> = [2, 3]) -> [MDHeading] {
        var out: [MDHeading] = []
        func walk(_ list: [MDBlock]) {
            for block in list {
                switch block {
                case .heading(let level, let content, let anchor):
                    if levels.contains(level) {
                        out.append(MDHeading(level: level, text: plainInline(content), anchor: anchor))
                    }
                case .quote(let inner):
                    walk(inner)
                default:
                    break
                }
            }
        }
        walk(blocks)
        return out
    }

    public static func plainText(_ blocks: [MDBlock]) -> String {
        var parts: [String] = []
        func walk(_ list: [MDBlock]) {
            for block in list {
                switch block {
                case .heading(_, let content, _):
                    parts.append(plainInline(content))
                case .paragraph(let content):
                    parts.append(plainInline(content))
                case .codeBlock(_, let code):
                    parts.append(code)
                case .bulletList(let items):
                    walkItems(items)
                case .orderedList(let items):
                    walkItems(items)
                case .table(let header, _, let rows):
                    parts.append(header.map { plainInline($0) }.joined(separator: " "))
                    for row in rows {
                        parts.append(row.map { plainInline($0) }.joined(separator: " "))
                    }
                case .quote(let inner):
                    walk(inner)
                case .thematicBreak:
                    break
                }
            }
        }
        func walkItems(_ items: [MDListItem]) {
            for item in items {
                parts.append(plainInline(item.content))
                walkItems(item.children)
            }
        }
        walk(blocks)
        return parts.joined(separator: "\n")
    }

    public static func plainInline(_ inlines: [MDInline]) -> String {
        var out = ""
        for inline in inlines {
            switch inline {
            case .text(let s), .code(let s):
                out += s
            case .bold(let children), .italic(let children), .link(let children, _):
                out += plainInline(children)
            }
        }
        return out
    }

    static func smartJoin(_ lines: [String]) -> String {
        var out = ""
        for line in lines {
            if out.isEmpty { out = line; continue }
            if let last = out.last, let first = line.first, isCJK(last) || isCJK(first) {
                out += line
            } else {
                out += " " + line
            }
        }
        return out
    }

    static func isCJK(_ c: Character) -> Bool {
        guard let s = c.unicodeScalars.first else { return false }
        return isCJKScalar(s)
    }

    static func isCJKScalar(_ s: Unicode.Scalar) -> Bool {
        let v = s.value
        return (0x3000...0x303F).contains(v)
            || (0x3040...0x30FF).contains(v)
            || (0x3400...0x4DBF).contains(v)
            || (0x4E00...0x9FFF).contains(v)
            || (0xFF00...0xFFEF).contains(v)
    }

    private static func listMarker(_ line: String) -> RawListItem? {
        var indent = 0
        for c in line {
            if c == " " { indent += 1 } else { break }
        }
        guard indent < 8 else { return nil }
        let body = String(line.dropFirst(indent))
        if body.hasPrefix("- ") || body.hasPrefix("* ") || body.hasPrefix("+ ") {
            return RawListItem(indent: indent, ordered: false, text: String(body.dropFirst(2)))
        }
        var digits = ""
        for c in body {
            if c.isNumber { digits.append(c) } else { break }
        }
        if !digits.isEmpty, digits.count <= 9 {
            let rest = body.dropFirst(digits.count)
            if rest.hasPrefix(". ") {
                return RawListItem(indent: indent, ordered: true, text: String(rest.dropFirst(2)))
            }
        }
        return nil
    }

    private static func isContinuation(_ line: String) -> Bool {
        var indent = 0
        for c in line {
            if c == " " { indent += 1 } else { break }
        }
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return indent >= 2 && !trimmed.isEmpty && listMarker(line) == nil
    }

    private static func buildItems(_ raw: [RawListItem], index: inout Int, indent: Int) -> [MDListItem] {
        var items: [MDListItem] = []
        var level = indent
        while index < raw.count {
            let item = raw[index]
            if item.indent < level { break }
            if item.indent > level {
                if items.isEmpty {
                    level = item.indent
                    continue
                }
                var childIndex = index
                let children = buildItems(raw, index: &childIndex, indent: item.indent)
                items[items.count - 1].children = children
                items[items.count - 1].childrenOrdered = item.ordered
                index = childIndex
                continue
            }
            index += 1
            items.append(MDListItem(content: parseInlines(item.text), children: [], childrenOrdered: false))
        }
        return items
    }

    private static func isSeparatorRow(_ line: String) -> Bool {
        guard line.hasPrefix("|") else { return false }
        let cells = cellStrings(line)
        guard !cells.isEmpty else { return false }
        return cells.allSatisfy { cell in
            let t = cell.trimmingCharacters(in: .whitespaces)
            guard t.contains("-") else { return false }
            return t.allSatisfy { $0 == "-" || $0 == ":" }
        }
    }

    private static func separatorAlignments(_ line: String) -> [MDAlignment] {
        cellStrings(line).map { cell in
            let t = cell.trimmingCharacters(in: .whitespaces)
            let left = t.hasPrefix(":")
            let right = t.hasSuffix(":")
            if left && right { return .center }
            if right { return .trailing }
            return .leading
        }
    }

    private static func cellStrings(_ line: String) -> [String] {
        var t = line.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("|") { t = String(t.dropFirst()) }
        if t.hasSuffix("|") { t = String(t.dropLast()) }
        return t.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
    }
}

private struct InlineScanner {
    let chars: [Character]
    var i = 0

    init(_ text: String) {
        chars = Array(text)
    }

    mutating func run(until stop: String?) -> [MDInline] {
        var out: [MDInline] = []
        var buffer = ""
        func flush() {
            if !buffer.isEmpty {
                out.append(.text(buffer))
                buffer.removeAll()
            }
        }
        while i < chars.count {
            if let stop, matches(stop), !(stop == "*" && matches("**")) {
                i += stop.count
                flush()
                return out
            }
            let c = chars[i]
            if c == "\\", i + 1 < chars.count {
                buffer.append(chars[i + 1])
                i += 2
                continue
            }
            if c == "`", let end = find("`", from: i + 1) {
                flush()
                out.append(.code(String(chars[(i + 1)..<end])))
                i = end + 1
                continue
            }
            if c == "*", matches("**") {
                flush()
                i += 2
                out.append(.bold(run(until: "**")))
                continue
            }
            if c == "*" {
                flush()
                i += 1
                out.append(.italic(run(until: "*")))
                continue
            }
            if c == "[", let close = find("]", from: i + 1),
               close + 1 < chars.count, chars[close + 1] == "(",
               let end = find(")", from: close + 2) {
                flush()
                let label = String(chars[(i + 1)..<close])
                let url = String(chars[(close + 2)..<end])
                var sub = InlineScanner(label)
                out.append(.link(sub.run(until: nil), url: url))
                i = end + 1
                continue
            }
            buffer.append(c)
            i += 1
        }
        flush()
        return out
    }

    private func matches(_ s: String) -> Bool {
        let sc = Array(s)
        guard i + sc.count <= chars.count else { return false }
        for k in 0..<sc.count where chars[i + k] != sc[k] { return false }
        return true
    }

    private func find(_ char: Character, from start: Int) -> Int? {
        var j = start
        while j < chars.count {
            if chars[j] == char { return j }
            if chars[j] == "\\", j + 1 < chars.count {
                j += 2
                continue
            }
            j += 1
        }
        return nil
    }
}
