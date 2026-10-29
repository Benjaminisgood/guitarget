import SwiftUI

struct SidebarView: View {
    @Binding var route: DocsRoute?
    @EnvironmentObject private var store: DocStore

    var body: some View {
        List(selection: $route) {
            Label("首页", systemImage: "house.fill")
                .tag(DocsRoute.home)
            Label("搜索", systemImage: "magnifyingglass")
                .tag(DocsRoute.search)
            ForEach(DocCatalog.sections) { section in
                Section {
                    ForEach(section.articles) { article in
                        Label {
                            HStack(spacing: 6) {
                                Text(article.title)
                                    .lineLimit(1)
                                Spacer(minLength: 4)
                                if let minutes = store.readingMinutes(article.id) {
                                    Text("\(minutes)′")
                                        .font(.caption2)
                                        .monospacedDigit()
                                        .foregroundStyle(.tertiary)
                                }
                            }
                        } icon: {
                            Image(systemName: article.symbol)
                        }
                        .tag(DocsRoute.article(article.id))
                    }
                } header: {
                    Label(section.title, systemImage: section.symbol)
                        .font(.caption)
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            VersionBadge()
        }
    }
}

struct VersionBadge: View {
    var body: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 9) {
                Image(systemName: "guitars.fill")
                    .font(.system(size: 15))
                    .foregroundStyle(DocTheme.heroGradient)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Guitarget Docs")
                        .font(.caption.weight(.semibold))
                    Text("v\(Self.version) · SwiftUI 原生 · macOS & iOS")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
        }
    }

    static var version: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "1.0"
    }
}
