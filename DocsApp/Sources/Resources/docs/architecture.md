# 架构与技术实现

本文面向想读懂或改动 Guitarget 的开发者：三大模块划分、播放与采集两条音频链路、钢弦物理建模、YIN 音高、NNLS 和弦识别管线，以及实时性能预算。所有实现均为原生 Swift，仅链接 Apple 系统框架。

## 模块划分

| 模块 | 职责 | 规模 |
| --- | --- | --- |
| `Sources/GuitarCore` | 乐理（音级、音阶、CAGED 数据）、唯一 `GuitarScore` 模型、ticks 时值体系、`ScoreValidator` 校验、`ScoreScheduler` 延音调度、`PracticeEngine` 跟练状态机、`ChordLibrary` 穷举、`LocalScoreLibrary` 曲库、`ScoreFollower` 演奏跟随 | 约 3100 行 |
| `Sources/GuitarAudio` | 六弦 DSP 合成、音频时钟、采集设备管理、CoreAudio process tap、YIN 音高、自研 FFT / NNLS 和弦识别、`AudioService` 共享服务 | 约 2200 行 |
| `Sources/Guitarget` | SwiftUI 场景、原生文档（`DocumentGroup` / `FileDocument`）、Canvas 六线谱、`NSView` 键盘桥、学习室十个栏目视图、原生自检 | 约 7000 行 |

依赖方向单向：UI → Audio → Core。`Tests` 覆盖乐理、文档、调度、识别与练习回归，最新一轮 **139 项 XCTest 全部通过**。

## 播放链路

```text
GuitarScore
  → ScoreScheduler.notes        # 逐音合并延音
  → ScoreRenderer               # 六弦物理模型渲染
  → AVAudioSourceNode           # 拉模式回调
  → AVAudioEngine
  → 独立选择的输出设备
```

- `AudioService.shared` 由所有窗口共享；`ownerID` 表示当前取得播放控制权的文档或学习模块，**新播放会停止上一个播放者**（`PlaybackCoordinator` 在同一进程内同步移交）。
- 旋律和低音在同一回调内按同一个 **48 kHz 样本计数器**调度；速度改变重新计算 ticks/sample，不改变拨弦频率。
- `transportStartHostTime` 来自首个输出回调的 `AudioTimeStamp.mHostTime` 减去当前样本位置（包含预备拍）；练习评分使用该**单调时钟锚点**，而不是按下播放按钮的时间。
- UI 游标以 **30 Hz** 从样本计数读取；调音器音高和电平以 **10 Hz** 更新；独立的 `pitchFrames` publisher 按分析原始频率发送每个有效帧，**跟练评分不经 UI 节流**。
- 暂停保留合成器状态；定位重建仍在持续的弦音（按已经过时长衰减重建，物理模型重建而非 PCM 逐位复现）；停止和循环清空琴弦、琴体与混响，跨循环起点仍在持续的音避免上一遍尾音泄漏。

## 钢弦物理建模（Karplus–Strong）

合成器完全由 Swift 实现，每根弦独立：

- 带**线性插值分数延迟**的 Karplus–Strong 循环；
- **速度相关的拨片激励**与高频阻尼（velocity 越大越亮）；
- 三个**琴体共振模式** + 轻量反馈混响；
- **12 Hz 直流阻断滤波**，防止随机拨弦激励产生持续的扬声器直流偏置；
- 六根弦具有**确定的随机种子**，自动化结果可复现。

技巧在物理层实现：击弦／勾弦**保留弦的振动状态**；滑音连续修改分数延迟；推弦到半音／全音；揉弦作周期调频；闷音加强阻尼；死音使用短噪声冲击。三十二分音符的推弦、滑音、击勾弦过渡随实际事件时长缩短（0.5×、1×、3× 变速均有测试）。

## 采集链路

```text
麦克风/声卡 AVAudioEngine input tap  或  CoreAudio process tap
  → CaptureRing           # 预分配 SPSC 环形缓冲
  → 专用分析队列           # YIN + 起音 + 和弦识别
  → PitchFrame / ChordFrame
  → MainActor UI
```

