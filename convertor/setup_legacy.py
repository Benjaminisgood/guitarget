#!/usr/bin/env python3
"""Explicitly install or verify the converter's pinned, private legacy runtime.

Pins were copied from .runtime/PROVENANCE.json after checking the publishers'
SHA256 files. This script is never invoked automatically by the converter.
"""
from __future__ import annotations

import argparse
from dataclasses import asdict, dataclass
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import platform
import shutil
import subprocess
import tarfile
import tempfile
import urllib.request


ROOT = Path(__file__).resolve().parent
RUNTIME = ROOT / ".runtime"


@dataclass(frozen=True)
class Component:
    component: str
    version: str
    archive: str
    source: str
    checksum_source: str
    sha256: str
    bytes: int
    directory: str
    bundle: str
    license: str


COMPONENTS = (
    Component(
        component="Eclipse Temurin OpenJDK", version="21.0.12.1+1",
        archive="temurin21-macos-arm64.tar.gz",
        source="https://github.com/adoptium/temurin21-binaries/releases/download/jdk-21.0.12.1%2B1/OpenJDK21U-jdk_aarch64_mac_hotspot_21.0.12.1_1.tar.gz",
        checksum_source="https://github.com/adoptium/temurin21-binaries/releases/download/jdk-21.0.12.1%2B1/OpenJDK21U-jdk_aarch64_mac_hotspot_21.0.12.1_1.tar.gz.sha256.txt",
        sha256="3623232f33a9c3baadf304480b2535f9a3cba8a58d42ecbb438ba267315d9998",
        bytes=200073404, directory="jdk", bundle="jdk-21.0.12.1+1",
        license="GPL-2.0 with Classpath Exception",
    ),
    Component(
        component="TuxGuitar", version="1.6.4", archive="tuxguitar-1.6.4.tar.gz",
        source="https://github.com/helge17/tuxguitar/releases/download/1.6.4/tuxguitar-1.6.4-linux-swt-amd64.tar.gz",
        checksum_source="https://github.com/helge17/tuxguitar/releases/download/1.6.4/tuxguitar-1.6.4.sha256",
        sha256="143d7eee357af44f407d37338c3e833860fea4f96c720e28f00f400c150cf41e",
        bytes=77553669, directory="tuxguitar", bundle="tuxguitar-1.6.4-linux-swt-amd64",
        license="LGPL-2.1",
    ),
)


def digest(stream) -> str:
    value = hashlib.sha256()
    for chunk in iter(lambda: stream.read(1024 * 1024), b""):
        value.update(chunk)
    return value.hexdigest()


def verified_archive(component: Component, *, offline: bool) -> Path:
    archive = RUNTIME / component.archive
    if archive.is_symlink():
        raise RuntimeError(f"归档路径不能是符号链接：{archive}")
    if not archive.exists():
        if offline:
            raise RuntimeError(f"缺少本地归档：{archive}；离线校验不会下载。")
        RUNTIME.mkdir(parents=True, exist_ok=True)
        print(f"下载 {component.component} {component.version}（{component.bytes / 1e6:.1f} MB）", flush=True)
        with tempfile.TemporaryDirectory(dir=RUNTIME, prefix=".download-") as staging:
            partial = Path(staging) / component.archive
            request = urllib.request.Request(component.source, headers={"User-Agent": "Guitarget-legacy-setup"})
            with urllib.request.urlopen(request, timeout=60) as response, partial.open("wb") as output:
                shutil.copyfileobj(response, output, length=1024 * 1024)
            _verify_archive_file(partial, component)
            os.replace(partial, archive)
    _verify_archive_file(archive, component)
    return archive


def _verify_archive_file(path: Path, component: Component) -> None:
    if path.stat().st_size != component.bytes:
        raise RuntimeError(f"归档大小不匹配，未修改现有文件：{path}")
    with path.open("rb") as stream:
        actual = digest(stream)
    if actual != component.sha256:
        raise RuntimeError(f"归档 SHA256 不匹配，未修改现有文件：{path}")


def selected_members(archive: tarfile.TarFile, component: Component) -> list[tarfile.TarInfo]:
    members = []
    seen = set()
    for member in archive.getmembers():
        path = PurePosixPath(member.name)
        if (path.is_absolute() or ".." in path.parts or "\\" in member.name
                or not path.parts or path.parts[0] != component.bundle):
            raise RuntimeError(f"不安全的归档路径：{member.name}")
        # These exact official archives contain no symlinks or hard links.
        # Refusing all link/device entries also prevents extraction through links.
        if not (member.isfile() or member.isdir()):
            raise RuntimeError(f"不允许的归档文件类型：{member.name}")
        if member.isfile() and (component.directory == "jdk" or member.name.endswith(".jar")
                                or "COPYING" in path.name or "LICENSE" in path.name):
            if path in seen:
                raise RuntimeError(f"归档包含重复文件路径：{member.name}")
            seen.add(path)
            members.append(member)
    if not members:
        raise RuntimeError(f"归档没有可安装的文件：{component.archive}")
    return members


