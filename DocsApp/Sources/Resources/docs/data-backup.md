# 数据存储位置与备份

Guitarget 的所有用户数据都保存在本机文件系统中，格式公开、可直接复制。本文给出准确的目录结构、备份与恢复步骤、各类数据的归属，以及迁移到新机器的方法。

## 数据都在哪里

| 数据 | 位置 | 格式 |
| --- | --- | --- |
| 我的曲库（清单、曲谱、音频副本、Apple Music 链接） | `~/Library/Application Support/Guitarget/MyLibrary/` | JSON + 音频文件 |
| 独立保存的曲谱文档 | 你在"存储"时选择的位置 | `.guitarget`（UTF-8 JSON） |
| 编辑器偏好（每行小节数、指板折叠状态） | 本机偏好存储 | 不写入曲谱文档 |
| QA 实例数据 | `~/Library/Application Support/Guitarget QA/MyLibrary/` | 与主应用完全独立 |

## 曲库目录结构

```text
~/Library/Application Support/Guitarget/MyLibrary/
├── library.json
├── 3F2A9C41-…-A7/
│   ├── score.guitarget
│   └── recording.m4a
├── 8B1D0E52-…-C3/
│   └── score.guitarget
└── …
```

- `library.json` 是**目录清单**（版本化 JSON）：条目名称、UUID、音频绑定与 Apple Music 链接都在这里。
- 每份谱使用**独立 UUID 子目录**，保存 `score.guitarget` 和绑定的音频副本。
- 曲库弹窗底部有"**在 Finder 中显示**"按钮，直接打开该目录。

## 备份步骤

1. 正常退出 Guitarget（⌘Q），避免备份到写入一半的清单。
2. 在 Finder 中前往 `~/Library/Application Support/Guitarget/`。
3. **复制整个 `MyLibrary/` 目录**到备份介质。部分复制（只拷 `library.json` 或只拷贝目录）会得到不一致的曲库。
4. 独立保存过的 `.guitarget` 文档不在曲库内，按普通文件另行备份。

### 恢复

1. 退出应用。
2. 把备份的 `MyLibrary/` 整体覆盖回 `~/Library/Application Support/Guitarget/`。
3. 启动应用，打开"我的曲库"核对条目与音频播放。

### 迁移到新机器

1. 旧机器按上述步骤备份 `MyLibrary/`。
2. 新机器构建并启动一次 Guitarget（让它创建目录），退出。
3. 覆盖 `MyLibrary/`，重新启动。

## 导出与备份的区别

| 操作 | 包含内容 |
| --- | --- |
| 曲库**导出** | 只有谱和歌词（`.guitarget` 文件） |
| 目录**备份** | 谱、歌词、音频副本、Apple Music 链接、管理名称——整个曲库状态 |

想把一首带原声绑定的谱分享给别人：导出 `.guitarget` 给对方，音频文件需要单独传输且对方应确认使用权。

## 数据完整性保护

- 曲库初始化会**解析符号链接**并拒绝非文件夹路径；测试目录覆盖包含空格的路径与末尾斜杠回归。
- `library.json` 丢失但目录内仍有文件时，应用报错"**library.json 丢失；现有文件已保留**"，不会静默重建空清单覆盖你的数据。
- 损坏条目在加载时被移除；重启不会重新添加已删除曲目。
- 音频绑定保存的是**受管理副本**：移除源文件后重开曲库，音频字节仍与输入一致。
- 读取损坏或未知版本的 `.guitarget` 会报错且**不改写源文件**。

## 常见问题

- **不要手工编辑 `library.json`**：清单与 UUID 目录需要保持一致；改坏了就恢复备份。
- 磁盘权限：目录在用户自己的 `~/Library` 下，不需要管理员权限；备份到外部磁盘时注意目标卷的权限。
- 卸载应用不会删除 `MyLibrary/`；想彻底清除时手动删除该目录（先备份）。

> **提示**：把"备份 MyLibrary 目录"加进你的定期备份清单（Time Machine 默认已覆盖 `~/Library/Application Support/`）。曲谱本体是纯 JSON，任何时候都可以用文本编辑器直接查看。
