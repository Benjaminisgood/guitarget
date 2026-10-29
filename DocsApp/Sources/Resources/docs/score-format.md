# .guitarget 曲谱格式

`.guitarget` 是 UTF-8 JSON 文件，统一解码为 `GuitarScore`。没有网络、插件或脚本执行入口；AI 可以直接生成 JSON，用应用打开时执行与人工录谱**相同的结构与乐理时值校验**。当前版本为 1。

## 顶层字段

| 字段 | 类型 | 约定 |
| --- | --- | --- |
| `version` | 整数 | 必须为 `1`；未知版本拒绝读取 |
| `title` | 字符串 | 文档标题 |
| `tuning` | 六个整数 | 第 1 弦（最高）到第 6 弦（最低）的 MIDI 音高；标准为 `[64,59,55,50,45,40]`；调弦、调弦加品位、技巧目标均须处于 MIDI 0–127 |
| `timeSignature` | 对象 | `numerator`、`denominator`，支持 2/4、3/4、4/4、6/8 |
| `bpm` | 数值 | 四分音符每分钟，20–300；默认 80；6/8 也按四分音符计速 |
| `measures` | 小节数组 | 至少一个小节；数组顺序就是播放顺序 |

## 小节、声部与事件

每小节含 UUID 字符串 `id` 与 `voices` 数组；`voices` 必须**恰好**包含 `{"voice":"melody",...}` 和 `{"voice":"bass",...}` 两项。两个声部各自独立计时，均使用同一小节起点。

每事件含 UUID `id`、整数 `startTick`、`rhythm` 和 `notes`：

- **四分音符固定 960 ticks**；4/4 小节固定 3840 ticks（2/4 为 1920，3/4 与 6/8 为 2880）。
- `startTick` 是小节内偏移，不是秒。
- 空 `notes: []` 是显式休止；没有事件覆盖的空隙由谱面补画休止。
- 相同时刻、同声部的和弦写在同一事件的 `notes` 数组内，**不能写成重叠事件**。
- 可选字符串 `lyric` 表示事件起点对齐的歌词（见《歌词编辑》）。

## rhythm

| 字段 | 约定 |
| --- | --- |
| `value` | `1/2/4/8/16/32`（全音符至三十二分） |
| `dotted` | 布尔；附点使时值乘 3/2 |
| `triplet` | 布尔；**仅八分音符支持三连音**，时值 320 ticks |

附点与三连音不能同时启用。

## notes

每音符必填：

| 字段 | 约定 |
| --- | --- |
| `id` | UUID；文档内每个小节、事件和音符均使用不同 UUID；复制事件时生成新 ID |
| `string` | 1–6（第 1 弦为最高弦） |
| `fret` | 0–24 |
| `velocity` | 0–1 |
| `technique` | 下表枚举之一 |
| `tieToNext` | 布尔 |
| `targetFret` | 可选；击弦、勾弦、滑音时**必须**提供 |

### technique 枚举

| 值 | 含义 | targetFret |
| --- | --- | --- |
| `none` | 正常拨弦 | 省略 |
| `hammerOn` | 击弦 | 高于起始品位 |
| `pullOff` | 勾弦 | 低于起始品位 |
| `slide` | 滑音 | 目标 0–24 品 |
| `bendHalf` / `bendFull` | 半音／全音推弦 | 省略，变化量由技巧决定 |
| `vibrato` | 揉弦 | 省略 |
| `palmMute` | 闷音 | 省略 |
| `deadNote` | 死音 | 省略；不能持续延音 |

## 延音（tieToNext）

`tieToNext: true` 仅连接该音符到**同声部、同弦同品、恰好在当前事件结束时开始**的续音；可以跨小节。续音的技巧必须为 `none`。

- 和弦中只有低音需要延长：只给低音设 `tieToNext`，下一事件重复该低音；其他音在自身时值结束时停止。
- 多段延音在播放调度中合并为**一次拨弦**。
- 尚未录入续音的延音显示警告，允许保存编辑中的文档；播放仅持续已明确记谱的时值，不猜测续音。

## 错误与拒绝

以下情况为**错误**，保存和修改会被拒绝，不移动另一声部、不截断音符：

- 超出小节容量；
- 同声部事件重叠；
- 同弦跨声部持续音冲突；
- 错误的技巧目标（如 hammerOn 目标低于起始品位）。

未来版本、损坏 JSON 及非法数据（整数极值、非整数 ticks、非有限数值）会报告错误；**读取操作不改写源文件**。

## 时间换算

```text
秒 = absoluteTick × 60 / (960 × bpm)
```

这是记谱速度下的时间，不包含预备拍，也不自动匹配原声录音。

## 最小有效文档

```json
{
  "version": 1,
  "title": "新曲谱",
  "tuning": [64, 59, 55, 50, 45, 40],
  "timeSignature": {"numerator": 4, "denominator": 4},
  "bpm": 80,
  "measures": [{
    "id": "E248F013-BF1D-4CE1-BB88-F68BCCF11001",
    "voices": [
      {"voice": "melody", "events": [{
        "id": "E248F013-BF1D-4CE1-BB88-F68BCCF11002",
        "startTick": 0,
        "rhythm": {"value": 4, "dotted": false, "triplet": false},
        "lyric": "啦",
        "notes": [{
          "id": "E248F013-BF1D-4CE1-BB88-F68BCCF11003",
          "string": 1, "fret": 0, "velocity": 0.75,
          "technique": "none", "tieToNext": false
        }]
      }]},
      {"voice": "bass", "events": []}
    ]
  }]
}
```

## 编写多段歌词谱的原则

把后续段落和反复段**按实际演奏顺序**依次写入后续 `measures`，每段使用自己的歌词和新 UUID；数组顺序就是演奏顺序。不要用同一事件的多行文字承载需要独立播放时间的不同段歌词。

## 示例文件

| 文件 | 内容 |
| --- | --- |
| `Examples/Fingerstyle.guitarget` | 两个完整小节：每小节八个八分旋律音，第 6 弦整小节低音跨小节延音 |
| `Examples/Techniques.guitarget` | 展示全部技巧枚举 |
| `Examples/F-Major.guitarget` | F 大调练习 |
| `Examples/GenerateExamples.swift` | 纯 Swift 生成脚本，所有示例经正式 `ScoreIO` 校验 |

原生文档窗口负责未保存状态、保存、另存为及关闭确认；序列化层只读写数据。
