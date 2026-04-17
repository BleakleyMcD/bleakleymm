#!/usr/bin/env bash
# fixity.sh - make (default) or verify hash sidecars for TBM files.
# Writes <file>.<algo> sidecars in GNU sum format: "<hash>  <basename>"

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

SUPPORTED_ALGOS=(md5 sha1 sha256 sha512 crc32)
SIDECAR_EXTS=(md5 sha1 sha224 sha256 sha384 sha512 crc32)

_usage() {
    cat <<EOF
${BOLD}${BLUE}USAGE:${RESET}
  ${GREEN}fixity.sh${RESET} ${CYAN}-i${RESET} ${YELLOW}PATH${RESET} [options]

Run ${GREEN}fixity.sh${RESET} ${CYAN}-h${RESET} for detailed help.
EOF
}

_help() {
    cat <<EOF
${BOLD}${BLUE}NAME${RESET}
  ${GREEN}fixity.sh${RESET} — make or verify hash sidecars for files

${BOLD}${BLUE}USAGE${RESET}
  ${GREEN}fixity.sh${RESET} ${CYAN}-i${RESET} ${YELLOW}PATH${RESET} [${CYAN}-a${RESET} ${YELLOW}ALGO${RESET}] [${CYAN}-n${RESET}]           ${DIM}# make sidecars (default)${RESET}
  ${GREEN}fixity.sh${RESET} ${CYAN}-i${RESET} ${YELLOW}PATH${RESET} [${CYAN}-a${RESET} ${YELLOW}ALGO${RESET}] ${CYAN}--verify${RESET}     ${DIM}# verify existing sidecars${RESET}

${BOLD}${BLUE}OPTIONS${RESET}
  ${CYAN}-i${RESET} ${YELLOW}PATH${RESET}                File or directory (directory is recursed)
  ${CYAN}-a${RESET}, ${CYAN}--algorithm${RESET} ${YELLOW}ALGO${RESET}   Hash algorithm: ${YELLOW}md5${RESET} (default), ${YELLOW}sha1${RESET}, ${YELLOW}sha256${RESET}, ${YELLOW}sha512${RESET}, ${YELLOW}crc32${RESET}
  ${CYAN}-c${RESET}, ${CYAN}--verify${RESET}            Verify existing sidecars instead of making new ones
  ${CYAN}-n${RESET}, ${CYAN}--dry-run${RESET}           Print planned actions, write nothing (make mode only)
  ${CYAN}-h${RESET}, ${CYAN}--help${RESET}              Show this help

${BOLD}${BLUE}EXAMPLES${RESET}
  ${DIM}# MD5 sidecars for a directory${RESET}
  ${GREEN}fixity.sh${RESET} ${CYAN}-i${RESET} /Volumes/archive/MEDIAID

  ${DIM}# SHA-256 instead of MD5${RESET}
  ${GREEN}fixity.sh${RESET} ${CYAN}-i${RESET} /Volumes/archive/MEDIAID ${CYAN}-a${RESET} sha256

  ${DIM}# Dry-run shows what would happen${RESET}
  ${GREEN}fixity.sh${RESET} ${CYAN}-i${RESET} /Volumes/archive/MEDIAID ${CYAN}-n${RESET}

  ${DIM}# Verify existing SHA-256 sidecars${RESET}
  ${GREEN}fixity.sh${RESET} ${CYAN}-i${RESET} /Volumes/archive/MEDIAID ${CYAN}-a${RESET} sha256 ${CYAN}--verify${RESET}

${BOLD}${BLUE}SIDECAR FORMAT${RESET}
  One sidecar per source file, named ${YELLOW}<file>.<algo>${RESET}
  Content is GNU <algo>sum format (one line):
      ${YELLOW}<hash>  <basename>${RESET}
EOF
}

_algo_valid() {
    local a
    for a in "${SUPPORTED_ALGOS[@]}"; do
        [[ "$1" == "$a" ]] && return 0
    done
    return 1
}

