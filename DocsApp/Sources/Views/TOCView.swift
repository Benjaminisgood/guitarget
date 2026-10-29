import SwiftUI

struct TOCPanel: View {
    let headings: [MDHeading]
    let articleTitle: String?
    @Binding var pendingAnchor: String?

    var body: some View {
        Group {
            if headings.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "list.bullet.indent")
                        .font(.title)
                        .foregroundStyle(.tertiary)
                    Text(articleTitle == nil ? "选择一篇文章\n这里会显示目录锚点" : "本文没有小节标题")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    Section("目录") {
                        ForEach(headings) { heading in
                            Button {
                                pendingAnchor = heading.anchor
                            } label: {
                                Text(heading.text)
                                    .font(heading.level == 2 ? .callout.weight(.medium) : .subheadline)
                                    .foregroundStyle(heading.level == 2 ? Color.primary : Color.secondary)
                                    .padding(.leading, heading.level == 2 ? 0 : 11)
                                    .lineLimit(2)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .listStyle(.inset)
            }
        }
        .navigationTitle("目录")
    }
}
