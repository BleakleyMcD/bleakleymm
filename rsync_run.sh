#!/usr/bin/env bash
# rsync_run.sh
# Usage: /root/rsync_run.sh [-n] <source1> [source2 ...] <destination>
#   -n = dry run
#   Last argument is always the destination
#   Run inside tmux: tmux new -s rsync
#
# Lives on the rsync host (192.168.3.220, TrueNAS CORE 13.0-U6.8 / FreeBSD)
# at /root/rsync_run.sh. Called by the Mac-side rsync_queue tool.
#
# Each invocation produces three files in $LOG_DIR, sharing a basename:
#   <ts>-<MODE>-<src>-to-<dst>.log          rsync output + header/footer
#   <ts>-<MODE>-<src>-to-<dst>.context.txt  one-time system snapshot
#   <ts>-<MODE>-<src>-to-<dst>.metrics.tsv  periodic samples (NIC, pool, CPU)
# .metrics.tsv is the diagnostic for speed drops: load it in any spreadsheet
# or `awk` to see exactly when throughput dipped and what dipped with it.

set -uo pipefail

# ── Configuration ──────────────────────────────────────
LOG_DIR="/mnt/ssd_raid/ssd_raid/_rsync_admin/rsync_logs"
MEDIALAB_KEY="/root/.ssh/id_medialab"
SAMPLE_INTERVAL=15      # seconds between metric samples
SRC_HOST_DEFAULT="192.168.3.225"

# ── Parse flags ────────────────────────────────────────
DRY_RUN=0
if [ "${1:-}" = "-n" ]; then
    DRY_RUN=1
    shift
fi

# ── Validate args ──────────────────────────────────────
if [ "$#" -lt 2 ]; then
    cat <<USAGE
Usage: $0 [-n] <source1> [source2 ...] <destination>
  -n = dry run
  Last argument is always the destination

  e.g. $0 medialab@192.168.3.225:/mnt/medialab/data/utility/BARNETT /mnt/data-pool-01/tbm-working/
  e.g. $0 -n medialab@192.168.3.225:/mnt/medialab/data/utility/BARNETT medialab@192.168.3.225:/mnt/medialab/data/utility/06_DCP /mnt/data-pool-01/tbm-working/
USAGE
    exit 1
fi

# ── Split sources and destination ──────────────────────
ARGS=("$@")
DST="${ARGS[-1]}"
unset 'ARGS[-1]'
SRCS=("${ARGS[@]}")

# ── Build basename / file paths ────────────────────────
if [ "${#SRCS[@]}" -gt 1 ]; then
    SRC_LABEL="multi"
else
    FIRST_SRC="${SRCS[0]}"
    SRC_LABEL=$(echo "$FIRST_SRC" | awk -F'/' '{print $(NF-1)"-"$NF}' | sed 's/[^a-zA-Z0-9_-]/-/g')
fi

DST_LABEL=$(echo "$DST" | awk -F'/' '{v=$NF; if(v=="") v=$(NF-1); print v}' | sed 's/[^a-zA-Z0-9_-]/-/g')
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
MODE_LABEL=$([ "$DRY_RUN" -eq 1 ] && echo "DRYRUN" || echo "LIVE")
BASE="${LOG_DIR}/${TIMESTAMP}-${MODE_LABEL}-${SRC_LABEL}-to-${DST_LABEL}"
LOG="${BASE}.log"
CTX="${BASE}.context.txt"
METRICS="${BASE}.metrics.tsv"

mkdir -p "$LOG_DIR"

# ── Detect dest NIC and pool ───────────────────────────
SRC_HOSTS=$(printf '%s\n' "${SRCS[@]}" | grep -oE '[a-zA-Z0-9_-]+@[0-9.]+' \
    | awk -F'@' '{print $2}' | sort -u)
PROBE_HOST=$(echo "$SRC_HOSTS" | head -1)
PROBE_HOST="${PROBE_HOST:-$SRC_HOST_DEFAULT}"

