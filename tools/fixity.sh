#!/usr/bin/env bash
# fixity.sh - make or verify MD5 sidecars for TBM files.
#
# Usage:
#   fixity.sh make   -i PATH [--dry-run]
#   fixity.sh verify -i PATH
#
# Writes <file>.md5 next to each source file in GNU md5sum format:
#     <hash>  <basename>

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=../lib/common.sh
source "${REPO_ROOT}/lib/common.sh"

tbm_trap_sigterm

_usage() {
    cat <<'EOF'
fixity.sh - make or verify MD5 sidecars

Usage:
  fixity.sh make   -i PATH [--dry-run]
  fixity.sh verify -i PATH

Options:
  -i PATH       File or directory (recursed)
  --dry-run     make: print planned actions, write nothing
  -h, --help    Show this help

Sidecar format (GNU md5sum): <hash>  <basename>
EOF
}

_hash_file() {
    local f="$1" base
    base="$(basename "$f")"
    if command -v md5sum >/dev/null 2>&1; then
        md5sum "$f" | awk -v b="$base" '{print $1"  "b}'
    else
        printf '%s  %s\n' "$(md5 -q "$f")" "$base"
    fi
}

_iter_files() {
    local root="$1"
    if [[ -f "$root" ]]; then
        printf '%s\n' "$root"
    elif [[ -d "$root" ]]; then
        find "$root" -type f ! -name '*.md5' | sort
    else
        tbm_error "Not a file or directory: $root"
        return 1
    fi
}

cmd_make() {
    local input="" dry=0
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -i) input="${2:-}"; shift 2 ;;
            --dry-run) dry=1; shift ;;
            -h|--help) _usage; exit 0 ;;
            *) tbm_error "Unknown arg: $1"; _usage; exit 2 ;;
        esac
    done
    [[ -n "$input" ]] || { tbm_error "-i INPUT required"; exit 2; }

    local count=0 skipped=0 f sidecar
    while IFS= read -r f; do
        sidecar="${f}.md5"
        if [[ -f "$sidecar" ]]; then
            tbm_info "skip (sidecar exists): $f"
            skipped=$((skipped+1))
            continue
        fi
        if (( dry )); then
            tbm_info "[dry-run] would write: $sidecar"
        else
            _hash_file "$f" > "$sidecar"
            tbm_ok "wrote $sidecar"
        fi
        count=$((count+1))
    done < <(_iter_files "$input")

    tbm_info "done: $count processed, $skipped skipped"
}

cmd_verify() {
    local input=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -i) input="${2:-}"; shift 2 ;;
            -h|--help) _usage; exit 0 ;;
            *) tbm_error "Unknown arg: $1"; _usage; exit 2 ;;
        esac
    done
    [[ -n "$input" ]] || { tbm_error "-i INPUT required"; exit 2; }

    local ok=0 failed=0 missing=0 f sidecar expected actual
    while IFS= read -r f; do
        sidecar="${f}.md5"
        if [[ ! -f "$sidecar" ]]; then
            tbm_warn "no sidecar: $f"
            missing=$((missing+1))
            continue
        fi
        expected="$(awk 'NR==1{print $1}' "$sidecar")"
        actual="$(_hash_file "$f" | awk '{print $1}')"
        if [[ "$expected" == "$actual" ]]; then
            tbm_ok "match: $f"
            ok=$((ok+1))
        else
            tbm_error "MISMATCH: $f (expected $expected, got $actual)"
            failed=$((failed+1))
        fi
    done < <(_iter_files "$input")

    tbm_info "verify: $ok ok, $failed failed, $missing missing"
    [[ $failed -eq 0 ]] || exit 1
}

main() {
    local sub="${1:-}"
    case "$sub" in
        make)   shift; cmd_make "$@" ;;
        verify) shift; cmd_verify "$@" ;;
        -h|--help|"") _usage ;;
        *) tbm_error "Unknown subcommand: $sub"; _usage; exit 2 ;;
    esac
}

main "$@"
