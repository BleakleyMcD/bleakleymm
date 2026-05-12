#!/usr/bin/env python3
"""rawcooked.py - wrapper for RAWcooked: encode DPX sequence -> .mkv, or decode .mkv -> DPX."""
from __future__ import annotations

import argparse
import os
import re
import shlex
import subprocess
import sys
import time
from datetime import datetime
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent / "lib"))
from common import get_logger, install_sigterm_trap, require  # noqa: E402

log = get_logger()

if sys.stderr.isatty():
    BOLD = "\033[1m"; BLUE = "\033[34m"; CYAN = "\033[36m"
    GREEN = "\033[32m"; YELLOW = "\033[33m"; RED = "\033[31m"
    DIM = "\033[2m"; RESET = "\033[0m"
else:
    BOLD = BLUE = CYAN = GREEN = YELLOW = RED = DIM = RESET = ""

SEP = "═" * 63
DPX_SEQ_RE = re.compile(r".*[^0-9](\d+)\.dpx$", re.IGNORECASE)


def print_usage(to=sys.stdout):
    print(f"{BOLD}{BLUE}USAGE:{RESET}", file=to)
    print(f"  {GREEN}rawcooked.py{RESET} {CYAN}-i{RESET} {YELLOW}PATH{RESET} "
          f"[{CYAN}-o{RESET} {YELLOW}OUTPUT{RESET}] [{CYAN}-n{RESET}] "
          f"[{CYAN}--force{RESET}] [{CYAN}--{RESET} {YELLOW}EXTRA...{RESET}]", file=to)
    print(file=to)
    print(f"Run {GREEN}rawcooked.py{RESET} {CYAN}-h{RESET} for detailed help.", file=to)


def print_help():
    print(f"""{BOLD}{BLUE}NAME{RESET}
  {GREEN}rawcooked.py{RESET} — encode DPX sequence to FFV1/Matroska, or decode it back

{BOLD}{BLUE}USAGE{RESET}
  {GREEN}rawcooked.py{RESET} {CYAN}-i{RESET} {YELLOW}PATH{RESET} [{CYAN}-o{RESET} {YELLOW}OUTPUT{RESET}] [{CYAN}-n{RESET}] [{CYAN}--force{RESET}] [{CYAN}--{RESET} {YELLOW}EXTRA...{RESET}]

{BOLD}{BLUE}OPTIONS{RESET}
  {CYAN}-i{RESET} {YELLOW}PATH{RESET}            DPX sequence directory (encode) or {YELLOW}.mkv{RESET} file (decode)
  {CYAN}-o{RESET} {YELLOW}OUTPUT{RESET}          Output path. Default: rawcooked's default
                     ({YELLOW}${{input}}.mkv{RESET} on encode, {YELLOW}${{input}}.RAWcooked/{RESET} on decode).
  {CYAN}-n{RESET}, {CYAN}--dry-run{RESET}       Print the rawcooked command, don't run it
  {CYAN}--force{RESET}             Pass {YELLOW}-y{RESET} to rawcooked — overwrite existing outputs
  {CYAN}--{RESET} {YELLOW}EXTRA...{RESET}        Anything after {CYAN}--{RESET} is passed to rawcooked verbatim
                     (e.g. {YELLOW}--no-check-padding{RESET}, {YELLOW}-framerate 24{RESET})
  {CYAN}-h{RESET}, {CYAN}--help{RESET}          Show this help

{BOLD}{BLUE}MODES{RESET}
  {YELLOW}encode{RESET}  {CYAN}-i{RESET} is a directory → DPX sequence becomes one FFV1/Matroska {YELLOW}.mkv{RESET}
  {YELLOW}decode{RESET}  {CYAN}-i{RESET} is a {YELLOW}.mkv{RESET}     → restore the original DPX sequence

{BOLD}{BLUE}DEFAULTS{RESET}
  Wrapper always passes {YELLOW}--all{RESET} to rawcooked (NMAAHC preservation defaults:
  check, conch, hash, coherency, framemd5, accept-gaps). Disable any of those
  by appending the negating flag after {CYAN}--{RESET}, e.g. {YELLOW}-- --no-conch{RESET}.

{BOLD}{BLUE}LOGGING{RESET}
  A sibling {YELLOW}<output>.log{RESET} is written next to the rawcooked output. It contains:
  pre-flight summary (input, output, DPX sequence analysis with first/last 10
  frames and any missing sequence numbers), the full rawcooked stdout+stderr,
  and a post-flight summary (duration, exit status, output size, output MD5).

{BOLD}{BLUE}EXAMPLES{RESET}
  {DIM}# Encode a DPX sequence directory{RESET}
  {GREEN}rawcooked.py{RESET} {CYAN}-i{RESET} /Volumes/archive/<reel>/

  {DIM}# Decode an MKV back to DPX{RESET}
  {GREEN}rawcooked.py{RESET} {CYAN}-i{RESET} /Volumes/archive/<reel>.mkv

  {DIM}# Skip padding check for speed{RESET}
  {GREEN}rawcooked.py{RESET} {CYAN}-i{RESET} /Volumes/archive/<reel>/ {CYAN}--{RESET} --no-check-padding

  {DIM}# See the command without running{RESET}
  {GREEN}rawcooked.py{RESET} {CYAN}-i{RESET} /Volumes/archive/<reel>/ {CYAN}-n{RESET}""")


