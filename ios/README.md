# Guitarget iOS

macOS 版 Guitarget 的 iOS 客户端。它直接复用同一个 SwiftPM 包里的 `GuitarCore`
（乐理 / 曲谱 / 调音 / 和弦识别算法）与 `GuitarAudio`（YIN 单音、和弦分析、
物理建模合成与 `AudioService`），只为触屏重写了 SwiftUI 界面。

macOS 端不受影响：`Sources/Guitarget` 与 `script/` 未做任何行为改动，
`GuitarAudio` 中平台专属代码只用 `#if os(macOS)` 包裹。

## 生成工程

```sh
xcodegen generate --spec ios/project.yml --project ios
```

生成物固定在 `ios/Guitarget.xcodeproj`（已被 `.gitignore` 之外的新增目录，
可重复生成，不需要提交）。

## 构建

真机架构（无签名）：

```sh
xcodebuild -project ios/Guitarget.xcodeproj -scheme Guitarget-iOS \
  -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build
```

模拟器架构（需已安装 iOS 模拟器 runtime）：

```sh
xcodebuild -project ios/Guitarget.xcodeproj -scheme Guitarget-iOS \
  -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' \
  CODE_SIGNING_ALLOWED=NO build
```

在 Xcode 中打开工程后，运行到真机需要把 `CODE_SIGNING_ALLOWED` 改回 `YES`
并配置自己的开发团队。

## 功能

- **调音**：`TunerEngine` 实时音分表、空弦目标网格、A4 基准与调弦预设、参考音播放。
- **和弦**：`ChordTracker` 多音识别（置信度 / 候选 / 保持时长）+ `ChordLibrary` 指法查询与扫弦、分解试听。
- **曲谱**：`LocalScoreLibrary`（Documents 下 `Guitarget/MyLibrary`）保存 / 删除，内置示例一键导入，
  `ScoreRenderer` 回放并带速度、节拍器、进度与逐小节音名。
- **练习**：`ChordPracticeDeck` 生成换和弦卡片，配合实时识别判定是否正确，统计顺畅 / 生疏。

底部常驻采集条控制麦克风采集（`CaptureSource.input`）。

## 已知限制

- 部署目标为 **iOS 18**：`GuitarAudio` 的无锁 DSP 状态使用 `Synchronization.Atomic`，
  该框架最低 iOS 18。
- **系统声音采集不可用**：macOS 的进程 tap（`CATapDescription` / 聚合设备）没有 iOS 对应物，
  `CaptureSource.system` 在 iOS 上会返回明确错误，只支持麦克风。
- **不能选择输入 / 输出设备**：iOS 由系统路由，`AudioService.setOutputDevice` 只记录选择，
  设备列表来自 `AVAudioSession.currentRoute`。
- 未处理 `AVAudioSession` 中断（来电）与路由变化的自动恢复；未包含曲谱编辑器、
  五线谱 / 指板绘制与参考音频对齐等 macOS 专有功能。
- 未附带 iOS 单元测试 target（共享逻辑由 `Tests/GuitarCoreTests`、`Tests/GuitarAudioTests` 覆盖）。
