#!/usr/bin/env bash
# metadata.sh - extract MediaInfo, ffprobe, and ExifTool sidecars for TBM files.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=../lib/common.sh
source "${REPO_ROOT}/lib/common.sh"

tbm_trap_sigterm

if [[ -t 1 ]]; then
    BOLD=$'\033[1m'; BLUE=$'\033[34m'; CYAN=$'\033[36m'
    GREEN=$'\033[32m'; YELLOW=$'\033[33m'; DIM=$'\033[2m'; RESET=$'\033[0m'
else
    BOLD=''; BLUE=''; CYAN=''; GREEN=''; YELLOW=''; DIM=''; RESET=''
fi

_usage() {
    cat <<EOF
${BOLD}${BLUE}USAGE:${RESET}
  ${GREEN}metadata.sh${RESET} ${CYAN}-i${RESET} ${YELLOW}PATH${RESET} [options]

Run ${GREEN}metadata.sh${RESET} ${CYAN}-h${RESET} for detailed help.
EOF
}

_help() {
    cat <<EOF
${BOLD}${BLUE}NAME${RESET}
  ${GREEN}metadata.sh${RESET} — extract MediaInfo, ffprobe, and ExifTool sidecars for files

${BOLD}${BLUE}USAGE${RESET}
  ${GREEN}metadata.sh${RESET} ${CYAN}-i${RESET} ${YELLOW}PATH${RESET} [${CYAN}--no-mediainfo${RESET}] [${CYAN}--no-ffprobe${RESET}] [${CYAN}--no-exiftool${RESET}] [${CYAN}-n${RESET}]

${BOLD}${BLUE}OPTIONS${RESET}
  ${CYAN}-i${RESET} ${YELLOW}PATH${RESET}          File or directory (directory is recursed)
  ${CYAN}--no-mediainfo${RESET}   Skip ${YELLOW}mediainfo${RESET} (default: run)
  ${CYAN}--no-ffprobe${RESET}     Skip ${YELLOW}ffprobe${RESET} (default: run)
  ${CYAN}--no-exiftool${RESET}    Skip ${YELLOW}exiftool${RESET} (default: run)
  ${CYAN}-n${RESET}, ${CYAN}--dry-run${RESET}     Print planned actions, write nothing
  ${CYAN}-h${RESET}, ${CYAN}--help${RESET}        Show this help

${BOLD}${BLUE}EXAMPLES${RESET}
  ${DIM}# All three sidecars for a single file${RESET}
  ${GREEN}metadata.sh${RESET} ${CYAN}-i${RESET} /Volumes/archive/<file>

  ${DIM}# Process a whole directory${RESET}
  ${GREEN}metadata.sh${RESET} ${CYAN}-i${RESET} /Volumes/archive/<dir>

  ${DIM}# ffprobe only${RESET}
  ${GREEN}metadata.sh${RESET} ${CYAN}-i${RESET} /Volumes/archive/<file> ${CYAN}--no-mediainfo${RESET} ${CYAN}--no-exiftool${RESET}

${BOLD}${BLUE}OUTPUT FILES${RESET}
  One sidecar per tool, next to each source file:
    ${YELLOW}<file>.mediainfo.txt${RESET}  (from ${YELLOW}mediainfo -f${RESET})
    ${YELLOW}<file>.ffprobe.json${RESET}   (from ${YELLOW}ffprobe -show_format -show_streams -of json${RESET})
    ${YELLOW}<file>.exiftool.txt${RESET}   (from ${YELLOW}exiftool${RESET})
  Existing sidecars are not overwritten.
EOF
}

_iter_source_files() {
    local root="$1"
    if [[ -f "$root" ]]; then
        printf '%s\n' "$root"
    elif [[ -d "$root" ]]; then
        local args=(-type f) suf
        for suf in "${TBM_SIDECAR_SUFFIXES[@]}"; do
            args+=(! -name "*${suf}")
        done
        find "$root" "${args[@]}" | sort
    else
        tbm_error "Not a file or directory: $root"
        return 1
    fi
}

_run_capture() {
    # Args: out-path, tool-name, dry, cmd...
    local out="$1"; shift
    local tool="$1"; shift
    local dry="$1"; shift
    if [[ -f "$out" ]]; then
        tbm_info "skip (exists): $out"
        return 0
    fi
    if (( dry )); then
        tbm_info "[dry-run] would run: $tool ... -> $(basename "$out")"
        return 0
    fi
    if "$@" > "$out" 2>/dev/null; then
        tbm_ok "wrote $out"
    else
        tbm_warn "$tool failed for: $(basename "$out" ".${tool}.txt")"
        rm -f "$out"
        return 0
    fi
}

_run_mediainfo() {
    local f="$1" dry="$2"
    _run_capture "${f}.mediainfo.txt" mediainfo "$dry" mediainfo -f "$f"
}

_run_ffprobe() {
    local f="$1" dry="$2"
    _run_capture "${f}.ffprobe.json" ffprobe "$dry" \
        ffprobe -hide_banner -loglevel error -show_format -show_streams -of json "$f"
}

_run_exiftool() {
    local f="$1" dry="$2"
    _run_capture "${f}.exiftool.txt" exiftool "$dry" exiftool "$f"
}

main() {
    if [[ $# -eq 0 ]]; then _usage; exit 0; fi
    local input="" dry=0 do_mi=1 do_ff=1 do_et=1
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -i) input="${2:-}"; shift 2 ;;
            -n|--dry-run) dry=1; shift ;;
            --no-mediainfo) do_mi=0; shift ;;
            --no-ffprobe) do_ff=0; shift ;;
            --no-exiftool) do_et=0; shift ;;
            -h|--help) _help; exit 0 ;;
            *) tbm_error "Unknown arg: $1"; _usage >&2; exit 2 ;;
        esac
    done
    [[ -n "$input" ]] || { tbm_error "-i INPUT required"; _usage >&2; exit 2; }
    (( do_mi || do_ff || do_et )) || { tbm_error "All tools disabled"; exit 2; }

    local deps=()
    (( do_mi )) && deps+=(mediainfo)
    (( do_ff )) && deps+=(ffprobe)
    (( do_et )) && deps+=(exiftool)
    tbm_require "${deps[@]}"

    local count=0 f
    while IFS= read -r f; do
        (( do_mi )) && _run_mediainfo "$f" "$dry"
        (( do_ff )) && _run_ffprobe "$f" "$dry"
        (( do_et )) && _run_exiftool "$f" "$dry"
        count=$((count+1))
    done < <(_iter_source_files "$input")

    tbm_info "done: $count files processed"
}

main "$@"