def detect_mode(in_path: Path) -> str | None:
    if in_path.is_dir():
        return "encode"
    if in_path.is_file() and in_path.suffix.lower() == ".mkv":
        return "decode"
    return None


def default_output(input_path: Path, mode: str) -> Path:
    p = input_path
    # Strip trailing slash (Path already handles this, but be explicit)
    if mode == "encode":
        return p.with_suffix(p.suffix + ".mkv") if p.suffix else Path(str(p) + ".mkv")
    # decode
    return p.with_suffix(p.suffix + ".RAWcooked") if p.suffix else Path(str(p) + ".RAWcooked")


def fmt_duration(seconds: int) -> str:
    h, rem = divmod(seconds, 3600)
    m, s = divmod(rem, 60)
    return f"{h}h {m:02d}m {s:02d}s"


def human_size(path: Path) -> str:
    """du -sh style: closest IEC unit (KiB/MiB/GiB)."""
    try:
        if path.is_dir():
            total = sum(f.stat().st_size for f in path.rglob("*") if f.is_file())
        else:
            total = path.stat().st_size
    except OSError:
        return ""
    for unit in ("B", "KiB", "MiB", "GiB", "TiB"):
        if total < 1024 or unit == "TiB":
            return f"{total:.1f} {unit}" if unit != "B" else f"{total} B"
        total /= 1024
    return ""


def analyze_dpx_sequence(directory: Path) -> dict:
    """Scan directory for .dpx files; return summary dict."""
    files = sorted(p for p in directory.iterdir()
                   if p.is_file() and p.suffix.lower() == ".dpx")
    out = {
        "files": files,
        "count": len(files),
        "first_name": "",
        "last_name": "",
        "first_num": "",
        "last_num": "",
        "missing": [],
    }
    if not files:
        return out
    out["first_name"] = files[0].name
    out["last_name"] = files[-1].name

    def seq_num(name: str) -> str:
        m = DPX_SEQ_RE.match(name)
        return m.group(1) if m else ""

    out["first_num"] = seq_num(files[0].name)
    out["last_num"] = seq_num(files[-1].name)

    if out["first_num"] and out["last_num"]:
        pad = len(out["first_num"])
        first_i = int(out["first_num"])
        last_i = int(out["last_num"])
        existing = {seq_num(f.name) for f in files}
        missing = [f"{i:0{pad}d}" for i in range(first_i, last_i + 1)
                   if f"{i:0{pad}d}" not in existing]
        out["missing"] = missing
    return out


