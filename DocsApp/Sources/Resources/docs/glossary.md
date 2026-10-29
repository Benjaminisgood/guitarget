# 术语表

按主题分组的术语速查，中英对照。带链接的条目在对应文章中有完整解释。

## 记谱与乐理

| 术语 | 英文 | 含义 |
| --- | --- | --- |
| 六线谱 | tablature / tab | 以六条线表示琴弦、数字表示品位的记谱法 |
| 声部 | voice | 独立计时的旋律线；Guitarget 固定为 melody（旋律）与 bass（低音）两部 |
| 小节 | measure | 拍号约束下的时间单位；4/4 为 3840 ticks |
| 拍号 | time signature | 每小节拍数与单位拍；支持 2/4、3/4、4/4、6/8 |
| tick | tick | 内部时间单位；四分音符恒为 960 ticks，不以浮点秒保存谱面 |
| 附点 | dotted | 时值乘 3/2 |
| 三连音 | triplet | 仅八分音符支持，时值 320 ticks |
| 延音 | tie / tieToNext | 连接同弦同品的相邻事件，合并为一次拨弦 |
| 休止 | rest | 空 `notes` 数组的显式事件或谱面补画的空余时值 |
| 根音 | root | 和弦的基准音；转位命名以它为参照 |
| 转位 | inversion | 低音不是根音的和弦形态，如 C/E |
| 音级 | pitch class | 忽略八度的十二音分类（C、C♯…B） |
| 音分 | cent | 半音的百分之一；判定容差与失谐估计的单位 |
| CAGED | CAGED | 以 C、A、G、E、D 五个开放和弦形状组织的指型系统 |
| 五声音阶 | pentatonic | 五音音阶；大调删 4、7 级，小调五声与关系大调五声同音 |
| 蓝调音 | blue note | 布鲁斯音阶中的 ♭5（大调布鲁斯为 ♭3）等张力音 |
| 三和弦 | triad | 根、三、五音构成的和弦；大、小、减三种性质 |
| 强力和弦 | power chord | 只有根音加五音，如 E5 |
| 横按 | barre | 一指同时按多根同品弦 |
| 调内级数 | roman numeral | I–vii° 的罗马数字和声标记 |

## 演奏技巧

| 术语 | 英文 / 标记 | 含义 |
| --- | --- | --- |
| 击弦 | hammer-on / H | 不拨弦捶击出更高音；需 `targetFret` |
| 勾弦 | pull-off / P | 不拨弦勾离出更低音；需 `targetFret` |
| 滑音 | slide / ／ | 按住滑向目标品位；需 `targetFret` |
| 推弦 | bend（½ / 1） | 半音或全音推弦 |
| 揉弦 | vibrato / ～ | 周期性音高调频 |
| 闷音 | palm mute / P.M. | 掌缘制音加强阻尼 |
| 死音 | dead note / × | 短噪声冲击，无确定音高；不能延音 |

## 音频与算法

| 术语 | 英文 | 含义 |
| --- | --- | --- |
| 钢弦模型 | steel-string model | Karplus–Strong 分数延迟线 + 琴体共振 + 混响的物理合成 |
| Karplus–Strong | Karplus–Strong | 拨弦物理建模算法：延迟线循环 + 低通阻尼 |
| 起音 | onset / attack | 拨弦攻击时刻；独立于音高窗口检测，90 ms 不应期 |
| YIN | YIN | 基于累积均值归一差分的单音音高检测算法（65–1500 Hz） |
| 置信度 | confidence | YIN 输出可信程度；低于 0.80 不输出音高 |
| RMS | RMS | 均方根能量；低于 0.004 视为静音 |
| FFT | Fast Fourier Transform | 自研基 2 快速傅里叶变换 |
| chroma | chroma | 十二音级能量向量；识别中分高音区／低音区两套 |
| NNLS | non-negative least squares | Lawson–Hanson 非负最小二乘，把谱分解为 56 个音的显著度 |
| HMM | hidden Markov model | 带惯性的前向滤波，平滑和弦判定切换 |
| process tap | CoreAudio process tap | 采集系统或其他进程音频输出的 macOS API（`CATapDescription` + `AudioHardwareCreateProcessTap`） |
| aggregate device | aggregate device | 组合设备；process tap 用默认输出主时钟构建私有 aggregate |
| 环形缓冲 | ring buffer (CaptureRing) | 无锁 SPSC 缓冲，音频回调只复制样本与时间戳 |
| 单调时钟 | monotonic clock | 评分与时间戳使用的不可回退时钟（`mHostTime` 锚点） |
| 跟拍校准 | tempo/latency calibration | 用多次起音的中位偏移估计输入延迟（含人为跟拍偏差） |
| 演奏模式 | performance mode | 附加音频／无伴奏时的只读模式，谱位由输入单音跟随 |
| 跟随器 | ScoreFollower | 演奏模式的位置确认器：约 120 ms 可信单音证据推进谱位 |
| A4 基准 | A4 reference | 标准音频率，默认 440 Hz，可调 400–480 Hz |

## 应用与数据

| 术语 | 英文 | 含义 |
| --- | --- | --- |
| 学习室 | Learning Room | 十栏目主窗口 |
| 我的曲库 | My Library | 本地曲谱、歌词、音频绑定与链接的管理中心 |
| 曲库清单 | library.json | 曲库目录文件，与 UUID 子目录共同构成曲库数据 |
| 入门谱 | starter scores | 首次使用自动加入的六份自编曲谱 |
| 附加音频 | attached audio | 绑定进曲库并复制到本地的原声／伴奏／录音 |
| 预备拍 | count-in | 正式播放前的倒数拍 |
| 联动指板 | linked fretboard | 编辑器下方随播放与选择同步的 24 品指板 |
| 演奏提示 | performance guide | 前句／当前歌词／后句与前后和弦的提示区 |
| 自检 | self-check | `--self-check` 启动参数触发的原生状态与音频离线诊断 |
| QA 实例 | QA instance | 独立 bundle ID 与数据目录的验收专用应用副本 |
| ad hoc 签名 | ad hoc signing | 本地临时签名，仅开发运行，不含分发与公证 |
