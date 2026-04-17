#!/usr/bin/env python3
"""fixity.py - make (default) or verify hash sidecars for TBM files."""
from __future__ import annotations

import argparse
import hashlib
import sys
import zlib
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "lib"))
from common import get_logger, install_sigterm_trap  # noqa: E402

log = get_logger()

SUPPORTED_ALGOS = ("md5", "sha1", "sha256", "sha512", "crc32")
SIDECAR_EXTS = {".md5", ".sha1", ".sha224", ".sha256", ".sha384", ".sha512", ".crc32"}

if sys.stdout.isatty():
    BOLD = "\033[1m"; BLUE = "\033[34m"; CYAN = "\033[36m"
    GREEN = "\033[32m"; YELLOW = "\033[33m"; DIM = "\033[2m"; RESET = "\033[0m"
else:
    BOLD = BLUE = CYAN = GREEN = YELLOW = DIM = RESET = ""


def print_usage(to=sys.stdout):
    print(f"{BOLD}{BLUE}USAGE:{RESET}", file=to)
    print(f"  {GREEN}fixity.py{RESET} {CYAN}-i{RESET} {YELLOW}PATH{RESET} [options]", file=to)
    print(file=to)
    print(f"Run {GREEN}fixity.py{RESET} {CYAN}-h{RESET} for detailed help.", file=to)


def print_help():
    print(f"""{BOLD}{BLUE}NAME{RESET}
  {GREEN}fixity.py{RESET} — make or verify hash sidecars for files

{BOLD}{BLUE}USAGE{RESET}
  {GREEN}fixity.py{RESET} {CYAN}-i{RESET} {YELLOW}PATH{RESET} [{CYAN}-a{RESET} {YELLOW}ALGO{RESET}] [{CYAN}-n{RESET}]           {DIM}# make sidecars (default){RESET}
  {GREEN}fixity.py{RESET} {CYAN}-i{RESET} {YELLOW}PATH{RESET} [{CYAN}-a{RESET} {YELLOW}ALGO{RESET}] {CYAN}--verify{RESET}     {DIM}# verify existing sidecars{RESET}

{BOLD}{BLUE}OPTIONS{RESET}
  {CYAN}-i{RESET} {YELLOW}PATH{RESET}                File or directory (directory is recursed)
  {CYAN}-a{RESET}, {CYAN}--algorithm{RESET} {YELLOW}ALGO{RESET}   Hash algorithm: {YELLOW}md5{RESET} (default), {YELLOW}sha1{RESET}, {YELLOW}sha256{RESET}, {YELLOW}sha512{RESET}, {YELLOW}crc32{RESET}
  {CYAN}-c{RESET}, {CYAN}--verify{RESET}            Verify existing sidecars instead of making new ones
  {CYAN}-n{RESET}, {CYAN}--dry-run{RESET}           Print planned actions, write nothing (make mode only)
  {CYAN}-h{RESET}, {CYAN}--help{RESET}              Show this help

{BOLD}{BLUE}EXAMPLES{RESET}
  {DIM}# MD5 sidecars for a directory{RESET}
  {GREEN}fixity.py{RESET} {CYAN}-i{RESET} /Volumes/archive/MEDIAID

  {DIM}# SHA-256 instead of MD5{RESET}
  {GREEN}fixity.py{RESET} {CYAN}-i{RESET} /Volumes/archive/MEDIAID {CYAN}-a{RESET} sha256

  {DIM}# Dry-run shows what would happen{RESET}
  {GREEN}fixity.py{RESET} {CYAN}-i{RESET} /Volumes/archive/MEDIAID {CYAN}-n{RESET}

  {DIM}# Verify existing SHA-256 sidecars{RESET}
  {GREEN}fixity.py{RESET} {CYAN}-i{RESET} /Volumes/archive/MEDIAID {CYAN}-a{RESET} sha256 {CYAN}--verify{RESET}

{BOLD}{BLUE}SIDECAR FORMAT{RESET}
  One sidecar per source file, named {YELLOW}<file>.<algo>{RESET}
  Content is GNU <algo>sum format (one line):
      {YELLOW}<hash>  <basename>{RESET}""")


def _hash_only(path: Path, algo: str) -> str:
    if algo == "crc32":
        c = 0
        with path.open("rb") as f:
            for chunk in iter(lambda: f.read(1024 * 1024), b""):
                c = zlib.crc32(chunk, c)
        return f"{c:08x}"
    h = hashlib.new(algo)
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def _iter_files(root: Path) -> list[Path]:
    if root.is_file():
        return [root]
    if root.is_dir():
        return sorted(
            p for p in root.rglob("*")
            if p.is_file() and p.suffix not in SIDECAR_EXTS
        )
    log.error(f"Not a file or directory: {root}")
    sys.exit(2)


def do_make(input_: Path, algo: str, dry_run: bool) -> int:
    count = skipped = 0
    for f in _iter_files(input_):
        sidecar = f.with_name(f.name + f".{algo}")
        if sidecar.exists():
            log.info(f"skip (sidecar exists): {f}")
            skipped += 1
            continue
        if dry_run:
            log.info(f"[dry-run] would write: {sidecar}")
        else:
            h = _hash_only(f, algo)
            sidecar.write_text(f"{h}  {f.name}\n")
            log.info(f"wrote {sidecar}")
        count += 1
    log.info(f"done: {count} processed, {skipped} skipped (algorithm: {algo})")
    return 0


def do_verify(input_: Path, algo: str) -> int:
    ok = failed = missing = 0
    for f in _iter_files(input_):
        sidecar = f.with_name(f.name + f".{algo}")
        if not sidecar.exists():
            log.warning(f"no {algo} sidecar: {f}")
            missing += 1
            continue
        expected = sidecar.read_text().split()[0]
        actual = _hash_only(f, algo)
        if expected == actual:
            log.info(f"match: {f}")
            ok += 1
        else:
            log.error(f"MISMATCH: {f} (expected {expected}, got {actual})")
            failed += 1
    log.info(f"verify: {ok} ok, {failed} failed, {missing} missing (algorithm: {algo})")
    return 1 if failed else 0


def main() -> int:
    install_sigterm_trap()
    argv = sys.argv[1:]
    if not argv:
        print_usage()
        return 0

    p = argparse.ArgumentParser(add_help=False)
    p.add_argument("-i", "--input")
    p.add_argument("-a", "--algorithm", default="md5", choices=SUPPORTED_ALGOS)
    p.add_argument("-c", "--verify", action="store_true")
    p.add_argument("-n", "--dry-run", action="store_true")
    p.add_argument("-h", "--help", action="store_true")

    try:
        args = p.parse_args(argv)
    except SystemExit as e:
        return int(e.code) if isinstance(e.code, int) else 2

    if args.help:
        print_help()
        return 0
    if not args.input:
        log.error("-i INPUT required")
        print_usage(to=sys.stderr)
        return 2
    if args.verify and args.dry_run:
        log.error("--dry-run is only valid in make mode")
        return 2

    path = Path(args.input)
    if args.verify:
        return do_verify(path, args.algorithm)
    return do_make(path, args.algorithm, args.dry_run)


if __name__ == "__main__":
    sys.exit(main())
