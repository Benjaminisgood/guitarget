import SwiftUI

struct CatalogListView: View {
    @EnvironmentObject private var store: DocStore

    var body: some View {
        List {
            ForEach(DocCatalog.sections) { section in
                Section {
                    ForEach(section.articles) { article in
                        NavigationLink(value: article.id) {
                            CatalogRow(article: article, minutes: store.readingMinutes(article.id))
                        }
                    }
                } header: {
                    Label(section.title, systemImage: section.symbol)
                }
            }
        }
        .navigationTitle("目录")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }
}
