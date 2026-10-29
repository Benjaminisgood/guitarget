# Guitarget Docs

Guitarget 项目的**纯原生 SwiftUI 文档 App**（产品名 "Guitarget Docs"），同时支持 macOS 14+ 与 iOS 17+。文档以 Markdown 文件形式打包进 app bundle，由自写的轻量 Markdown 解析器渲染为原生 SwiftUI 视图——无 WebView、无 JavaScript、无第三方依赖、无 NSAttributedString HTML 路径。

## 构建与运行

需要 Xcode（含 iOS Simulator SDK）与 XcodeGen 2.38+（本机验证 2.46）。

```sh
./script/build.sh          # xcodegen generate + macOS 与 iOS Simulator 双平台构建
./script/build.sh mac      # 仅 macOS
./script/build.sh ios      # 仅 iOS Simulator
./script/build.sh run      # 构建并启动 macOS 应用
```

或手动执行：

```sh
xcodegen generate
xcodebuild -project GuitargetDocs.xcodeproj -scheme GuitargetDocs \
  -configuration Debug -destination 'platform=macOS' build
xcodebuild -project GuitargetDocs.xcodeproj -scheme GuitargetDocsMobile \
  -configuration Debug -destination 'generic/platform=iOS Simulator' build
```

在 Xcode 中打开 `GuitargetDocs.xcodeproj`，分别选择 GuitargetDocs（My Mac）或 GuitargetDocsMobile（任意 iOS 模拟器）运行。

## 目录结构

```text
DocsApp/
├── project.yml                  # XcodeGen 工程定义（双 target）
├── script/build.sh              # 生成 + 双平台构建脚本
├── Sources/
│   ├── App/GuitargetDocsApp.swift        # @main、RootView、平台根视图
│   ├── Model/DocCatalog.swift            # 章节与文章元数据（标题、图标、摘要）
│   ├── Model/DocStore.swift              # 加载 / 解析 / 搜索 / 阅读时间
│   ├── Markdown/MarkdownParser.swift     # 轻量 Markdown 解析器（AST）
│   ├── Markdown/MarkdownViews.swift      # 原生渲染：标题、代码块、表格、列表、引用、行内样式
│   ├── Views/                            # 主题、首页 Hero、侧边栏、文章页、TOC、搜索、目录
│   └── Resources/docs/*.md               # 21 篇中文文档（随 bundle 打包）
└── README.md
```

## 功能

- **首页 Hero**：渐变大标题、产品简介、统计条、特性卡片网格、快速入口、文档地图。
- **macOS**：三栏 `NavigationSplitView`（分组目录 + 文章 + 目录 TOC 锚点），侧边栏底部版本徽标。
- **iOS**：TabView（首页 / 目录 / 搜索）+ NavigationStack，文章页工具栏弹出 TOC。
- **全局搜索**：标题、小节标题与全文实时过滤，命中高亮与次数统计。
- **代码块**：等宽字体、深色背景、圆角、语言徽标、一键复制。
- **排版**：约 720pt 可读宽度、行距调校、深浅色模式适配、暖木色／琥珀 accent。
- **Markdown 支持**：H1–H4、粗体、斜体、行内代码、围栏代码块、有序／无序／嵌套列表、表格（含对齐）、引用（提示块）、分隔线、链接。

## 新增文章

1. 把 `.md` 文件放进 `Sources/Resources/docs/`（仅使用上述支持的语法子集）。
2. 在 `Sources/Model/DocCatalog.swift` 对应章节注册文件名、标题、摘要与 SF Symbol。
3. 重新运行 `./script/build.sh`。

阅读时间由正文字数自动估算（中文约 420 字/分钟）。
