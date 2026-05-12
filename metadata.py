#!/usr/bin/env python3
"""metadata.py - extract MediaInfo, ffprobe, and ExifTool sidecars for TBM files."""
from __future__ import annotations

import argparse
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "lib"))
from common import get_logger, install_sigterm_trap, is_sidecar, require  # noqa: E402

log = get_logger()

if sys.stdout.isatty():
    BOLD = "\033[1m"; BLUE = "\033[34m"; CYAN = "\033[36m"
    GREEN = "\033[32m"; YELLOW = "\033[33m"; DIM = "\033[2m"; RESET = "\033[0m"
else:
    BOLD = BLUE = CYAN = GREEN = YELLOW = DIM = RESET = ""


def print_usage(to=sys.stdout):
    print(f"{BOLD}{BLUE}USAGE:{RESET}", file=to)
    print(f"  {GREEN}metadata.py{RESET} {CYAN}-i{RESET} {YELLOW}PATH{RESET} [options]", file=to)
    print(file=to)
    print(f"Run {GREEN}metadata.py{RESET} {CYAN}-h{RESET} for detailed help.", file=to)


def print_help():
    print(f"""{BOLD}{BLUE}NAME{RESET}
  {GREEN}metadata.py{RESET} — extract MediaInfo, ffprobe, and ExifTool sidecars for files

{BOLD}{BLUE}USAGE{RESET}
  {GREEN}metadata.py{RESET} {CYAN}-i{RESET} {YELLOW}PATH{RESET} [{CYAN}--no-mediainfo{RESET}] [{CYAN}--no-ffprobe{RESET}] [{CYAN}--no-exiftool{RESET}] [{CYAN}--mediatrace{RESET}] [{CYAN}--ee2{RESET}|{CYAN}--ee3{RESET}] [{CYAN}-n{RESET}]

{BOLD}{BLUE}OPTIONS{RESET}
  {CYAN}-i{RESET} {YELLOW}PATH{RESET}          File or directory (directory is recursed)
  {CYAN}--no-mediainfo{RESET}   Skip {YELLOW}mediainfo{RESET} (plain text + JSON) (default: run)
  {CYAN}--no-ffprobe{RESET}     Skip {YELLOW}ffprobe{RESET} (default: run)
  {CYAN}--no-exiftool{RESET}    Skip {YELLOW}exiftool{RESET} (plain text + JSON) (default: run)
  {CYAN}--mediatrace{RESET}     Also write mediainfo XML trace sidecar (default: off)
  {CYAN}--ee2{RESET}            Use {YELLOW}exiftool -ee2{RESET} (deeper embedded extraction)
  {CYAN}--ee3{RESET}            Use {YELLOW}exiftool -ee3{RESET} (deepest; slowest). Default: {YELLOW}-ee1{RESET}
  {CYAN}-n{RESET}, {CYAN}--dry-run{RESET}     Print planned actions, write nothing
  {CYAN}-h{RESET}, {CYAN}--help{RESET}        Show this help

{BOLD}{BLUE}EXAMPLES{RESET}
  {DIM}# All sidecars for a single file{RESET}
  {GREEN}metadata.py{RESET} {CYAN}-i{RESET} /Volumes/archive/<file>

  {DIM}# Process a whole directory{RESET}
  {GREEN}metadata.py{RESET} {CYAN}-i{RESET} /Volumes/archive/<dir>

  {DIM}# Add XML mediatrace alongside the usual outputs{RESET}
  {GREEN}metadata.py{RESET} {CYAN}-i{RESET} /Volumes/archive/<dir> {CYAN}--mediatrace{RESET}

  {DIM}# Deeper exiftool embedded extraction{RESET}
  {GREEN}metadata.py{RESET} {CYAN}-i{RESET} /Volumes/archive/<dir> {CYAN}--ee2{RESET}

  {DIM}# ffprobe only{RESET}
  {GREEN}metadata.py{RESET} {CYAN}-i{RESET} /Volumes/archive/<file> {CYAN}--no-mediainfo{RESET} {CYAN}--no-exiftool{RESET}

{BOLD}{BLUE}OUTPUT FILES{RESET}
  Next to each source file:
    {YELLOW}<file>.mediainfo.txt{RESET}   (from {YELLOW}mediainfo -f{RESET})
    {YELLOW}<file>.mediainfo.json{RESET}  (from {YELLOW}mediainfo -f --Output=JSON{RESET})
    {YELLOW}<file>.ffprobe.json{RESET}    (from {YELLOW}ffprobe -show_format -show_streams -of json{RESET})
    {YELLOW}<file>.exiftool.txt{RESET}    (from {YELLOW}exiftool -a -G1 -u -eeN{RESET})
    {YELLOW}<file>.exiftool.json{RESET}   (from {YELLOW}exiftool -a -G1 -u -eeN -j{RESET})
  With {CYAN}--mediatrace{RESET}:
    {YELLOW}<file>.mediatrace.xml{RESET}  (from {YELLOW}mediainfo --Details=1 --Output=XML{RESET})
  Existing sidecars are not overwritten.""")


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


