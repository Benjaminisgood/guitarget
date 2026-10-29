import SwiftUI

struct HomeView: View {
    var onOpen: ((String) -> Void)?
    @EnvironmentObject private var store: DocStore

    var body: some View {
        ScrollView {
            VStack(spacing: 34) {
                hero
                quickActions
                statsRow
                featureSection
                catalogSection
                footerNote
            }
            .frame(maxWidth: 940)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 24)
            .padding(.vertical, 26)
        }
        .navigationTitle("Guitarget Docs")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }

    private var hero: some View {
        VStack(spacing: 16) {
            ZStack {
                Circle()
                    .fill(DocTheme.heroGradient)
                    .frame(width: 82, height: 82)
                    .opacity(0.16)
                Image(systemName: "guitars.fill")
                    .font(.system(size: 36))
                    .foregroundStyle(DocTheme.heroGradient)
            }
            .padding(.top, 10)
            Text("Guitarget Docs")
                .font(DocTheme.heroTitleFont)
                .foregroundStyle(DocTheme.heroGradient)
                .minimumScaleFactor(0.5)
                .lineLimit(1)
            Text("纯 Swift 原生 macOS 吉他学习应用 · 完整中文文档")
                .font(DocTheme.platform(macos: Font.system(size: 17, weight: .medium), ios: Font.title3.weight(.medium)))
                .foregroundStyle(.secondary)
            Text("双声部六线谱与歌词编辑、本地曲库、钢弦吉他合成、单音跟练、复音和弦识别、调音器、CAGED、和弦库与合奏。全部功能离线可用，无 WebView、无第三方依赖。")
                .font(DocTheme.calloutFont)
                .foregroundStyle(.secondary)
                .lineSpacing(5)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 620)
        }
    }

    private var quickActions: some View {
        let actions: [(String, String, String)] = [
            ("quickstart", "快速开始", "play.circle.fill"),
            ("editor", "编辑器指南", "square.and.pencil"),
            ("shortcuts", "快捷键速查", "command"),
            ("faq", "FAQ 排查", "questionmark.circle.fill"),
        ]
        return HStack(spacing: 10) {
            Spacer(minLength: 0)
            ForEach(actions, id: \.0) { action in
                ArticleLink(id: action.0, onOpen: onOpen) {
                    Label(action.1, systemImage: action.2)
                        .font(.callout.weight(.medium))
                        .foregroundStyle(DocTheme.accent)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(Capsule().fill(DocTheme.accent.opacity(0.10)))
                        .overlay(Capsule().strokeBorder(DocTheme.accent.opacity(0.28), lineWidth: 1))
                }
                #if os(iOS)
                .buttonStyle(.plain)
                #endif
            }
            Spacer(minLength: 0)
        }
    }

    private var statsRow: some View {
        HStack(spacing: 0) {
            statItem(value: "\(DocCatalog.articles.count)", label: "篇文档")
            statDivider
            statItem(value: "\(DocCatalog.sections.count)", label: "个章节")
            statDivider
            statItem(value: "\(store.totalReadingMinutes)", label: "分钟读完")
            statDivider
            statItem(value: "0", label: "第三方依赖")
        }
        .padding(.vertical, 14)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(DocTheme.cardFill))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(DocTheme.cardStroke, lineWidth: 1))
    }

    private var statDivider: some View {
        Rectangle().fill(DocTheme.cardStroke).frame(width: 1, height: 30)
    }

    private func statItem(value: String, label: String) -> some View {
        VStack(spacing: 3) {
            Text(value)
                .font(.title3.weight(.bold))
                .monospacedDigit()
                .foregroundStyle(DocTheme.accent)
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private var featureSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionTitle("功能亮点", symbol: "sparkles")
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 218), spacing: 14)], alignment: .leading, spacing: 14) {
                ForEach(Self.features, id: \.1) { feature in
                    ArticleLink(id: feature.3, onOpen: onOpen) {
                        FeatureCard(symbol: feature.0, title: feature.1, text: feature.2)
                    }
                    #if os(iOS)
                    .buttonStyle(.plain)
                    #endif
                }
            }
        }
    }

    private var catalogSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            sectionTitle("文档地图", symbol: "map.fill")
            VStack(alignment: .leading, spacing: 14) {
                ForEach(DocCatalog.sections) { section in
                    VStack(alignment: .leading, spacing: 9) {
                        Label(section.title, systemImage: section.symbol)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(DocTheme.accent)
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 180), spacing: 8)], alignment: .leading, spacing: 8) {
                            ForEach(section.articles) { article in
                                ArticleLink(id: article.id, onOpen: onOpen) {
                                    HStack(spacing: 7) {
                                        Image(systemName: article.symbol)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .frame(width: 16)
                                        Text(article.title)
                                            .font(.callout)
                                            .foregroundStyle(.primary)
                                            .lineLimit(1)
                                        Spacer(minLength: 0)
                                    }
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 7)
                                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(DocTheme.cardFill))
                                }
                                #if os(iOS)
                                .buttonStyle(.plain)
                                #endif
                            }
                        }
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.primary.opacity(0.02)))
                    .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(DocTheme.cardStroke, lineWidth: 1))
                }
            }
        }
    }

    private func sectionTitle(_ title: String, symbol: String) -> some View {
        Label(title, systemImage: symbol)
            .font(DocTheme.platform(macos: Font.system(size: 18, weight: .bold), ios: Font.title3.bold()))
    }

    private var footerNote: some View {
        VStack(spacing: 6) {
            Divider().padding(.bottom, 8)
            Text("本文档应用由纯 SwiftUI 编写：内置轻量 Markdown 解析器把文档渲染为原生视图，无 WebView、无 JavaScript、无第三方依赖。")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
            Text("Guitarget Docs v\(VersionBadge.version) · 为 Guitarget 项目编写 · 深浅色模式均适配")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.top, 6)
    }

    static let features: [(String, String, String, String)] = [
        ("square.and.pencil", "双声部六线谱编辑", "旋律与低音独立计时，全键盘录入，原生撤销与文档保存。", "editor"),
        ("music.mic", "逐事件歌词对齐", "歌词按事件对齐在六线谱下方，随播放高亮，支持撤销重做。", "lyrics"),
        ("books.vertical.fill", "我的曲库与原声", "本地曲库管理谱、歌词与音频副本，演奏模式智能跟随。", "library"),
        ("waveform", "复音和弦识别", "NNLS chroma + HMM 实时识别 205 个模板，含转位低音。", "recognition"),
        ("ear.badge.checkmark", "单音跟练判定", "弹对再前进与按节拍跟练，中位数跟拍校准，边界诚实。", "practice"),
        ("tuningfork", "专业调音器", "三种模式、七种调弦预设、A4 400–480 Hz 可调基准。", "tuner"),
        ("guitars.fill", "CAGED 与和弦库", "五种指型数据化，12 根音 × 15 种和弦类型穷举按法。", "scales-caged"),
        ("music.note.list", "合奏与练习谱", "四种原创双声部伴奏，推荐音一键生成单音练习谱。", "ensemble"),
        ("cpu", "纯原生架构", "AVAudioEngine、CoreAudio process tap、自研 DSP，零依赖。", "architecture"),
    ]
}

struct FeatureCard: View {
    let symbol: String
    let title: String
    let text: String
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Image(systemName: symbol)
                .font(.system(size: 20))
                .foregroundStyle(DocTheme.heroGradient)
                .frame(height: 24)
            Text(title)
                .font(DocTheme.platform(macos: Font.system(size: 14.5, weight: .semibold), ios: Font.headline))
            Text(text)
                .font(DocTheme.platform(macos: Font.system(size: 12.5), ios: Font.footnote))
                .foregroundStyle(.secondary)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(15)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(DocTheme.cardFill))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(hovering ? DocTheme.accent.opacity(0.5) : DocTheme.cardStroke, lineWidth: 1)
        )
        .scaleEffect(hovering ? 1.015 : 1.0)
        .animation(.easeOut(duration: 0.15), value: hovering)
        .onHover { hovering = $0 }
    }
}
