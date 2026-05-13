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
_DSEP='───────────────────────────────────────────────────────────────'

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
  ${CYAN}--fps${RESET} ${YELLOW}N${RESET}            Frame rate to pass to rawcooked. Any ffmpeg value works
                     (${YELLOW}24${RESET}, ${YELLOW}23.976${RESET}, ${YELLOW}18${RESET}, ${YELLOW}16${RESET}, ${YELLOW}12${RESET}, ${YELLOW}8${RESET}, etc.). Required if the
                     DPX header has no frame-rate metadata; overrides the
                     header if present.
  ${CYAN}-n${RESET}, ${CYAN}--dry-run${RESET}      Print the rawcooked command, don't run it
  ${CYAN}--force${RESET}            Pass ${YELLOW}-y${RESET} to rawcooked — overwrite existing outputs
  ${CYAN}--${RESET} ${YELLOW}EXTRA...${RESET}        Anything after ${CYAN}--${RESET} is passed to rawcooked verbatim
                     (e.g. ${YELLOW}--no-check-padding${RESET})
  ${CYAN}-h${RESET}, ${CYAN}--help${RESET}         Show this help

${BOLD}${BLUE}MODES${RESET}
  ${YELLOW}encode${RESET}  ${CYAN}-i${RESET} is a directory → DPX sequence becomes one FFV1/Matroska ${YELLOW}.mkv${RESET}
  ${YELLOW}decode${RESET}  ${CYAN}-i${RESET} is a ${YELLOW}.mkv${RESET} → restore the original DPX sequence

${BOLD}${BLUE}DEFAULTS${RESET}
  Wrapper always passes ${YELLOW}--all${RESET} to rawcooked (NMAAHC preservation defaults:
  check, conch, hash, coherency, framemd5, accept-gaps). Disable any of those
  by appending the negating flag after ${CYAN}--${RESET}, e.g. ${YELLOW}-- --no-conch${RESET}.

${BOLD}${BLUE}LOGGING${RESET}
  A sibling ${YELLOW}<output>.log${RESET} is written next to the rawcooked output. It contains:
  pre-flight summary (input, output, DPX sequence analysis with first/last 10
  frames and any missing sequence numbers), the full rawcooked stdout+stderr,
  a Technical Summary (encode only — plain-English breakdown of what was encoded),
  an ffmpeg pipeline section (encode only), and a post-flight summary
  (Started/Finished in ET, duration, exit status, output size, output MD5).
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

# Eastern Time clock string "HH:MM:SS ET".
_now_et() {
    TZ=America/New_York date +'%H:%M:%S ET'
}

# Convert a KiB count to a human-readable IEC unit (e.g. "16.0 GiB").
_human_kib() {
    awk -v kib="$1" 'BEGIN {
        if (kib == "") exit;
        u[1]="KiB"; u[2]="MiB"; u[3]="GiB"; u[4]="TiB";
        i=1; v=kib;
        while (v >= 1024 && i < 4) { v /= 1024; i++; }
        printf "%.1f %s", v, u[i];
    }'
}

# Probe the first DPX file with mediainfo to determine whether its FrameRate
# field is populated. Echoes a short provenance string.
_probe_framerate_source() {
    local input="$1"
    local first_dpx
    first_dpx=$(find "$input" -maxdepth 1 -type f -iname '*.dpx' -print 2>/dev/null | sort | head -1)
    if [[ -z "$first_dpx" ]]; then echo "unknown (no DPX files found)"; return; fi
    if ! command -v mediainfo >/dev/null 2>&1; then echo "unknown (mediainfo not available)"; return; fi
    local fr
    fr=$(mediainfo --Inform='Image;%FrameRate%' "$first_dpx" 2>/dev/null | tr -d '[:space:]')
    if [[ -n "$fr" && "$fr" != "0" && "$fr" != "0.000" ]]; then
        echo "from DPX header"
    else
        echo "default — no header metadata"
    fi
}

# Derive a (prefix, width, ext) DPX naming pattern from a single filename.
# Returns 0 and sets DPX_PATTERN_{PREFIX,WIDTH,EXT} globals on success;
# returns 1 if the name doesn't fit the "<prefix><digits>.dpx" shape.
# Uses globals instead of stdout because the prefix can be empty and a
# tab-separated read with leading empty field is awkward in bash.
_derive_dpx_pattern() {
    local name="$1"
    local lower="${name,,}"
    [[ "$lower" == *.dpx ]] || return 1
    local base="${name%.*}" ext="${name##*.}"
    local digits="" i=${#base} c
    while (( i > 0 )); do
        c="${base:i-1:1}"
        case "$c" in
            [0-9]) digits="$c$digits"; i=$((i - 1)) ;;
            *) break ;;
        esac
    done
    [[ -n "$digits" ]] || return 1
    DPX_PATTERN_PREFIX="${base:0:$i}"
    DPX_PATTERN_WIDTH="${#digits}"
    DPX_PATTERN_EXT="$ext"
}

