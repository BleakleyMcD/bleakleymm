#!/usr/bin/env python3
"""rawcooked.py - wrapper for RAWcooked: encode DPX sequence -> .mkv, or decode .mkv -> DPX."""
from __future__ import annotations

import argparse
import os
import re
import shlex
import shutil
import subprocess
import sys
import time
from datetime import datetime
from pathlib import Path
from zoneinfo import ZoneInfo

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "lib"))
from common import get_logger, install_sigterm_trap, require  # noqa: E402

log = get_logger()

if sys.stderr.isatty():
    BOLD = "\033[1m"; BLUE = "\033[34m"; CYAN = "\033[36m"
    GREEN = "\033[32m"; YELLOW = "\033[33m"; RED = "\033[31m"
    DIM = "\033[2m"; RESET = "\033[0m"
else:
    BOLD = BLUE = CYAN = GREEN = YELLOW = RED = DIM = RESET = ""

SEP = "═" * 63
DSEP = "─" * 63
ET = ZoneInfo("America/New_York")

FORMAT_TOKENS = {
    "DPX":     "DPX file",
    "TIFF":    "TIFF file",
    "EXR":     "OpenEXR file",
    "Raw":     "uncompressed",
    "RLE":     "run-length encoded",
    "RGB":     "RGB color",
    "RGBA":    "RGBA color (with alpha)",
    "Y":       "Y luminance only",
    "YUV":     "YUV color",
    "8bit":    "8 bits per component",
    "10bit":   "10 bits per component",
    "12bit":   "12 bits per component",
    "16bit":   "16 bits per component",
    "U":       "unsigned values",
    "S":       "signed values",
    "BE":      "big-endian byte order",
    "LE":      "little-endian byte order",
    "FilledA": "Method-A packing (padding at LSB)",
    "FilledB": "Method-B packing (padding at MSB)",
    "Packed":  "packed (no padding)",
}


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
  a Technical Summary (encode only — plain-English breakdown of what was encoded),
  an ffmpeg pipeline section (encode only), and a post-flight summary
  (Started/Finished in ET, duration, exit status, output size, output MD5).""")


def detect_mode(in_path: Path) -> str | None:
    if in_path.is_dir():
        return "encode"
    if in_path.is_file() and in_path.suffix.lower() == ".mkv":
        return "decode"
    return None


def default_output(input_path: Path, mode: str) -> Path:
    if mode == "encode":
        return Path(str(input_path).rstrip("/") + ".mkv")
    return Path(str(input_path).rstrip("/") + ".RAWcooked")


def fmt_duration(seconds: int) -> str:
    h, rem = divmod(seconds, 3600)
    m, s = divmod(rem, 60)
    return f"{h}h {m:02d}m {s:02d}s"


def now_et() -> str:
    return datetime.now(ET).strftime("%H:%M:%S ET")


def human_size(path: Path) -> str:
    """du -sh style: closest IEC unit (KiB/MiB/GiB)."""
    try:
        if path.is_dir():
            total = sum(f.stat().st_size for f in path.rglob("*") if f.is_file())
        else:
            total = path.stat().st_size
    except OSError:
        return ""
    val: float = float(total)
    for unit in ("B", "KiB", "MiB", "GiB", "TiB"):
        if val < 1024 or unit == "TiB":
            return f"{val:.1f} {unit}" if unit != "B" else f"{int(val)} B"
        val /= 1024
    return ""


def human_kib(kib_str: str) -> str:
    try:
        v = float(kib_str)
    except (TypeError, ValueError):
        return ""
    units = ("KiB", "MiB", "GiB", "TiB")
    i = 0
    while v >= 1024 and i < 3:
        v /= 1024
        i += 1
    return f"{v:.1f} {units[i]}"


def probe_framerate_source(input_path: Path) -> str:
    """Probe the first DPX with mediainfo to determine frame-rate provenance."""
    first = next(
        iter(sorted(p for p in input_path.iterdir()
                    if p.is_file() and p.suffix.lower() == ".dpx")),
        None,
    )
    if first is None:
        return "unknown (no DPX files found)"
    if shutil.which("mediainfo") is None:
        return "unknown (mediainfo not available)"
    try:
        out = subprocess.run(
            ["mediainfo", "--Inform=Image;%FrameRate%", str(first)],
            capture_output=True, text=True, check=False,
        )
    except OSError:
        return "unknown (mediainfo failed)"
    fr = out.stdout.strip()
    if fr and fr not in ("0", "0.000"):
        return "from DPX header"
    return "default — no header metadata"


def decode_format(raw: str) -> str:
    """Decode rawcooked source-format shorthand to plain-English description."""
    if not raw:
        return ""
    parts = [FORMAT_TOKENS.get(tok, tok) for tok in raw.split("/")]
    return ", ".join(parts)


def derive_dpx_pattern(name: str) -> tuple[str, int, str] | None:
    """Derive (prefix, width, ext) from a DPX filename, or None if it doesn't fit
    the <prefix><digits>.dpx shape. Extension keeps its original case."""
    if not name.lower().endswith(".dpx"):
        return None
    base, _, ext = name.rpartition(".")
    i = len(base)
    while i > 0 and base[i - 1].isdigit():
        i -= 1
    digits = base[i:]
    if not digits:
        return None
    return base[:i], len(digits), ext


def check_dpx_name(name: str, prefix: str, width: int) -> bool:
    """True if filename matches (prefix, width) DPX pattern. Extension is
    case-insensitive against .dpx; prefix must match exactly."""
    if not name.lower().endswith(".dpx"):
        return False
    base = name.rpartition(".")[0]
    if not base.startswith(prefix):
        return False
    seq = base[len(prefix):]
    return len(seq) == width and seq.isdigit()


def analyze_dpx_sequence(directory: Path) -> dict:
    files = sorted(p for p in directory.iterdir()
                   if p.is_file() and p.suffix.lower() == ".dpx")
    out = {
        "files": files, "count": len(files),
        "first_name": "", "last_name": "",
        "first_num": "", "last_num": "",
        "missing": [], "mismatches": [],
        "pattern_prefix": "", "pattern_width": 0, "pattern_ext": "",
        "pattern_display": "", "pattern_error": "",
    }
    if not files:
        return out

    pat = derive_dpx_pattern(files[0].name)
    if pat is None:
        out["pattern_error"] = "first file does not match the <prefix><digits>.dpx shape"
        out["first_name"] = files[0].name
        return out

    prefix, width, ext = pat
    out["pattern_prefix"] = prefix
    out["pattern_width"] = width
    out["pattern_ext"] = ext
    out["pattern_display"] = f"{prefix}{'N' * width}.{ext}"

    seq_numbers: list[str] = []
    for f in files:
        if check_dpx_name(f.name, prefix, width):
            base = f.name.rpartition(".")[0]
            seq_numbers.append(base[len(prefix):])
        else:
            out["mismatches"].append(f.name)

    if seq_numbers:
        out["first_num"] = seq_numbers[0]
        out["last_num"] = seq_numbers[-1]
        # Reconstruct first/last names from pattern so a stray mismatch at the
        # alphabetic edge doesn't masquerade as the sequence's first or last frame.
        out["first_name"] = f"{prefix}{seq_numbers[0]}.{ext}"
        out["last_name"] = f"{prefix}{seq_numbers[-1]}.{ext}"
        first_i, last_i = int(seq_numbers[0]), int(seq_numbers[-1])
        existing = set(seq_numbers)
        out["missing"] = [f"{i:0{width}d}" for i in range(first_i, last_i + 1)
                          if f"{i:0{width}d}" not in existing]
    return out


def preflight(mode: str, input_path: Path, output: Path, log_path: Path) -> int:
    """Render banner, write log header, validate DPX naming. Returns 0 normally;
    returns 3 if encode-mode naming inconsistencies were detected (caller aborts)."""
    seq = (analyze_dpx_sequence(input_path)
           if mode == "encode" and input_path.is_dir() else None)
    mode_upper = mode.upper()

    # Terminal banner: bars bold/blue, header text plain.
    print(file=sys.stderr)
    print(f"{BOLD}{BLUE}{SEP}{RESET}", file=sys.stderr)
    print(f"  RAWcooked {mode_upper}", file=sys.stderr)
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
        elif seq["pattern_error"]:
            print(f"    {RED}ERROR:{RESET}    {seq['pattern_error']}", file=sys.stderr)
            print(f"    First:    {seq['first_name']}", file=sys.stderr)
        else:
            mismatches = seq["mismatches"]
            print(f"    Pattern:  {seq['pattern_display']} ({seq['pattern_width']}-digit sequence)",
                  file=sys.stderr)
            if not mismatches:
                print(f"    Found:    {seq['count']} frames", file=sys.stderr)
            else:
                print(f"    Found:    {seq['count']} .dpx total "
                      f"({GREEN}{seq['count'] - len(mismatches)} match pattern{RESET}, "
                      f"{RED}{len(mismatches)} do not{RESET})", file=sys.stderr)
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
            if mismatches:
                print(f"    {RED}Mismatches:{RESET}  {RED}{len(mismatches)} files do not match pattern{RESET}",
                      file=sys.stderr)
                for mm in mismatches[:5]:
                    print(f"      {RED}{mm}{RESET}", file=sys.stderr)
                if len(mismatches) > 5:
                    print(f"      {DIM}… ({len(mismatches) - 5} more — full list in log){RESET}",
                          file=sys.stderr)
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
        fh.write(f"Started:   {datetime.now():%Y-%m-%d %H:%M:%S} ({now_et()})\n")
        fh.write(f"Input:     {input_path}\n")
        fh.write(f"Output:    {output}\n")
        fh.write(f"Mode:      {mode}\n\n")
        if mode == "encode":
            fh.write("DPX Sequence\n")
            fh.write("------------\n")
            if not seq or seq["count"] == 0:
                fh.write("No .dpx files found at the top level of the input directory.\n")
                fh.write("(RAWcooked may still probe subdirs.)\n")
            elif seq["pattern_error"]:
                fh.write(f"ERROR:     {seq['pattern_error']}\n")
                fh.write(f"First:     {seq['first_name']}\n")
            else:
                mismatches = seq["mismatches"]
                fh.write(f"Pattern:   {seq['pattern_display']} ({seq['pattern_width']}-digit sequence)\n")
                fh.write(f"Found:     {seq['count']} frames total "
                         f"({seq['count'] - len(mismatches)} match pattern, {len(mismatches)} mismatched)\n")
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
                if mismatches:
                    fh.write(f"\nNaming mismatches ({len(mismatches)}):\n")
                    for mm in mismatches:
                        fh.write(f"  {mm}\n")
            fh.write("\n")
        fh.write("RAWcooked Output\n")
        fh.write("-" * 16 + "\n")

    # Signal abort if encode-mode naming inconsistencies were detected.
    if mode == "encode" and seq:
        if seq.get("pattern_error") or seq.get("mismatches"):
            return 3
    return 0


def tech_summary(log_path: Path, framerate_source: str) -> None:
    """Parse captured rawcooked/ffmpeg output and emit a Technical Summary."""
    text = log_path.read_text(errors="replace")

    def find(pat, flags=0):
        m = re.search(pat, text, flags)
        return m.group(1) if m else ""

    raw_format = find(r"^[ \t]*((?:DPX|TIFF|EXR)/[A-Za-z0-9/]+)\s*$", re.MULTILINE)
    pretty_format = decode_format(raw_format)

    input_stream_m = re.search(r"Stream #0:0:.*Video:.*dpx.*", text)
    input_stream = input_stream_m.group(0) if input_stream_m else ""
    res_m = re.search(r"(\d+)x(\d+)", input_stream)
    resolution = f"{res_m.group(1)} × {res_m.group(2)}" if res_m else ""
    fps_m = re.search(r"([\d.]+) fps", input_stream)
    fps = fps_m.group(1) if fps_m else ""

    progress_lines = re.findall(r"^frame=.*$", text, re.MULTILINE)
    progress = progress_lines[-1] if progress_lines else ""
    fc_m = re.search(r"frame=\s*(\d+)", progress)
    frame_count = fc_m.group(1) if fc_m else ""
    lsize_m = re.search(r"Lsize=\s*(\d+)KiB", progress)
    lsize_kib = lsize_m.group(1) if lsize_m else ""
    br_m = re.search(r"bitrate=\s*([\d.]+)kbits/s", progress)
    bitrate_kbps = br_m.group(1) if br_m else ""

    output_size = human_kib(lsize_kib)
    bitrate_mbps = f"{float(bitrate_kbps)/1000:.0f}" if bitrate_kbps else ""

    dur_m = re.search(r"Duration:\s*(\d+):(\d+):([\d.]+)", text)
    if dur_m:
        h, m, s = int(dur_m.group(1)), int(dur_m.group(2)), dur_m.group(3)
        # Strip leading zero on seconds ("06.04" -> "6.04"; "00.62" -> "0.62").
        if s.startswith("0") and len(s) > 1 and s[1] != ".":
            s = s[1:]
        if h > 0:
            content_pretty = f"{h}h {m}m {s}s"
        elif m > 0:
            content_pretty = f"{m}m {s}s"
        else:
            content_pretty = f"{s}s"
    else:
        content_pretty = ""

    # Encode speed (ffmpeg pass): from the final "frame=... speed=N.Nx" line.
    enc_m = re.search(r"speed=\s*([\d.]+x)", progress)
    encode_speed = enc_m.group(1) if enc_m else ""

    # Check speed (reversibility pass): from the final rawcooked "Time=..." progress line.
    time_lines = re.findall(r"^Time=.*$", text, re.MULTILINE)
    check_line = time_lines[-1] if time_lines else ""
    chk_m = re.search(r"([\d.]+x realtime)", check_line)
    check_speed = chk_m.group(1) if chk_m else ""

    # Overall throughput: rawcooked's final "N.N MiB/s, N.NNx realtime" line (not the Time= lines).
    overall_lines = [ln for ln in re.findall(r".*realtime.*", text)
                     if not ln.startswith("Time=")]
    overall_line = overall_lines[-1] if overall_lines else ""
    tp_m = re.search(r"([\d.]+ MiB/s)", overall_line)
    overall_throughput = tp_m.group(1) if tp_m else ""
    ov_m = re.search(r"([\d.]+x realtime)", overall_line)
    overall_speed = ov_m.group(1) if ov_m else ""

    if "Reversibility was checked, no issue detected" in text:
        rev_color = f"{GREEN}✓ checked, no issues detected{RESET}"
        rev_plain = "checked, no issues detected"
    elif re.search(r"Reversibility.*issue.*detected", text):
        rev_color = f"{RED}✗ ISSUES DETECTED — see log{RESET}"
        rev_plain = "ISSUES DETECTED — see log"
    else:
        rev_color = f"{YELLOW}not verified{RESET}"
        rev_plain = "not verified"

    if re.search(r"Uncompressed file hashes.*present", text):
        hashes_color = f"{GREEN}✓ uncompressed source hashes embedded{RESET}"
        hashes_plain = "uncompressed source hashes embedded"
    else:
        hashes_color = f"{YELLOW}not embedded{RESET}"
        hashes_plain = "not embedded"

    md5_m = re.search(r"Output file MD5 is ([a-f0-9]+)", text)
    md5 = md5_m.group(1) if md5_m else ""
    # Match the version specifically — not the trailing period in the Info line.
    rc_m = re.search(r"created by RAWcooked (\d+(?:\.\d+)*)", text)
    rc_ver = rc_m.group(1) if rc_m else ""

    fc_pretty = f"{int(frame_count):,}" if frame_count else ""

    # Terminal
    print(file=sys.stderr)
    print(f"{BLUE}{DSEP}{RESET}", file=sys.stderr)
    print(f"  Technical Summary", file=sys.stderr)
    print(f"{BLUE}{DSEP}{RESET}", file=sys.stderr)
    if pretty_format:
        print(f"  {CYAN}Source format:{RESET}    {pretty_format}", file=sys.stderr)
    print(f"  {CYAN}Output codec:{RESET}     FFV1 in Matroska", file=sys.stderr)
    if resolution:
        print(f"  {CYAN}Resolution:{RESET}       {resolution}", file=sys.stderr)
    if fps:
        print(f"  {CYAN}Frame rate:{RESET}       {fps} fps ({framerate_source})", file=sys.stderr)
    if frame_count:
        print(f"  {CYAN}Frame count:{RESET}      {fc_pretty}", file=sys.stderr)
    if content_pretty and fps and frame_count:
        print(f"  {CYAN}Content length:{RESET}   {content_pretty} ({fc_pretty} frames @ {fps} fps)",
              file=sys.stderr)
    if output_size:
        print(f"  {CYAN}Output size:{RESET}      {output_size}", file=sys.stderr)
    if bitrate_mbps:
        print(f"  {CYAN}Output bitrate:{RESET}   ~{bitrate_mbps} Mbps", file=sys.stderr)
    if encode_speed:
        print(f"  {CYAN}Encode speed:{RESET}     {encode_speed} realtime (ffmpeg pass)", file=sys.stderr)
    if check_speed:
        print(f"  {CYAN}Check speed:{RESET}      {check_speed} (reversibility pass)", file=sys.stderr)
    if overall_speed and overall_throughput:
        print(f"  {CYAN}Overall:{RESET}          {overall_speed} ({overall_throughput})", file=sys.stderr)
    elif overall_speed:
        print(f"  {CYAN}Overall:{RESET}          {overall_speed}", file=sys.stderr)
    print(f"  {CYAN}Reversibility:{RESET}    {rev_color}", file=sys.stderr)
    print(f"  {CYAN}File hashes:{RESET}      {hashes_color}", file=sys.stderr)
    if md5:
        print(f"  {CYAN}Output MD5:{RESET}       {md5}", file=sys.stderr)
    if rc_ver:
        print(f"  {CYAN}RAWcooked ver.:{RESET}   {rc_ver}", file=sys.stderr)
    print(f"{BLUE}{DSEP}{RESET}", file=sys.stderr)

    # Log (plain)
    with log_path.open("a") as fh:
        fh.write("\nTechnical Summary\n")
        fh.write("-----------------\n")
        if pretty_format:
            fh.write(f"Source format:    {pretty_format}\n")
        fh.write("Output codec:     FFV1 in Matroska\n")
        if resolution:
            fh.write(f"Resolution:       {resolution}\n")
        if fps:
            fh.write(f"Frame rate:       {fps} fps ({framerate_source})\n")
        if frame_count:
            fh.write(f"Frame count:      {fc_pretty}\n")
        if content_pretty and fps and frame_count:
            fh.write(f"Content length:   {content_pretty} ({fc_pretty} frames @ {fps} fps)\n")
        if output_size:
            fh.write(f"Output size:      {output_size}\n")
        if bitrate_mbps:
            fh.write(f"Output bitrate:   ~{bitrate_mbps} Mbps\n")
        if encode_speed:
            fh.write(f"Encode speed:     {encode_speed} realtime (ffmpeg pass)\n")
        if check_speed:
            fh.write(f"Check speed:      {check_speed} (reversibility pass)\n")
        if overall_speed and overall_throughput:
            fh.write(f"Overall:          {overall_speed} ({overall_throughput})\n")
        elif overall_speed:
            fh.write(f"Overall:          {overall_speed}\n")
        fh.write(f"Reversibility:    {rev_plain}\n")
        fh.write(f"File hashes:      {hashes_plain}\n")
        if md5:
            fh.write(f"Output MD5:       {md5}\n")
        if rc_ver:
            fh.write(f"RAWcooked ver.:   {rc_ver}\n")


def ffmpeg_summary(log_path: Path) -> None:
    text = log_path.read_text(errors="replace")

    ver_m = re.search(r"^ffmpeg version\s+(\S+)", text, re.MULTILINE)
    ffmpeg_ver = ver_m.group(1) if ver_m else ""

    def lib_ver(name):
        # Line looks like "  libavcodec     62. 11.100 / 62. 11.100" — join first two fields after name.
        m = re.search(rf"^\s+{name}\s+(\S+)\s+(\S+)", text, re.MULTILINE)
        return (m.group(1) + m.group(2)).strip() if m else ""

    libavcodec = lib_ver("libavcodec")
    libavformat = lib_ver("libavformat")

    streams_desc = ("1 video (FFV1) + 1 attachment (reversibility data)"
                    if "Attachment:" in text else "1 video (FFV1)")

    out_video_m = re.search(r"Stream #0:0:.*Video: ffv1.*", text)
    out_video = out_video_m.group(0) if out_video_m else ""
    ctag_m = re.search(r"bt\d+", out_video)
    color_tag = ctag_m.group(0).upper() if ctag_m else "unspecified"
    scan = "progressive" if "progressive" in out_video else "interlaced/unknown"

    mux_m = re.search(r"muxing overhead:\s*([\d.]+%)", text)
    muxing = mux_m.group(1) if mux_m else ""

    # Terminal
    print(file=sys.stderr)
    print(f"{BLUE}{DSEP}{RESET}", file=sys.stderr)
    print("  ffmpeg pipeline", file=sys.stderr)
    print(f"{BLUE}{DSEP}{RESET}", file=sys.stderr)
    if ffmpeg_ver:
        print(f"  {CYAN}ffmpeg version:{RESET}   {ffmpeg_ver} "
              f"(libavcodec {libavcodec}, libavformat {libavformat})", file=sys.stderr)
    print(f"  {CYAN}Pipeline:{RESET}         DPX → FFV1 → Matroska", file=sys.stderr)
    print(f"  {CYAN}Streams in .mkv:{RESET}  {streams_desc}", file=sys.stderr)
    print(f"  {CYAN}Color tag:{RESET}        {color_tag} RGB, {scan}", file=sys.stderr)
    if muxing:
        print(f"  {CYAN}Muxing overhead:{RESET}  {muxing}", file=sys.stderr)
    print(f"{BLUE}{DSEP}{RESET}", file=sys.stderr)

    # Log (plain)
    with log_path.open("a") as fh:
        fh.write("\nffmpeg pipeline\n")
        fh.write("---------------\n")
        if ffmpeg_ver:
            fh.write(f"ffmpeg version:   {ffmpeg_ver} "
                     f"(libavcodec {libavcodec}, libavformat {libavformat})\n")
        fh.write("Pipeline:         DPX → FFV1 → Matroska\n")
        fh.write(f"Streams in .mkv:  {streams_desc}\n")
        fh.write(f"Color tag:        {color_tag} RGB, {scan}\n")
        if muxing:
            fh.write(f"Muxing overhead:  {muxing}\n")


def postflight(status: int, duration: int, output: Path, log_path: Path,
               mode: str, start_et: str, end_et: str) -> None:
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
    if mode == "encode":
        duration_label, output_label = "Encode duration", "Output .mkv"
    else:
        duration_label, output_label = "Decode duration", "Output dir"

    # Terminal banner. Bars bold/blue; "Summary" plain.
    print(file=sys.stderr)
    print(f"{BOLD}{BLUE}{SEP}{RESET}", file=sys.stderr)
    print(f"  Summary   {status_color}{status_word}{RESET}", file=sys.stderr)
    print(f"{BOLD}{BLUE}{SEP}{RESET}", file=sys.stderr)
    print(f"  {CYAN}Started:{RESET}          {start_et}", file=sys.stderr)
    print(f"  {CYAN}Finished:{RESET}         {end_et}", file=sys.stderr)
    print(f"  {CYAN}{duration_label}:{RESET}  {dur_str}", file=sys.stderr)
    print(f"  {CYAN}{output_label}:{RESET}      {output}", file=sys.stderr)
    if size:
        print(f"  {CYAN}Output size:{RESET}      {size}", file=sys.stderr)
    if mode == "encode" and md5:
        print(f"  {CYAN}Output MD5:{RESET}       {md5}", file=sys.stderr)
    print(f"  {CYAN}Log:{RESET}              {log_path}", file=sys.stderr)
    print(f"{BOLD}{BLUE}{SEP}{RESET}", file=sys.stderr)
    print(file=sys.stderr)

    # Log footer (printf-style field width keeps columns aligned regardless of label length)
    with log_path.open("a") as fh:
        fh.write("\nSummary\n-------\n")
        fh.write(f"{'Started:':<19} {start_et}\n")
        fh.write(f"{'Finished:':<19} {end_et}\n")
        fh.write(f"{duration_label + ':':<19} {dur_str}\n")
        fh.write(f"{'Exit:':<19} {status} ({status_word})\n")
        fh.write(f"{output_label + ':':<19} {output}\n")
        if size:
            fh.write(f"{'Output size:':<19} {size}\n")
        if mode == "encode" and md5:
            fh.write(f"{'Output MD5:':<19} {md5}\n")


def main() -> int:
    install_sigterm_trap()
    argv = sys.argv[1:]
    if not argv:
        print_usage()
        return 0

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

    framerate_source = ""
    if mode == "encode":
        framerate_source = probe_framerate_source(in_path)

    preflight_status = preflight(mode, in_path, output, log_path)
    if preflight_status != 0:
        log.error("Aborting: DPX naming inconsistencies detected in input dir.")
        log.error("Every .dpx file must follow the pattern derived from the first file.")
        log.error(f"See pre-flight output above (and {log_path}) for the full list.")
        return 3

    start = time.time()
    start_et = now_et()
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
    end_et = now_et()

    if mode == "encode":
        tech_summary(log_path, framerate_source)
        ffmpeg_summary(log_path)

    postflight(status, duration, output, log_path, mode, start_et, end_et)
    return status


if __name__ == "__main__":
    sys.exit(main())