def installed_matches(archive: tarfile.TarFile, members: list[tarfile.TarInfo], base: Path) -> bool:
    for member in members:
        path = base / member.name
        # Check ancestors too: existing directories may not redirect verification
        # or a subsequent repair outside the private runtime.
        if path.is_symlink() or any(parent.is_symlink() for parent in path.parents):
            return False
        if not path.is_file() or path.stat().st_size != member.size:
            return False
        if member.mode & 0o111 and not os.access(path, os.X_OK):
            return False
        with archive.extractfile(member) as expected, path.open("rb") as actual:
            if digest(expected) != digest(actual):
                return False
    return True


def install_component(component: Component, archive_path: Path, *, check: bool) -> None:
    base = RUNTIME / component.directory
    if base.is_symlink():
        raise RuntimeError(f"运行时目录不能是符号链接：{base}")
    with tarfile.open(archive_path, "r:gz") as archive:
        members = selected_members(archive, component)
        if installed_matches(archive, members, base):
            print(f"已核验，跳过安装：{component.component} {component.version}（{len(members)} 个文件）", flush=True)
            return
        if check:
            raise RuntimeError(f"安装文件缺失或内容不匹配：{base / component.bundle}")
        # Extract only regular files into a fresh directory. No tarfile extraction
        # primitive is used, and every destination was checked above.
        with tempfile.TemporaryDirectory(dir=RUNTIME, prefix=".extract-") as staging:
            stage = Path(staging)
            for member in members:
                destination = stage / member.name
                destination.parent.mkdir(parents=True, exist_ok=True)
                with archive.extractfile(member) as source, destination.open("xb") as output:
                    shutil.copyfileobj(source, output, length=1024 * 1024)
                destination.chmod(member.mode & 0o777)
            if not installed_matches(archive, members, stage):
                raise RuntimeError(f"解压后校验失败：{component.component}")
            base.mkdir(parents=True, exist_ok=True)
            destination = base / component.bundle
            backup = None
            if destination.exists() or destination.is_symlink():
                backup_root = RUNTIME / ".replaced"
                backup_root.mkdir(exist_ok=True)
                backup = Path(tempfile.mkdtemp(dir=backup_root, prefix=component.directory + "-")) / component.bundle
                os.replace(destination, backup)
            try:
                os.replace(stage / component.bundle, destination)
            except BaseException:
                if backup is not None:
                    os.replace(backup, destination)
                raise
            print(f"已安装：{destination}", flush=True)
            if backup is not None:
                print(f"原有不匹配的安装已保留：{backup}", flush=True)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true", help="只校验现有归档与安装文件，不写入，不联网")
    parser.add_argument("--offline", action="store_true", help="只使用本地已核验归档安装，禁止下载")
    args = parser.parse_args()
    if platform.system() != "Darwin" or platform.machine() not in {"arm64", "aarch64"}:
        parser.error("当前固定的 Java 归档适用于 Apple Silicon macOS。")
    if RUNTIME.is_symlink():
        parser.error(".runtime 不能是符号链接。")
    try:
        for component in COMPONENTS:
            archive = verified_archive(component, offline=args.offline or args.check)
            install_component(component, archive, check=args.check)
        java_bin = RUNTIME / "jdk" / COMPONENTS[0].bundle / "Contents" / "Home" / "bin"
        for name in ("java", "javac"):
            subprocess.run([str(java_bin / name), "-version"], check=True, capture_output=True, timeout=30)
        provenance = RUNTIME / "PROVENANCE.json"
        if not args.check and not provenance.exists():
            info = {
                "components": [asdict(component) for component in COMPONENTS],
                "active_reader_version": "1.6.4",
                "note": "Pinned official archives verified with SHA256. Private installation; no system Java settings changed.",
                "tuxguitar_source": "https://github.com/helge17/tuxguitar/tree/1.6.4/common/TuxGuitar-gtp",
            }
            provenance.write_text(json.dumps(info, indent=2) + "\n")
        print("私有 legacy 运行时已就绪；系统 Java 设置未更改。")
        return 0
    except (OSError, RuntimeError, tarfile.TarError, subprocess.SubprocessError) as error:
        parser.exit(1, f"setup_legacy: {error}\n")


if __name__ == "__main__":
    raise SystemExit(main())
