import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

struct InlineText: View {
    let inlines: [MDInline]
    var base: Font = DocTheme.bodyFont

    var body: some View {
        Text(Self.attributed(inlines, base: base))
            .tint(DocTheme.accent)
    }

    static func attributed(_ inlines: [MDInline], base: Font, bold: Bool = false, italic: Bool = false) -> AttributedString {
        var out = AttributedString()
        for inline in inlines {
            switch inline {
            case .text(let s):
                var run = AttributedString(s)
                run.font = styled(base, bold: bold, italic: italic, code: false)
                out += run
            case .code(let s):
                var run = AttributedString(s)
                run.font = styled(base, bold: bold, italic: italic, code: true)
                run.foregroundColor = DocTheme.inlineCode
                out += run
            case .bold(let children):
                out += attributed(children, base: base, bold: true, italic: italic)
            case .italic(let children):
                out += attributed(children, base: base, bold: bold, italic: italic)
            case .link(let children, let url):
                var child = attributed(children, base: base, bold: bold, italic: italic)
                child.link = URL(string: url)
                child.underlineStyle = .single
                out += child
            }
        }
        return out
    }

    static func styled(_ base: Font, bold: Bool, italic: Bool, code: Bool) -> Font {
        var f = code ? base.monospaced() : base
        if bold { f = f.bold() }
        if italic { f = f.italic() }
        return f
    }
}

struct MarkdownBlockListView: View {
    let blocks: [MDBlock]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            ForEach(blocks.indices, id: \.self) { idx in
                MarkdownBlockView(block: blocks[idx])
            }
        }
    }
}

struct MarkdownBlockView: View {
    let block: MDBlock

    var body: some View {
        switch block {
        case .heading(let level, let content, let anchor):
            InlineText(inlines: content, base: DocTheme.headingFont(level: level))
                .lineSpacing(3)
                .padding(.top, level <= 2 ? 14 : 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
                .id(anchor)
        case .paragraph(let content):
            InlineText(inlines: content, base: DocTheme.bodyFont)
                .lineSpacing(DocTheme.bodySpacing)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        case .codeBlock(let language, let code):
            CodeBlockView(language: language, code: code)
        case .bulletList(let items):
            MarkdownListView(items: items, ordered: false)
        case .orderedList(let items):
            MarkdownListView(items: items, ordered: true)
        case .table(let header, let alignments, let rows):
            MarkdownTableView(header: header, alignments: alignments, rows: rows)
        case .quote(let inner):
            QuoteBlockView(blocks: inner)
        case .thematicBreak:
            Divider().padding(.vertical, 6)
        }
    }
}

struct QuoteBlockView: View {
    let blocks: [MDBlock]

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            RoundedRectangle(cornerRadius: 2)
                .fill(DocTheme.heroGradient)
                .frame(width: 4)
            VStack(alignment: .leading, spacing: 10) {
                MarkdownBlockListView(blocks: blocks)
            }
            .padding(.leading, 14)
            .padding(.trailing, 14)
            .padding(.vertical, 12)
        }
        .background(DocTheme.quoteFill)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .padding(.vertical, 2)
    }
}

struct MarkdownListView: View {
    let items: [MDListItem]
    let ordered: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(items.indices, id: \.self) { idx in
                row(items[idx], number: idx + 1)
            }
        }
    }

    @ViewBuilder
    private func row(_ item: MDListItem, number: Int) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 9) {
                marker(number: number)
                InlineText(inlines: item.content, base: DocTheme.bodyFont)
                    .lineSpacing(5)
            }
            if !item.children.isEmpty {
                MarkdownListView(items: item.children, ordered: item.childrenOrdered)
                    .padding(.leading, 25)
            }
        }
    }

    @ViewBuilder
    private func marker(number: Int) -> some View {
        if ordered {
            Text("\(number).")
                .font(DocTheme.bodyFont.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(DocTheme.accent)
                .frame(minWidth: 21, alignment: .trailing)
        } else {
            Text("•")
                .font(DocTheme.bodyFont.weight(.bold))
                .foregroundStyle(DocTheme.accent)
                .frame(minWidth: 21, alignment: .trailing)
        }
    }
}

