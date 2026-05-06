#!/usr/bin/env bash
# rsync_queue
#
# Mac-side interactive wrapper for queueing rsync transfers between TrueNAS
# .220 and .225. Translates Mac SMB mount paths (/Volumes/<share>/...) to
# server-side paths (/mnt/...), builds a queue of transfers, and kicks them
# off in a detached tmux session on .220 by calling the existing
# /root/rsync_run.sh.
#
# Usage: rsync_queue
#
# Workflow:
#   1. Add transfers interactively (drag folders from Finder)
#   2. Review the queue
#   3. Confirm and launch
#   4. Auto-attach to remote tmux to watch live; Ctrl+B D to walk away
#
# The transfer keeps running on .220 even after you disconnect.

set -uo pipefail

trap 'printf "Interrupted\n" >&2; exit 130' INT TERM

# ── Configuration ──────────────────────────────────────────────────────────
NAS_220="192.168.3.220"
NAS_225="192.168.3.225"
NAS_220_USER="root"
NAS_225_USER="medialab"
TMUX_SESSION="rsync"
REMOTE_RSYNC_SCRIPT="/root/rsync_run.sh"
REMOTE_QUEUE_DIR="/mnt/ssd_raid/ssd_raid/_rsync_admin/queue_history"
REMOTE_LOG_DIR="/mnt/ssd_raid/ssd_raid/_rsync_admin/rsync_logs"

# Share-to-path lookup table.
# Format: "<server-ip>|<share-name>|<server-path>"
# When you add new shares, add a line here.
SHARE_MAP=(
    "${NAS_220}|SSD_SCAN_RAID|/mnt/ssd_raid/ssd_raid"
    "${NAS_220}|tbm-access|/mnt/data-pool-01/tbm-access"
    "${NAS_220}|tbm-exhibitions-presentations|/mnt/data-pool-01/tbm-exhibitions-presentations"
    "${NAS_220}|tbm-gmhmp|/mnt/data-pool-01/tbm-gmhmp"
    "${NAS_220}|TBM-Staff|/mnt/data-pool-01/tbm-staff"
    "${NAS_220}|tbm-utility|/mnt/data-pool-02/tbm-utility"
    "${NAS_220}|tbm-working|/mnt/data-pool-01/tbm-working"
    "${NAS_225}|xScans|/mnt/medialab/data/scans"
    "${NAS_225}|xUtility|/mnt/medialab/data/utility"
)

# ── Pretty output helpers ──────────────────────────────────────────────────
if [[ -t 1 ]]; then
    BOLD=$'\033[1m'; BLUE=$'\033[34m'; CYAN=$'\033[36m'
    GREEN=$'\033[32m'; YELLOW=$'\033[33m'; RED=$'\033[31m'; DIM=$'\033[2m'; RESET=$'\033[0m'
else
    BOLD=''; BLUE=''; CYAN=''; GREEN=''; YELLOW=''; RED=''; DIM=''; RESET=''
fi

say()   { printf "%s\n" "$*"; }
info()  { printf "%s%s%s\n" "${DIM}" "$*" "${RESET}"; }
ok()    { printf "%s✓%s %s\n" "${GREEN}" "${RESET}" "$*"; }
warn()  { printf "%s!%s %s\n" "${YELLOW}" "${RESET}" "$*"; }
err()   { printf "%s✗%s %s\n" "${RED}" "${RESET}" "$*" >&2; }
hdr()   { printf "\n%s%s%s\n" "${BOLD}" "$*" "${RESET}"; }
rule()  { printf "%s\n" "────────────────────────────────────────────────────"; }

require_cmds() {
    local missing=0 dep
    for dep in "$@"; do
        command -v "$dep" >/dev/null 2>&1 || { err "Missing dependency: $dep"; missing=1; }
    done
    [ "$missing" -eq 0 ] || exit 1
}

