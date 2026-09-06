# Guitarget 音频实现与验证

## 数据流

`AudioService.shared` 由所有窗口共享；`ownerID` 表示当前取得播放控制权的文档或学习模块。新播放会停止上一个播放者。试听无需任何录音权限。

播放：`GuitarScore → ScoreScheduler.notes（逐音合并延音）→ ScoreRenderer → AVAudioSourceNode → AVAudioEngine → 独立选择的输出设备`。旋律和低音在同一回调内按同一个 48 kHz 样本计数器调度。速度改变重新计算 ticks/sample，不改变拨弦频率。暂停保留合成器状态，定位重建仍在持续的弦音，停止和循环清空琴弦、琴体与混响。跨循环起点仍在持续的音按已经过时长衰减重建，避免上一遍尾音泄漏。这里是按物理模型重建持续音，而非对之前 PCM 的逐位复现。

`transportStartHostTime` 来自首个输出回调的 `AudioTimeStamp.mHostTime`，减去当前样本位置，包含预备拍。UI 游标以 30 Hz 从样本计数读取；公开的调音器音高和电平以 10 Hz 更新，独立 `pitchFrames` publisher 按分析原始频率发送每个有效 frame，跟练评分不经 UI 节流；练习评分使用该单调时钟锚点，而不使用按下播放按钮的时间。重新定位和变速会建立新锚点。

钢弦模型由 Swift 实现：每根弦独立的带线性插值分数延迟 Karplus–Strong 循环、速度相关拨片激励和高频阻尼、三个琴体共振模式及轻量反馈混响，以及 12 Hz 直流阻断滤波，防止随机拨弦激励产生持续的扬声器直流偏置。击弦／勾弦保留弦的振动状态，滑音连续修改分数延迟，推弦到半音／全音，揉弦作周期调频，闷音加强阻尼，死音使用短噪声冲击。六根弦具有确定的随机种子，自动化结果可以复现。

采集：`麦克风或外接声卡 AVAudioEngine input tap / CoreAudio process tap → CaptureRing → 专用分析队列 → PitchFrame → MainActor UI`。输入与系统采集互斥。预分配的单生产者／单消费者环形缓冲区通过 Swift `Synchronization.Atomic` 传递样本；回调只复制 Float32 样本及其原始单调时间戳，不更新 UI、不执行 YIN、不申请数组内存、无互斥锁。环形缓冲区满时丢弃新样本并计数，避免覆盖尚未读取的数据。

系统采集使用真实 `CATapDescription`、`AudioHardwareCreateProcessTap`、带默认输出设备主时钟的私有 aggregate device 与 `AudioDeviceCreateIOProcIDWithBlock`。aggregate 不等待源 App 的新启动转换；安静时仍应回调零样本。物理声卡输入和输出流通过 `IOProcStreamUsage` 关闭，只读取 aggregate 最后的 process tap 输入流，避免把声卡麦克风当作系统声音。分析采样率取自 aggregate 协商后的名义采样率；不能沿用 process tap 创建前的 48 kHz，因为蓝牙输出可能为 44.1 kHz。默认系统输出时钟或采样率变化时停止当前系统采集并提示重新开始。整机混音明确排除 Guitarget 自身 CoreAudio process ID；macOS 26 上同时排除自身 bundle ID。无法确定自身 process ID 时会报错，不会悄悄创建包含自身的混音。指定 App 模式选择 CoreAudio 音频进程。只读取音频，不截取屏幕或视频。

## 音高、起音与稳定性

YIN 在分析队列计算累积均值归一差分和局部抛物线插值，范围 65–1500 Hz。48 kHz 输入采用相邻平均低通后降采样到 24 kHz，窗口 2048 点（对应原始 4096 点，约 85.3 ms），约 25 ms 更新一次；更低采样率直接分析。输入 RMS 小于 0.004 或置信度低于 0.80 时不输出虚假音高。相邻谷簇内的小范围细化避免钢弦激励产生的近邻假极小值，并限制搜索不跨入另一八度候选。

短块起音检测独立扫描 128 个原始样本，以能量上升、差分高频能量重新增加和背景阈值记录攻击的原始时间；有 90 ms 不应期。同音的自然延音不会不断生成新起音。保持低 E 后同等力度再次拨弦的独立回归测试验证一次持续音只生成一次起音，两次拨弦生成两次。音高 frame 的 `timestamp` 是采样窗口中心；`onsetTimestamp` 是独立检测的最近攻击时间。两者不会以 UI 收到分析结果的时间代替。稳定性要求连续帧变化小于 18 音分且持续至少 120 ms，静音／丢帧后重置。

音高识别不能推断实际弦位，也不承诺复音音高识别、音箱串音消除或真实演奏准确率。窗口长度和硬件缓冲都贡献显示延迟；评分用起音时间与可校准的输入偏移，避免把 YIN 等待时间误当成拖拍。

## 权限与设备状态

- 麦克风／外接声卡仅在用户点击“开始采集”时请求 `AVCaptureDevice` 音频授权。
- 系统采集仅在用户点击开始时创建 process tap，让 macOS 处理系统音频录制授权。
- App 包含 `NSMicrophoneUsageDescription` 与 `NSAudioCaptureUsageDescription`。
- 拒绝授权、CoreAudio 错误或采集没有返回帧时显示原因；编辑和播放保持可用。
- 每秒刷新设备和音频进程；显式输入设备断开、指定来源 App 退出、麦克风授权变化或连续 4 秒无采样帧会停止采集。
- 输出设备独立于采集来源。设备断开会停止播放并恢复默认输出。
- 使用麦克风加伴奏时提示佩戴耳机。

## 自动化证据

运行：

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter GuitarAudioTests
```

本机 2026-09-05 执行 17 个音频测试全部通过。测试包含六根空弦及更高已知频率、静音、确定性宽带噪声、失谐、强二次谐波的八度判定、实际分数延迟合成的六弦识别、全部技巧的有限非零输出与区别、停止清空尾音、120 ms 稳定判定、重复起音及独立时间戳、整小节低音与八个八分旋律音、跨小节延音只触发一次、定位到持续低音、循环、变速保持音高、预备拍不推进谱面以及环形缓冲区溢出。

这些是算法与调度的自动化证据，不等价于麦克风或真琴的实际准确率。真实 .app 的设备、权限与听感验收记录由项目验收报告另行保存。需真琴分别测试六空弦、低 E 弱拨／强拨、持续音和同音再拨、±25 音分阈值、接声卡后延迟校准、系统混音与指定 App、自身声音排除，以及授权拒绝后继续编辑试听。无真实测量时不得报告虚构准确率或延迟。

## 开发构建的实时性能

`GuitarAudio` 目标在 Debug 配置下也显式使用 Swift `-O`；SwiftUI 和核心模型仍保留普通 Debug 体验。实测未优化 YIN 单窗口约 63–65 ms，会超过 25 ms 分析更新周期。优化后相同窗口约 0.41–0.46 ms，六弦并发含连续变音时每 256 样本渲染块平均约 0.023 ms、最大约 0.10 ms，而 48 kHz 下该块时限为 5.33 ms。数值结果的最大音分误差仍小于 0.31 音分。具体数值会受机器负载影响，离线基准不是声卡端到端延迟测量。`AudioDiagnostics.run` 同时输出 `renderBenchmark` 和 `processingBudgetPassed`，本地报告位于 `artifacts/audio-optimized/audio-diagnostics.json`。
