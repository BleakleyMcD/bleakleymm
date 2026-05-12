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

# Technical Summary (encode only) — parses captured output, emits plain-English
# breakdown to stderr and appends to log. Args: log framerate_source
_tech_summary() {
    local log="$1" framerate_source="$2"

    local raw_format pretty_format
    raw_format=$(grep -m1 -E '^[[:space:]]*(DPX|TIFF|EXR)/' "$log" 2>/dev/null | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    pretty_format=$(_decode_format "$raw_format")

    local input_stream resolution fps
    input_stream=$(grep -m1 -E 'Stream #0:0:.*Video:.*dpx' "$log" 2>/dev/null || true)
    resolution=$(grep -oE '[0-9]+x[0-9]+' <<< "$input_stream" | head -1 | sed 's/x/ × /')
    fps=$(grep -oE '[0-9.]+ fps' <<< "$input_stream" | head -1 | awk '{print $1}')

    local progress_line frame_count lsize_kib bitrate_kbps
    progress_line=$(grep -E '^frame=' "$log" 2>/dev/null | tail -1)
    frame_count=$(sed -nE 's/^frame=[[:space:]]*([0-9]+).*/\1/p' <<< "$progress_line")
    lsize_kib=$(sed -nE 's/.*Lsize=[[:space:]]*([0-9]+)KiB.*/\1/p' <<< "$progress_line")
    bitrate_kbps=$(sed -nE 's/.*bitrate=[[:space:]]*([0-9.]+)kbits\/s.*/\1/p' <<< "$progress_line")

    local output_size bitrate_mbps
    output_size=$(_human_kib "$lsize_kib")
    bitrate_mbps=$(awk -v k="$bitrate_kbps" 'BEGIN { if (k != "") printf "%.0f", k/1000 }')

    local duration_str content_pretty
    duration_str=$(grep -m1 -E 'Duration: *[0-9]+:[0-9]+:[0-9.]+' "$log" 2>/dev/null \
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

    local realtime_line throughput speed_x
    realtime_line=$(grep -E 'realtime' "$log" 2>/dev/null | tail -1 || true)
    throughput=$(grep -oE '[0-9.]+ MiB/s' <<< "$realtime_line" | head -1)
    speed_x=$(grep -oE '[0-9.]+x realtime' <<< "$realtime_line" | head -1)

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
    md5=$(grep -oE 'Output file MD5 is [a-f0-9]+' "$log" 2>/dev/null | awk '{print $NF}' | head -1)
    # Match the version number specifically, not the trailing period after it.
    rc_ver=$(grep -m1 -oE 'created by RAWcooked [0-9]+(\.[0-9]+)*' "$log" 2>/dev/null | awk '{print $NF}')

    local fc_pretty="$frame_count"
    if [[ -n "$frame_count" ]]; then
        fc_pretty=$(LC_ALL=en_US.UTF-8 printf "%'d" "$frame_count" 2>/dev/null || echo "$frame_count")
    fi

    # Terminal
    {
        echo ""
        printf '%s%s%s\n' "${BLUE}" "$_DSEP" "${RESET}"
        echo "  Technical Summary"
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
        if [[ -n "$speed_x" && -n "$throughput" ]]; then
            printf '  %sEncode speed:%s     %s (%s)\n' "${CYAN}" "${RESET}" "$speed_x" "$throughput"
        elif [[ -n "$speed_x" ]]; then
            printf '  %sEncode speed:%s     %s\n' "${CYAN}" "${RESET}" "$speed_x"
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
        echo "Technical Summary"
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
        if [[ -n "$speed_x" && -n "$throughput" ]]; then
            echo "Encode speed:     $speed_x ($throughput)"
        elif [[ -n "$speed_x" ]]; then
            echo "Encode speed:     $speed_x"
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
    ffmpeg_ver=$(grep -m1 'ffmpeg version' "$log" 2>/dev/null | awk '{print $3}')
    # Lib version lines look like "  libavcodec     62. 11.100 / 62. 11.100" — join $2 and $3.
    libavcodec=$(grep -m1 '^[[:space:]]*libavcodec' "$log" 2>/dev/null | awk '{print $2$3}')
    libavformat=$(grep -m1 '^[[:space:]]*libavformat' "$log" 2>/dev/null | awk '{print $2$3}')

    local streams_desc
    if grep -q 'Attachment:' "$log" 2>/dev/null; then
        streams_desc="1 video (FFV1) + 1 attachment (reversibility data)"
    else
        streams_desc="1 video (FFV1)"
    fi

    local output_video color_tag scan
    output_video=$(grep -m1 -E 'Stream #0:0:.*Video: ffv1' "$log" 2>/dev/null || true)
    color_tag=$(grep -oE 'bt[0-9]+' <<< "$output_video" | head -1 | tr '[:lower:]' '[:upper:]')
    [[ -z "$color_tag" ]] && color_tag="unspecified"
    if grep -q 'progressive' <<< "$output_video"; then scan="progressive"; else scan="interlaced/unknown"; fi

    local muxing
    muxing=$(grep -m1 'muxing overhead' "$log" 2>/dev/null | grep -oE 'muxing overhead: [0-9.]+%' | awk '{print $NF}')

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
        size=$(du -sh "$output" 2>/dev/null | cut -f1)
    fi
    md5=$(grep -oE 'Output file MD5 is [a-f0-9]+' "$log" 2>/dev/null | awk '{print $NF}' | head -1)

    local dur_str
    dur_str=$(_fmt_duration "$duration")

    local status_color status_word duration_label output_label
    if (( status == 0 )); then
        status_color="${GREEN}"; status_word="success"
    else
        status_color="${RED}";   status_word="FAILED (exit $status)"
    fi
    if [[ "$mode" == "encode" ]]; then
        duration_label="Encode duration"; output_label="Output .mkv"
    else
        duration_label="Decode duration"; output_label="Output dir"
    fi

    # Terminal banner. Bars bold/blue; "Summary" plain.
    {
        echo ""
        printf '%s%s%s\n' "${BOLD}${BLUE}" "$_SEP" "${RESET}"
        printf '  Summary   %s%s%s\n' "${status_color}" "$status_word" "${RESET}"
        printf '%s%s%s\n' "${BOLD}${BLUE}" "$_SEP" "${RESET}"
        printf '  %sStarted:%s          %s\n' "${CYAN}" "${RESET}" "$start_et"
        printf '  %sFinished:%s         %s\n' "${CYAN}" "${RESET}" "$end_et"
        printf '  %s%s:%s  %s\n' "${CYAN}" "$duration_label" "${RESET}" "$dur_str"
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
        printf '%-19s %s\n' "Started:"             "$start_et"
        printf '%-19s %s\n' "Finished:"            "$end_et"
        printf '%-19s %s\n' "${duration_label}:"   "$dur_str"
        printf '%-19s %s\n' "Exit:"                "$status ($status_word)"
        printf '%-19s %s\n' "${output_label}:"     "$output"
        [[ -n "$size" ]] && printf '%-19s %s\n' "Output size:"  "$size"
        if [[ "$mode" == "encode" && -n "$md5" ]]; then
            printf '%-19s %s\n' "Output MD5:" "$md5"
        fi
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

    # Probe framerate provenance before encode.
    local framerate_source=""
    if [[ "$mode" == "encode" ]]; then
        framerate_source=$(_probe_framerate_source "$input")
    fi

    _preflight "$mode" "$input" "$output" "$log"

    local start_t end_t status start_et end_et
    start_t=$(date +%s)
    start_et=$(_now_et)
    { "${cmd[@]}" 2>&1; } | tee -a "$log" || true
    status=${PIPESTATUS[0]}
    end_t=$(date +%s)
    end_et=$(_now_et)

    if [[ "$mode" == "encode" ]]; then
        _tech_summary "$log" "$framerate_source"
        _ffmpeg_summary "$log"
    fi

    _postflight "$status" "$((end_t - start_t))" "$output" "$log" "$mode" "$start_et" "$end_et"

    return "$status"
}

main "$@"
