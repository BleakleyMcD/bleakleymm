#!/usr/bin/env bash
# rawcooked.sh - wrapper for RAWcooked: encode DPX sequence -> .mkv, or decode .mkv -> DPX.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=../lib/common.sh
source "${REPO_ROOT}/lib/common.sh"

tbm_trap_sigterm

# Banner colors (to stderr, so log capture from stdout stays clean)
if [[ -t 2 ]]; then
    BOLD=$'\033[1m'; BLUE=$'\033[34m'; CYAN=$'\033[36m'
    GREEN=$'\033[32m'; YELLOW=$'\033[33m'; RED=$'\033[31m'; DIM=$'\033[2m'; RESET=$'\033[0m'
else
    BOLD=''; BLUE=''; CYAN=''; GREEN=''; YELLOW=''; RED=''; DIM=''; RESET=''
fi

_SEP='═══════════════════════════════════════════════════════════════'

_usage() {
    cat <<EOF
${BOLD}${BLUE}USAGE:${RESET}
  ${GREEN}rawcooked.sh${RESET} ${CYAN}-i${RESET} ${YELLOW}PATH${RESET} [${CYAN}-o${RESET} ${YELLOW}OUTPUT${RESET}] [${CYAN}-n${RESET}] [${CYAN}--force${RESET}] [${CYAN}--${RESET} ${YELLOW}EXTRA...${RESET}]

Run ${GREEN}rawcooked.sh${RESET} ${CYAN}-h${RESET} for detailed help.
EOF
}

_help() {
    cat <<EOF
${BOLD}${BLUE}NAME${RESET}
  ${GREEN}rawcooked.sh${RESET} — encode DPX sequence to FFV1/Matroska, or decode it back

${BOLD}${BLUE}USAGE${RESET}
  ${GREEN}rawcooked.sh${RESET} ${CYAN}-i${RESET} ${YELLOW}PATH${RESET} [${CYAN}-o${RESET} ${YELLOW}OUTPUT${RESET}] [${CYAN}-n${RESET}] [${CYAN}--force${RESET}] [${CYAN}--${RESET} ${YELLOW}EXTRA...${RESET}]

${BOLD}${BLUE}OPTIONS${RESET}
  ${CYAN}-i${RESET} ${YELLOW}PATH${RESET}            DPX sequence directory (encode) or ${YELLOW}.mkv${RESET} file (decode)
  ${CYAN}-o${RESET} ${YELLOW}OUTPUT${RESET}          Output path. Default: rawcooked's default
                     (${YELLOW}\${input}.mkv${RESET} on encode, ${YELLOW}\${input}.RAWcooked/${RESET} on decode).
  ${CYAN}-n${RESET}, ${CYAN}--dry-run${RESET}       Print the rawcooked command, don't run it
  ${CYAN}--force${RESET}             Pass ${YELLOW}-y${RESET} to rawcooked — overwrite existing outputs
  ${CYAN}--${RESET} ${YELLOW}EXTRA...${RESET}        Anything after ${CYAN}--${RESET} is passed to rawcooked verbatim
                     (e.g. ${YELLOW}--no-check-padding${RESET}, ${YELLOW}-framerate 24${RESET})
  ${CYAN}-h${RESET}, ${CYAN}--help${RESET}          Show this help

${BOLD}${BLUE}MODES${RESET}
  ${YELLOW}encode${RESET}  ${CYAN}-i${RESET} is a directory → DPX sequence becomes one FFV1/Matroska ${YELLOW}.mkv${RESET}
  ${YELLOW}decode${RESET}  ${CYAN}-i${RESET} is a ${YELLOW}.mkv${RESET}     → restore the original DPX sequence

${BOLD}${BLUE}DEFAULTS${RESET}
  Wrapper always passes ${YELLOW}--all${RESET} to rawcooked (NMAAHC preservation defaults:
  check, conch, hash, coherency, framemd5, accept-gaps). Disable any of those
  by appending the negating flag after ${CYAN}--${RESET}, e.g. ${YELLOW}-- --no-conch${RESET}.

${BOLD}${BLUE}LOGGING${RESET}
  A sibling ${YELLOW}<output>.log${RESET} is written next to the rawcooked output. It contains:
  pre-flight summary (input, output, DPX sequence analysis with first/last 10
  frames and any missing sequence numbers), the full rawcooked stdout+stderr,
  and a post-flight summary (duration, exit status, output size, output MD5).

${BOLD}${BLUE}EXAMPLES${RESET}
  ${DIM}# Encode a DPX sequence directory${RESET}
  ${GREEN}rawcooked.sh${RESET} ${CYAN}-i${RESET} /Volumes/archive/<reel>/

  ${DIM}# Decode an MKV back to DPX${RESET}
  ${GREEN}rawcooked.sh${RESET} ${CYAN}-i${RESET} /Volumes/archive/<reel>.mkv

  ${DIM}# Skip padding check for speed${RESET}
  ${GREEN}rawcooked.sh${RESET} ${CYAN}-i${RESET} /Volumes/archive/<reel>/ ${CYAN}--${RESET} --no-check-padding

  ${DIM}# See the command without running${RESET}
  ${GREEN}rawcooked.sh${RESET} ${CYAN}-i${RESET} /Volumes/archive/<reel>/ ${CYAN}-n${RESET}
EOF
}

