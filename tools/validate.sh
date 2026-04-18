#!/usr/bin/env bash
# validate.sh - run MediaConch policy + ffprobe parse check on each file.
# Exits non-zero if any file fails.

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

DEFAULT_POLICY="${REPO_ROOT}/policies/default.xml"

_usage() {
    cat <<EOF
${BOLD}${BLUE}USAGE:${RESET}
  ${GREEN}validate.sh${RESET} ${CYAN}-i${RESET} ${YELLOW}PATH${RESET} [${CYAN}--policy${RESET} ${YELLOW}POLICY.xml${RESET}]

Run ${GREEN}validate.sh${RESET} ${CYAN}-h${RESET} for detailed help.
EOF
}

_help() {
    cat <<EOF
${BOLD}${BLUE}NAME${RESET}
  ${GREEN}validate.sh${RESET} — validate files against a MediaConch policy and confirm ffprobe can parse them

${BOLD}${BLUE}USAGE${RESET}
  ${GREEN}validate.sh${RESET} ${CYAN}-i${RESET} ${YELLOW}PATH${RESET} [${CYAN}--policy${RESET} ${YELLOW}POLICY.xml${RESET}]

${BOLD}${BLUE}OPTIONS${RESET}
  ${CYAN}-i${RESET} ${YELLOW}PATH${RESET}              File or directory (directory is recursed)
  ${CYAN}--policy${RESET} ${YELLOW}POLICY.xml${RESET}   MediaConch policy to check against
                       (default: ${YELLOW}policies/default.xml${RESET} in this repo)
  ${CYAN}-h${RESET}, ${CYAN}--help${RESET}            Show this help

${BOLD}${BLUE}CHECKS${RESET}
  For each file:
    1. ${YELLOW}mediaconch -p POLICY${RESET} — must report "pass!"
    2. ${YELLOW}ffprobe${RESET} must parse the file without error

${BOLD}${BLUE}EXIT CODES${RESET}
  ${YELLOW}0${RESET}  All files passed both checks
  ${YELLOW}1${RESET}  At least one file failed one or both checks
  ${YELLOW}2${RESET}  Bad invocation

${BOLD}${BLUE}EXAMPLES${RESET}
  ${DIM}# Validate a file against the bundled default policy${RESET}
  ${GREEN}validate.sh${RESET} ${CYAN}-i${RESET} /Volumes/archive/<file>

  ${DIM}# Validate a directory against a custom policy${RESET}
  ${GREEN}validate.sh${RESET} ${CYAN}-i${RESET} /Volumes/archive/<dir> ${CYAN}--policy${RESET} ~/my-ffv1.xml

${BOLD}${BLUE}OUTPUT${RESET}
  Per-file pass/fail is printed to the terminal.
  No sidecar files are written.
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

_check_mediaconch() {
    # stdout: "pass!" or "fail!" prefix followed by filename
    local f="$1" policy="$2" out
    if out=$(mediaconch -p "$policy" "$f" 2>&1); then
        if [[ "$out" == pass!* ]]; then
            tbm_ok "mediaconch pass: $f"
            return 0
        fi
        tbm_error "mediaconch FAIL: $f"
        printf '%s\n' "$out" | sed 's/^/    /'
        return 1
    fi
    tbm_error "mediaconch error: $f"
    printf '%s\n' "$out" | sed 's/^/    /'
    return 1
}

_check_ffprobe() {
    local f="$1"
    if ffprobe -v error -show_format -show_streams "$f" >/dev/null 2>&1; then
        tbm_ok "ffprobe parse: $f"
        return 0
    fi
    tbm_error "ffprobe FAIL: $f"
    ffprobe -v error -show_format "$f" 2>&1 | sed 's/^/    /' || true
    return 1
}

main() {
    if [[ $# -eq 0 ]]; then _usage; exit 0; fi

    local input="" policy="$DEFAULT_POLICY"
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -i) input="${2:-}"; shift 2 ;;
            --policy) policy="${2:-}"; shift 2 ;;
            -h|--help) _help; exit 0 ;;
            *) tbm_error "Unknown arg: $1"; _usage >&2; exit 2 ;;
        esac
    done
    [[ -n "$input" ]] || { tbm_error "-i INPUT required"; _usage >&2; exit 2; }
    [[ -f "$policy" ]] || { tbm_error "Policy file not found: $policy"; exit 2; }
    tbm_require mediaconch ffprobe

    local total=0 failed=0 f
    while IFS= read -r f; do
        total=$((total+1))
        local ok=1
        _check_mediaconch "$f" "$policy" || ok=0
        _check_ffprobe "$f" || ok=0
        (( ok )) || failed=$((failed+1))
    done < <(_iter_source_files "$input")

    tbm_info "summary: $((total-failed))/$total passed (policy: $(basename "$policy"))"
    [[ $failed -eq 0 ]] || exit 1
}

main "$@"
