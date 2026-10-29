# 安装、构建与运行

Guitarget 不通过 App Store 分发，而是从源码在本地构建出 `dist/Guitarget.app`。仓库自带两个脚本：`build_and_run.sh` 负责构建、签名与启动，`test.sh` 负责跑全部 XCTest。本文覆盖系统要求、脚本用法、参数与常见构建问题。

## 系统要求

| 项目 | 要求 |
| --- | --- |
| 操作系统 | macOS 15 或更新（项目在 macOS 26 上验证） |
| 工具链 | Swift 6 工具链；Xcode 或 Command Line Tools 均可构建 |
| 测试 | 建议安装 Xcode：部分 Command Line Tools 不包含 XCTest，`test.sh` 检测到 Xcode 时自动使用它的工具链 |
| 依赖 | 无第三方包，无需 `swift package resolve` 联网 |

## 一键构建并启动

在仓库根目录执行：

```sh
./script/build_and_run.sh
```

脚本会完成以下动作：

1. 若 Guitarget 正在运行，先通过 AppleScript 请求**正常退出**（`tell application id "com.guitarget.mac" to quit`）；未保存文档由系统弹窗处理，用户取消关闭时脚本直接失败退出，**不会强杀进程**。
2. `swift build` 编译三个目标（GuitarCore、GuitarAudio、Guitarget）。
3. 把二进制复制到 `dist/Guitarget.app/Contents/MacOS/`，连同 `script/Info.plist` 与 `Guitarget.icns` 组装应用包。
4. 调用 `script/finalize_app_bundle.sh` 做本地临时签名（ad hoc，仅开发用，不含对外分发或公证）。图标文件缺失会**中止打包**。
5. `open dist/Guitarget.app` 启动应用。

Codex 的 **Run** 按钮调用的也是同一脚本。正式包与 QA 包在签名后都会更新包目录时间并重新登记应用，让 Finder 和程序坞刷新图标。

### 脚本参数

```sh
./script/build_and_run.sh [--build-only|--verify|--debug|--logs|--telemetry]
```

| 参数 | 行为 |
| --- | --- |
| （无参数） | 构建、打包并启动应用 |
| `--build-only` | 只构建打包，不启动 |
| `--verify` | 启动后等待 2 秒，用 `pgrep` 验证进程存活 |
| `--debug` | 用 lldb 挂载启动，便于断点调试 |
| `--logs` | 启动并跟随 `log stream`，过滤 `process == "Guitarget"` |
| `--telemetry` | 启动并跟随 subsystem 为 `com.guitarget.mac` 的结构化日志 |

## 运行测试

```sh
./script/test.sh
```

脚本内容极简：设置 `DEVELOPER_DIR` 指向 Xcode（若存在），然后执行 `swift test "$@"`，可以透传过滤器：

```sh
./script/test.sh --filter GuitarAudioTests
```

两点值得注意：

- **DSP 模块的 Debug 构建也启用 `-O` 优化**，因为未优化的 YIN 单窗口约 63–65 ms，超过 25 ms 的分析周期预算；优化后同一窗口约 0.41–0.46 ms。UI 与曲谱模块仍保留普通调试构建。
- 最新一轮完整测试为 **139 项 XCTest，0 失败**（乐理、文档、调度、识别、练习状态机、和弦库、调音器、合奏编配等）。

## 首次启动清单

1. 主窗口进入**学习室**：左侧十个栏目（指板、音阶、CAGED、三和弦、和弦库、调音器、和弦识别、合奏、和弦练习、曲谱）。
2. 点击**曲谱 → 我的曲库**：首次使用自动加入六份自编入门谱（爬格子、C 大调音阶、分解和弦、小星星、欢乐颂、Frère Jacques）。
3. 窗口底部是**声音来源**状态栏：输入和输出设备独立选择；采集必须由用户显式启用。编辑、保存和普通试听**不要求任何录音权限**。
4. 默认参数：A4 = 440 Hz、标准调弦、4/4 拍、80 BPM；界面外观跟随系统深浅色。
5. 按 ⌘N 新建曲谱文档窗口，或从曲库打开已有谱。

## QA 验证实例

```sh
./script/stage_qa.sh
```

生成独立 bundle ID 的 `Guitarget QA.app`，数据目录也独立（`Guitarget QA/MyLibrary/`），可以在不碰主应用文档与权限的前提下做破坏性验收。该实例仅用于开发。可附加 `--hardware-smoke`、`--system-isolation-smoke` 等参数运行硬件冒烟，详见《开发诊断与自检》。

## 开发自检

构建后可直接让应用输出诊断产物：

```sh
./script/build_and_run.sh --build-only
open dist/Guitarget.app --args --self-check "$PWD/artifacts/app-self-check.json"
```

自检调用原生编辑状态和 UndoManager，输出六弦数值诊断、`steel-string-demo.wav` 与 `reference-a4.wav`；它不会启动采集，也不会把算法结果描述为真琴准确率。

## 常见构建问题

| 症状 | 处理 |
| --- | --- |
| `swift build` 找不到 XCTest | 安装完整 Xcode，或让 `test.sh` 自动设置 `DEVELOPER_DIR` |
| 打包中止并提示图标缺失 | 检查 `script/Guitarget.icns` 是否存在；脚本故意 fail-fast |
| 旧实例未退出导致构建失败 | 处理保存对话框后重试；脚本不会 SIGKILL |
| 权限弹窗未出现 | 采集只在点击"开始采集"时请求授权；QA 实例与正式实例的授权互相独立 |

> **提示**：签名仅为本地开发的 ad hoc 临时签名。对外分发需要 Developer ID 签名与公证，超出本项目当前范围。
