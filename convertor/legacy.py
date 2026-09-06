"""Read old GTP and fallback GP files through a private headless TuxGuitar runtime.

No source file is modified. The temporary GP5 and validation metadata live in
``convertor/.cache/legacy``. Dependencies are preinstalled in ``.runtime``; this
module never downloads or installs anything automatically.
"""
from __future__ import annotations

import hashlib
import io
import json
import os
from pathlib import Path
import subprocess
import tempfile


ROOT = Path(__file__).resolve().parent
RUNTIME = ROOT / ".runtime"
CACHE = ROOT / ".cache" / "legacy"
HELPER = ROOT / "LegacyToGP5.java"
TUX = RUNTIME / "tuxguitar" / "tuxguitar-1.6.4-linux-swt-amd64"
DEPENDENCY_JARS = [
    TUX / "lib" / "tuxguitar-lib.jar",
    TUX / "lib" / "tuxguitar-gm-utils.jar",
    TUX / "lib" / "tuxguitar-editor-utils.jar",
    TUX / "lib" / "tuxguitar.jar",
    TUX / "share" / "plugins" / "tuxguitar-gtp.jar",
]


class LegacyConversionError(RuntimeError):
    """The official legacy reader or its GP5 validation could not finish."""


def _runtime() -> tuple[Path, Path]:
    homes = sorted((RUNTIME / "jdk").glob("*/Contents/Home"))
    if len(homes) != 1 or not all(p.is_file() for p in DEPENDENCY_JARS):
        raise LegacyConversionError("Private Java/TuxGuitar runtime is unavailable; see .runtime/PROVENANCE.json")
    return homes[0] / "bin" / "java", homes[0] / "bin" / "javac"


def _run(argv: list[str], timeout: int) -> subprocess.CompletedProcess[str]:
    try:
        result = subprocess.run(argv, capture_output=True, text=True, timeout=timeout)
    except (OSError, subprocess.TimeoutExpired) as error:
        raise LegacyConversionError(str(error)) from error
    if result.returncode:
        raise LegacyConversionError((result.stderr or result.stdout).strip()[-6000:])
    return result


def gp5_bytes(source_path: str | Path, encoding: str = "cp1252") -> bytes:
    """Return a validated GP5 copy; recognize GP1–GP5 from bytes, not extension."""
    import guitarpro

    source = Path(source_path).resolve(strict=True)
    raw = source.read_bytes()
    length = raw[0] if raw else 0
    header = raw[1:1 + length]
    prefixes = (b"FICHIER GUITARE PRO v1",) + tuple(
        f"FICHIER GUITAR PRO v{version}".encode() for version in range(2, 6)
    )
    if length > 30 or not header.startswith(prefixes):
        raise LegacyConversionError("Unsupported or truncated Guitar Pro header")
    revision = hashlib.sha256(HELPER.read_bytes()).hexdigest()
    key = hashlib.sha256(raw + encoding.encode() + revision.encode()).hexdigest()
    CACHE.mkdir(parents=True, exist_ok=True)
    cached = CACHE / (key + ".gp5")
    metadata = CACHE / (key + ".json")
    if cached.is_file() and metadata.is_file():
        data = cached.read_bytes()
        info = json.loads(metadata.read_text())
        if hashlib.sha256(data).hexdigest() == info.get("gp5_sha256"):
            guitarpro.parse(io.BytesIO(data), encoding=encoding)
            return data
    java, javac = _runtime()
    # Per-revision directory and atomic rename tolerate parallel worker startup.
    classes = CACHE / ("classes-" + revision[:16])
    classpath = os.pathsep.join(map(str, DEPENDENCY_JARS))
    if not (classes / "LegacyToGP5.class").is_file():
        with tempfile.TemporaryDirectory(dir=CACHE, prefix="compile-") as temporary:
            _run([str(javac), "-cp", classpath, "-d", temporary, str(HELPER)], 60)
            classes.mkdir(exist_ok=True)
            for path in Path(temporary).glob("*.class"):
                os.replace(path, classes / path.name)
    with tempfile.TemporaryDirectory(dir=CACHE, prefix="convert-") as temporary:
        output = Path(temporary) / "converted.gp5"
        result = _run([
            str(java), "-Djava.awt.headless=true", "-Xmx512m", "-cp",
            os.pathsep.join([str(classes), classpath]), "LegacyToGP5",
            str(source), str(output), encoding,
        ], 60)
        data = output.read_bytes()
        # The downstream parser must also accept the result before publishing it.
        try:
            guitarpro.parse(io.BytesIO(data), encoding=encoding)
        except Exception as error:
            raise LegacyConversionError("TuxGuitar output failed PyGuitarPro validation: " + str(error)) from error
        stats = json.loads(result.stdout.strip())
        info = {
            "source": str(source), "source_sha256": hashlib.sha256(raw).hexdigest(),
            "gp5_sha256": hashlib.sha256(data).hexdigest(), "encoding": encoding,
            "reader": "TuxGuitar 1.6.4 headless", "helper_sha256": revision,
            "roundtrip_counts": stats,
            "note": "TuxGuitar normalizes legacy rhythms and effects when exporting GP5.",
        }
        receipt = Path(temporary) / "receipt.json"
        receipt.write_text(json.dumps(info, ensure_ascii=False, indent=2) + "\n")
        os.replace(output, cached)
        os.replace(receipt, metadata)
        return data