# Interface that routes to the source host. FreeBSD: `route -n get <host>`
# prints `interface: <name>` somewhere in the block.
DEST_NIC=$(route -n get "$PROBE_HOST" 2>/dev/null \
    | awk '/interface:/{print $2; exit}')
[ -z "$DEST_NIC" ] && DEST_NIC=$(route -n get default 2>/dev/null \
    | awk '/interface:/{print $2; exit}')
DEST_NIC="${DEST_NIC:-em0}"

# Pool name is the second path component of /mnt/<pool>/...
DEST_POOL=$(echo "$DST" | awk -F'/' '{print $3}')

# ── Header ─────────────────────────────────────────────
DIVIDER="============================================================"
{
echo "$DIVIDER"
echo "TrueNAS rsync Transfer"
echo "Started:   $(date '+%Y-%m-%d %H:%M:%S')"
echo "Mode:      $([ "$DRY_RUN" -eq 1 ] && echo 'DRY RUN' || echo 'LIVE')"
for SRC in "${SRCS[@]}"; do
    echo "Source:    $SRC"
done
echo "Dest:      $DST"
echo "Log:       $LOG"
echo "Context:   $CTX"
echo "Metrics:   $METRICS"
echo "SSH key:   $MEDIALAB_KEY"
echo "Dest NIC:  $DEST_NIC"
echo "Dest pool: $DEST_POOL"
echo "$DIVIDER"
echo ""
} | tee -a "$LOG"

