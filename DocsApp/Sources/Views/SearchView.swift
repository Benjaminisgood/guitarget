import SwiftUI

struct SearchView: View {
    var onOpen: ((String) -> Void)?
    @EnvironmentObject private var store: DocStore
    @State private var query = ""

    private var hits: [DocStore.SearchHit] {
        store.search(query)
    }

    private var queryIsEmpty: Bool {
        query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        List {
            if queryIsEmpty {
                Section {
                    FlowChips(keywords: Self.popularKeywords) { keyword in
                        query = keyword
                    }
                } header: {
                    Text("热门搜索")
                } footer: {
                    Text("搜索覆盖全部 \(store.articles.count) 篇文章的标题、小节标题与正文，实时过滤并高亮命中。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Section("全部文章") {
                    ForEach(store.articles) { article in
                        ArticleLink(id: article.id, onOpen: onOpen) {
                            CatalogRow(article: article.meta, minutes: article.readingMinutes)
                        }
                        #if os(iOS)
                        .buttonStyle(.plain)
                        #endif
                    }
                }
            } else if hits.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .font(.title)
                        .foregroundStyle(.tertiary)
                    Text("没有找到包含 “\(query)” 的内容")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 40)
                .listRowBackground(Color.clear)
            } else {
                Section {
                    ForEach(hits) { hit in
                        ArticleLink(id: hit.id, onOpen: onOpen) {
                            SearchHitRow(hit: hit)
                        }
                        #if os(iOS)
                        .buttonStyle(.plain)
                        #endif
                    }
                } header: {
                    Text("找到 \(hits.count) 篇文章")
                }
            }
        }
        .listStyle(.inset)
        .searchable(text: $query, prompt: "搜索标题与全文…")
        .navigationTitle("搜索")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }

    static let popularKeywords = ["快捷键", "我的曲库", "process tap", "调音预设", "跟练", "备份", "和弦识别", "guitarget"]
}

struct SearchHitRow: View {
    let hit: DocStore.SearchHit

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Image(systemName: hit.article.symbol)
                    .font(.callout)
                    .foregroundStyle(DocTheme.accent)
                    .frame(width: 20)
                Text(hit.article.title)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(hit.matchedTitle ? DocTheme.accent : Color.primary)
                    .lineLimit(1)
                Text(hit.sectionTitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.primary.opacity(0.06)))
                Spacer(minLength: 4)
                if hit.matchCount > 0 {
                    Text("\(hit.matchCount) 处")
                        .font(.caption2)
                        .monospacedDigit()
                        .foregroundStyle(.tertiary)
                }
            }
            snippet
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineSpacing(2)
                .lineLimit(2)
        }
        .padding(.vertical, 2)
    }

    private var snippet: Text {
        hit.segments.reduce(Text("")) { acc, segment in
            if segment.isMatch {
                return acc + Text(segment.text)
                    .fontWeight(.semibold)
                    .foregroundStyle(DocTheme.accent)
            }
            return acc + Text(segment.text)
        }
    }
}

struct FlowChips: View {
    let keywords: [String]
    let action: (String) -> Void
    @State private var hovering: String?

    var body: some View {
        let columns = [GridItem(.adaptive(minimum: 108), spacing: 8)]
        LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
            ForEach(keywords, id: \.self) { keyword in
                Button {
                    action(keyword)
                } label: {
                    Text(keyword)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(hovering == keyword ? DocTheme.accent : Color.secondary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .frame(maxWidth: .infinity)
                        .background(Capsule().fill(Color.primary.opacity(0.05)))
                        .overlay(Capsule().strokeBorder(
                            hovering == keyword ? DocTheme.accent.opacity(0.5) : DocTheme.cardStroke, lineWidth: 1))
                }
                .buttonStyle(.plain)
                .onHover { inside in
                    hovering = inside ? keyword : nil
                }
            }
        }
        .padding(.vertical, 4)
    }
}

struct CatalogRow: View {
    let article: DocArticle
    var minutes: Int?

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: article.symbol)
                .font(.system(size: 16))
                .foregroundStyle(DocTheme.accent)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(article.title)
                        .font(.body.weight(.medium))
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    if let minutes {
                        Text("\(minutes) 分钟")
                            .font(.caption2)
                            .monospacedDigit()
                            .foregroundStyle(.tertiary)
                    }
                }
                Text(article.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 2)
    }
}
