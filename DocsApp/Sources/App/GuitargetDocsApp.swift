import SwiftUI

@main
struct GuitargetDocsApp: App {
    @StateObject private var store = DocStore()

    var body: some Scene {
        WindowGroup("Guitarget Docs") {
            RootView()
                .environmentObject(store)
        }
        #if os(macOS)
        .defaultSize(width: 1280, height: 840)
        #endif
    }
}

enum DocsRoute: Hashable {
    case home
    case search
    case article(String)
}

struct RootView: View {
    var body: some View {
        #if os(macOS)
        MacRootView()
        #else
        IOSRootView()
        #endif
    }
}

struct ArticleLink<Content: View>: View {
    let id: String
    let onOpen: ((String) -> Void)?
    let content: () -> Content

    init(id: String, onOpen: ((String) -> Void)? = nil, @ViewBuilder content: @escaping () -> Content) {
        self.id = id
        self.onOpen = onOpen
        self.content = content
    }

    var body: some View {
        #if os(iOS)
        NavigationLink(value: id) {
            content()
        }
        #else
        Button {
            onOpen?(id)
        } label: {
            content()
        }
        #endif
    }
}

#if os(macOS)
struct MacRootView: View {
    @State private var route: DocsRoute? = .home
    @State private var pendingAnchor: String?
    @EnvironmentObject private var store: DocStore

    var body: some View {
        NavigationSplitView {
            SidebarView(route: $route)
                .navigationSplitViewColumnWidth(min: 235, ideal: 268, max: 320)
        } content: {
            Group {
                switch route ?? .home {
                case .home:
                    HomeView(onOpen: open)
                case .search:
                    SearchView(onOpen: open)
                case .article(let id):
                    ArticleView(articleID: id, pendingAnchor: $pendingAnchor, onOpen: open)
                }
            }
            .frame(minWidth: 470, minHeight: 400)
        } detail: {
            TOCPanel(headings: currentArticle?.headings ?? [],
                     articleTitle: currentArticle?.meta.title,
                     pendingAnchor: $pendingAnchor)
                .navigationSplitViewColumnWidth(min: 190, ideal: 224, max: 290)
        }
        .tint(DocTheme.accent)
    }

    private func open(_ id: String) {
        pendingAnchor = nil
        route = .article(id)
    }

    private var currentArticle: DocStore.LoadedArticle? {
        if case .article(let id) = route ?? .home {
            return store.article(id)
        }
        return nil
    }
}
#else
struct IOSRootView: View {
    @State private var tab = 0

    var body: some View {
        TabView(selection: $tab) {
            NavigationStack {
                HomeView(onOpen: nil)
                    .navigationDestination(for: String.self) { id in
                        ArticleScreen(articleID: id)
                    }
            }
            .tabItem { Label("首页", systemImage: "house.fill") }
            .tag(0)
            NavigationStack {
                CatalogListView()
                    .navigationDestination(for: String.self) { id in
                        ArticleScreen(articleID: id)
                    }
            }
            .tabItem { Label("目录", systemImage: "list.bullet.indent") }
            .tag(1)
            NavigationStack {
                SearchView(onOpen: nil)
                    .navigationDestination(for: String.self) { id in
                        ArticleScreen(articleID: id)
                    }
            }
            .tabItem { Label("搜索", systemImage: "magnifyingglass") }
            .tag(2)
        }
        .tint(DocTheme.accent)
    }
}

struct ArticleScreen: View {
    let articleID: String
    @EnvironmentObject private var store: DocStore
    @State private var anchor: String?
    @State private var showTOC = false

    var body: some View {
        ArticleView(articleID: articleID, pendingAnchor: $anchor, onOpen: nil)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showTOC = true
                    } label: {
                        Image(systemName: "list.bullet")
                    }
                    .disabled(store.article(articleID)?.headings.isEmpty ?? true)
                }
            }
            .sheet(isPresented: $showTOC) {
                NavigationStack {
                    List {
                        ForEach(store.article(articleID)?.headings ?? []) { heading in
                            Button {
                                anchor = heading.anchor
                                showTOC = false
                            } label: {
                                Text(heading.text)
                                    .font(heading.level == 2 ? .body.weight(.medium) : .subheadline)
                                    .foregroundStyle(heading.level == 2 ? Color.primary : Color.secondary)
                                    .padding(.leading, heading.level == 2 ? 0 : 14)
                            }
                        }
                    }
                    .navigationTitle("目录")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("完成") { showTOC = false }
                        }
                    }
                }
                .presentationDetents([.medium, .large])
            }
    }
}
#endif