# Compute rawcooked's default output path for a given input + mode.
_default_output() {
    local input="$1" mode="$2"
    input="${input%/}"
    case "$mode" in
        encode) printf '%s.mkv' "$input" ;;
        decode) printf '%s.RAWcooked' "$input" ;;
    esac
}

# Format a seconds count as "Xh YYm ZZs".
_fmt_duration() {
    local s="$1"
    printf '%dh %02dm %02ds' $((s/3600)) $((s%3600/60)) $((s%60))
}

# Pre-flight: scan DPX sequence, print banner to stderr, write log header.
# Globals consumed: BOLD/BLUE/CYAN/etc, _SEP.
# Args: mode input output log
_preflight() {
    local mode="$1" input="$2" output="$3" log="$4"

    # DPX sequence analysis (encode mode only)
    local -a files=()
    local count=0 first_name="" last_name="" first_num="" last_num="" missing_count=0
    local -a missing=()

    if [[ "$mode" == "encode" && -d "$input" ]]; then
        mapfile -t files < <(find "$input" -maxdepth 1 -type f \( -iname '*.dpx' \) -print 2>/dev/null | sort)
        count=${#files[@]}
        if (( count > 0 )); then
            first_name="${files[0]##*/}"
            last_name="${files[-1]##*/}"
            first_num=$(sed -nE 's/.*[^0-9]([0-9]+)\.[dD][pP][xX]$/\1/p' <<< "$first_name")
            last_num=$(sed -nE 's/.*[^0-9]([0-9]+)\.[dD][pP][xX]$/\1/p' <<< "$last_name")
            if [[ -n "$first_num" && -n "$last_num" ]]; then
                local expected=$((10#$last_num - 10#$first_num + 1))
                missing_count=$((expected - count))
                if (( missing_count > 0 )); then
                    local pad=${#first_num}
                    local existing
                    existing=$(printf '%s\n' "${files[@]##*/}" \
                        | sed -nE 's/.*[^0-9]([0-9]+)\.[dD][pP][xX]$/\1/p' | sort -u)
                    local i seq
                    for ((i=10#$first_num; i<=10#$last_num; i++)); do
                        printf -v seq "%0${pad}d" "$i"
                        grep -qE "^${seq}$" <<< "$existing" || missing+=("$seq")
                    done
                fi
            fi
        fi
    fi

    local mode_upper="${mode^^}"

    # Terminal banner (stderr)
    {
        echo ""
        printf '%s%s%s\n' "${BOLD}${BLUE}" "$_SEP" "${RESET}"
        printf '  %sRAWcooked %s%s\n' "${BOLD}" "$mode_upper" "${RESET}"
        printf '%s%s%s\n' "${BOLD}${BLUE}" "$_SEP" "${RESET}"
        printf '  %sInput:%s   %s%s%s\n' "${CYAN}" "${RESET}" "${YELLOW}" "$input" "${RESET}"
        printf '  %sOutput:%s  %s%s%s\n' "${CYAN}" "${RESET}" "${YELLOW}" "$output" "${RESET}"
        printf '  %sLog:%s     %s%s%s\n' "${CYAN}" "${RESET}" "${DIM}" "$log" "${RESET}"
        if [[ "$mode" == "encode" ]]; then
            echo ""
            printf '  %sDPX sequence:%s\n' "${CYAN}" "${RESET}"
            if (( count == 0 )); then
                printf '    %s(no .dpx files found at top level — rawcooked will probe further)%s\n' "${YELLOW}" "${RESET}"
            else
                printf '    Found:    %s frames\n' "$count"
                printf '    First:    %s\n' "$first_name"
                printf '    Last:     %s\n' "$last_name"
                if [[ -n "$first_num" ]]; then
                    if (( missing_count == 0 )); then
                        printf '    Range:    %s → %s  %s(no gaps)%s\n' "$first_num" "$last_num" "${GREEN}" "${RESET}"
                    else
                        printf '    Range:    %s → %s  %s(%s missing — listed in log)%s\n' \
                            "$first_num" "$last_num" "${YELLOW}" "$missing_count" "${RESET}"
                    fi
                fi
            fi
        fi
        echo ""
        printf '  %sDefaults:%s --all (check, conch, hash, coherency, framemd5, accept-gaps)\n' "${CYAN}" "${RESET}"
        printf '%s%s%s\n' "${BOLD}${BLUE}" "$_SEP" "${RESET}"
        echo ""
        printf '  %s↓ rawcooked output below ↓%s\n' "${DIM}" "${RESET}"
        echo ""
    } >&2

    # Log header (plain text)
    {
        echo "RAWcooked $mode_upper Log"
        printf '=%.0s' {1..63}; echo
        echo "Started:   $(date '+%Y-%m-%d %H:%M:%S')"
        echo "Input:     $input"
        echo "Output:    $output"
        echo "Mode:      $mode"
        echo ""
        if [[ "$mode" == "encode" ]]; then
            echo "DPX Sequence"
            echo "------------"
            if (( count == 0 )); then
                echo "No .dpx files found at the top level of the input directory."
                echo "(RAWcooked may still probe subdirs.)"
            else
                echo "Found:     $count frames"
                echo "First:     $first_name"
                echo "Last:      $last_name"
                if [[ -n "$first_num" ]]; then
                    echo "Range:     $first_num → $last_num"
                    if (( missing_count == 0 )); then
                        echo "Gaps:      none detected"
                    else
                        echo "Gaps:      $missing_count missing"
                    fi
                fi
                echo ""
                echo "First 10 frames:"
                local f
                for f in "${files[@]:0:10}"; do printf '  %s\n' "${f##*/}"; done
                if (( count > 10 )); then
                    echo ""
                    echo "Last 10 frames:"
                    local start=$((count - 10))
                    for f in "${files[@]:$start}"; do printf '  %s\n' "${f##*/}"; done
                fi
                if (( missing_count > 0 )); then
                    echo ""
                    echo "Missing frames ($missing_count):"
                    local m
                    for m in "${missing[@]}"; do printf '  %s\n' "$m"; done
                fi
            fi
            echo ""
        fi
        echo "RAWcooked Output"
        echo "----------------"
    } > "$log"
}

# Post-flight: print summary banner to stderr, append log footer.
# Args: status duration_seconds output log
_postflight() {
    local status="$1" duration="$2" output="$3" log="$4"

    local size="" md5="" status_color status_word
    if [[ -e "$output" ]]; then
        size=$(du -sh "$output" 2>/dev/null | cut -f1)
    fi
    # rawcooked prints "Info: Output file MD5 is XXX." — grab it from the log if present
    md5=$(grep -oE 'Output file MD5 is [a-f0-9]+' "$log" 2>/dev/null | awk '{print $NF}' | head -1)

    local dur_str
    dur_str=$(_fmt_duration "$duration")

    if (( status == 0 )); then
        status_color="${GREEN}"; status_word="success"
    else
        status_color="${RED}";   status_word="FAILED (exit $status)"
    fi

    # Terminal banner
    {
        echo ""
        printf '%s%s%s\n' "${BOLD}${BLUE}" "$_SEP" "${RESET}"
        printf '  %sSummary%s   %s%s%s\n' "${BOLD}" "${RESET}" "${status_color}" "$status_word" "${RESET}"
        printf '%s%s%s\n' "${BOLD}${BLUE}" "$_SEP" "${RESET}"
        printf '  %sDuration:%s %s\n' "${CYAN}" "${RESET}" "$dur_str"
        [[ -n "$size" ]] && printf '  %sSize:%s     %s\n' "${CYAN}" "${RESET}" "$size"
        [[ -n "$md5" ]]  && printf '  %sMD5:%s      %s\n' "${CYAN}" "${RESET}" "$md5"
        printf '  %sOutput:%s   %s\n' "${CYAN}" "${RESET}" "$output"
        printf '  %sLog:%s      %s\n' "${CYAN}" "${RESET}" "$log"
        printf '%s%s%s\n' "${BOLD}${BLUE}" "$_SEP" "${RESET}"
        echo ""
    } >&2

    # Log footer
    {
        echo ""
        echo "Summary"
        echo "-------"
        echo "Finished:  $(date '+%Y-%m-%d %H:%M:%S')"
        echo "Duration:  $dur_str"
        echo "Exit:      $status ($status_word)"
        echo "Output:    $output"
        [[ -n "$size" ]] && echo "Size:      $size"
        [[ -n "$md5" ]]  && echo "MD5:       $md5"
    } >> "$log"
}

main() {
    if [[ $# -eq 0 ]]; then _usage; exit 0; fi
    local input="" output="" dry=0 force=0
    local extras=()

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -i) input="${2:-}"; shift 2 ;;
            -o) output="${2:-}"; shift 2 ;;
            -n|--dry-run) dry=1; shift ;;
            --force) force=1; shift ;;
            -h|--help) _help; exit 0 ;;
            --) shift; extras=("$@"); break ;;
            *) tbm_error "Unknown arg: $1"; _usage >&2; exit 2 ;;
        esac
    done

    [[ -n "$input" ]] || { tbm_error "-i INPUT required"; _usage >&2; exit 2; }

    local mode
    if [[ -d "$input" ]]; then
        mode="encode"
    elif [[ -f "$input" && "${input,,}" == *.mkv ]]; then
        mode="decode"
    else
        tbm_error "input must be a directory (encode) or .mkv file (decode): $input"
        exit 2
    fi

    [[ -n "$output" ]] || output=$(_default_output "$input" "$mode")
    local log="${output}.log"

    local cmd=(rawcooked --all)
    (( force )) && cmd+=(-y)
    cmd+=(-o "$output" "$input")
    if (( ${#extras[@]} > 0 )); then
        cmd+=("${extras[@]}")
    fi

    if (( dry )); then
        local quoted="" arg
        for arg in "${cmd[@]}"; do
            quoted+=" $(printf '%q' "$arg")"
        done
        tbm_info "[dry-run]${quoted}"
        tbm_info "[dry-run] would write log: $log"
        return 0
    fi

    tbm_require rawcooked

    _preflight "$mode" "$input" "$output" "$log"

    local start_t end_t status
    start_t=$(date +%s)
    # Run rawcooked; tee combined output to terminal AND the log.
    # `|| true` keeps pipefail from killing us before we capture status.
    { "${cmd[@]}" 2>&1; } | tee -a "$log" || true
    status=${PIPESTATUS[0]}
    end_t=$(date +%s)

    _postflight "$status" "$((end_t - start_t))" "$output" "$log"

    return "$status"
}

main "$@"
