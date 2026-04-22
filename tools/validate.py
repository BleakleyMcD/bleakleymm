#!/usr/bin/env python3
"""validate.py - MediaConch policy + ffprobe parse check on each file."""
from __future__ import annotations

import argparse
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "lib"))
from common import get_logger, install_sigterm_trap, is_sidecar, require  # noqa: E402

log = get_logger()

REPO_ROOT = Path(__file__).resolve().parent.parent
DEFAULT_POLICY = REPO_ROOT / "policies" / "default.xml"

if sys.stdout.isatty():
    BOLD = "\033[1m"; BLUE = "\033[34m"; CYAN = "\033[36m"
    GREEN = "\033[32m"; YELLOW = "\033[33m"; DIM = "\033[2m"; RESET = "\033[0m"
else:
    BOLD = BLUE = CYAN = GREEN = YELLOW = DIM = RESET = ""


def print_usage(to=sys.stdout):
    print(f"{BOLD}{BLUE}USAGE:{RESET}", file=to)
    print(f"  {GREEN}validate.py{RESET} {CYAN}-i{RESET} {YELLOW}PATH{RESET} [{CYAN}--policy{RESET} {YELLOW}POLICY.xml{RESET}]", file=to)
    print(file=to)
    print(f"Run {GREEN}validate.py{RESET} {CYAN}-h{RESET} for detailed help.", file=to)


def print_help():
    print(f"""{BOLD}{BLUE}NAME{RESET}
  {GREEN}validate.py{RESET} — validate files against a MediaConch policy and confirm ffprobe can parse them

{BOLD}{BLUE}USAGE{RESET}
  {GREEN}validate.py{RESET} {CYAN}-i{RESET} {YELLOW}PATH{RESET} [{CYAN}--policy{RESET} {YELLOW}POLICY.xml{RESET}]

{BOLD}{BLUE}OPTIONS{RESET}
  {CYAN}-i{RESET} {YELLOW}PATH{RESET}              File or directory (directory is recursed)
  {CYAN}--policy{RESET} {YELLOW}POLICY.xml{RESET}   MediaConch policy to check against
                       (default: {YELLOW}policies/default.xml{RESET} in this repo)
  {CYAN}-h{RESET}, {CYAN}--help{RESET}            Show this help

{BOLD}{BLUE}CHECKS{RESET}
  For each file:
    1. {YELLOW}mediaconch -p POLICY{RESET} — must report "pass!"
    2. {YELLOW}ffprobe{RESET} must parse the file without error

{BOLD}{BLUE}EXIT CODES{RESET}
  {YELLOW}0{RESET}  All files passed both checks
  {YELLOW}1{RESET}  At least one file failed one or both checks
  {YELLOW}2{RESET}  Bad invocation

{BOLD}{BLUE}EXAMPLES{RESET}
  {DIM}# Validate a file against the bundled default policy{RESET}
  {GREEN}validate.py{RESET} {CYAN}-i{RESET} /Volumes/archive/<file>

  {DIM}# Validate a directory against a custom policy{RESET}
  {GREEN}validate.py{RESET} {CYAN}-i{RESET} /Volumes/archive/<dir> {CYAN}--policy{RESET} ~/my-ffv1.xml

{BOLD}{BLUE}OUTPUT{RESET}
  Per-file pass/fail is printed to the terminal.
  No sidecar files are written.""")


def _iter_source_files(root: Path) -> list[Path]:
    if root.is_file():
        return [root]
    if root.is_dir():
        return sorted(
            p for p in root.rglob("*")
            if p.is_file() and not is_sidecar(p.name)
        )
    log.error(f"Not a file or directory: {root}")
    sys.exit(2)


def _check_mediaconch(f: Path, policy: Path) -> bool:
    try:
        result = subprocess.run(
            ["mediaconch", "-p", str(policy), str(f)],
            capture_output=True, text=True, check=False,
        )
        out = (result.stdout + result.stderr).strip()
        if out.startswith("pass!"):
            log.info(f"mediaconch pass: {f}")
            return True
        log.error(f"mediaconch FAIL: {f}")
        for line in out.splitlines():
            log.error(f"    {line}")
        return False
    except FileNotFoundError:
        log.error("mediaconch not installed")
        return False


def _check_ffprobe(f: Path) -> bool:
    result = subprocess.run(
        ["ffprobe", "-v", "error", "-show_format", "-show_streams", str(f)],
        capture_output=True, text=True, check=False,
    )
    if result.returncode == 0:
        log.info(f"ffprobe parse: {f}")
        return True
    log.error(f"ffprobe FAIL: {f}")
    for line in (result.stderr or "").strip().splitlines():
        log.error(f"    {line}")
    return False


def main() -> int:
    install_sigterm_trap()
    argv = sys.argv[1:]
    if not argv:
        print_usage()
        return 0

    p = argparse.ArgumentParser(add_help=False)
    p.add_argument("-i", "--input")
    p.add_argument("--policy", default=str(DEFAULT_POLICY))
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

    policy = Path(args.policy)
    if not policy.is_file():
        log.error(f"Policy file not found: {policy}")
        return 2

    require("mediaconch", "ffprobe")

    path = Path(args.input)
    if path.is_dir():
        path = path.resolve()

    total = failed = 0
    for f in _iter_source_files(path):
        total += 1
        ok_mc = _check_mediaconch(f, policy)
        ok_ff = _check_ffprobe(f)
        if not (ok_mc and ok_ff):
            failed += 1

    log.info(f"summary: {total - failed}/{total} passed (policy: {policy.name})")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
