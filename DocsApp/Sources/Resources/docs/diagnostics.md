# 开发诊断与自检

Guitarget 内置多条不依赖 UI 手工操作的诊断路径：应用自检、识别冒烟、硬件冒烟、离线诊断与结构化日志。本文汇总命令、产物与解读方式，全部可在本地复现。

## 应用自检（--self-check）

```sh
./script/build_and_run.sh --build-only
open dist/Guitarget.app --args --self-check "$PWD/artifacts/app-self-check.json"
```

自检调用**真实的原生编辑状态和 UndoManager**（`ScoreEditorState`、文档 Binding、macOS 撤销管理器），并输出：

- 六弦数值诊断（合成信号频率核对）；
- `steel-string-demo.wav`（钢弦模型演示音频）；
- `reference-a4.wav`（440 Hz 参考音）。

它**不会启动采集**，也不把算法结果描述为真琴准确率。JSON 报告的 `passed` 应为 `true`。最新正式包自检含 **23 项原生检查 + 音频离线自检**。

### 编辑器专项

`runScoreEditorChecks()` 与异步 `runScoreEditorDelayedUndoCheck()` 覆盖两个独立声部、原生撤销重做、同弦和超容量拒绝、两位品位、JSON 重开、和弦单音跨小节延音、静音后的联动高亮，以及"逆操作写回后延迟到达的文档记账不破坏重做栈"。另有 `runScoreTransportChecks()` 在 QA 进程中用实际 `AudioService` 连续三轮验证选择→播放→暂停→重选→续播的完整传输链路。

## 和弦识别冒烟（--chord-recognition-smoke）

```sh
open dist/Guitarget.app --args --chord-recognition-smoke "$PWD/artifacts/chord-smoke"
```

流程：让 `afplay` 播放合成的 C–G–Am–F–C/E 扫弦 → 应用通过 **CoreAudio process tap 只采集该进程** → 把 `chordFrames` 折叠成连续段与预期序列比对 → 报告写入 `chord-recognition-smoke.json`。

2026-09-24 本机通过示例：180 帧、平均匹配 0.95、五段依次为 C、G、Am、F、C，最后一段全部帧带 E 低音；段间切换处有 1–4 帧过渡判定。

## QA 实例与硬件冒烟

```sh
./script/stage_qa.sh                          # 生成独立 bundle ID 的 QA 应用
./script/stage_qa.sh --hardware-smoke         # 真实采集 + 自管理参考播放器
./script/stage_qa.sh --system-isolation-smoke # 双来源系统采集隔离实验
```

- QA 实例使用独立数据目录与授权状态，避免操作主应用文档。
- 隔离实验用纯 Swift helper（`script/AudioTestSource.swift`）播放 440 Hz 与 697 Hz 两个来源，验证 process tap 按进程／bundle ID 隔离、自身声音排除（0 有效帧、RMS 0）与输出设备回读。
- 运行前应正常退出旧 QA 应用；只停止本次创建的播放器。

## 离线音频测试

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter GuitarAudioTests
```

17 个音频测试覆盖：六根空弦及更高已知频率、静音、确定性宽带噪声、失谐、强二次谐波的八度判定、实际分数延迟合成的六弦识别、全部技巧的非零输出与区别、停止清空尾音、120 ms 稳定判定、重复起音与独立时间戳、整小节低音加八个八分旋律音、跨小节延音只触发一次、定位到持续低音、循环、变速保持音高、预备拍不推进谱面、环形缓冲区溢出。

`AudioDiagnostics.run` 输出 `renderBenchmark`、八个开放和弦的 `chordMeasurements`、`chordBenchmark` 与 `processingBudgetPassed`，本地报告在 `artifacts/audio-optimized/audio-diagnostics.json`。

## 结构化日志

应用日志走公开 OSLog，subsystem 为 `com.guitarget.mac`：

```sh
/usr/bin/log show --last 5m --style compact \
  --predicate 'subsystem == "com.guitarget.mac" AND category == "EditorUndo"'
```

`EditorUndo` 分类记录撤销管理器身份、注册状态和分组，曾用于定位文本字段撤销污染曲谱历史的缺陷。构建脚本的 `--logs` 与 `--telemetry` 模式分别跟随进程日志与该 subsystem。

## 验收记录（docs/acceptance.md）

验收文档是诊断文化的载体，按日期记录三类证据：

| 类别 | 例子 |
| --- | --- |
| 自动化 | 139 项 XCTest、离线合成 180 按法识别 177 正确 |
| 原生窗口操作 | 真实 `.app` 中键入 12 品、三条路径撤销重做 12→1→12、密集谱 31 次方向键滚动 |
| 真琴与硬件 | 内置麦克风 100 秒真琴引导（375 帧）、八个 E2 节拍跟练 8/8、校准 +4 ms |

关键约定：**失败记录不因后续修复而删除**（系统采集启动超时、麦克风格式协商失败都保留在案）；未测量的项目（物理端到端延迟、真琴识别准确率）明确标注未完成，不用离线结果冒充。

## 诊断速查

| 症状 | 命令 |
| --- | --- |
| 构建后应用行为异常 | `./script/build_and_run.sh --debug`（lldb 挂载） |
| 查看运行时日志 | `./script/build_and_run.sh --logs` |
| 核对合成与识别 | `--self-check` 后查看 `artifacts/app-self-check.json` 与两个 wav |
| 验证系统采集链路 | `stage_qa.sh --system-isolation-smoke` |
| 撤销历史问题 | `log show` 过滤 `EditorUndo` |

> **提示**：所有冒烟命令都设计为**可重复、产物落盘**：JSON 报告带时间戳与明确的 `passed` 字段，音频产物可直接试听。给项目提改动时，跑一遍对应冒烟并保留新旧报告，是这个仓库的惯例。