struct MarkdownTableView: View {
    let header: [[MDInline]]
    let alignments: [MDAlignment]
    let rows: [[[MDInline]]]

    var body: some View {
        let widths = columnWidths()
        ScrollView(.horizontal) {
            Grid(alignment: .topLeading, horizontalSpacing: 16, verticalSpacing: 9) {
                GridRow {
                    ForEach(header.indices, id: \.self) { col in
                        cell(header[col], column: col, widths: widths, isHeader: true)
                    }
                }
                GridRow {
                    Rectangle()
                        .fill(Color.primary.opacity(0.16))
                        .frame(height: 1)
                        .gridCellColumns(max(header.count, 1))
                }
                ForEach(rows.indices, id: \.self) { rowIdx in
                    GridRow {
                        ForEach(rows[rowIdx].indices, id: \.self) { col in
                            cell(rows[rowIdx][col], column: col, widths: widths, isHeader: false)
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 13)
        }
        .scrollIndicators(.hidden)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(DocTheme.cardFill))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(DocTheme.cardStroke, lineWidth: 1))
    }

    @ViewBuilder
    private func cell(_ content: [MDInline], column: Int, widths: [CGFloat], isHeader: Bool) -> some View {
        let alignment = alignmentFor(column)
        InlineText(inlines: content,
                   base: isHeader ? DocTheme.calloutFont.weight(.semibold) : DocTheme.calloutFont)
            .lineSpacing(3)
            .multilineTextAlignment(textAlignmentFor(column))
            .frame(width: column < widths.count ? widths[column] : nil,
                   alignment: frameAlignment(alignment))
    }

    private func alignmentFor(_ column: Int) -> MDAlignment {
        column < alignments.count ? alignments[column] : .leading
    }

    private func textAlignmentFor(_ column: Int) -> TextAlignment {
        switch alignmentFor(column) {
        case .leading: return .leading
        case .center: return .center
        case .trailing: return .trailing
        }
    }

    private func frameAlignment(_ alignment: MDAlignment) -> Alignment {
        switch alignment {
        case .leading: return .leading
        case .center: return .center
        case .trailing: return .trailing
        }
    }

    private func columnWidths() -> [CGFloat] {
        guard !header.isEmpty else { return [] }
        let fontSize: CGFloat = DocTheme.platform(macos: 13.5, ios: 15)
        let maxColumnWidth: CGFloat = DocTheme.platform(macos: 265, ios: 240)
        var widths: [CGFloat] = []
        for col in header.indices {
            var cells = [header[col]]
            for row in rows where col < row.count {
                cells.append(row[col])
            }
            var widest: CGFloat = 0
            for cell in cells {
                let text = MarkdownParser.plainInline(cell)
                var w: CGFloat = 0
                for scalar in text.unicodeScalars {
                    w += MarkdownParser.isCJKScalar(scalar) ? fontSize : fontSize * 0.56
                }
                widest = max(widest, w + 8)
            }
            widths.append(min(max(widest, 46), maxColumnWidth))
        }
        return widths
    }
}

struct CodeBlockView: View {
    let language: String?
    let code: String
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                if let language, !language.isEmpty {
                    Text(language)
                        .font(.caption.monospaced())
                        .foregroundStyle(DocTheme.codeBadge)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2.5)
                        .background(Capsule().fill(Color.white.opacity(0.09)))
                }
                Spacer(minLength: 8)
                Button(action: copy) {
                    HStack(spacing: 4) {
                        Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        Text(copied ? "已复制" : "复制")
                    }
                    .font(.caption)
                    .foregroundStyle(Color.white.opacity(copied ? 0.92 : 0.55))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 14)
            .padding(.top, 10)
            .padding(.bottom, 8)
            ScrollView(.horizontal) {
                Text(code)
                    .font(DocTheme.codeFont)
                    .foregroundStyle(DocTheme.codeForeground)
                    .lineSpacing(4)
                    .textSelection(.enabled)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 13)
            }
            .scrollIndicators(.hidden)
        }
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(DocTheme.codeBackground))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.white.opacity(0.07), lineWidth: 1))
        .padding(.vertical, 2)
    }

    private func copy() {
        #if os(macOS)
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(code, forType: .string)
        #else
        UIPasteboard.general.string = code
        #endif
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
            copied = false
        }
    }
}
