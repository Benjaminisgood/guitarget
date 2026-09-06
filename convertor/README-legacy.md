# 旧 Guitar Pro 格式的私有运行时

`legacy.py` 通过 TuxGuitar 的 Java 读写器，将 GP1–GP5 文件转换成临时 GP5，供 PyGuitarPro 读取。文件格式按文件头判断，不依赖后缀。原始谱文件保持只读，临时 GP5 和转换记录保存在 `.cache/legacy`。

`run.sh` 和转换器不会自动下载或安装 Java/TuxGuitar 运行时（首次运行的 Python 依赖由 `run.sh` 安装）。若提示旧格式运行时缺失，在项目根目录执行：

```sh
python3 convertor/setup_legacy.py
```

脚本适用于 **Apple Silicon macOS**，只写入 `convertor/.runtime`，不会设置系统 `JAVA_HOME`、修改 shell 配置或安装全局 Java。它固定使用：

| 依赖 | 固定版本 | 官方归档 | SHA256 |
| --- | --- | --- | --- |
| Eclipse Temurin OpenJDK | 21.0.12.1+1，macOS ARM64 | [200.1 MB](https://github.com/adoptium/temurin21-binaries/releases/download/jdk-21.0.12.1%2B1/OpenJDK21U-jdk_aarch64_mac_hotspot_21.0.12.1_1.tar.gz) | `3623232f33a9c3baadf304480b2535f9a3cba8a58d42ecbb438ba267315d9998` |
| TuxGuitar | 1.6.4 | [77.6 MB](https://github.com/helge17/tuxguitar/releases/download/1.6.4/tuxguitar-1.6.4-linux-swt-amd64.tar.gz) | `143d7eee357af44f407d37338c3e833860fea4f96c720e28f00f400c150cf41e` |

这些固定值来自已核验的 `.runtime/PROVENANCE.json`。发布方校验文件：[Temurin SHA256](https://github.com/adoptium/temurin21-binaries/releases/download/jdk-21.0.12.1%2B1/OpenJDK21U-jdk_aarch64_mac_hotspot_21.0.12.1_1.tar.gz.sha256.txt)、[TuxGuitar SHA256](https://github.com/helge17/tuxguitar/releases/download/1.6.4/tuxguitar-1.6.4.sha256)。TuxGuitar 包只提取 Java JAR 和许可文件，读取器不加载 Linux 原生库，也不启动 GUI。

已有大归档会先核验大小和 SHA256，再复用；已有安装文件会逐一与归档内容校验，一致时跳过解压。归档损坏时脚本报错并保留文件。修复不完整的安装时，原目录保留在 `.runtime/.replaced`。解压只接受固定根目录下的普通文件，拒绝路径穿越、符号链接、硬链接和设备文件。

只校验现有运行时，禁止写入或联网：

```sh
python3 convertor/setup_legacy.py --check
```

只使用本地归档重新安装，禁止联网：

```sh
python3 convertor/setup_legacy.py --offline
```

固定使用 1.6.4，是因为实测 TuxGuitar 2.1.0 的 GP1/GP2 读取器会在 `preciseStart` 为空时失败。该回退使用 TuxGuitar 的节拍和效果规范化逻辑；转换结果经过轨道、小节、音符计数检查，以及 PyGuitarPro 回读验证。
