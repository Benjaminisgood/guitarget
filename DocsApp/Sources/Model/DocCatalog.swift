import Foundation

struct DocArticle: Identifiable, Hashable {
    var id: String { file }
    let file: String
    let title: String
    let summary: String
    let symbol: String
}

struct DocSection: Identifiable, Hashable {
    let id: String
    let title: String
    let symbol: String
    let articles: [DocArticle]
}

enum DocCatalog {

    static let sections: [DocSection] = [
        DocSection(id: "overview", title: "概览", symbol: "star.fill", articles: [
            DocArticle(file: "overview",
                       title: "产品概览与设计理念",
                       summary: "Guitarget 是什么：纯 Swift 原生吉他学习应用的十大栏目、技术取舍与诚实验证文化。",
                       symbol: "book.closed.fill"),
        ]),
        DocSection(id: "getting-started", title: "快速开始", symbol: "bolt.fill", articles: [
            DocArticle(file: "quickstart",
                       title: "安装、构建与运行",
                       summary: "系统要求、build_and_run.sh 一键构建启动、test.sh 测试、脚本参数与 QA 实例。",
                       symbol: "play.circle.fill"),
            DocArticle(file: "interface",
                       title: "界面导览",
                       summary: "学习室十个栏目、曲谱编辑器窗口布局、声音来源与全局播放行为。",
                       symbol: "square.grid.2x2.fill"),
        ]),
        DocSection(id: "guides", title: "功能指南", symbol: "book.fill", articles: [
            DocArticle(file: "editor",
                       title: "六线谱编辑器与键盘输入全解",
                       summary: "双声部录谱流程、全部快捷键、检查器、延音拆分、演奏提示与播放控制。",
                       symbol: "square.and.pencil"),
            DocArticle(file: "lyrics",
                       title: "歌词编辑",
                       summary: "逐事件歌词、谱面对齐与播放高亮、和弦标记、格式字段与旧文件兼容。",
                       symbol: "music.mic"),
            DocArticle(file: "library",
                       title: "我的曲库与音频绑定",
                       summary: "曲库管理、六份入门谱、绑定原声音频、只读演奏模式与智能跟随。",
                       symbol: "books.vertical.fill"),
            DocArticle(file: "apple-music",
                       title: "Apple Music 链接",
                       summary: "粘贴分享链接、交给系统“音乐”应用打开、隐私与地区边界。",
                       symbol: "link"),
            DocArticle(file: "tuner",
                       title: "调音器",
                       summary: "色度／自动目标弦／锁弦三模式、七种调弦预设、A4 基准与稳定性判定。",
                       symbol: "tuningfork"),
            DocArticle(file: "scales-caged",
                       title: "指板、音阶与 CAGED",
                       summary: "指板试听、12 根音 × 6 类音阶、五种指型数据与 CAGED 和弦形状。",
                       symbol: "guitars.fill"),
            DocArticle(file: "chords",
                       title: "三和弦与和弦库",
                       summary: "调内三和弦练习、12 根音 × 15 种和弦类型的按法穷举与筛选条件。",
                       symbol: "rectangle.grid.3x2"),
            DocArticle(file: "recognition",
                       title: "和弦识别",
                       summary: "扫弦实时识别和弦名、转位、构成音、音级能量条与延迟边界。",
                       symbol: "waveform"),
            DocArticle(file: "ensemble",
                       title: "合奏",
                       summary: "四种原创双声部伴奏、转调与速度、和弦卡片、推荐音与练习谱生成。",
                       symbol: "music.note.list"),
            DocArticle(file: "practice",
                       title: "曲谱跟练",
                       summary: "弹对再前进与按节拍跟练、判定参数、跟拍校准与练习时钟。",
                       symbol: "ear.badge.checkmark"),
            DocArticle(file: "chord-practice",
                       title: "和弦练习模式",
                       summary: "看图、听示范、限时记忆三种训练与三种判定方式的组合。",
                       symbol: "brain.head.profile"),
        ]),
        DocSection(id: "advanced", title: "进阶", symbol: "wrench.and.screwdriver.fill", articles: [
            DocArticle(file: "architecture",
                       title: "架构与技术实现",
                       summary: "三大模块、AVAudioEngine 播放链、钢弦物理建模、process tap 采集、YIN 与 NNLS 和弦识别。",
                       symbol: "cpu"),
            DocArticle(file: "data-backup",
                       title: "数据存储位置与备份",
                       summary: "~/Library/Application Support/Guitarget/MyLibrary/ 结构、备份恢复与迁移。",
                       symbol: "externaldrive.fill"),
            DocArticle(file: "diagnostics",
                       title: "开发诊断与自检",
                       summary: "--self-check、chord smoke、stage_qa.sh、音频诊断与 OSLog 日志。",
                       symbol: "stethoscope"),
        ]),
        DocSection(id: "reference", title: "参考", symbol: "text.book.closed.fill", articles: [
            DocArticle(file: "shortcuts",
                       title: "快捷键速查",
                       summary: "编辑器录入、导航、时值、编辑与播放的全部按键，以及系统文档快捷键。",
                       symbol: "command"),
            DocArticle(file: "score-format",
                       title: ".guitarget 曲谱格式",
                       summary: "版本化 JSON、960 ticks 时值体系、技巧枚举、延音规则与最小有效文档。",
                       symbol: "curlybraces"),
            DocArticle(file: "glossary",
                       title: "术语表",
                       summary: "六线谱、乐理、音频与算法术语的中英对照速查。",
                       symbol: "textformat"),
        ]),
        DocSection(id: "faq", title: "FAQ", symbol: "questionmark.bubble.fill", articles: [
            DocArticle(file: "faq",
                       title: "FAQ 与故障排查",
                       summary: "构建、权限、采集、跟练、识别、曲库与播放的常见问题和解决办法。",
                       symbol: "questionmark.circle.fill"),
        ]),
    ]

    static let articles: [DocArticle] = sections.flatMap { $0.articles }

    static func article(_ id: String) -> DocArticle? {
        articles.first { $0.id == id }
    }

    static func sectionTitle(for id: String) -> String {
        sections.first { section in section.articles.contains { $0.id == id } }?.title ?? "文档"
    }

    static func neighbors(of id: String) -> (previous: DocArticle?, next: DocArticle?) {
        guard let idx = articles.firstIndex(where: { $0.id == id }) else { return (nil, nil) }
        let previous = idx > 0 ? articles[idx - 1] : nil
        let next = idx + 1 < articles.count ? articles[idx + 1] : nil
        return (previous, next)
    }
}
