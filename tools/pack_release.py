#!/usr/bin/env python3
"""Build a release ZIP for Dramatic Shape Voxel Mod.

Flat root (manifest.json at zip root) so Gen1Recomp can import it directly.

Exclusions come **only** from `.packageignore` at the mod root.
If that file is missing, nothing is skipped (entire tree is packed aside from
non-files).

Usage:
  python3 tools/pack_release.py --list
  python3 tools/pack_release.py -o dist/DRAMATIC_SHAPE-1.9.0.zip
  python3 tools/pack_release.py --root /path/to/mod -o out.zip
"""

from __future__ import annotations

import argparse
import fnmatch
import re
import zipfile
from pathlib import Path

PACKAGEIGNORE_NAME = ".packageignore"


def load_packageignore(root: Path) -> list[str] | None:
    """Return patterns, or None if .packageignore is absent (skip nothing)."""
    path = root / PACKAGEIGNORE_NAME
    if not path.is_file():
        return None
    patterns: list[str] = []
    for line in path.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        patterns.append(line.replace("\\", "/"))
    return patterns


def match_pattern(rel: str, pattern: str) -> bool:
    """Match a relative posix path against one .packageignore pattern."""
    rel = rel.replace("\\", "/")
    pattern = pattern.replace("\\", "/")

    # Directory prefix: "foo/" matches foo and foo/...
    if pattern.endswith("/"):
        return rel == pattern[:-1] or rel.startswith(pattern)

    if rel == pattern:
        return True

    if "**" in pattern:
        parts = pattern.split("**")
        rx = ".*".join(re.escape(p) for p in parts)
        rx = rx.replace(re.escape("*"), "[^/]*")
        return re.fullmatch(rx, rel) is not None

    if "*" in pattern or "?" in pattern:
        return fnmatch.fnmatch(rel, pattern) or fnmatch.fnmatch(Path(rel).name, pattern)

    if rel.startswith(pattern + "/"):
        return True

    return False


def should_exclude(rel: str, patterns: list[str] | None) -> bool:
    """Exclude only when .packageignore exists and a pattern matches."""
    if patterns is None:
        return False
    rel = rel.replace("\\", "/")
    return any(match_pattern(rel, pat) for pat in patterns)


def collect_files(root: Path) -> list[Path]:
    patterns = load_packageignore(root)
    files: list[Path] = []
    for path in sorted(root.rglob("*")):
        if not path.is_file():
            continue
        rel = path.relative_to(root).as_posix()
        if should_exclude(rel, patterns):
            continue
        files.append(path)
    return files


def build_zip(root: Path, output: Path) -> int:
    if output.suffix.lower() != ".zip":
        raise ValueError("release output must use the .zip extension")
    files = collect_files(root)
    if not files:
        raise FileNotFoundError("no files found to pack")
    required = {"manifest.json", "main.lua"}
    have = {p.relative_to(root).as_posix() for p in files}
    missing = required - have
    if missing:
        raise FileNotFoundError(f"missing required files: {sorted(missing)}")

    output.parent.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(output, "w", zipfile.ZIP_DEFLATED, compresslevel=9) as archive:
        for source in files:
            relative = source.relative_to(root).as_posix()
            info = zipfile.ZipInfo(relative, (1980, 1, 1, 0, 0, 0))
            info.compress_type = zipfile.ZIP_DEFLATED
            info.external_attr = 0o100644 << 16
            archive.writestr(info, source.read_bytes())
    return len(files)


def main() -> int:
    parser = argparse.ArgumentParser(
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument(
        "--output",
        "-o",
        type=Path,
        default=None,
        help="path to the release .zip (required unless --list)",
    )
    parser.add_argument(
        "--root",
        type=Path,
        default=None,
        help="mod / repo root (default: parent of tools/)",
    )
    parser.add_argument(
        "--list",
        action="store_true",
        help="print included paths and exit (no zip)",
    )
    parser.add_argument(
        "--list-excluded",
        action="store_true",
        help="print paths that exist but were excluded by .packageignore",
    )
    args = parser.parse_args()
    root = (args.root or Path(__file__).resolve().parent.parent).resolve()
    if not (root / "manifest.json").is_file():
        parser.error(f"no manifest.json under {root}")

    patterns = load_packageignore(root)

    if args.list_excluded:
        if patterns is None:
            print("# no .packageignore — nothing excluded", flush=True)
            return 0
        for path in sorted(root.rglob("*")):
            if not path.is_file():
                continue
            rel = path.relative_to(root).as_posix()
            if should_exclude(rel, patterns):
                print(rel)
        return 0

    files = collect_files(root)
    if args.list:
        for p in files:
            print(p.relative_to(root).as_posix())
        if patterns is None:
            print(f"# {len(files)} files (no .packageignore — nothing skipped)", flush=True)
        else:
            print(f"# {len(files)} files (ignore source: {PACKAGEIGNORE_NAME})", flush=True)
        return 0

    if args.output is None:
        parser.error("--output is required unless --list / --list-excluded is set")
    try:
        n = build_zip(root, args.output.resolve())
    except (ValueError, FileNotFoundError) as exc:
        parser.error(str(exc))
    print(f"built {args.output.resolve()} ({n} files)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
