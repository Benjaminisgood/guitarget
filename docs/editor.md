# 原生曲谱文档与编辑器

`GuitarScoreDocument` 通过 SwiftUI `DocumentGroup` 接入 macOS 原生新建、打开、保存、另存为、未保存状态和关闭流程。文件使用 `com.guitarget.score` / `.guitarget` 类型，严格调用 `GuitarCore.ScoreIO` 读取和写入 JSON。版本、节奏、声部、弦位和技巧验证失败会抛出原生打开错误，读取过程不写原文件。原生文件菜单中的“复制”或按 Option 后的“存储为”可以另存副本。

`ScoreEditorState` 持有选择状态，曲谱由 `FileDocument` 的 Binding 管理。每次渲染刷新 Binding；尚未被 SwiftUI 下一次渲染确认的写入临时缓存在桥内，确认后清除，以免连续按键或检查器读取旧快照。每次有效编辑注册一个原生 `UndoManager` 逆操作；撤销同时注册重做。每个文档编辑器持有一个 Foundation UndoManager，只记录曲谱编辑的逆操作；Canvas 第一响应者、曲谱快捷键和工具栏调用它。FileDocument 窗口自身的管理器继续负责其内部记账及文本字段的原生编辑流程；曲谱编辑器不会采用它，避免逆操作写回文档后的延迟记账清空曲谱重做栈。两者始终读写同一个 FileDocument Binding，没有第二份曲谱历史模型。文本字段获得焦点时仍使用其原生文本撤销。候选值先通过 `ScoreValidator`，错误时保持当前曲谱并显示原因。悬空延音属于可见警告，允许先录延音起点再录目标。

录入：点击谱面选择弦和时间位置，数字输入 0–24 品（连续两位输入窗口 0.8 秒）。同一时间在不同弦输入会合成一个和弦事件。左右键按当前事件时值移动，上下键换弦，Tab 换声部，Return 前进。W/H/Q/E/S/T 选择全音符至三十二分；`.` 附点，R 休止，L 延音，⌫ 删除当前弦音符，⌘C/⌘V 复制粘贴完整事件，⌘X 剪切完整事件，⌘Z/⇧⌘Z 撤销重做，空格播放暂停。

两声部独立计时，旋律蓝色符干向上，低音橙色符干向下。当前音符可在检查器中设置技巧、目标品位、力度和单音延音。和弦中部分音持续使用短时值分段并对需要持续的弦设置延音；另一个声部可同时保持整小节低音。浅色休止表示空余时值，显式休止使用声部颜色。

播放、暂停、停止、定位、变速、节拍器、预备拍、声部静音与循环均调用共享 `AudioService`，每文档使用独立 owner ID；录入试听使用独立的 preview owner，不会把单音试听误认为完整曲谱播放。谱面游标、活动事件和下方 24 品指板同步。循环范围可从检查器选择，也可右键小节设为开始或结束。“跟练”打开共享练习面板，进入前停止本文档示范播放。

键盘能力仅通过 `NSViewRepresentable` 包装一个原生 `NSView` 加入响应者链；Canvas、文档值、选择和检查器均由 SwiftUI 管理。键盘桥在谱面点击后请求第一响应者，不在文字输入期间拦截全局键盘。

## 编辑状态回归验证

`runScoreEditorChecks()` 与异步 `runScoreEditorDelayedUndoCheck()` 使用实际 `ScoreEditorState`、文档 Binding 和 macOS `UndoManager`，覆盖两个独立声部、原生撤销/重做、同弦和超容量拒绝、两位品位、JSON 重开，以及先录起点的和弦单音跨小节延音、静音后的联动高亮。`docs/editor-self-check.json` 保存最近一次十项检查的输出。异步用例模拟逆操作写回后延迟到达的文档记账，确认等待后仍能重做。这是编辑状态验证，不代替实际窗口中的键盘焦点、文件菜单或真琴验收。

从最终 `.app` 重新记录这些检查（构建脚本会先正常关闭旧应用）：

```sh
./script/build_and_run.sh --build-only
open dist/Guitarget.app --args --self-check "$PWD/dist/editor-self-check.json"
cat dist/editor-self-check.json
```

输出的 `passed` 应为 `true`，并包含十项 `checks`。

撤销诊断使用公开 OSLog 字段，可读取管理器身份、注册状态和分组：

```sh
/usr/bin/log show --last 5m --style compact --predicate 'subsystem == "com.guitarget.mac" AND category == "EditorUndo"'
```

附点休止符按基础时值选择图形，附点独立绘制。2026-09-06 使用实际 `ScoreNotationView` 和 SwiftUI `ImageRenderer` 离屏绘制普通／附点十六分与三十二分休止，确认旗数分别保持 2／2 与 3／3，附点可见。图像证据位于 `artifacts/notation-rest-glyphs.png`；该检查未打开或操作应用窗口。