- 输入与系统采集**互斥**。
- `CaptureRing` 是单生产者／单消费者环形缓冲区，通过 Swift `Synchronization.Atomic` 传递样本：音频回调**只复制 Float32 样本及其原始单调时间戳**——不更新 UI、不执行 YIN、不申请数组内存、无互斥锁。缓冲区满时丢弃新样本并计数，避免覆盖未读取数据。

### CoreAudio process tap（系统声音采集）

系统采集使用真实 `CATapDescription` + `AudioHardwareCreateProcessTap`，配合带默认输出设备主时钟的**私有 aggregate device** 与 `AudioDeviceCreateIOProcIDWithBlock`。关键工程决策：

| 决策 | 原因 |
| --- | --- |
| aggregate 不等待源 App 的新启动转换 | 安静时仍应回调零样本 |
| 用 `IOProcStreamUsage` 关闭物理声卡输入输出流 | 只读 aggregate 最后的 process tap 输入流，避免把声卡麦克风当作系统声音 |
| 分析采样率取自 aggregate **协商后**的名义采样率 | 蓝牙输出可能为 44.1 kHz，不能沿用创建前的 48 kHz 假设 |
| 整机混音明确**排除自身 CoreAudio process ID**（macOS 26 上同时排除自身 bundle ID） | 否则合成音会污染识别；无法确定自身 PID 时**报错**，不悄悄创建包含自身的混音 |
| tap 的创建、检查与销毁移到串行后台队列，启动等待 10 秒 | HAL 调用可能阻塞（`MACH_RCV_TIMED_OUT`），主线程同步等待会卡死窗口 |
| 默认系统输出时钟或采样率变化时停止采集并提示 | 保持时间戳一致性 |

只读取音频，不截取屏幕或视频。指定 App 模式选择 CoreAudio 音频进程；每次采集使用独立缓冲区，迟到回调核对会话身份。

## YIN 音高与起音检测

- YIN 在分析队列计算**累积均值归一差分**（CMND）和局部抛物线插值，频率范围 **65–1500 Hz**。
- 48 kHz 输入先相邻平均低通再降采样到 24 kHz，窗口 **2048 点**（对应原始 4096 点，约 85.3 ms），约 **25 ms** 更新一次；更低采样率直接分析。
- 输入 RMS < 0.004 或置信度 < 0.80 时**不输出虚假音高**。
- 相邻谷簇内的小范围细化避免钢弦激励产生的近邻假极小值，并限制搜索不跨入另一八度候选。
- **起音检测**独立扫描 128 个原始样本，以能量上升、差分高频能量重新增加和背景阈值记录攻击的原始时间，**90 ms 不应期**；实现为逐采样的连续功率平滑，按秒计算能量及亮度背景（修复了谐波持续音误报 31 个起音的旧缺陷，96 组合回归全部单起音）。
- `PitchFrame.timestamp` 是采样窗口中心；`onsetTimestamp` 是独立检测的最近攻击时间——**两者都不会以 UI 收到结果的时间代替**。
- 稳定性：连续帧变化 < 18 音分且持续 ≥ 120 ms；静音／丢帧后重置。

## 和弦识别管线（NNLS chroma + HMM）

思路沿用 Mauch & Dixon 2010 的 NNLS chroma（Chordino），针对单把吉他调整，全部原生 Swift（`ChordAnalysis.swift`、`ChordRecognition.swift`）：