_hash_only() {
    local f="$1" algo="$2"
    case "$algo" in
        md5)
            if command -v md5sum >/dev/null 2>&1; then
                md5sum "$f" | awk '{print $1}'
            else
                md5 -q "$f"
            fi
            ;;
        sha1|sha256|sha512)
            local bits="${algo#sha}"
            if command -v "sha${bits}sum" >/dev/null 2>&1; then
                "sha${bits}sum" "$f" | awk '{print $1}'
            else
                shasum -a "$bits" "$f" | awk '{print $1}'
            fi
            ;;
        crc32)
            if command -v crc32 >/dev/null 2>&1; then
                crc32 "$f"
            else
                python3 - "$f" <<'PY'
import sys, zlib
c = 0
with open(sys.argv[1], "rb") as f:
    while True:
        d = f.read(1048576)
        if not d:
            break
        c = zlib.crc32(d, c)
print(f"{c:08x}")
PY
            fi
            ;;
        *)
            tbm_error "Unsupported algorithm: $algo"
            exit 2
            ;;
    esac
}

_hash_file() {
    local f="$1" algo="$2"
    printf '%s  %s\n' "$(_hash_only "$f" "$algo")" "$(basename "$f")"
}

_iter_files() {
    local root="$1"
    if [[ -f "$root" ]]; then
        printf '%s\n' "$root"
    elif [[ -d "$root" ]]; then
        local args=(-type f) ext
        for ext in "${SIDECAR_EXTS[@]}"; do
            args+=(! -name "*.${ext}")
        done
        find "$root" "${args[@]}" | sort
    else
        tbm_error "Not a file or directory: $root"
        return 1
    fi
}

do_make() {
    local input="$1" algo="$2" dry="$3"
    local count=0 skipped=0 f sidecar
    while IFS= read -r f; do
        sidecar="${f}.${algo}"
        if [[ -f "$sidecar" ]]; then
            tbm_info "skip (sidecar exists): $f"
            skipped=$((skipped+1))
            continue
        fi
        if (( dry )); then
            tbm_info "[dry-run] would write: $sidecar"
        else
            _hash_file "$f" "$algo" > "$sidecar"
            tbm_ok "wrote $sidecar"
        fi
        count=$((count+1))
    done < <(_iter_files "$input")

    tbm_info "done: $count processed, $skipped skipped (algorithm: $algo)"
}

do_verify() {
    local input="$1" algo="$2"
    local ok=0 failed=0 missing=0 f sidecar expected actual
    while IFS= read -r f; do
        sidecar="${f}.${algo}"
        if [[ ! -f "$sidecar" ]]; then
            tbm_warn "no $algo sidecar: $f"
            missing=$((missing+1))
            continue
        fi
        expected="$(awk 'NR==1{print $1}' "$sidecar")"
        actual="$(_hash_only "$f" "$algo")"
        if [[ "$expected" == "$actual" ]]; then
            tbm_ok "match: $f"
            ok=$((ok+1))
        else
            tbm_error "MISMATCH: $f (expected $expected, got $actual)"
            failed=$((failed+1))
        fi
    done < <(_iter_files "$input")

    tbm_info "verify: $ok ok, $failed failed, $missing missing (algorithm: $algo)"
    [[ $failed -eq 0 ]] || exit 1
}

main() {
    if [[ $# -eq 0 ]]; then
        _usage
        exit 0
    fi

    local input="" algo="md5" dry=0 verify=0
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -i) input="${2:-}"; shift 2 ;;
            -a|--algorithm) algo="${2:-}"; shift 2 ;;
            -c|--verify) verify=1; shift ;;
            -n|--dry-run) dry=1; shift ;;
            -h|--help) _help; exit 0 ;;
            *) tbm_error "Unknown arg: $1"; _usage >&2; exit 2 ;;
        esac
    done

    [[ -n "$input" ]] || { tbm_error "-i INPUT required"; _usage >&2; exit 2; }
    _algo_valid "$algo" || { tbm_error "Unsupported algorithm: $algo (supported: ${SUPPORTED_ALGOS[*]})"; exit 2; }

    if (( verify )); then
        (( dry )) && { tbm_error "--dry-run is only valid in make mode"; exit 2; }
        do_verify "$input" "$algo"
    else
        do_make "$input" "$algo" "$dry"
    fi
}

main "$@"