# True if a filename matches the (prefix, width) DPX pattern. Extension is
# checked case-insensitively against .dpx; prefix must match exactly.
_check_dpx_name() {
    local name="$1" prefix="$2" width="$3"
    local lower="${name,,}"
    [[ "$lower" == *.dpx ]] || return 1
    local base="${name%.*}"
    [[ "${base:0:${#prefix}}" == "$prefix" ]] || return 1
    local seq="${base:${#prefix}}"
    (( ${#seq} == width )) || return 1
    [[ "$seq" =~ ^[0-9]+$ ]]
}

# Decode rawcooked's source-format shorthand (e.g. "DPX/Raw/RGB/10bit/U/BE/FilledA")
# into a plain-English, comma-separated description.
_decode_format() {
    local raw="$1"
    [[ -z "$raw" ]] && return
    local IFS='/'
    # shellcheck disable=SC2206
    local -a tokens=($raw)
    local -a parts=()
    local tok
    for tok in "${tokens[@]}"; do
        case "$tok" in
            DPX)     parts+=("DPX file") ;;
            TIFF)    parts+=("TIFF file") ;;
            EXR)     parts+=("OpenEXR file") ;;
            Raw)     parts+=("uncompressed") ;;
            RLE)     parts+=("run-length encoded") ;;
            RGB)     parts+=("RGB color") ;;
            RGBA)    parts+=("RGBA color (with alpha)") ;;
            Y)       parts+=("Y luminance only") ;;
            YUV)     parts+=("YUV color") ;;
            8bit)    parts+=("8 bits per component") ;;
            10bit)   parts+=("10 bits per component") ;;
            12bit)   parts+=("12 bits per component") ;;
            16bit)   parts+=("16 bits per component") ;;
            U)       parts+=("unsigned values") ;;
            S)       parts+=("signed values") ;;
            BE)      parts+=("big-endian byte order") ;;
            LE)      parts+=("little-endian byte order") ;;
            FilledA) parts+=("Method-A packing (padding at LSB)") ;;
            FilledB) parts+=("Method-B packing (padding at MSB)") ;;
            Packed)  parts+=("packed (no padding)") ;;
            *)       parts+=("$tok") ;;
        esac
    done
    local out="" first=1 p
    for p in "${parts[@]}"; do
        if (( first )); then out="$p"; first=0; else out+=", $p"; fi
    done
    printf '%s' "$out"
}