# ── One-time context capture (.context.txt) ────────────
{
echo "rsync_run.sh context"
echo "Captured: $(date '+%Y-%m-%d %H:%M:%S')"
echo "For:      $LOG"
echo "$DIVIDER"

echo ""
echo "──── Local host ────"
hostname; uname -a; uptime

echo ""
echo "──── TrueNAS / OS version ────"
[ -r /etc/version ] && cat /etc/version
freebsd-version 2>/dev/null

echo ""
echo "──── NIC: $DEST_NIC ────"
ifconfig "$DEST_NIC" 2>&1
echo ""
echo "-- driver / hardware sysctls (best-effort) --"
# bge0 → dev.bge.0 ; em0 → dev.em.0 ; ix0 → dev.ix.0 ; etc.
NIC_DRV=$(echo "$DEST_NIC" | sed -E 's/[0-9]+$//')
NIC_UNIT=$(echo "$DEST_NIC" | grep -oE '[0-9]+$')
if [ -n "$NIC_DRV" ] && [ -n "$NIC_UNIT" ]; then
    sysctl "dev.${NIC_DRV}.${NIC_UNIT}" 2>/dev/null \
      | grep -iE 'speed|duplex|link|media|mtu|tso|lro|rxcsum|txcsum|driver|description|model|fc' | head -40
fi

echo ""
echo "──── All interfaces ────"
for IF in $(ifconfig -l); do
    LINE=$(ifconfig "$IF" 2>/dev/null | awk '
        /flags=/{flags=$0}
        /status:/{status=$0}
        /media:/{media=$0}
        END{print flags; print status; print media}')
    echo "## $IF"
    echo "$LINE"
done

echo ""
echo "──── Routing to $PROBE_HOST ────"
route -n get "$PROBE_HOST" 2>&1
echo ""
echo "-- routing table (default + 192.168.3.x) --"
netstat -rn -f inet 2>&1 | awk 'NR<=4 || /^default/ || /^192\.168\.3/'

echo ""
echo "──── Latency to $PROBE_HOST (ping x5) ────"
ping -c 5 -W 2000 "$PROBE_HOST" 2>&1 || true

echo ""
echo "──── MTU path probe to $PROBE_HOST (DF set) ────"
echo "# 1500-byte (1472 payload):"
ping -c 2 -W 2000 -D -s 1472 "$PROBE_HOST" 2>&1 || true
echo "# 9000-byte jumbo (8972 payload):"
ping -c 2 -W 2000 -D -s 8972 "$PROBE_HOST" 2>&1 || true

echo ""
echo "──── SSH config to source ($MEDIALAB_KEY) ────"
ssh -i "$MEDIALAB_KEY" -G "medialab@${PROBE_HOST}" 2>&1 \
  | grep -iE '^(ciphers|macs|kexalgorithms|hostname|port|user|compression|controlpath|hostkeyalgorithms)\b' || true

echo ""
echo "──── Pool: $DEST_POOL ────"
zpool list -v "$DEST_POOL" 2>&1
echo ""
zpool status "$DEST_POOL" 2>&1
echo ""
zpool get all "$DEST_POOL" 2>&1 \
  | grep -E 'fragmentation|capacity|ashift|autotrim|failmode|free|allocated|size' || true

echo ""
echo "──── ZFS datasets under $DEST_POOL ────"
zfs list -t filesystem -o name,used,available,referenced,recordsize,compression,compressratio,sync,encryption,atime -r "$DEST_POOL" 2>&1

echo ""
echo "──── Properties of dataset containing $DST ────"
DEST_DATASET=$(zfs list -H -o name "${DST%/}" 2>/dev/null \
    || zfs list -H -o name "$(dirname "${DST%/}")" 2>/dev/null)
if [ -n "$DEST_DATASET" ]; then
    echo "Dataset: $DEST_DATASET"
    zfs get all "$DEST_DATASET" 2>&1 \
      | grep -vE '\b(default|inherited)\b' | head -40
    echo "(showing locally-set properties only)"
else
    echo "(could not resolve dataset for $DST)"
fi

echo ""
echo "──── ARC summary ────"
sysctl kstat.zfs.misc.arcstats 2>/dev/null \
  | grep -E 'arcstats\.(size|c|c_max|c_min|hits|misses|p|memory_throttle_count|arc_meta_used|arc_meta_max|arc_meta_limit)$' || true

echo ""
echo "──── Memory ────"
sysctl -h hw.physmem hw.usermem 2>/dev/null
vmstat -h 2>/dev/null | head -3 || true

echo ""
echo "──── CPU ────"
sysctl -n hw.ncpu hw.model hw.machine 2>/dev/null

echo ""
echo "──── Load avg / uptime ────"
uptime
sysctl -n vm.loadavg 2>/dev/null

echo ""
echo "──── Mounts (non-virtual) ────"
mount | grep -vE '^(devfs|fdescfs|procfs|tmpfs|nullfs) ' || true

echo ""
echo "──── Source host(s) probe via SSH ────"
for h in $SRC_HOSTS; do
    echo "## medialab@${h}"
    timeout 10 ssh -o BatchMode=yes -o ConnectTimeout=5 -i "$MEDIALAB_KEY" \
        "medialab@${h}" \
        'echo "-- uname --"; uname -a; echo "-- uptime --"; uptime; echo "-- df -hT --"; df -hT 2>/dev/null | head -40; echo "-- ifconfig -l --"; ifconfig -l 2>/dev/null; echo "-- ifconfig (link/status/media for each) --"; for i in $(ifconfig -l 2>/dev/null); do ifconfig $i 2>/dev/null | awk -v i=$i "/flags=/{print i,\$0}/status:/{print i,\$0}/media:/{print i,\$0}"; done' \
        2>&1 || echo "(probe failed for ${h})"
    echo ""
done

echo "$DIVIDER"
} > "$CTX" 2>&1

# ── Periodic sampler (.metrics.tsv) ────────────────────
# Background loop. One row every $SAMPLE_INTERVAL seconds. NIC bytes are
# diff'd from `netstat -I <if> -bn`; pool throughput comes from
# `zpool iostat -Hpy <pool> <interval> 1`, which itself blocks for the
# interval — that's our pacing source for the loop.

# TSV header
{
printf 'epoch_iso\twall_s\tnic_rx_MBps\tnic_tx_MBps\tpool_r_MBps\tpool_w_MBps\tpool_r_iops\tpool_w_iops\tpool_used_GB\tpool_avail_GB\tarc_size_GB\tloadavg_1m\tcpu_idle_pct\tssh_cpu_pct\trsync_cpu_pct\n'
} > "$METRICS"

T0=$(date +%s)

# Read RX/TX bytes for an interface from `netstat -I <if> -bn`. Returns "rx tx".
# `netstat -I bge0 -bn` prints a header row plus one or more rows for the
# interface (Link# row, IPv4 row, IPv6 row); byte counters are identical
# across them, so we take the first data row.
read_nic_bytes() {
    netstat -I "$1" -bn 2>/dev/null \
      | awk -v ifc="$1" '$1==ifc{print $8, $11; exit}'
}

to_MB() { awk -v b="${1:-0}" 'BEGIN{printf "%.2f", b/1048576}'; }
to_GB() { awk -v b="${1:-0}" 'BEGIN{printf "%.2f", b/1073741824}'; }

iso_now() { date "+%Y-%m-%dT%H:%M:%S%z"; }

sampler() {
    local prev_rx prev_tx prev_t now rx tx d_rx d_tx interval
    local pool_line pool_used pool_avail pool_r pool_w pool_r_iops pool_w_iops
    local arc_size load1 cpu_idle ssh_cpu rsync_cpu wall

    read prev_rx prev_tx <<< "$(read_nic_bytes "$DEST_NIC")"
    prev_rx=${prev_rx:-0}; prev_tx=${prev_tx:-0}
    prev_t=$(date +%s)

    while :; do
        # zpool iostat -y blocks for SAMPLE_INTERVAL and reports averaged rates.
        pool_line=$(zpool iostat -Hpy "$DEST_POOL" "$SAMPLE_INTERVAL" 1 2>/dev/null | tail -1)

        now=$(date +%s)
        interval=$(( now - prev_t ))
        [ "$interval" -lt 1 ] && interval=1

        read rx tx <<< "$(read_nic_bytes "$DEST_NIC")"
        rx=${rx:-0}; tx=${tx:-0}
        d_rx=$(( (rx - prev_rx) / interval ))
        d_tx=$(( (tx - prev_tx) / interval ))
        prev_rx=$rx; prev_tx=$tx; prev_t=$now

        # zpool iostat -Hp columns: pool alloc free read_ops write_ops read_bytes write_bytes
        pool_used=$(awk '{print $2}' <<<"$pool_line")
        pool_avail=$(awk '{print $3}' <<<"$pool_line")
        pool_r_iops=$(awk '{print $4}' <<<"$pool_line")
        pool_w_iops=$(awk '{print $5}' <<<"$pool_line")
        pool_r=$(awk '{print $6}' <<<"$pool_line")
        pool_w=$(awk '{print $7}' <<<"$pool_line")

        arc_size=$(sysctl -n kstat.zfs.misc.arcstats.size 2>/dev/null)
        load1=$(sysctl -n vm.loadavg 2>/dev/null | awk '{gsub(/[{}]/,""); print $1}')
        # FreeBSD top: -b batch, -d 1 = one display, "0" = show 0 processes
        cpu_idle=$(top -b -d 1 0 2>/dev/null \
          | awk '/^CPU/{for(i=1;i<=NF;i++) if($i ~ /idle/){gsub("%","",$(i-1)); print $(i-1); exit}}')
        ssh_cpu=$(ps -axo pcpu,comm 2>/dev/null \
          | awk '$2=="ssh"{s+=$1}END{printf "%.1f", s+0}')
        rsync_cpu=$(ps -axo pcpu,comm 2>/dev/null \
          | awk '$2=="rsync"{s+=$1}END{printf "%.1f", s+0}')

        wall=$(( now - T0 ))

        printf '%s\t%d\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
            "$(iso_now)" "$wall" \
            "$(to_MB "$d_rx")" "$(to_MB "$d_tx")" \
            "$(to_MB "${pool_r:-0}")" "$(to_MB "${pool_w:-0}")" \
            "${pool_r_iops:-0}" "${pool_w_iops:-0}" \
            "$(to_GB "${pool_used:-0}")" "$(to_GB "${pool_avail:-0}")" \
            "$(to_GB "${arc_size:-0}")" \
            "${load1:-NA}" "${cpu_idle:-NA}" \
            "${ssh_cpu:-0}" "${rsync_cpu:-0}" \
            >> "$METRICS"
    done
}

sampler &
SAMPLER_PID=$!
trap 'kill $SAMPLER_PID 2>/dev/null; wait $SAMPLER_PID 2>/dev/null' EXIT

# ── Build rsync flags ──────────────────────────────────
RSYNC_FLAGS=(
    --archive
    --acls
    --xattrs
    --verbose
    --verbose
    --human-readable
    --progress
    --itemize-changes
    --stats
    --partial-dir=.rsync-partial
    -e "ssh -i $MEDIALAB_KEY"
    --log-file="$LOG"
)
[ "$DRY_RUN" -eq 1 ] && RSYNC_FLAGS+=(--dry-run)

# ── Run rsync ──────────────────────────────────────────
rsync "${RSYNC_FLAGS[@]}" "${SRCS[@]}" "$DST" 2>&1 | tee -a "$LOG"
RC=${PIPESTATUS[0]}

# ── Stop sampler before footer so the metrics file is final ──
kill "$SAMPLER_PID" 2>/dev/null
wait "$SAMPLER_PID" 2>/dev/null
trap - EXIT

# ── Footer with metric summary ────────────────────────
{
echo ""
echo "$DIVIDER"
echo "Finished:  $(date '+%Y-%m-%d %H:%M:%S')"
echo "Exit code: $RC"
echo ""
if [ -s "$METRICS" ]; then
    echo "──── Throughput summary (from $METRICS) ────"
    awk -F'\t' -v interval="$SAMPLE_INTERVAL" '
        NR==1{next}
        {
            n++
            sum_rx += $3; sum_w += $6
            if (n==1 || $3 < min_rx) min_rx = $3
            if ($3 > max_rx) max_rx = $3
            if ($6 > max_w)  max_w  = $6
            if ($6 > 0 && (active==0 || $6 < min_w_active)) { min_w_active = $6; active = 1 }
        }
        END{
            if (n == 0) { print "No metric samples captured."; exit }
            printf "Samples:           %d (every %ds, ~%.1f min total)\n", n, interval, n*interval/60
            printf "NIC rx MB/s:       avg=%.1f  min=%.1f  max=%.1f\n", sum_rx/n, min_rx, max_rx
            printf "Pool write MB/s:   avg=%.1f  max=%.1f  min(active)=%.1f\n", sum_w/n, max_w, (active?min_w_active:0)
        }' "$METRICS"

    echo ""
    echo "──── Slow windows (NIC rx < 50% of run avg) ────"
    awk -F'\t' '
        NR==1{next}
        { n++; sum+=$3; rows[n]=$0 }
        END{
            if (n == 0) exit
            avg = sum/n; thresh = avg*0.5
            printf "avg=%.1f MB/s, threshold=%.1f MB/s\n", avg, thresh
            cnt = 0
            for (i=1; i<=n && cnt<25; i++) {
                split(rows[i], f, "\t")
                if (f[3] + 0 < thresh) {
                    print rows[i]
                    cnt++
                }
            }
            if (cnt == 0) print "(none — throughput stayed above 50% of avg the whole run)"
        }' "$METRICS"
fi
echo ""
echo "$DIVIDER"
echo "Sidecar files:"
echo "  Context: $CTX"
echo "  Metrics: $METRICS"
echo "$DIVIDER"
} | tee -a "$LOG"

# ── Result line (unchanged for rsync_queue compatibility) ──
echo ""
if [ "$RC" -eq 0 ]; then
    echo "$([ "$DRY_RUN" -eq 1 ] && echo 'DRY RUN COMPLETE' || echo 'TRANSFER COMPLETE')"
    echo "Log: $LOG"
else
    echo "ERROR - rsync exited with code $RC"
    echo "Log: $LOG"
fi

exit $RC
