#!/usr/bin/env python3
"""fixity.py - make or verify MD5 sidecars for TBM files.

Usage:
    fixity.py make   -i PATH [--dry-run]
    fixity.py verify -i PATH

Writes <file>.md5 next to each source file in GNU md5sum format:
    <hash>  <basename>
"""
from __future__ import annotations

import argparse
import hashlib
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "lib"))
from common import get_logger, install_sigterm_trap  # noqa: E402

log = get_logger()


def _hash_file(path: Path) -> str:
    h = hashlib.md5()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def _iter_files(root: Path) -> list[Path]:
    if root.is_file():
        return [root]
    if root.is_dir():
        return sorted(p for p in root.rglob("*") if p.is_file() and p.suffix != ".md5")
    log.error(f"Not a file or directory: {root}")
    sys.exit(2)


def cmd_make(args: argparse.Namespace) -> int:
    count = skipped = 0
    for f in _iter_files(Path(args.input)):
        sidecar = f.with_name(f.name + ".md5")
        if sidecar.exists():
            log.info(f"skip (sidecar exists): {f}")
            skipped += 1
            continue
        if args.dry_run:
            log.info(f"[dry-run] would write: {sidecar}")
        else:
            h = _hash_file(f)
            sidecar.write_text(f"{h}  {f.name}\n")
            log.info(f"wrote {sidecar}")
        count += 1
    log.info(f"done: {count} processed, {skipped} skipped")
    return 0


def cmd_verify(args: argparse.Namespace) -> int:
    ok = failed = missing = 0
    for f in _iter_files(Path(args.input)):
        sidecar = f.with_name(f.name + ".md5")
        if not sidecar.exists():
            log.warning(f"no sidecar: {f}")
            missing += 1
            continue
        expected = sidecar.read_text().split()[0]
        actual = _hash_file(f)
        if expected == actual:
            log.info(f"match: {f}")
            ok += 1
        else:
            log.error(f"MISMATCH: {f} (expected {expected}, got {actual})")
            failed += 1
    log.info(f"verify: {ok} ok, {failed} failed, {missing} missing")
    return 1 if failed else 0


def main() -> int:
    install_sigterm_trap()
    p = argparse.ArgumentParser(prog="fixity.py", description="Make or verify MD5 sidecars")
    sub = p.add_subparsers(dest="cmd", required=True)

    m = sub.add_parser("make", help="write .md5 sidecars")
    m.add_argument("-i", "--input", required=True)
    m.add_argument("--dry-run", action="store_true")
    m.set_defaults(func=cmd_make)

    v = sub.add_parser("verify", help="verify .md5 sidecars")
    v.add_argument("-i", "--input", required=True)
    v.set_defaults(func=cmd_verify)

    args = p.parse_args()
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())
