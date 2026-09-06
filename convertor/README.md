# Guitar Pro → Guitarget 转换与合谱

独立离线转换器。输出使用应用原有的 **v1 `.guitarget` 格式**，不改应用代码、界面或文档格式。每个原始 GP 版本输出一份文件：同版本的吉他音轨按时间对齐合并，片段按原顺序连接；不同版本分别保存。

## 使用

```bash
/Users/ben/Desktop/guitarget/convertor/run.sh '/Users/ben/Desktop/Guitar Pro Tabs'
```

递归读取 GP3/GP4/GP5 等源谱，原地输出 `源文件名.gp5.guitarget`。原始扩展名用于避免文件名碰撞。源文件只读；不同内容的已有输出不覆盖。`--sample 100 --dry-run` 可先抽样校验，`--workers 6` 设置进程数，`--timeout 300` 设置单文件处理超时。报告保存在 `convertor/reports/`。

旧 GP1/GP2 或主解析器无法读取的 GP3–GP5 可通过私有 TuxGuitar 运行时回退；中间文件只存转换器缓存，详见 [运行时说明](README-legacy.md)。GPX/新版 GP 若解析器不支持会明确报告失败。

## 合谱规则

优先原样合并：同版本的音轨在同一时间轴叠加，兼容的片段按顺序接上。若发生同弦冲突或声部不足，则保留覆盖较完整的主吉他轨，优先同等覆盖下标明 main／lead／主吉他 的轨道，不重新配器、调整音高或量化。

主吉他轨内部若也有无法原样表示的调弦、BPM 或拍号变化，则只保留其最长连续兼容段。报告明确区分完整主轨与摘段，并列出保留和省略的轨道、片段。音符、弦位、品位、力度、技巧、节奏和歌词保持原样；旧有断延音只报告，不擅自改掉。

每个不同版本各自输出文件。同一首歌中，原 GP 文件 SHA-256 完全相同且现有谱面内容一致的重复下载只保留一份。最终文件只有应用原生字段，没有被应用忽略的容器或自定义格式。每份成品必须通过原应用 `ScoreIO.decode` 校验后才输出。


## 整理本机已有片段库

```bash
cd /Users/ben/Desktop/guitarget/convertor
bash build_validator.sh
.venv/bin/python merge_library.py prepare --report reports/v1-merged-library
.venv/bin/python merge_library.py apply --report reports/v1-merged-library
```

该迁移入口针对已有转换与清理报告，恢复准确的源版本、音轨和片段关系。`prepare` 只在报告目录暂存新谱；`apply` 完整核对现有目录、原始内容归档和所有新谱后才替换片段文件。`--limit 100` 仅预演，不能替换全库；中断可加 `--resume` 重试准备，替换阶段可直接重试。

迁移前全部片段内容已保留在 `reports/consolidate-full-20260906/songs/` 的历史归档中，并有逐片段内容哈希与文件名映射。该归档仅用于恢复数据，不是供应用导入的曲库。旧 `consolidate.py` 的 v2 发布已禁用。最终用户目录只放可直接打开的 v1 `.guitarget` 文件。

`versions.jsonl` 记录每个源版本的文件名、SHA-256、校验结果、主轨选择报告和原片段映射；`summary.json` 记录最终数量。可以在原版应用打开成品，或通过“我的曲库 → 导入曲谱”导入，按普通吉他谱编辑和播放；标明摘段的文件仅包含选中的可用段。

## 验证与依赖

```bash
cd /Users/ben/Desktop/guitarget/convertor
.venv/bin/python -m unittest discover -s tests -v
bash build_validator.sh
```

转换器使用 [PyGuitarPro](https://github.com/Perlence/PyGuitarPro)（LGPL-3.0）和本项目现有 Swift 原生校验器；Python 与第三方依赖只存在于转换器环境，不加入应用。