1. **窗口**：最接近 0.34 秒的 2 的幂（16384 点），每 1/8 窗口（约 43 ms）分析一次；RMS < 0.004 视为静音。
2. **对数频率谱**：自研基 2 FFT + 汉宁窗；功率按**每半音三格、C2 起 74 个半音**的网格用三角核映射，核宽取格宽与 FFT 分辨率的较大者，保证任意频率正弦贡献相同总功率。
3. **音准**：对会话累计谱按三格周期取相位，估计整体偏离（−50…+50 音分），用于对齐谱峰并在界面显示。
4. **压缩**：减去第 20 百分位噪声底后开平方。刻意不用 Chordino 的局部标准化——它会放大空旷邻域的低音峰、抹平字典依赖的谐波衰减。
5. **近似转录**：Lawson–Hanson NNLS 把压缩谱分解为 **E2–B6 共 56 个音**的显著度；字典为几何衰减（每分音 0.5）谐波序列，由同一分析算子对理想加窗正弦生成。不建模 E2 以下的音，避免把 D3–A3–F♯4 解释成 D2 的泛音列。
6. **清理**：低于最强音 20% 视为分解噪声；响 3 倍以上的半音邻居是低频宽峰泄漏；远弱于低音的第 5、7 分音与第 3、6 分音按不同门限剔除；最强音的伴音全是弱分音时判为单音。
7. **音级折叠**：高音区色度按每个音级取最响八度显著度的平方根（三根弦重复的根音不应压过只出现一次的三音）；低音区色度以最低音为中心加权，用于转位与同音级集合（Am7/C6、Csus2/Gsus4、减七、增三）的区分。
8. **判定**：205 个模板按余弦匹配加低音奖励打分，经**带惯性的 HMM 前向滤波**（切换概率 0.03、锐度 18）输出后验最高状态、匹配度、保持时长与前三候选；低音为非根音和弦音时标转位（C/E）。

`ChordFrame.timestamp` 为窗口中心时间，比实时约晚半个窗口。和弦识别与 YIN 在同一分析队列并行，读同一环形缓冲，不触碰实时回调。

## 实时性能预算

| 项目 | 未优化 | 优化后 | 预算 |
| --- | --- | --- | --- |
| YIN 单窗口 | 63–65 ms | 0.41–0.46 ms | 25 ms 分析周期 |
| 六弦渲染（256 样本块，48 kHz） | — | 平均 0.023 ms，最大 0.10 ms | 5.33 ms |
| 和弦识别每跳（2048 样本） | — | 约 0.7 ms（含 16384 点 FFT、映射、NNLS、解码） | 42.7 ms |

`GuitarAudio` 目标在 **Debug 配置下也显式使用 `-O`**；SwiftUI 和核心模型保留普通 Debug 体验。数值结果最大音分误差 < 0.31 音分。`AudioDiagnostics.run` 输出 `renderBenchmark`、八个开放和弦的 `chordMeasurements`、`chordBenchmark` 与 `processingBudgetPassed`。

## UI 层关键决策

- **六线谱**用 Canvas 逐音符绘制（不用文本排版引擎），密集谱保证品位数字、符尾、PM 标记互不覆盖；离屏 `ImageRenderer` 曾用于休止符字形的图像级回归。
- **键盘桥**：`NSViewRepresentable` 包装一个原生 `NSView` 加入响应者链，谱面点击后请求第一响应者；不在文字输入期间拦截全局键盘。
- **撤销隔离**：每文档一个 Foundation `UndoManager` 只记录曲谱编辑逆操作；底层 `NSTextStorage` 提供 `nil` 撤销管理器，文本字段用原生文本撤销——修复过"字段撤销污染曲谱历史"与原生重做 `NSRangeException` 两个真实缺陷。
- **Binding 桥**：尚未被 SwiftUI 下一次渲染确认的写入临时缓存在桥内，避免连续按键读到旧快照。

## 数据层

- `.guitarget` 版本化 JSON，四分音符恒 960 ticks；`ScoreIO` 读写、`ScoreValidator` 校验；失败读取不改写源文件，文件安全测试覆盖整数极值、非法节奏、非整数 ticks、未知版本与非有限数值。
- 曲库 `library.json` 清单 + UUID 子目录；路径解析符号链接、拒绝非文件夹、清单丢失时保留现有文件并报错。

## 测试与验证哲学

离线测试（17 项音频专项 + 其余共 139 项）证明**算法与调度**在确定输入下的正确性；`--self-check`、`--chord-recognition-smoke`、`stage_qa.sh --hardware-smoke` 等冒烟验证**真实链路**；真琴、麦克风和房间条件下的准确率**明确标注未测量**。三类证据不互相冒充——这是整个工程最重要的约定。
