import SwiftUI

struct ArticleView: View {
    let articleID: String
    @Binding var pendingAnchor: String?
    var onOpen: ((String) -> Void)?
    @EnvironmentObject private var store: DocStore

    var body: some View {
        Group {
            if let article = store.article(articleID) {
                content(article)
            } else {
                ContentUnavailableView("未找到文章", systemImage: "doc.text.magnifyingglass")
            }
        }
        .navigationTitle(store.article(articleID)?.meta.title ?? "文章")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }

    @ViewBuilder
    private func content(_ article: DocStore.LoadedArticle) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    ArticleHeader(article: article)
                    MarkdownBlockListView(blocks: article.blocks)
                    ArticleFooterNav(articleID: articleID, onOpen: onOpen)
                }
                .frame(maxWidth: DocTheme.contentWidth, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .top)
                .padding(.horizontal, 26)
                .padding(.top, 16)
                .padding(.bottom, 64)
            }
            .id(articleID)
            .onAppear {
                if let anchor = pendingAnchor {
                    DispatchQueue.main.async {
                        proxy.scrollTo(anchor, anchor: .top)
                    }
                    pendingAnchor = nil
                }
            }
            .onChange(of: pendingAnchor) { _, newValue in
                guard let newValue else { return }
                DispatchQueue.main.async {
                    withAnimation(.easeInOut(duration: 0.25)) {
                        proxy.scrollTo(newValue, anchor: .top)
                    }
                }
                pendingAnchor = nil
            }
        }
    }
}

struct ArticleHeader: View {
    let article: DocStore.LoadedArticle

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Text(article.sectionTitle)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(DocTheme.accent)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(DocTheme.accent.opacity(0.12)))
                Label("\(article.readingMinutes) 分钟阅读", systemImage: "clock")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(article.meta.title)
                .font(DocTheme.articleTitleFont)
                .textSelection(.enabled)
            Text(article.meta.summary)
                .font(DocTheme.summaryFont)
                .foregroundStyle(.secondary)
                .lineSpacing(4)
            Divider()
                .padding(.top, 4)
        }
        .padding(.bottom, 4)
    }
}

struct ArticleFooterNav: View {
    let articleID: String
    var onOpen: ((String) -> Void)?

    var body: some View {
        let neighbors = DocCatalog.neighbors(of: articleID)
        HStack(alignment: .top, spacing: 12) {
            if let previous = neighbors.previous {
                ArticleLink(id: previous.id, onOpen: onOpen) {
                    FooterNavCard(caption: "上一篇", title: previous.title, symbol: "arrow.left", trailing: false)
                }
                #if os(iOS)
                .buttonStyle(.plain)
                #endif
            }
            Spacer(minLength: 0)
            if let next = neighbors.next {
                ArticleLink(id: next.id, onOpen: onOpen) {
                    FooterNavCard(caption: "下一篇", title: next.title, symbol: "arrow.right", trailing: true)
                }
                #if os(iOS)
                .buttonStyle(.plain)
                #endif
            }
        }
        .padding(.top, 28)
    }
}

struct FooterNavCard: View {
    let caption: String
    let title: String
    let symbol: String
    let trailing: Bool
    @State private var hovering = false

    var body: some View {
        VStack(alignment: trailing ? .trailing : .leading, spacing: 5) {
            HStack(spacing: 5) {
                if !trailing { Image(systemName: symbol).font(.caption2) }
                Text(caption).font(.caption)
                if trailing { Image(systemName: symbol).font(.caption2) }
            }
            .foregroundStyle(.secondary)
            Text(title)
                .font(.callout.weight(.semibold))
                .foregroundStyle(DocTheme.accent)
                .lineLimit(2)
                .multilineTextAlignment(trailing ? .trailing : .leading)
        }
        .frame(maxWidth: 255, alignment: trailing ? .trailing : .leading)
        .padding(13)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(DocTheme.cardFill))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(hovering ? DocTheme.accent.opacity(0.55) : DocTheme.cardStroke, lineWidth: 1)
        )
        .onHover { hovering = $0 }
    }
}
