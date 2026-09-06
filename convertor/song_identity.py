"""Conservative song families for existing conversion provenance.

Public API: group_sources(sources: list[str]) -> dict[str, dict]. Each value is
{"title": "Artist - Song", "sources": [original relative source paths, ...]}.
Keys are SHA-256 hashes of the normalized (artist, song) identity, not file data.
This module only operates on names; it never reads, hashes, changes or deletes
score files. Distinct source versions are retained in each group's sources.

Rules deliberately leave ambiguous names separate:
* Unicode NFD, casefold and collapsed whitespace establish name equality.
  Accents, punctuation, words and artist aliases are never discarded.
* A filename's "Artist - " prefix overrides its parent directory only when
  that exact normalized artist occurs as an artist directory in this batch.
* Recognized trailing GP extensions are stripped, including doubled ones.
* Explicit trailing v/ver/version numbers are removed.
* A bare trailing (number) is removed only if the same artist has an actual
  companion source whose filename title omits that suffix. Four-digit numbers
  are retained as possible years. This test uses original filename titles,
  not GP metadata titles and not a guessed/fuzzy catalog match.
* Live, acoustic, correct, alternate tuning, part/chapter, Roman numerals and
  unmarked numbers remain part of the identity.

Only sources with available converted material should be passed when building
an available-song library. A failed unnumbered source does not establish a
companion identity for surviving numbered versions in that library.
"""
from __future__ import annotations

import hashlib
import json
from pathlib import PurePosixPath
import re
import unicodedata

_GP_SUFFIX = re.compile(r"\.(?:gp[345]?|gtp|gpx)$", re.IGNORECASE)
_ARTIST_SEPARATOR = re.compile(r"^(.*?)\s+-\s+(.*)$")
_VERSION_TAG = r"(?:version|ver|v)\.?\s*\d+"
_EXPLICIT_VERSION = re.compile(
    rf"(?:\s*\(\s*{_VERSION_TAG}\s*\)|\s*\[\s*{_VERSION_TAG}\s*\]|(?:\s+-\s*|\s+){_VERSION_TAG})\s*$",
    re.IGNORECASE,
)
_NUMERIC_SUFFIX = re.compile(r"\s*\(\s*(\d+)\s*\)\s*$")


def name_key(value: str) -> str:
    """Canonical equivalence and casing only; preserve accents and punctuation."""
    return unicodedata.normalize("NFD", " ".join(value.split())).casefold()


def _display(value: str) -> str:
    return unicodedata.normalize("NFC", " ".join(value.split()))


def _source_parts(source: str, known_artists: dict[str, str]) -> tuple[str, str]:
    path = PurePosixPath(source)
    artist = _display(path.parent.name)
    if not artist:
        raise ValueError(f"Source must include an artist directory: {source!r}")
    stem = _display(path.name)
    while _GP_SUFFIX.search(stem):
        stem = _GP_SUFFIX.sub("", stem).rstrip()
    match = _ARTIST_SEPARATOR.match(stem)
    if match and name_key(match.group(1)) in known_artists and match.group(2).strip():
        artist = known_artists[name_key(match.group(1))]
        stem = match.group(2).strip()
    else:
        artist = known_artists.get(name_key(artist), artist)
    if not stem:
        raise ValueError(f"Source filename has no song title: {source!r}")
    return artist, stem


def _family_title(artist: str, title: str, original_titles: set[tuple[str, str]]) -> str:
    current = title
    while True:
        explicit = _EXPLICIT_VERSION.search(current)
        if explicit:
            candidate = current[:explicit.start()].strip()
            if candidate:
                current = candidate
                continue
        numeric = _NUMERIC_SUFFIX.search(current)
        if numeric:
            number = numeric.group(1)
            candidate = current[:numeric.start()].strip()
            # A four-digit parenthetical is more safely treated as a year.
            # Numeric suffixes are not stripped merely because sibling (2)
            # and (3) files happen to coexist: an unsuffixed companion is needed.
            if len(number) != 4 and candidate and (name_key(artist), name_key(candidate)) in original_titles:
                current = candidate
                continue
        return current


def group_sources(sources: list[str]) -> dict[str, dict]:
    """Group original GP relative paths without removing any distinct source.

    Results, member order and display titles are deterministic regardless of
    input order. Repeated occurrences of the exact same source path represent
    one provenance source; different paths are always retained, even if their
    contents or normalized filenames are identical.
    """
    if not all(isinstance(source, str) and source for source in sources):
        raise ValueError("Every source must be a nonempty relative path string")
    ordered_sources = sorted(set(sources))
    known_artists = {}
    for source in ordered_sources:
        artist = _display(PurePosixPath(source).parent.name)
        if not artist:
            raise ValueError(f"Source must include an artist directory: {source!r}")
        key = name_key(artist)
        # Prefer one stable original capitalization for matching directory names.
        known_artists[key] = min(artist, known_artists.get(key, artist))
    parsed = [(source, *_source_parts(source, known_artists)) for source in ordered_sources]
    original_titles = {(name_key(artist), name_key(title)) for _, artist, title in parsed}
    groups = {}
    for source, artist, original_title in parsed:
        title = _family_title(artist, original_title, original_titles)
        canonical = json.dumps([name_key(artist), name_key(title)], ensure_ascii=False, separators=(",", ":"))
        key = hashlib.sha256(canonical.encode("utf-8")).hexdigest()
        display_title = f"{artist} - {_display(title)}"
        if key not in groups:
            groups[key] = {"title": display_title, "sources": []}
        else:
            groups[key]["title"] = min(groups[key]["title"], display_title)
        groups[key]["sources"].append(source)
    return dict(sorted(groups.items()))