def preflight(mode: str, input_path: Path, output: Path, log_path: Path) -> None:
    seq = (analyze_dpx_sequence(input_path)
           if mode == "encode" and input_path.is_dir() else None)
    mode_upper = mode.upper()

    # Terminal banner -> stderr
    print(file=sys.stderr)
    print(f"{BOLD}{BLUE}{SEP}{RESET}", file=sys.stderr)
    print(f"  {BOLD}RAWcooked {mode_upper}{RESET}", file=sys.stderr)
    print(f"{BOLD}{BLUE}{SEP}{RESET}", file=sys.stderr)
    print(f"  {CYAN}Input:{RESET}   {YELLOW}{input_path}{RESET}", file=sys.stderr)
    print(f"  {CYAN}Output:{RESET}  {YELLOW}{output}{RESET}", file=sys.stderr)
    print(f"  {CYAN}Log:{RESET}     {DIM}{log_path}{RESET}", file=sys.stderr)
    if mode == "encode":
        print(file=sys.stderr)
        print(f"  {CYAN}DPX sequence:{RESET}", file=sys.stderr)
        if not seq or seq["count"] == 0:
            print(f"    {YELLOW}(no .dpx files found at top level — rawcooked will probe further){RESET}",
                  file=sys.stderr)
        else:
            print(f"    Found:    {seq['count']} frames", file=sys.stderr)
            print(f"    First:    {seq['first_name']}", file=sys.stderr)
            print(f"    Last:     {seq['last_name']}", file=sys.stderr)
            if seq["first_num"]:
                missing_n = len(seq["missing"])
                if missing_n == 0:
                    print(f"    Range:    {seq['first_num']} → {seq['last_num']}  "
                          f"{GREEN}(no gaps){RESET}", file=sys.stderr)
                else:
                    print(f"    Range:    {seq['first_num']} → {seq['last_num']}  "
                          f"{YELLOW}({missing_n} missing — listed in log){RESET}", file=sys.stderr)
    print(file=sys.stderr)
    print(f"  {CYAN}Defaults:{RESET} --all (check, conch, hash, coherency, framemd5, accept-gaps)",
          file=sys.stderr)
    print(f"{BOLD}{BLUE}{SEP}{RESET}", file=sys.stderr)
    print(file=sys.stderr)
    print(f"  {DIM}↓ rawcooked output below ↓{RESET}", file=sys.stderr)
    print(file=sys.stderr)

    # Log header (plain text)
    with log_path.open("w") as fh:
        fh.write(f"RAWcooked {mode_upper} Log\n")
        fh.write("=" * 63 + "\n")
        fh.write(f"Started:   {datetime.now():%Y-%m-%d %H:%M:%S}\n")
        fh.write(f"Input:     {input_path}\n")
        fh.write(f"Output:    {output}\n")
        fh.write(f"Mode:      {mode}\n\n")
        if mode == "encode":
            fh.write("DPX Sequence\n")
            fh.write("------------\n")
            if not seq or seq["count"] == 0:
                fh.write("No .dpx files found at the top level of the input directory.\n")
                fh.write("(RAWcooked may still probe subdirs.)\n")
            else:
                fh.write(f"Found:     {seq['count']} frames\n")
                fh.write(f"First:     {seq['first_name']}\n")
                fh.write(f"Last:      {seq['last_name']}\n")
                if seq["first_num"]:
                    fh.write(f"Range:     {seq['first_num']} → {seq['last_num']}\n")
                    missing_n = len(seq["missing"])
                    fh.write(f"Gaps:      {'none detected' if missing_n == 0 else f'{missing_n} missing'}\n")
                fh.write("\nFirst 10 frames:\n")
                for f in seq["files"][:10]:
                    fh.write(f"  {f.name}\n")
                if seq["count"] > 10:
                    fh.write("\nLast 10 frames:\n")
                    for f in seq["files"][-10:]:
                        fh.write(f"  {f.name}\n")
                if seq["missing"]:
                    fh.write(f"\nMissing frames ({len(seq['missing'])}):\n")
                    for m in seq["missing"]:
                        fh.write(f"  {m}\n")
            fh.write("\n")
        fh.write("RAWcooked Output\n")
        fh.write("-" * 16 + "\n")