def _run_capture(cmd: list[str], out: Path, tool: str, dry: bool) -> None:
    if out.exists():
        log.info(f"skip (exists): {out}")
        return
    if dry:
        log.info(f"[dry-run] would run: {tool} ... -> {out.name}")
        return
    try:
        result = subprocess.run(cmd, capture_output=True, text=True, check=True)
        out.write_text(result.stdout)
        log.info(f"wrote {out}")
    except subprocess.CalledProcessError as e:
        err = (e.stderr or "").strip().splitlines()
        first = err[0] if err else ""
        log.warning(f"{tool} failed for {out.name}: {first}")
        out.unlink(missing_ok=True)


def run_mediainfo_text(f: Path, dry: bool) -> None:
    _run_capture(["mediainfo", "-f", str(f)],
                 f.with_name(f.name + ".mediainfo.txt"), "mediainfo", dry)


def run_mediainfo_json(f: Path, dry: bool) -> None:
    _run_capture(["mediainfo", "-f", "--Output=JSON", str(f)],
                 f.with_name(f.name + ".mediainfo.json"), "mediainfo", dry)


def run_mediatrace(f: Path, dry: bool) -> None:
    _run_capture(["mediainfo", "--Details=1", "--Output=XML", str(f)],
                 f.with_name(f.name + ".mediatrace.xml"), "mediatrace", dry)


def run_ffprobe(f: Path, dry: bool) -> None:
    _run_capture(
        ["ffprobe", "-hide_banner", "-loglevel", "error",
         "-show_format", "-show_streams", "-of", "json", str(f)],
        f.with_name(f.name + ".ffprobe.json"), "ffprobe", dry,
    )


def run_exiftool_text(f: Path, dry: bool, ee: str) -> None:
    _run_capture(["exiftool", "-a", "-G1", "-u", ee, str(f)],
                 f.with_name(f.name + ".exiftool.txt"), "exiftool", dry)


def run_exiftool_json(f: Path, dry: bool, ee: str) -> None:
    _run_capture(["exiftool", "-a", "-G1", "-u", ee, "-j", str(f)],
                 f.with_name(f.name + ".exiftool.json"), "exiftool", dry)


def main() -> int:
    install_sigterm_trap()
    argv = sys.argv[1:]
    if not argv:
        print_usage()
        return 0

    p = argparse.ArgumentParser(add_help=False)
    p.add_argument("-i", "--input")
    p.add_argument("-n", "--dry-run", action="store_true")
    p.add_argument("--no-mediainfo", action="store_true")
    p.add_argument("--no-ffprobe", action="store_true")
    p.add_argument("--no-exiftool", action="store_true")
    p.add_argument("--mediatrace", action="store_true")
    p.add_argument("--ee2", action="store_true")
    p.add_argument("--ee3", action="store_true")
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

    do_mi = not args.no_mediainfo
    do_ff = not args.no_ffprobe
    do_et = not args.no_exiftool
    do_trace = args.mediatrace and do_mi  # --no-mediainfo also disables mediatrace
    if args.ee2 and args.ee3:
        log.error("--ee2 and --ee3 are mutually exclusive")
        return 2
    ee_flag = "-ee2" if args.ee2 else "-ee3" if args.ee3 else "-ee1"
    if not (do_mi or do_ff or do_et):
        log.error("All tools disabled")
        return 2

    deps: list[str] = []
    if do_mi: deps.append("mediainfo")
    if do_ff: deps.append("ffprobe")
    if do_et: deps.append("exiftool")
    require(*deps)

    path = Path(args.input)
    if path.is_dir():
        path = path.resolve()

    count = 0
    for f in _iter_source_files(path):
        if do_mi:
            run_mediainfo_text(f, args.dry_run)
            run_mediainfo_json(f, args.dry_run)
            if do_trace:
                run_mediatrace(f, args.dry_run)
        if do_ff: run_ffprobe(f, args.dry_run)
        if do_et:
            run_exiftool_text(f, args.dry_run, ee_flag)
            run_exiftool_json(f, args.dry_run, ee_flag)
        count += 1

    log.info(f"done: {count} files processed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
