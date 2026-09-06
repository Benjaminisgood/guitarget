# Guitarget 原生曲谱格式（版本 1）

`.guitarget` 是 UTF-8 JSON 文件，统一解码为 `GuitarScore`。没有网络、插件或脚本执行入口。AI 可以直接生成 JSON；用应用打开时将执行与人工录谱相同的结构与乐理时值校验。

## 字段约定

| 字段 | 类型 | 约定 |
| --- | --- | --- |
| `version` | 整数 | 必须为 `1`；未知版本拒绝读取 |
| `title` | 字符串 | 文档标题 |
| `tuning` | 六个整数 | 从第 1 弦（最高弦）到第 6 弦（最低弦）的 MIDI 音高；标准为 `[64,59,55,50,45,40]`；调弦、调弦加品位、技巧目标均须处于 MIDI 0–127 |
| `timeSignature` | 对象 | `numerator`、`denominator`，支持 2/4、3/4、4/4、6/8 |
| `bpm` | 数值 | 四分音符每分钟，20–300；默认 80；6/8 也按四分音符计速 |
| `measures` | 小节数组 | 至少一个小节；数组顺序就是播放顺序 |

每小节含 UUID 字符串 `id` 与 `voices` 数组。`voices` 必须恰好包含 `{"voice":"melody","events":[...]}` 和 `{"voice":"bass","events":[...]}` 两项。两个声部各自独立计时，均使用同一小节起点。

每事件含 UUID `id`、整数 `startTick`、`rhythm` 和 `notes`。四分音符固定 **960 ticks**；4/4 小节固定 **3840 ticks**。`startTick` 是小节内偏移，不是秒。空 `notes: []` 是显式休止；没有事件覆盖的空隙由谱面补画休止。

事件还可包含可选字符串 `lyric`，表示在该事件起点对齐的歌词、音节或短句，例如 `"lyric": "星"`。同一和弦共用这一份歌词；旋律与低音声部各自拥有歌词，显式休止也可以保留换气等文字。省略 `lyric` 或设为 `null` 都表示没有歌词，旧版本 1 文件无需转换即可打开。歌词原样保留 Unicode 与换行，不改变音符播放时间。

编写或生成新谱时，把后续段落和反复段依次写入后续 `measures`，每段使用自己的歌词和新 UUID，数组顺序就是实际演奏顺序。不要用同一事件的多行文字承载需要独立播放时间的不同段歌词。曲谱位置秒数为 `absoluteTick × 60 / (960 × bpm)`；这是记谱速度下的时间，不包含预备拍，也不自动匹配原声录音。

在编辑器中选中事件后，可在检查器的“歌词”输入框中编辑；留空移除歌词。谱面在六线谱下方按事件位置显示歌词，并支持点击歌词选中对应事件。长文字自动换行，相邻文字碰撞时分行显示。歌词随保存、撤销、重做与事件复制粘贴保留；更改品位、时值或转为休止时也会保留。删除带歌词事件的最后一个音符时先保留为带歌词休止，再删除该休止即可移除整个事件。

`rhythm` 含三个必填字段：`value` 为 `1/2/4/8/16/32`（全音符至三十二分），`dotted`、`triplet` 均为布尔值。附点使时值乘 3/2；仅八分音符支持三连音，时值为 320 ticks；附点与三连音不能同时启用。相同时刻、同声部的和弦写在同一事件的 `notes` 数组内，不能写成重叠事件。

每音符必填 `id`（UUID）、`string`（1–6）、`fret`（0–24）、`velocity`（0–1）、`technique`（下面的枚举之一）、`tieToNext`（布尔）。`targetFret` 可省略；击弦、勾弦、滑音时必须提供。

| `technique` | 含义 | `targetFret` |
| --- | --- | --- |
| `none` | 正常拨弦 | 省略 |
| `hammerOn` | 击弦 | 高于起始品位 |
| `pullOff` | 勾弦 | 低于起始品位 |
| `slide` | 滑音 | 目标 0–24 品 |
| `bendHalf` / `bendFull` | 半音 / 全音推弦 | 省略，变化量由技巧决定 |
| `vibrato` | 揉弦 | 省略 |
| `palmMute` | 闷音 | 省略 |
| `deadNote` | 死音 | 省略；不能持续延音 |

## 延音和独立声部

`tieToNext: true` 仅连接该音符到**同声部、同弦同品、恰好在当前事件结束时开始**的续音；可以跨小节。续音的技巧必须为 `none`。例如和弦有两个音，仅低音需要延长，就只给低音设 `tieToNext`，下一事件重复该低音；另一个音会在自身时值结束时停止。多段延音在播放调度中合并为一次拨弦。

尚未录入续音的延音显示警告，允许保存编辑中的文档；播放时仅持续已明确记谱的时值，不猜测续音。超出小节容量、同声部事件重叠、同弦跨声部持续音冲突及错误的技巧目标是错误。保存和修改会拒绝此类错误，不移动另一声部，不截断音符。未来版本、损坏 JSON 及非法数据会报告错误，读取操作不改写源文件。

`Examples/Fingerstyle.guitarget` 提供两个完整小节：每小节八个八分旋律音，第 6 弦整小节低音跨小节延音。`Examples/Techniques.guitarget` 展示全部技巧枚举；`Examples/F-Major.guitarget` 为 F 大调练习。所有示例由纯 Swift 的 `Examples/GenerateExamples.swift` 生成，并经过正式 `ScoreIO` 校验。

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

文档内每个小节、事件和音符均使用不同的 UUID。复制事件时生成新 ID。原生文档窗口负责未保存状态、保存、另存为及关闭确认；序列化层只读写数据。