# ── Usage / help ──────────────────────────────────────────────────────────
_usage() {
    cat <<EOF
${BOLD}${BLUE}USAGE:${RESET}
  ${GREEN}rsync_queue${RESET}   ${DIM}# interactive — no flags${RESET}

Run ${GREEN}rsync_queue${RESET} ${CYAN}-h${RESET} for detailed help.
EOF
}

_help() {
    cat <<EOF
${BOLD}${BLUE}NAME${RESET}
  ${GREEN}rsync_queue${RESET} — Mac-side interactive queue builder for rsync transfers
  between TrueNAS ${YELLOW}${NAS_220}${RESET} and ${YELLOW}${NAS_225}${RESET}

${BOLD}${BLUE}USAGE${RESET}
  ${GREEN}rsync_queue${RESET}                     ${DIM}# run the interactive workflow${RESET}
  ${GREEN}rsync_queue${RESET} ${CYAN}-h${RESET}                  ${DIM}# show this help${RESET}

${BOLD}${BLUE}OPTIONS${RESET}
  ${CYAN}-h${RESET}, ${CYAN}--help${RESET}              Show this help and exit

${BOLD}${BLUE}WORKFLOW${RESET}
  1. Add transfers interactively (drag folders from Finder into the terminal)
  2. Review the queue
  3. Pick mode: dry-run (default) or live
  4. Confirm and launch — batch script is uploaded to ${YELLOW}${NAS_220}${RESET} and run
     in a detached tmux session named ${YELLOW}${TMUX_SESSION}${RESET}
  5. Auto-attaches to the remote tmux; Ctrl+B then D detaches without stopping
     the transfer. Reattach with:
        ${DIM}ssh ${NAS_220_USER}@${NAS_220} 'tmux attach -t ${TMUX_SESSION}'${RESET}

${BOLD}${BLUE}OUTPUT FILES${RESET}
  Each batch produces three files in ${YELLOW}${REMOTE_LOG_DIR}${RESET}:
    ${CYAN}.log${RESET}          rsync output + header/footer with throughput summary
    ${CYAN}.context.txt${RESET}  one-time system snapshot (NIC, pool, ZFS, ping/MTU, SSH cipher)
    ${CYAN}.metrics.tsv${RESET}  per-15s samples (NIC, pool, CPU) — load in any spreadsheet
                  to see when throughput dipped during the run

${BOLD}${BLUE}PATH TRANSLATION${RESET}
  Mac SMB mount paths (${YELLOW}/Volumes/<share>/...${RESET}) are translated to server-side
  rsync paths using the built-in ${YELLOW}SHARE_MAP${RESET}. Sources on the non-rsync host
  come back as ${YELLOW}user@host:/path${RESET}; sources on ${YELLOW}${NAS_220}${RESET} stay local.
  Destinations must be on ${YELLOW}${NAS_220}${RESET} (that's where rsync runs).
  When you mount a new share, add a line to ${YELLOW}SHARE_MAP${RESET} in this script.

${BOLD}${BLUE}EXAMPLES${RESET}
  ${DIM}# Start the interactive queue builder${RESET}
  ${GREEN}rsync_queue${RESET}

${BOLD}${BLUE}SHARE MAP${RESET} ${DIM}(edit the SHARE_MAP array in this script to add entries)${RESET}
EOF
    printf "  ${DIM}%-15s  %-32s  %s${RESET}\n" "Host" "Share" "Server path"
    local entry e_host e_share e_path
    for entry in "${SHARE_MAP[@]}"; do
        IFS='|' read -r e_host e_share e_path <<< "$entry"
        printf "  ${YELLOW}%-15s${RESET}  %-32s  %s\n" "$e_host" "$e_share" "$e_path"
    done
}

# ── Mount discovery: parse `mount` for current SMB mounts ─────────────────
# Returns lines of form: "<mount-point>|<server-ip>|<share-name>"
#
# Known limitation: parses `mount` with awk $1/$3, so mount points containing
# spaces (e.g. /Volumes/TBM Archives) will be truncated at the first space.
# No such shares today; revisit if that changes.
discover_smb_mounts() {
    mount | grep -E "smbfs|cifs" | while IFS= read -r line; do
        # Example line:
        # //medialab@192.168.3.225/xScans on /Volumes/xScans (smbfs, ...)
        local src mp
        src=$(echo "$line" | awk '{print $1}')
        mp=$(echo "$line" | awk '{print $3}')
        # src looks like //user@host/share
        local host share
        host=$(echo "$src" | sed -E 's|//[^@]+@([^/]+)/.*|\1|')
        share=$(echo "$src" | sed -E 's|//[^/]+/(.*)|\1|')
        echo "${mp}|${host}|${share}"
    done
}

# ── Path translation ──────────────────────────────────────────────────────
# Input: a Mac path like /Volumes/tbm-working/2012_79_BOWSER/foo
# Output (stdout): the server-side rsync path, e.g.
#   /mnt/data-pool-01/tbm-working/2012_79_BOWSER/foo                (local on .220)
#   medialab@192.168.3.225:/mnt/medialab/data/utility/foo           (remote, .225)
# The "context" arg is the IP of the NAS we're running rsync on (always .220
# in our setup since rsync_run.sh lives there). Local paths return bare paths;
# remote paths return user@host:path form.
translate_path() {
    local mac_path="$1"
    local rsync_host="$2"   # the IP of the NAS where rsync runs (the destination NAS, typically .220)

    # Strip trailing slash for consistent matching, but preserve trailing-slash
    # semantics for rsync: a trailing slash on a source folder means
    # "contents of this folder", without means "this folder itself". We track
    # it and re-append at the end.
    local trailing_slash=""
    if [[ "$mac_path" == */ ]]; then
        trailing_slash="/"
        mac_path="${mac_path%/}"
    fi

    # Find which mount this path belongs to
    local mounts
    mounts=$(discover_smb_mounts)

    local match_mp="" match_host="" match_share=""
    while IFS='|' read -r mp host share; do
        # Longest-prefix match. Require the next char to be / (or exact
        # match) so mount point "/Volumes/tbm" doesn't swallow a path under
        # "/Volumes/tbm-working".
        if [[ "$mac_path" == "$mp" || "$mac_path" == "$mp"/* ]] && [ ${#mp} -gt ${#match_mp} ]; then
            match_mp="$mp"
            match_host="$host"
            match_share="$share"
        fi
    done <<< "$mounts"

    if [ -z "$match_mp" ]; then
        err "Path is not on a known SMB mount: $mac_path"
        return 1
    fi

    # Look up server-side path for this host+share
    local server_root=""
    for entry in "${SHARE_MAP[@]}"; do
        IFS='|' read -r e_host e_share e_path <<< "$entry"
        if [ "$e_host" = "$match_host" ] && [ "$e_share" = "$match_share" ]; then
            server_root="$e_path"
            break
        fi
    done

    if [ -z "$server_root" ]; then
        err "No server path mapping for ${match_host}:${match_share}"
        err "Add it to SHARE_MAP in this script."
        return 1
    fi

    # Compute the relative portion below the mount point
    local relative="${mac_path#$match_mp}"
    local server_path="${server_root}${relative}${trailing_slash}"

    # If this path is on the rsync host itself, return bare path.
    # Otherwise, return user@host:path form.
    if [ "$match_host" = "$rsync_host" ]; then
        echo "$server_path"
    else
        local user
        case "$match_host" in
            "$NAS_220") user="$NAS_220_USER" ;;
            "$NAS_225") user="$NAS_225_USER" ;;
            *) user="medialab" ;;
        esac
        echo "${user}@${match_host}:${server_path}"
    fi
}

# ── Trim leading/trailing whitespace ──────────────────────────────────────
trim() {
    local s="$1"
    # Drag-and-drop from Finder often appends a trailing space
    s="${s#"${s%%[![:space:]]*}"}"
    s="${s%"${s##*[![:space:]]}"}"
    echo "$s"
}

# Strip surrounding single or double quotes (drag-and-drop adds them when
# the path contains spaces).
unquote() {
    local s="$1"
    if [[ "$s" == \"*\" ]]; then s="${s#\"}"; s="${s%\"}"; fi
    if [[ "$s" == \'*\' ]]; then s="${s#\'}"; s="${s%\'}"; fi
    echo "$s"
}

# ── Prompt helper: read input with a prompt, return cleaned value ─────────
ask() {
    local prompt="$1"
    local default="${2:-}"
    local reply
    if [ -n "$default" ]; then
        printf "%s [%s]: " "$prompt" "$default" >&2
    else
        printf "%s: " "$prompt" >&2
    fi
    IFS= read -r reply
    if [ -z "$reply" ] && [ -n "$default" ]; then
        reply="$default"
    fi
    reply=$(unquote "$reply")
    reply=$(trim "$reply")
    echo "$reply"
}

# Yes/no prompt. Default is the second arg ("y" or "n").
ask_yn() {
    local prompt="$1"
    local default="${2:-n}"
    local hint="(y/N)"
    [ "$default" = "y" ] && hint="(Y/n)"
    local reply
    while true; do
        printf "%s %s: " "$prompt" "$hint" >&2
        IFS= read -r reply
        reply=$(trim "$reply")
        [ -z "$reply" ] && reply="$default"
        case "$reply" in
            y|Y|yes|YES) return 0 ;;
            n|N|no|NO)   return 1 ;;
            *) warn "Please answer y or n." ;;
        esac
    done
}

# ── Build one transfer's sources + destination ────────────────────────────
# Echoes lines: "src|<resolved-source-1>", "src|...", "dst|<resolved-dest>"
build_transfer() {
    local transfer_num="$1"
    hdr "Transfer ${transfer_num}"
    info "Tip: drag folders from Finder into this terminal."

    # Sources (one or more)
    local sources=()
    local src_n=1
    while true; do
        local raw
        raw=$(ask "  Source ${src_n}")
        if [ -z "$raw" ]; then
            err "  Empty source. Try again."
            continue
        fi
        local resolved
        if ! resolved=$(translate_path "$raw" "$NAS_220"); then
            warn "  Skipping that source. Try again."
            continue
        fi
        ok "  → $resolved"
        sources+=("$resolved")
        src_n=$((src_n + 1))
        if ! ask_yn "  Add another source for this transfer?" "n"; then
            break
        fi
    done

    # Destination
    local dst_resolved=""
    while true; do
        local raw
        raw=$(ask "  Destination")
        if [ -z "$raw" ]; then
            err "  Empty destination. Try again."
            continue
        fi
        if ! dst_resolved=$(translate_path "$raw" "$NAS_220"); then
            warn "  Try again."
            continue
        fi
        # Destination must be local on .220 (rsync runs there).
        # If it came back as user@host:path form, that's wrong.
        if [[ "$dst_resolved" == *@*:* ]]; then
            err "  Destination must be on .220 (rsync runs there)."
            err "  Got: $dst_resolved"
            continue
        fi
        ok "  → $dst_resolved"
        break
    done

    # Emit results
    for s in "${sources[@]}"; do
        printf "src|%s\n" "$s"
    done
    printf "dst|%s\n" "$dst_resolved"
}

# ── Render a queue summary (Batch N: src/dst lines) ───────────────────────
# Usage: print_queue_summary "${queue[@]}"
print_queue_summary() {
    rule
    local i=1
    local t line s
    local -a srcs
    local dst
    for t in "$@"; do
        printf "%sBatch %d:%s\n" "${BOLD}" "$i" "${RESET}"
        srcs=()
        dst=""
        while IFS= read -r line; do
            case "$line" in
                src\|*) srcs+=("${line#src|}") ;;
                dst\|*) dst="${line#dst|}" ;;
            esac
        done <<< "$t"
        for s in "${srcs[@]}"; do
            printf "    src: %s\n" "$s"
        done
        printf "    dst: %s\n" "$dst"
        i=$((i + 1))
    done
    rule
}

# ── Generate batch script, ship to .220, run in tmux, attach ──────────────
# Usage: launch_queue <mode> "${queue[@]}"
# Returns nonzero on failure; on success returns after the tmux session
# ends (i.e. after the user presses Enter inside it or detaches and the
# session is killed). Does NOT exec — caller continues after this returns.
launch_queue() {
    local mode="$1"
    shift
    local -a q=("$@")

    local timestamp
    timestamp=$(date +%Y%m%d-%H%M%S)
    local batch_script="/tmp/rsync_queue_${timestamp}.sh"

    {
        echo "#!/usr/bin/env bash"
        echo "# Auto-generated by rsync_queue on $(date)"
        echo "# Mode: ${mode}"
        echo "set -e"   # stop on first failure
        echo ""
        local i=1
        local total="${#q[@]}"
        local t line s cmd
        local -a srcs
        local dst
        for t in "${q[@]}"; do
            srcs=()
            dst=""
            while IFS= read -r line; do
                case "$line" in
                    src\|*) srcs+=("${line#src|}") ;;
                    dst\|*) dst="${line#dst|}" ;;
                esac
            done <<< "$t"
            echo "echo ''"
            echo "echo '============================================================'"
            echo "echo 'BATCH ${i} of ${total}'"
            echo "echo '============================================================'"
            # Use printf %q so paths containing ", $, `, \, or spaces can't
            # break out of the generated command.
            cmd=$(printf '%q' "${REMOTE_RSYNC_SCRIPT}")
            [ "$mode" = "dry" ] && cmd+=" -n"
            for s in "${srcs[@]}"; do
                cmd+=" $(printf '%q' "$s")"
            done
            cmd+=" $(printf '%q' "$dst")"
            echo "$cmd"
            i=$((i + 1))
        done
        echo ""
        echo "echo ''"
        echo "echo '============================================================'"
        echo "echo 'QUEUE COMPLETE'"
        echo "echo '============================================================'"
    } > "$batch_script"

    info "Uploading batch script to ${NAS_220}..."
    if ! scp -q "$batch_script" "${NAS_220_USER}@${NAS_220}:${batch_script}"; then
        err "Failed to copy batch script to ${NAS_220}."
        return 1
    fi
    ok "Uploaded: ${batch_script}"

    ssh "${NAS_220_USER}@${NAS_220}" "mkdir -p '${REMOTE_QUEUE_DIR}' && cp '${batch_script}' '${REMOTE_QUEUE_DIR}/' && chmod +x '${batch_script}'" >/dev/null

    if ssh "${NAS_220_USER}@${NAS_220}" "tmux has-session -t '${TMUX_SESSION}' 2>/dev/null"; then
        err "A tmux session named '${TMUX_SESSION}' already exists on ${NAS_220}."
        err "Attach to it (ssh ${NAS_220_USER}@${NAS_220} 'tmux attach -t ${TMUX_SESSION}')"
        err "or kill it (ssh ${NAS_220_USER}@${NAS_220} 'tmux kill-session -t ${TMUX_SESSION}')"
        err "before launching a new queue."
        return 1
    fi

    info "Launching tmux session '${TMUX_SESSION}' on ${NAS_220}..."
    ssh "${NAS_220_USER}@${NAS_220}" \
        "tmux new-session -d -s '${TMUX_SESSION}' 'bash ${batch_script}; echo; echo Press Enter to close this session.; read'" \
        || { err "Failed to start tmux session."; return 1; }
    ok "Started."

    say ""
    info "Each batch will produce three files in ${REMOTE_LOG_DIR}:"
    info "  <ts>-<MODE>-<src>-to-<dst>.log          rsync output + summary"
    info "  <ts>-<MODE>-<src>-to-<dst>.context.txt  one-time system snapshot"
    info "  <ts>-<MODE>-<src>-to-<dst>.metrics.tsv  per-15s samples (NIC/pool/CPU)"
    info "The .metrics.tsv file is the diagnostic for speed drops."
    say ""
    info "Attaching to tmux session. Detach with Ctrl+B then D — transfer keeps running."
    info "Reattach later with: ssh ${NAS_220_USER}@${NAS_220} 'tmux attach -t ${TMUX_SESSION}'"
    say ""
    sleep 1
    # No exec — caller continues after the tmux session ends so we can
    # offer dry-run → live re-run without rebuilding the queue.
    ssh -t "${NAS_220_USER}@${NAS_220}" "tmux attach -t '${TMUX_SESSION}'"

    # After tmux ends, show files this queue produced. Use the uploaded batch
    # script as the reference for `find -newer` so we get exactly the files
    # written during this run (.log, .context.txt, .metrics.tsv per batch).
    say ""
    hdr "Files produced by this queue (under ${REMOTE_LOG_DIR}):"
    ssh "${NAS_220_USER}@${NAS_220}" \
        "find '${REMOTE_LOG_DIR}' -type f -newer '${batch_script}' 2>/dev/null | sort" \
        | while IFS= read -r f; do
            [ -z "$f" ] && continue
            printf "  %s\n" "$f"
        done
    say ""
    return 0
}

# ── Main ──────────────────────────────────────────────────────────────────
main() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help) _help; exit 0 ;;
            *) err "Unknown arg: $1"; _usage >&2; exit 2 ;;
        esac
    done

    require_cmds mount awk sed ssh scp

    hdr "rsync queue builder"
    info "Builds a queue of rsync transfers and runs them sequentially on ${NAS_220} in tmux."

    # Sanity check: are there any SMB mounts at all?
    local mounts
    mounts=$(discover_smb_mounts)
    if [ -z "$mounts" ]; then
        err "No SMB mounts found. Mount your NAS shares in Finder first."
        exit 1
    fi
    hdr "Active SMB mounts:"
    while IFS='|' read -r mp host share; do
        printf "  %-40s %s:%s\n" "$mp" "$host" "$share"
    done <<< "$mounts"

    # Collect transfers
    local -a queue   # each element is a multi-line string with src|... and dst|... lines
    local n=1
    while true; do
        local transfer
        transfer=$(build_transfer "$n")
        queue+=("$transfer")
        n=$((n + 1))
        echo
        if ! ask_yn "Add another transfer to the queue?" "n"; then
            break
        fi
    done

    # Show the plan
    hdr "Final plan"
    print_queue_summary "${queue[@]}"

    # Mode (dry-run by default per your preference)
    local mode="dry"
    if ask_yn "Run LIVE? (default is dry-run)" "n"; then
        mode="live"
    fi
    info "Mode: ${mode}"

    if ! ask_yn "Confirm and launch?" "n"; then
        warn "Aborted by user. Nothing was launched."
        exit 0
    fi

    launch_queue "$mode" "${queue[@]}" || exit 1

    # After a dry run, offer to re-run the same queue in live mode without
    # rebuilding it. Show the queue again so the user can confirm confidently.
    if [ "$mode" = "dry" ]; then
        echo
        hdr "Dry run finished. Same transfers if you re-run in LIVE mode:"
        print_queue_summary "${queue[@]}"
        if ask_yn "Re-run these transfers in LIVE mode?" "n"; then
            launch_queue "live" "${queue[@]}" || exit 1
        else
            say ""
            info "Done. To re-run later, start rsync_queue again."
        fi
    fi
}

main "$@"
