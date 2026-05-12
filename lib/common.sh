#!/usr/bin/env bash
# common.sh - shared helpers for bleakleymm scripts.
# Sourced by transcode.sh, fixity.sh, metadata.sh, package.sh, validate.sh, rawcooked.sh.

# Suffixes that mark a file as a sidecar / generated output rather than a source.
# Scripts iterating a directory skip files matching these to avoid re-processing
# previously-generated artifacts.
TBM_SIDECAR_SUFFIXES=(
    .access.mp4
    .mediainfo.txt
    .mediainfo.json
    .mediatrace.xml
    .md5.txt
    .sha1.txt
    .sha256.txt
    .sha512.txt
    .crc32.txt
    .framemd5
    .log
)

# Color codes — empty if stderr isn't a TTY (e.g. piped to a log file).
if [[ -t 2 ]]; then
    _TBM_RED=$'\033[31m'
    _TBM_YELLOW=$'\033[33m'
    _TBM_GREEN=$'\033[32m'
    _TBM_CYAN=$'\033[36m'
    _TBM_RESET=$'\033[0m'
else
    _TBM_RED=''
    _TBM_YELLOW=''
    _TBM_GREEN=''
    _TBM_CYAN=''
    _TBM_RESET=''
fi

# Leveled logging — all to stderr so script stdout stays clean for piping.
tbm_error() { printf '%s[error]%s %s\n' "${_TBM_RED}"    "${_TBM_RESET}" "$*" >&2; }
tbm_warn()  { printf '%s[warn]%s  %s\n' "${_TBM_YELLOW}" "${_TBM_RESET}" "$*" >&2; }
tbm_info()  { printf '%s[info]%s  %s\n' "${_TBM_CYAN}"   "${_TBM_RESET}" "$*" >&2; }
tbm_ok()    { printf '%s[ok]%s    %s\n' "${_TBM_GREEN}"  "${_TBM_RESET}" "$*" >&2; }

# Assert a command exists on PATH; exit 127 if not.
tbm_require() {
    local cmd="$1"
    if ! command -v "$cmd" >/dev/null 2>&1; then
        tbm_error "required tool not found: $cmd"
        exit 127
    fi
}

# Install a SIGTERM handler that exits cleanly (status 143).
tbm_trap_sigterm() {
    trap 'tbm_warn "terminated"; exit 143' TERM
}