# Pre-flight: scan DPX sequence, print banner to stderr, write log header.
# Args: mode input output log
_preflight() {
    local mode="$1" input="$2" output="$3" log="$4"

    local -a files=()
    local count=0 first_name="" last_name="" first_num="" last_num="" missing_count=0
    local -a missing=() mismatches=()
    local pattern_prefix="" pattern_width="" pattern_ext="" pattern_display=""
    local pattern_error=""

    if [[ "$mode" == "encode" && -d "$input" ]]; then
        mapfile -t files < <(find "$input" -maxdepth 1 -type f \( -iname '*.dpx' \) -print 2>/dev/null | sort)
        count=${#files[@]}
        if (( count > 0 )); then
            first_name="${files[0]##*/}"
            last_name="${files[-1]##*/}"

            # Derive the naming pattern from the first DPX in the stack.
            if ! _derive_dpx_pattern "$first_name"; then
                pattern_error="first file does not match the <prefix><digits>.dpx shape"
            else
                pattern_prefix="$DPX_PATTERN_PREFIX"
                pattern_width="$DPX_PATTERN_WIDTH"
                pattern_ext="$DPX_PATTERN_EXT"
                local _N
                printf -v _N '%*s' "$pattern_width" ''
                _N="${_N// /N}"
                pattern_display="${pattern_prefix}${_N}.${pattern_ext}"

                # Validate every file against the derived pattern; collect sequence numbers.
                local -a seq_numbers=()
                local f fname seq
                for f in "${files[@]}"; do
                    fname="${f##*/}"
                    if _check_dpx_name "$fname" "$pattern_prefix" "$pattern_width"; then
                        local _b="${fname%.*}"
                        seq_numbers+=("${_b:${#pattern_prefix}}")
                    else
                        mismatches+=("$fname")
                    fi
                done

                # Range + gap detection over the sequence numbers (already file-sorted).
                if (( ${#seq_numbers[@]} > 0 )); then
                    first_num="${seq_numbers[0]}"
                    last_num="${seq_numbers[-1]}"
                    # Re-derive first/last names from the pattern + matching seq numbers
                    # so a stray mismatch file at the alphabetic edge doesn't masquerade
                    # as the sequence's first or last frame.
                    first_name="${pattern_prefix}${first_num}.${pattern_ext}"
                    last_name="${pattern_prefix}${last_num}.${pattern_ext}"
                    local expected=$((10#$last_num - 10#$first_num + 1))
                    missing_count=$((expected - ${#seq_numbers[@]}))
                    if (( missing_count > 0 )); then
                        local seq_list
                        seq_list=$(printf '%s\n' "${seq_numbers[@]}")
                        local i
                        for ((i=10#$first_num; i<=10#$last_num; i++)); do
                            printf -v seq "%0${pattern_width}d" "$i"
                            grep -qFx "$seq" <<< "$seq_list" || missing+=("$seq")
                        done
                    fi
                fi
            fi
        fi
    fi

    local mode_upper="${mode^^}"

    # Terminal banner (stderr). Bars bold/blue; header text plain.
    {
        echo ""
        printf '%s%s%s\n' "${BOLD}${BLUE}" "$_SEP" "${RESET}"
        printf '  RAWcooked %s\n' "$mode_upper"
        printf '%s%s%s\n' "${BOLD}${BLUE}" "$_SEP" "${RESET}"
        printf '  %sInput:%s   %s%s%s\n' "${CYAN}" "${RESET}" "${YELLOW}" "$input" "${RESET}"
        printf '  %sOutput:%s  %s%s%s\n' "${CYAN}" "${RESET}" "${YELLOW}" "$output" "${RESET}"
        printf '  %sLog:%s     %s%s%s\n' "${CYAN}" "${RESET}" "${DIM}" "$log" "${RESET}"
        if [[ "$mode" == "encode" ]]; then
            echo ""
            printf '  %sDPX sequence:%s\n' "${CYAN}" "${RESET}"
            if (( count == 0 )); then
                printf '    %s(no .dpx files found at top level — rawcooked will probe further)%s\n' "${YELLOW}" "${RESET}"
            elif [[ -n "$pattern_error" ]]; then
                printf '    %sERROR:%s    %s\n' "${RED}" "${RESET}" "$pattern_error"
                printf '    First:    %s\n' "$first_name"
            else
                printf '    Pattern:  %s (%s-digit sequence)\n' "$pattern_display" "$pattern_width"
                if (( ${#mismatches[@]} == 0 )); then
                    printf '    Found:    %s frames\n' "$count"
                else
                    printf '    Found:    %s .dpx total (%s%s match pattern%s, %s%s do not%s)\n' \
                        "$count" "${GREEN}" "$((count - ${#mismatches[@]}))" "${RESET}" \
                        "${RED}" "${#mismatches[@]}" "${RESET}"
                fi
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
                if (( ${#mismatches[@]} > 0 )); then
                    printf '    %sMismatches:%s  %s%s files do not match pattern%s\n' \
                        "${RED}" "${RESET}" "${RED}" "${#mismatches[@]}" "${RESET}"
                    local _mm_show=$(( ${#mismatches[@]} < 5 ? ${#mismatches[@]} : 5 ))
                    local _mm_i
                    for ((_mm_i=0; _mm_i<_mm_show; _mm_i++)); do
                        printf '      %s%s%s\n' "${RED}" "${mismatches[_mm_i]}" "${RESET}"
                    done
                    if (( ${#mismatches[@]} > 5 )); then
                        printf '      %s… (%s more — full list in log)%s\n' "${DIM}" $((${#mismatches[@]} - 5)) "${RESET}"
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
        echo "Started:   $(date '+%Y-%m-%d %H:%M:%S') ($(_now_et))"
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
            elif [[ -n "$pattern_error" ]]; then
                echo "ERROR:     $pattern_error"
                echo "First:     $first_name"
            else
                echo "Pattern:   $pattern_display ($pattern_width-digit sequence)"
                echo "Found:     $count frames total ($((count - ${#mismatches[@]})) match pattern, ${#mismatches[@]} mismatched)"
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
                if (( ${#mismatches[@]} > 0 )); then
                    echo ""
                    echo "Naming mismatches (${#mismatches[@]}):"
                    local mm
                    for mm in "${mismatches[@]}"; do printf '  %s\n' "$mm"; done
                fi
            fi
            echo ""
        fi
        echo "RAWcooked Output"
        echo "----------------"
    } > "$log"

    # If naming inconsistencies were found in encode mode, signal abort.
    if [[ "$mode" == "encode" ]]; then
        if [[ -n "$pattern_error" ]] || (( ${#mismatches[@]} > 0 )); then
            return 3
        fi
    fi
    return 0
}

# Technical Summary (encode only) — parses captured output, emits plain-English
# breakdown to stderr and appends to log.
# Args: log framerate_source total_wall_seconds
_tech_summary() {
    local log="$1" framerate_source="$2" total_wall="${3:-0}"

    # All grep|sed|awk pipelines below tolerate no-match without aborting set -e.
    local raw_format pretty_format
    raw_format=$( (grep -m1 -E '^[[:space:]]*(DPX|TIFF|EXR)/' "$log" 2>/dev/null || true) \
        | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    pretty_format=$(_decode_format "$raw_format")

    local input_stream resolution fps
    input_stream=$(grep -m1 -E 'Stream #0:0:.*Video:.*dpx' "$log" 2>/dev/null || true)
    resolution=$(grep -oE '[0-9]+x[0-9]+' <<< "$input_stream" | head -1 | sed 's/x/ × /' || true)
    fps=$(grep -oE '[0-9.]+ fps' <<< "$input_stream" | head -1 | awk '{print $1}' || true)

    local progress_line frame_count lsize_kib bitrate_kbps
    progress_line=$( (grep -E '^frame=' "$log" 2>/dev/null || true) | tail -1)
    frame_count=$(sed -nE 's/^frame=[[:space:]]*([0-9]+).*/\1/p' <<< "$progress_line" || true)
    lsize_kib=$(sed -nE 's/.*Lsize=[[:space:]]*([0-9]+)KiB.*/\1/p' <<< "$progress_line" || true)
    bitrate_kbps=$(sed -nE 's/.*bitrate=[[:space:]]*([0-9.]+)kbits\/s.*/\1/p' <<< "$progress_line" || true)

    local output_size bitrate_mbps
    output_size=$(_human_kib "$lsize_kib")
    bitrate_mbps=$(awk -v k="$bitrate_kbps" 'BEGIN { if (k != "") printf "%.0f", k/1000 }')

    local duration_str content_pretty
    duration_str=$( (grep -m1 -E 'Duration: *[0-9]+:[0-9]+:[0-9.]+' "$log" 2>/dev/null || true) \
        | sed -nE 's/.*Duration: *([0-9]+:[0-9]+:[0-9.]+).*/\1/p' | head -1)
    if [[ "$duration_str" =~ ^([0-9]+):([0-9]+):([0-9.]+)$ ]]; then
        local h=$((10#${BASH_REMATCH[1]})) m=$((10#${BASH_REMATCH[2]})) s="${BASH_REMATCH[3]}"
        # Strip leading zero on seconds for readability ("06.04" -> "6.04").
        s="${s#0}"
        [[ "$s" == .* ]] && s="0$s"
        if (( h > 0 )); then
            content_pretty="${h}h ${m}m ${s}s"
        elif (( m > 0 )); then
            content_pretty="${m}m ${s}s"
        else
            content_pretty="${s}s"
        fi
    else
        content_pretty="$duration_str"
    fi

    # Encode speed (ffmpeg pass): from the final "frame=... speed=N.Nx ..." line.
    local encode_speed
    encode_speed=$(grep -oE 'speed=[[:space:]]*[0-9.]+x' <<< "$progress_line" | grep -oE '[0-9.]+x' || true)

    # rawcooked's Time= progress and final overall-throughput lines are emitted with \r
    # (carriage return) to update in place. In the log they end up concatenated onto a
    # single \n-terminated line, which defeats line-based grep filters. Normalize \r to
    # \n so each update is its own searchable line before parsing the check/overall fields.
    local log_lines
    log_lines=$(tr '\r' '\n' < "$log" 2>/dev/null || true)

    # Check speed (reversibility pass): the check phase slows progressively, so report
    # both endpoints + the true average. Parse first and last Time= lines for the
    # instantaneous speeds; compute average as content_duration / check_wall_time.
    local first_check_line="" last_check_line="" check_first="" check_last="" check_avg=""
    first_check_line=$(grep -E '^Time=.*realtime' <<< "$log_lines" | head -1 || true)
    last_check_line=$(grep -E '^Time=.*realtime'  <<< "$log_lines" | tail -1 || true)
    check_first=$(grep -oE '[0-9.]+x realtime' <<< "$first_check_line" | head -1 | awk '{print $1}' || true)
    check_last=$(grep -oE '[0-9.]+x realtime'  <<< "$last_check_line"  | head -1 | awk '{print $1}' || true)

    # Average check speed = content seconds / check wall seconds.
    # encode_wall comes from the final ffmpeg "elapsed=H:MM:SS[.ff]" field.
    # check_wall = total_wall - encode_wall.
    local content_seconds=0 encode_wall=0 check_wall=0
    if [[ "$duration_str" =~ ^([0-9]+):([0-9]+):([0-9]+) ]]; then
        content_seconds=$((10#${BASH_REMATCH[1]} * 3600 + 10#${BASH_REMATCH[2]} * 60 + 10#${BASH_REMATCH[3]}))
    fi
    local elapsed_str
    elapsed_str=$(grep -oE 'elapsed=[0-9]+:[0-9]+:[0-9]+' <<< "$progress_line" | head -1 | sed 's/elapsed=//')
    if [[ "$elapsed_str" =~ ^([0-9]+):([0-9]+):([0-9]+)$ ]]; then
        encode_wall=$((10#${BASH_REMATCH[1]} * 3600 + 10#${BASH_REMATCH[2]} * 60 + 10#${BASH_REMATCH[3]}))
    fi
    if (( total_wall > 0 && encode_wall > 0 )); then
        check_wall=$((total_wall - encode_wall))
    fi
    if (( check_wall > 0 && content_seconds > 0 )); then
        check_avg=$(awk -v c="$content_seconds" -v w="$check_wall" 'BEGIN { printf "%.2f", c/w }')
    fi

    # Overall throughput: rawcooked's final "N.N MiB/s, N.NNx realtime" line (not the Time= ones).
    local overall_line overall_throughput overall_speed
    overall_line=$(grep -E 'realtime' <<< "$log_lines" | grep -v '^Time=' | tail -1 || true)
    overall_throughput=$(grep -oE '[0-9.]+ MiB/s' <<< "$overall_line" | head -1 || true)
    overall_speed=$(grep -oE '[0-9.]+x realtime' <<< "$overall_line" | head -1 || true)

    local rev_color rev_plain hashes_color hashes_plain
    if grep -q 'Reversibility was checked, no issue detected' "$log" 2>/dev/null; then
        rev_color="${GREEN}✓ checked, no issues detected${RESET}"
        rev_plain="checked, no issues detected"
    elif grep -qE 'Reversibility.*issue.*detected' "$log" 2>/dev/null; then
        rev_color="${RED}✗ ISSUES DETECTED — see log${RESET}"
        rev_plain="ISSUES DETECTED — see log"
    else
        rev_color="${YELLOW}not verified${RESET}"
        rev_plain="not verified"
    fi
    if grep -q 'Uncompressed file hashes.*present' "$log" 2>/dev/null; then
        hashes_color="${GREEN}✓ uncompressed source hashes embedded${RESET}"
        hashes_plain="uncompressed source hashes embedded"
    else
        hashes_color="${YELLOW}not embedded${RESET}"
        hashes_plain="not embedded"
    fi

    local md5 rc_ver
    md5=$( (grep -oE 'Output file MD5 is [a-f0-9]+' "$log" 2>/dev/null || true) | awk '{print $NF}' | head -1)
    # Match the version number specifically, not the trailing period after it.
    rc_ver=$( (grep -m1 -oE 'created by RAWcooked [0-9]+(\.[0-9]+)*' "$log" 2>/dev/null || true) | awk '{print $NF}')

    local fc_pretty="$frame_count"
    if [[ -n "$frame_count" ]]; then
        fc_pretty=$(LC_ALL=en_US.UTF-8 printf "%'d" "$frame_count" 2>/dev/null || echo "$frame_count")
    fi

    # Terminal
    {
        echo ""
        printf '%s%s%s\n' "${BLUE}" "$_DSEP" "${RESET}"
        printf '  Technical Summary      %s(Check speed = Reversibility check)%s\n' "${DIM}" "${RESET}"
        printf '%s%s%s\n' "${BLUE}" "$_DSEP" "${RESET}"
        [[ -n "$pretty_format" ]] && printf '  %sSource format:%s    %s\n' "${CYAN}" "${RESET}" "$pretty_format"
                                     printf '  %sOutput codec:%s     FFV1 in Matroska\n' "${CYAN}" "${RESET}"
        [[ -n "$resolution" ]]    && printf '  %sResolution:%s       %s\n' "${CYAN}" "${RESET}" "$resolution"
        [[ -n "$fps" ]]           && printf '  %sFrame rate:%s       %s fps (%s)\n' "${CYAN}" "${RESET}" "$fps" "$framerate_source"
        [[ -n "$frame_count" ]]   && printf '  %sFrame count:%s      %s\n' "${CYAN}" "${RESET}" "$fc_pretty"
        [[ -n "$content_pretty" && -n "$fps" && -n "$frame_count" ]] \
            && printf '  %sContent length:%s   %s (%s frames @ %s fps)\n' "${CYAN}" "${RESET}" "$content_pretty" "$fc_pretty" "$fps"
        [[ -n "$output_size" ]]   && printf '  %sOutput size:%s      %s\n' "${CYAN}" "${RESET}" "$output_size"
        [[ -n "$bitrate_mbps" ]]  && printf '  %sOutput bitrate:%s   ~%s Mbps\n' "${CYAN}" "${RESET}" "$bitrate_mbps"
        [[ -n "$encode_speed" ]] && printf '  %sEncode speed:%s     %s realtime (ffmpeg pass)\n' "${CYAN}" "${RESET}" "$encode_speed"
        if [[ -n "$check_first" && -n "$check_last" && "$check_first" != "$check_last" ]]; then
            if [[ -n "$check_avg" ]]; then
                printf '  %sCheck speed:%s      %s → %s realtime (avg ~%sx)\n' "${CYAN}" "${RESET}" "$check_first" "$check_last" "$check_avg"
            else
                printf '  %sCheck speed:%s      %s → %s realtime (start → end)\n' "${CYAN}" "${RESET}" "$check_first" "$check_last"
            fi
        elif [[ -n "$check_last" ]]; then
            printf '  %sCheck speed:%s      %s realtime\n' "${CYAN}" "${RESET}" "$check_last"
        fi
        if [[ -n "$overall_speed" && -n "$overall_throughput" ]]; then
            printf '  %sOverall:%s          %s (%s)\n' "${CYAN}" "${RESET}" "$overall_speed" "$overall_throughput"
        elif [[ -n "$overall_speed" ]]; then
            printf '  %sOverall:%s          %s\n' "${CYAN}" "${RESET}" "$overall_speed"
        fi
        printf '  %sReversibility:%s    %s\n' "${CYAN}" "${RESET}" "$rev_color"
        printf '  %sFile hashes:%s      %s\n' "${CYAN}" "${RESET}" "$hashes_color"
        [[ -n "$md5" ]]    && printf '  %sOutput MD5:%s       %s\n' "${CYAN}" "${RESET}" "$md5"
        [[ -n "$rc_ver" ]] && printf '  %sRAWcooked ver.:%s   %s\n' "${CYAN}" "${RESET}" "$rc_ver"
        printf '%s%s%s\n' "${BLUE}" "$_DSEP" "${RESET}"
    } >&2

    # Log (plain)
    {
        echo ""
        echo "Technical Summary      (Check speed = Reversibility check)"
        echo "-----------------"
        [[ -n "$pretty_format" ]] && echo "Source format:    $pretty_format"
                                     echo "Output codec:     FFV1 in Matroska"
        [[ -n "$resolution" ]]    && echo "Resolution:       $resolution"
        [[ -n "$fps" ]]           && echo "Frame rate:       $fps fps ($framerate_source)"
        [[ -n "$frame_count" ]]   && echo "Frame count:      $fc_pretty"
        [[ -n "$content_pretty" && -n "$fps" && -n "$frame_count" ]] \
            && echo "Content length:   $content_pretty ($fc_pretty frames @ $fps fps)"
        [[ -n "$output_size" ]]   && echo "Output size:      $output_size"
        [[ -n "$bitrate_mbps" ]]  && echo "Output bitrate:   ~$bitrate_mbps Mbps"
        [[ -n "$encode_speed" ]] && echo "Encode speed:     $encode_speed realtime (ffmpeg pass)"
        if [[ -n "$check_first" && -n "$check_last" && "$check_first" != "$check_last" ]]; then
            if [[ -n "$check_avg" ]]; then
                echo "Check speed:      $check_first → $check_last realtime (avg ~${check_avg}x)"
            else
                echo "Check speed:      $check_first → $check_last realtime (start → end)"
            fi
        elif [[ -n "$check_last" ]]; then
            echo "Check speed:      $check_last realtime"
        fi
        if [[ -n "$overall_speed" && -n "$overall_throughput" ]]; then
            echo "Overall:          $overall_speed ($overall_throughput)"
        elif [[ -n "$overall_speed" ]]; then
            echo "Overall:          $overall_speed"
        fi
        echo "Reversibility:    $rev_plain"
        echo "File hashes:      $hashes_plain"
        [[ -n "$md5" ]]    && echo "Output MD5:       $md5"
        [[ -n "$rc_ver" ]] && echo "RAWcooked ver.:   $rc_ver"
    } >> "$log"
}

# ffmpeg pipeline section (encode only) — plain-English summary of what ffmpeg did.
# Args: log
_ffmpeg_summary() {
    local log="$1"
    local ffmpeg_ver libavcodec libavformat
    ffmpeg_ver=$( (grep -m1 'ffmpeg version' "$log" 2>/dev/null || true) | awk '{print $3}')
    # Lib version lines look like "  libavcodec     62. 11.100 / 62. 11.100" — join $2 and $3.
    libavcodec=$( (grep -m1 '^[[:space:]]*libavcodec' "$log" 2>/dev/null || true) | awk '{print $2$3}')
    libavformat=$( (grep -m1 '^[[:space:]]*libavformat' "$log" 2>/dev/null || true) | awk '{print $2$3}')

    local streams_desc
    if grep -q 'Attachment:' "$log" 2>/dev/null; then
        streams_desc="1 video (FFV1) + 1 attachment (reversibility data)"
    else
        streams_desc="1 video (FFV1)"
    fi

    local output_video color_tag scan
    output_video=$(grep -m1 -E 'Stream #0:0:.*Video: ffv1' "$log" 2>/dev/null || true)
    color_tag=$(grep -oE 'bt[0-9]+' <<< "$output_video" | head -1 | tr '[:lower:]' '[:upper:]' || true)
    [[ -z "$color_tag" ]] && color_tag="unspecified"
    if grep -q 'progressive' <<< "$output_video"; then scan="progressive"; else scan="interlaced/unknown"; fi

    local muxing
    muxing=$( (grep -m1 'muxing overhead' "$log" 2>/dev/null || true) | grep -oE 'muxing overhead: [0-9.]+%' | awk '{print $NF}' || true)

    # Terminal
    {
        echo ""
        printf '%s%s%s\n' "${BLUE}" "$_DSEP" "${RESET}"
        echo "  ffmpeg pipeline"
        printf '%s%s%s\n' "${BLUE}" "$_DSEP" "${RESET}"
        if [[ -n "$ffmpeg_ver" ]]; then
            printf '  %sffmpeg version:%s   %s (libavcodec %s, libavformat %s)\n' "${CYAN}" "${RESET}" "$ffmpeg_ver" "$libavcodec" "$libavformat"
        fi
        printf '  %sPipeline:%s         DPX → FFV1 → Matroska\n' "${CYAN}" "${RESET}"
        printf '  %sStreams in .mkv:%s  %s\n' "${CYAN}" "${RESET}" "$streams_desc"
        printf '  %sColor tag:%s        %s RGB, %s\n' "${CYAN}" "${RESET}" "$color_tag" "$scan"
        [[ -n "$muxing" ]] && printf '  %sMuxing overhead:%s  %s\n' "${CYAN}" "${RESET}" "$muxing"
        printf '%s%s%s\n' "${BLUE}" "$_DSEP" "${RESET}"
    } >&2

    # Log
    {
        echo ""
        echo "ffmpeg pipeline"
        echo "---------------"
        [[ -n "$ffmpeg_ver" ]] && echo "ffmpeg version:   $ffmpeg_ver (libavcodec $libavcodec, libavformat $libavformat)"
        echo "Pipeline:         DPX → FFV1 → Matroska"
        echo "Streams in .mkv:  $streams_desc"
        echo "Color tag:        $color_tag RGB, $scan"
        [[ -n "$muxing" ]] && echo "Muxing overhead:  $muxing"
    } >> "$log"
}

# Post-flight: print summary banner to stderr, append log footer.
# Args: status duration_seconds output log mode start_et end_et
_postflight() {
    local status="$1" duration="$2" output="$3" log="$4" mode="$5" start_et="$6" end_et="$7"

    local size="" md5=""
    if [[ -e "$output" ]]; then
        # awk strips any leading whitespace some macOS `du -sh` outputs include
        # (cut -f1 alone would preserve it and misalign the Summary column).
        size=$(du -sh "$output" 2>/dev/null | awk '{print $1}')
    fi
    md5=$( (grep -oE 'Output file MD5 is [a-f0-9]+' "$log" 2>/dev/null || true) | awk '{print $NF}' | head -1)

    # Split total wall time into encode-phase and check-phase.
    # encode_wall comes from ffmpeg's final "elapsed=H:MM:SS" field in the log;
    # check_wall = total wall - encode_wall (the reversibility-check phase).
    local encode_wall_str="" check_wall_str=""
    local elapsed_field
    elapsed_field=$( (grep -oE 'elapsed=[0-9]+:[0-9]+:[0-9]+' "$log" 2>/dev/null || true) | tail -1 | sed 's/elapsed=//')
    if [[ "$elapsed_field" =~ ^([0-9]+):([0-9]+):([0-9]+)$ ]]; then
        local enc_secs=$((10#${BASH_REMATCH[1]} * 3600 + 10#${BASH_REMATCH[2]} * 60 + 10#${BASH_REMATCH[3]}))
        encode_wall_str=$(_fmt_duration "$enc_secs")
        if (( duration > enc_secs )); then
            check_wall_str=$(_fmt_duration $((duration - enc_secs)))
        fi
    fi

    local total_dur_str
    total_dur_str=$(_fmt_duration "$duration")

    local status_color status_word output_label
    if (( status == 0 )); then
        status_color="${GREEN}"; status_word="success"
    else
        status_color="${RED}";   status_word="FAILED (exit $status)"
    fi
    if [[ "$mode" == "encode" ]]; then
        output_label="Output .mkv"
    else
        output_label="Output dir"
    fi

    # Terminal banner. Bars bold/blue; "Summary" plain.
    {
        echo ""
        printf '%s%s%s\n' "${BOLD}${BLUE}" "$_SEP" "${RESET}"
        printf '  Summary   %s%s%s\n' "${status_color}" "$status_word" "${RESET}"
        printf '%s%s%s\n' "${BOLD}${BLUE}" "$_SEP" "${RESET}"
        printf '  %sStarted:%s          %s\n' "${CYAN}" "${RESET}" "$start_et"
        printf '  %sFinished:%s         %s\n' "${CYAN}" "${RESET}" "$end_et"
        if [[ "$mode" == "encode" && -n "$encode_wall_str" ]]; then
            printf '  %sEncode duration:%s  %s\n' "${CYAN}" "${RESET}" "$encode_wall_str"
            [[ -n "$check_wall_str" ]] && printf '  %sCheck duration:%s   %s\n' "${CYAN}" "${RESET}" "$check_wall_str"
        else
            printf '  %sDecode duration:%s  %s\n' "${CYAN}" "${RESET}" "$total_dur_str"
        fi
        printf '  %s%s:%s      %s\n' "${CYAN}" "$output_label" "${RESET}" "$output"
        [[ -n "$size" ]] && printf '  %sOutput size:%s      %s\n' "${CYAN}" "${RESET}" "$size"
        if [[ "$mode" == "encode" && -n "$md5" ]]; then
            printf '  %sOutput MD5:%s       %s\n' "${CYAN}" "${RESET}" "$md5"
        fi
        printf '  %sLog:%s              %s\n' "${CYAN}" "${RESET}" "$log"
        printf '%s%s%s\n' "${BOLD}${BLUE}" "$_SEP" "${RESET}"
        echo ""
    } >&2

    # Log footer (plain) — printf with field width keeps columns aligned regardless of label length.
    {
        echo ""
        echo "Summary"
        echo "-------"
        printf '%-19s %s\n' "Started:"  "$start_et"
        printf '%-19s %s\n' "Finished:" "$end_et"
        if [[ "$mode" == "encode" && -n "$encode_wall_str" ]]; then
            printf '%-19s %s\n' "Encode duration:" "$encode_wall_str"
            [[ -n "$check_wall_str" ]] && printf '%-19s %s\n' "Check duration:" "$check_wall_str"
        else
            printf '%-19s %s\n' "Decode duration:" "$total_dur_str"
        fi
        printf '%-19s %s\n' "Exit:"            "$status ($status_word)"
        printf '%-19s %s\n' "${output_label}:" "$output"
        [[ -n "$size" ]] && printf '%-19s %s\n' "Output size:" "$size"
        if [[ "$mode" == "encode" && -n "$md5" ]]; then
            printf '%-19s %s\n' "Output MD5:" "$md5"
        fi
    } >> "$log"
}

main() {
    if [[ $# -eq 0 ]]; then _usage; exit 0; fi
    local input="" output="" dry=0 force=0 fps=""
    local extras=()

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -i) input="${2:-}"; shift 2 ;;
            -o) output="${2:-}"; shift 2 ;;
            --fps) fps="${2:-}"; shift 2 ;;
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

    # Frame rate resolution (encode mode only). If --fps wasn't given, probe the first
    # DPX header. If the header lacks metadata too, refuse to proceed rather than let
    # rawcooked silently default to 24 fps — that default could be wrong for the content.
    local framerate_source=""
    if [[ "$mode" == "encode" ]]; then
        if [[ -n "$fps" ]]; then
            framerate_source="from --fps flag"
        else
            local probe
            probe=$(_probe_framerate_source "$input")
            if [[ "$probe" == "from DPX header" ]]; then
                framerate_source="from DPX header"
            else
                local _qin
                _qin=$(printf '%q' "$input")
                # fps values padded so the inline '#' comments align at the same column.
                # "--fps 23.976" is the longest (12 chars), so pad shorter ones to match.
                tbm_error "DPX headers contain no frame rate metadata.

RAWcooked would silently default to 24 fps — which could be wrong for the content.

Specify --fps explicitly. Any value ffmpeg accepts works (integer, decimal, fraction).

Common examples:
  ./tools/rawcooked.sh -i ${_qin} --fps 24      # sound film standard
  ./tools/rawcooked.sh -i ${_qin} --fps 23.976  # NTSC pulldown
  ./tools/rawcooked.sh -i ${_qin} --fps 18      # other common silent speed
  ./tools/rawcooked.sh -i ${_qin} --fps 16      # other common silent speed
  ./tools/rawcooked.sh -i ${_qin} --fps 12      # less common silent speed
  ./tools/rawcooked.sh -i ${_qin} --fps 8       # plausible"
                exit 4
            fi
        fi
    fi

    local cmd=(rawcooked --all)
    (( force )) && cmd+=(-y)
    [[ -n "$fps" ]] && cmd+=(-framerate "$fps")
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

    local preflight_status=0
    _preflight "$mode" "$input" "$output" "$log" || preflight_status=$?
    if (( preflight_status != 0 )); then
        tbm_error "Aborting: DPX naming inconsistencies detected in input dir."
        tbm_error "Every .dpx file must follow the pattern derived from the first file."
        tbm_error "See pre-flight output above (and $log) for the full list."
        return 3
    fi

    local start_t end_t status start_et end_et
    start_t=$(date +%s)
    start_et=$(_now_et)
    { "${cmd[@]}" 2>&1; } | tee -a "$log" || true
    status=${PIPESTATUS[0]}
    end_t=$(date +%s)
    end_et=$(_now_et)

    if [[ "$mode" == "encode" ]]; then
        _tech_summary "$log" "$framerate_source" "$((end_t - start_t))"
        _ffmpeg_summary "$log"
    fi

    _postflight "$status" "$((end_t - start_t))" "$output" "$log" "$mode" "$start_et" "$end_et"

    return "$status"
}

main "$@"