def postflight(status: int, duration: int, output: Path, log_path: Path) -> None:
    size = human_size(output) if output.exists() else ""
    md5 = ""
    try:
        content = log_path.read_text(errors="replace")
        m = re.search(r"Output file MD5 is ([a-f0-9]+)", content)
        if m:
            md5 = m.group(1)
    except OSError:
        pass

    dur_str = fmt_duration(duration)
    if status == 0:
        status_color, status_word = GREEN, "success"
    else:
        status_color, status_word = RED, f"FAILED (exit {status})"

    # Terminal banner
    print(file=sys.stderr)
    print(f"{BOLD}{BLUE}{SEP}{RESET}", file=sys.stderr)
    print(f"  {BOLD}Summary{RESET}   {status_color}{status_word}{RESET}", file=sys.stderr)
    print(f"{BOLD}{BLUE}{SEP}{RESET}", file=sys.stderr)
    print(f"  {CYAN}Duration:{RESET} {dur_str}", file=sys.stderr)
    if size:
        print(f"  {CYAN}Size:{RESET}     {size}", file=sys.stderr)
    if md5:
        print(f"  {CYAN}MD5:{RESET}      {md5}", file=sys.stderr)
    print(f"  {CYAN}Output:{RESET}   {output}", file=sys.stderr)
    print(f"  {CYAN}Log:{RESET}      {log_path}", file=sys.stderr)
    print(f"{BOLD}{BLUE}{SEP}{RESET}", file=sys.stderr)
    print(file=sys.stderr)

    # Log footer
    with log_path.open("a") as fh:
        fh.write("\nSummary\n-------\n")
        fh.write(f"Finished:  {datetime.now():%Y-%m-%d %H:%M:%S}\n")
        fh.write(f"Duration:  {dur_str}\n")
        fh.write(f"Exit:      {status} ({status_word})\n")
        fh.write(f"Output:    {output}\n")
        if size:
            fh.write(f"Size:      {size}\n")
        if md5:
            fh.write(f"MD5:       {md5}\n")


def main() -> int:
    install_sigterm_trap()
    argv = sys.argv[1:]
    if not argv:
        print_usage()
        return 0

    # Split off pass-through extras at the first '--' so argparse doesn't see them.
    extras: list[str] = []
    if "--" in argv:
        i = argv.index("--")
        extras = argv[i + 1:]
        argv = argv[:i]

    p = argparse.ArgumentParser(add_help=False)
    p.add_argument("-i", "--input")
    p.add_argument("-o", "--output")
    p.add_argument("-n", "--dry-run", action="store_true")
    p.add_argument("--force", action="store_true")
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

    in_path = Path(args.input)
    mode = detect_mode(in_path)
    if mode is None:
        log.error(f"input must be a directory (encode) or .mkv file (decode): {in_path}")
        return 2

    output = Path(args.output) if args.output else default_output(in_path, mode)
    log_path = Path(str(output) + ".log")

    cmd = ["rawcooked", "--all"]
    if args.force:
        cmd.append("-y")
    cmd.extend(["-o", str(output), str(in_path)])
    cmd.extend(extras)

    if args.dry_run:
        log.info("[dry-run] " + " ".join(shlex.quote(c) for c in cmd))
        log.info(f"[dry-run] would write log: {log_path}")
        return 0

    require("rawcooked")

    preflight(mode, in_path, output, log_path)

    start = time.time()
    # Stream rawcooked output to terminal AND log.
    with log_path.open("a") as logfh:
        proc = subprocess.Popen(
            cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
            text=True, bufsize=1,
        )
        assert proc.stdout is not None
        for line in proc.stdout:
            sys.stdout.write(line)
            sys.stdout.flush()
            logfh.write(line)
        status = proc.wait()
    duration = int(time.time() - start)

    postflight(status, duration, output, log_path)
    return status


if __name__ == "__main__":
    sys.exit(main())
