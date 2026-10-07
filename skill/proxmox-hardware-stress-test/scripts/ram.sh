#!/usr/bin/env bash
# =============================================================================
# ram.sh - RAM stress + benchmark for a Proxmox VE host (part 2 of 5: RAM)
#
# Usage (run as root ON the Proxmox host, after scp to /root/pve-stresstest/):
#   ram.sh --duration SECONDS --out DIR [--stress-mb MB] [--no-install]
#          [--skip-memtester]
#
#   --duration        sustained stress-phase length in seconds (30/60/300/600).
#                     REQUIRED (10..3600). Benchmarks add a bounded extra.
#   --out             output directory (created if missing). REQUIRED.
#   --stress-mb       ask for a smaller/larger stress size; it is still capped
#                     by the safety rules below.
#   --no-install      never apt-get install; missing tools -> sub-test skipped.
#   --skip-memtester  skip the memtester pass.
#   Needs cpu.sh and stream.c / latency.c in the same folder as this script.
#
# WHAT IT MEASURES (in this order)
#   0. Inventory: DIMMs (dmidecode: count, size, type, configured speed,
#      locators), ECC yes/no, EDAC error counters, CPU cache sizes (sysfs),
#      MemAvailable, swap, ZFS ARC size, running guests and how much more RAM
#      they could still claim (VM max memory - current RSS, CT limit - usage).
#   1. STRESS PHASE (DURATION s): stress-ng --vm <physical cores> --vm-method all
#      --verify --vm-keep. Size = min(40% of MemAvailable, size cap), and always
#      capped so the host keeps >= 4 GiB + the guests' possible growth free.
#      Size cap scales with the time available to cover the memory several
#      times: 64 GiB for DURATION < 300 s, 128 GiB for < 600 s, 256 GiB for
#      >= 600 s (--stress-mb can raise it; the safety caps still apply).
#      Workers = all physical cores of all sockets (min 64 MiB each), so on
#      NUMA hosts every node's memory controller is loaded. Every write is read back and
#      checked (--verify): any miscompare = memory error. A 1 s watchdog stops
#      the stress if MemAvailable falls below 1.5 GiB.
#      (stress-ng >= ~0.17 treats --vm-bytes as the TOTAL for all workers, older
#      versions as PER worker. A 2 s probe detects which, so the real tested size
#      is right - otherwise a run can silently test only a small fraction of
#      the planned size.)
#   2. STREAM (stream.c, gcc -O3 -march=native -fopenmp): Copy/Scale/Add/Triad
#      at 1 thread, one thread per physical core, all threads (and P-cores only
#      on hybrid Intel). Each array >= 4x total CPU cache (min 800 MB when RAM
#      allows) so it measures RAM, not cache. Results are self-validated.
#      Multi-NUMA hosts: also one run PER NUMA NODE (threads pinned to that
#      node's cores, memory bound with numactl when installed, else local by
#      first touch), scored against theoretical / number of nodes.
#   3. stress-ng --stream (all threads, 20 s) as a second bandwidth opinion.
#   4. sysbench memory: 1-thread sequential read (block >= 4x cache, 10 s) and
#      multi-thread random read (10 s, informational only).
#   5. Pointer-chase latency (latency.c, 1 thread, pinned): L1, L2, L3 and DRAM
#      sized buffers; DRAM latency = largest buffer (>= 256 MB and >= 8x L3).
#      Multi-NUMA + numactl: DRAM latency from node 0 CPUs to every node's
#      memory (local vs remote).
#   Inventory also lists every DIMM (locator, size, type, speed, configured
#   speed, rank, manufacturer, part number, voltage; no serial numbers) and
#   every NUMA node (CPUs, memory) in summary.json; per-socket CPU package
#   W / temp / MHz during each phase come from telemetry-socket-1s.csv.
#   6. memtester: one pass over min(4 GiB, 10% MemAvailable), time-capped at
#      clamp(DURATION, 30, 300) s (a partial pass is normal and noted).
#   7. Health after: EDAC counters, new kernel MCE/EDAC/OOM lines, swap use.
#
#   CACHE-RESIDENT RESULTS ARE MARKED INVALID: any bandwidth whose working set
#   is < 4x the total CPU cache, or that exceeds the DIMMs' theoretical peak,
#   gets "valid": false and is excluded from scoring (sysbench memory
#   with small blocks can report several hundred GB/s - that is cache, not RAM).
#
#   Telemetry once per second -> DIR/telemetry-1s.csv (same sampler and columns
#   as cpu.sh: telemetry.sh "cpu mem" groups when present, with a "phase"
#   column): CPU package W / temp / MHz (the memory controller lives in the
#   CPU), mem used/available, swap used. Missing sensor -> "n/a".
#
# TIME IT TAKES
#   ~ DURATION + memtester cap clamp(DURATION,30,300) + ~2.5-4 min of fixed
#   benchmarks (STREAM 4 runs, 20 s stress-ng stream, 2x10 s sysbench, latency
#   ladder, pauses). 30 s -> ~4-5 min, 60 s -> ~5-6 min, 300 s -> ~13 min,
#   600 s -> ~18-19 min.
#
# OUTPUTS (in DIR)
#   summary.json, summary.txt, run.log, telemetry-1s.csv, inventory.txt,
#   dimm-info.txt, stress-vm.log/.yaml, stream-*.txt, stress-stream.log,
#   sysbench-*.txt, latency.txt, memtester.txt, edac-pre/post.txt,
#   dmesg-new.txt, dmesg-new-hw-errors.txt, watchdog.txt (only if it fired),
#   bin/ (compiled stream + latency)
#
# SAFETY
#   Never touches guests, BIOS, kernel params or swap settings. Memory sizes
#   are capped so the host keeps >= 4 GiB plus the running guests' possible
#   growth free; the ZFS ARC is NOT counted as free (it shrinks only slowly), so
#   on ZFS hosts the test is smaller and safer. Packages: distro repos only;
#   new ones are recorded in DIR/../installed-packages.txt.
#
# EXIT CODES: 0 = finished (sub-tests may be skipped, see summary.json);
#             2 = bad usage / not root / not Linux / cpu.sh missing.
# =============================================================================

set -u
set -o pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
[ -r "$SCRIPT_DIR/cpu.sh" ] || { echo "ERROR: $SCRIPT_DIR/cpu.sh not found (ram.sh reuses its helpers)" >&2; exit 2; }
# shellcheck source=cpu.sh
CR_LIB_ONLY=1 . "$SCRIPT_DIR/cpu.sh"

usage() { sed -n '3,20p' "$0" | sed 's/^# \{0,1\}//'; }

DURATION=""; OUT=""; STRESS_MB_REQ=""; SKIP_MEMTESTER=0
while [ $# -gt 0 ]; do
  case "$1" in
    --duration) DURATION=${2-}; shift 2 || cr_die "--duration needs a value" ;;
    --out) OUT=${2-}; shift 2 || cr_die "--out needs a value" ;;
    --stress-mb) STRESS_MB_REQ=${2-}; shift 2 || cr_die "--stress-mb needs a value" ;;
    --no-install) CR_NO_INSTALL=1; shift ;;
    --skip-memtester) SKIP_MEMTESTER=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; cr_die "unknown argument: $1" ;;
  esac
done
[[ $DURATION =~ ^[0-9]+$ ]] && [ "$DURATION" -ge 10 ] && [ "$DURATION" -le 3600 ] || cr_die "--duration must be an integer 10..3600 (seconds)"
[ -n "$OUT" ] || cr_die "--out DIR is required"
[ -z "$STRESS_MB_REQ" ] || [[ $STRESS_MB_REQ =~ ^[0-9]+$ ]] || cr_die "--stress-mb must be an integer (MB)"
cr_require_root_linux

mkdir -p "$OUT/bin" || cr_die "cannot create $OUT"
OUT=$(cd "$OUT" && pwd)
CR_PKG_RECORD="$(dirname "$OUT")/installed-packages.txt"
exec > >(tee -a "$OUT/run.log") 2>&1
trap 'cr_cleanup_jobs' EXIT
trap 'cr_log "interrupted"; exit 130' INT TERM

STARTED=$(date -Is)
cr_log "RAM test starting: duration=${DURATION}s out=$OUT"

GIB_KB=1048576
RESERVE_KB=$((4 * GIB_KB))          # host always keeps >= 4 GiB free
CR_MEM_FLOOR_KB=$((3 * GIB_KB / 2)) # watchdog: stop workload below 1.5 GiB available

meminfo_kb() { awk -v k="$1:" '$1==k{print $2; exit}' /proc/meminfo; }
min() { local m=$1 x; shift; for x in "$@"; do [ "$x" -lt "$m" ] && m=$x; done; echo "$m"; }
max() { local m=$1 x; shift; for x in "$@"; do [ "$x" -gt "$m" ] && m=$x; done; echo "$m"; }
to_bytes() { # "32K" "1024K" "32M" "1G" "512" -> bytes
  local v=${1-0} n u
  [[ $v =~ ^([0-9]+)([KkMmGg]?) ]] || { echo 0; return; }
  n=${BASH_REMATCH[1]}; u=${BASH_REMATCH[2]}
  case $u in K|k) echo $((n*1024));; M|m) echo $((n*1024*1024));; G|g) echo $((n*1024*1024*1024));; *) echo "$n";; esac
}

# ---- tools -------------------------------------------------------------------------
HAVE_STRESS=0; HAVE_GCC=0; HAVE_SYSBENCH=0; HAVE_MEMTESTER=0
cr_need stress-ng stress-ng && HAVE_STRESS=1
if cr_need gcc gcc; then
  HAVE_GCC=1
  if [ ! -f /usr/include/stdio.h ]; then cr_apt_install libc6-dev || true; fi
fi
cr_need sysbench sysbench && HAVE_SYSBENCH=1
[ "$SKIP_MEMTESTER" -eq 0 ] && cr_need memtester memtester && HAVE_MEMTESTER=1
cr_need dmidecode dmidecode >/dev/null || true

# ---- inventory -------------------------------------------------------------------------
cr_detect_topology
cr_detect_sensors

# CPU caches (unique instances, data/unified only)
L1D=0; L2MAX=0; L3INST=0; L3TOTAL=0; CACHETOTAL=0
declare -A SEEN_CACHE=()
for d in /sys/devices/system/cpu/cpu[0-9]*/cache/index[0-9]*; do
  [ -r "$d/level" ] || continue
  read -r lvl < "$d/level"; read -r typ < "$d/type"; read -r sz < "$d/size"
  shared=$(cat "$d/shared_cpu_list" 2>/dev/null || echo "?")
  [ "$typ" = Instruction ] && continue
  key="$lvl:$shared"; [ -n "${SEEN_CACHE[$key]:-}" ] && continue; SEEN_CACHE[$key]=1
  b=$(to_bytes "$sz"); CACHETOTAL=$((CACHETOTAL + b))
  case $lvl in
    1) [ "$b" -gt "$L1D" ] && L1D=$b ;;
    2) [ "$b" -gt "$L2MAX" ] && L2MAX=$b ;;
    3) L3TOTAL=$((L3TOTAL + b)); [ "$b" -gt "$L3INST" ] && L3INST=$b ;;
  esac
done
if [ "$CACHETOTAL" -eq 0 ]; then
  L3TOTAL=$(getconf LEVEL3_CACHE_SIZE 2>/dev/null || echo 0); cr_is_num "$L3TOTAL" || L3TOTAL=0
  [ "$L3TOTAL" -gt 0 ] || { L3TOTAL=$((64*1024*1024)); cr_warn "could not read CPU cache sizes; assuming 64 MiB L3 for sizing"; }
  L3INST=$L3TOTAL; CACHETOTAL=$((L3TOTAL * 2)); L2MAX=$((1024*1024)); L1D=$((32*1024))
fi
MIN_WS=$((4 * CACHETOTAL))   # minimum working set for a valid RAM (not cache) result
cr_log "caches: L1d ${L1D}B L2 ${L2MAX}B L3 ${L3TOTAL}B total ${CACHETOTAL}B -> min RAM working set $((MIN_WS/1048576)) MiB"

# DIMMs
dmidecode -t 17 > "$OUT/dimm-info.txt" 2>&1 || true
dmidecode -t 16 >> "$OUT/dimm-info.txt" 2>&1 || true
DIMM_COUNT=$(awk -F: '/^Memory Device/{d=1} d && /^\tSize:/{ if ($2 !~ /No Module|Not Installed|Unknown/) n++ ; d=0} END{print n+0}' "$OUT/dimm-info.txt")
DIMM_SPEED=$(awk -F: '/Configured (Memory|Clock) Speed:/{ if ($2 ~ /[0-9]/) { gsub(/[^0-9]/,"",$2); print $2; exit } }' "$OUT/dimm-info.txt")
DIMM_RATED=$(awk -F: '/^\tSpeed:/{ if ($2 ~ /[0-9]/) { gsub(/[^0-9]/,"",$2); print $2; exit } }' "$OUT/dimm-info.txt")
DIMM_TYPE=$(awk -F: '/^\tType:/{ gsub(/^ +| +$/,"",$2); if ($2 !~ /Unknown|Other/) { print $2; exit } }' "$OUT/dimm-info.txt")
DIMM_SIZES=$(awk -F: '/^\tSize:/ && $2 !~ /No Module|Not Installed/ {gsub(/^ +/,"",$2); printf "%s%s", sep, $2; sep=", "}' "$OUT/dimm-info.txt")
DIMM_PARTS=$(awk -F: '/Part Number:/ {gsub(/^ +| +$/,"",$2); if ($2!="" && $2 !~ /Not Specified|NO DIMM|Unknown/) { if (!(s[$2]++)) {printf "%s%s", sep, $2; sep=", "} } }' "$OUT/dimm-info.txt")
DIMM_LOCATORS=$(awk -F: '/^\tSize:/{ inst = ($2 !~ /No Module|Not Installed/) } /^\tLocator:/ && inst {gsub(/^ +/,"",$2); printf "%s%s", sep, $2; sep=", "}' "$OUT/dimm-info.txt")
ECC=$(awk -F: '/Error Correction Type:/{gsub(/^ +/,"",$2); print $2; exit}' "$OUT/dimm-info.txt")
: "${DIMM_SPEED:=n/a}" "${DIMM_RATED:=n/a}" "${DIMM_TYPE:=n/a}" "${ECC:=n/a}"
PER_CH_GBS="n/a"; THEO_GBS="n/a"; BW_BOUND_GBS="n/a"
if cr_is_num "$DIMM_SPEED" && [ "$DIMM_COUNT" -gt 0 ]; then
  PER_CH_GBS=$(cr_calc "$DIMM_SPEED*8/1000" "%.1f")
  # Peak if every DIMM sits on its own channel (true for 1-2 DIMM desktops and 1DPC servers).
  THEO_GBS=$(cr_calc "$DIMM_SPEED*8/1000*$DIMM_COUNT" "%.1f")
  BW_BOUND_GBS=$(cr_calc "$THEO_GBS*1.10" "%.1f")   # anything above this cannot be RAM
fi
cr_log "DIMMs: $DIMM_COUNT x ($DIMM_SIZES) $DIMM_TYPE @ ${DIMM_SPEED} MT/s (rated ${DIMM_RATED}) ECC: $ECC; theoretical ${THEO_GBS} GB/s if one DIMM per channel"
# Every DIMM slot (installed ones with full specs; serial numbers deliberately left out)
DIMM_SLOTS=$(grep -c '^Memory Device$' "$OUT/dimm-info.txt" 2>/dev/null); cr_is_num "$DIMM_SLOTS" || DIMM_SLOTS=0
DIMM_MAX_CAP=$(awk -F: '/^\tMaximum Capacity:/{gsub(/^ +/,"",$2); print $2; exit}' "$OUT/dimm-info.txt")
DIMM_LIST_JSON=$(awk -F': ' '
  function esc(v) { gsub(/\\/,"\\\\",v); gsub(/"/,"\\\"",v); return v }
  function flush() { if (!indev) return; if (sz != "" && sz !~ /No Module|Not Installed|Unknown/) {
      printf "%s{ \"locator\": \"%s\", \"bank\": \"%s\", \"size\": \"%s\", \"type\": \"%s\", \"type_detail\": \"%s\", \"form_factor\": \"%s\", \"rated_speed\": \"%s\", \"configured_speed\": \"%s\", \"rank\": \"%s\", \"data_width\": \"%s\", \"total_width\": \"%s\", \"manufacturer\": \"%s\", \"part_number\": \"%s\", \"configured_voltage\": \"%s\" }", \
        (n++ ? ", " : ""), esc(loc), esc(bank), esc(sz), esc(ty), esc(td), esc(ff), esc(sp), esc(cs), esc(rk), esc(dw), esc(tw), esc(mf), esc(pn), esc(cv) }
    indev=0 }
  /^Memory Device$/ { flush(); indev=1; loc=bank=sz=ty=td=ff=sp=cs=rk=dw=tw=mf=pn=cv=""; next }
  /^Handle / { flush(); next }
  indev { k=$1; sub(/^\t/,"",k); v=$2; sub(/[ \t]+$/,"",v)
    if (k=="Locator") loc=v; else if (k=="Bank Locator") bank=v; else if (k=="Size") sz=v; else if (k=="Type") ty=v
    else if (k=="Type Detail") td=v; else if (k=="Form Factor") ff=v; else if (k=="Speed") sp=v
    else if (k=="Configured Memory Speed" || k=="Configured Clock Speed") cs=v; else if (k=="Rank") rk=v
    else if (k=="Data Width") dw=v; else if (k=="Total Width") tw=v; else if (k=="Manufacturer") mf=v
    else if (k=="Part Number") pn=v; else if (k=="Configured Voltage") cv=v }
  END { flush() }' "$OUT/dimm-info.txt")
DIMM_LIST_JSON="[${DIMM_LIST_JSON}]"
# NUMA nodes: CPUs and memory per node
NUMA_JSON=""; NUMA_IDS=()
for nd in /sys/devices/system/node/node[0-9]*; do
  [ -d "$nd" ] || continue
  nid=${nd##*node}; NUMA_IDS+=("$nid")
  ncpus=$(cat "$nd/cpulist" 2>/dev/null); nmem=$(awk '/MemTotal:/{printf "%d", $(NF-1)/1024}' "$nd/meminfo" 2>/dev/null)
  nfree=$(awk '/MemFree:/{printf "%d", $(NF-1)/1024}' "$nd/meminfo" 2>/dev/null)
  NUMA_JSON+="${NUMA_JSON:+, }{ \"node\": $nid, \"cpus\": $(cr_jstr "$ncpus"), \"mem_total_mib\": $(cr_jnum "$nmem"), \"mem_free_mib_start\": $(cr_jnum "$nfree") }"
done
NUMA_JSON="[${NUMA_JSON}]"
[ ${#NUMA_IDS[@]} -gt 0 ] || NUMA_IDS=(0)
HAVE_NUMACTL=0; command -v numactl >/dev/null 2>&1 && HAVE_NUMACTL=1
cr_log "NUMA nodes: ${#NUMA_IDS[@]} (numactl: $HAVE_NUMACTL); DIMM slots: $DIMM_SLOTS, installed: $DIMM_COUNT"

edac_counts() { # prints "ce ue" or "n/a n/a"
  local ce=0 ue=0 f found=0
  for f in /sys/devices/system/edac/mc/mc*/ce_count; do [ -r "$f" ] && { ce=$((ce + $(cat "$f"))); found=1; }; done
  for f in /sys/devices/system/edac/mc/mc*/ue_count; do [ -r "$f" ] && { ue=$((ue + $(cat "$f"))); found=1; }; done
  [ $found -eq 1 ] && printf '%s %s' "$ce" "$ue" || printf 'n/a n/a'
}
edac_dump() { { ls /sys/devices/system/edac/mc/ 2>&1; grep -H . /sys/devices/system/edac/mc/mc*/{ce,ue}_count 2>/dev/null; lsmod 2>/dev/null | grep -i edac; } > "$1"; }
edac_dump "$OUT/edac-pre.txt"
read -r EDAC_CE_PRE EDAC_UE_PRE <<<"$(edac_counts)"

# Guests' possible growth (read-only)
guest_growth_kb() {
  local total=0 conf id pid maxmb rss lim cur g
  for conf in /etc/pve/qemu-server/*.conf; do
    [ -r "$conf" ] || continue
    id=$(basename "$conf" .conf)
    [ -r "/var/run/qemu-server/$id.pid" ] || continue
    read -r pid < "/var/run/qemu-server/$id.pid" || continue
    kill -0 "$pid" 2>/dev/null || continue
    maxmb=$(awk '/^\[/{exit} /^memory:/{v=$2; sub(/^current=/,"",v); sub(/,.*/,"",v); print v; exit}' "$conf")
    cr_is_num "$maxmb" || maxmb=512
    rss=$(awk '/^VmRSS:/{print $2; exit}' "/proc/$pid/status" 2>/dev/null); cr_is_num "$rss" || rss=0
    g=$((maxmb * 1024 - rss)); [ "$g" -gt 0 ] && total=$((total + g))
  done
  for conf in /etc/pve/lxc/*.conf; do
    [ -r "$conf" ] || continue
    id=$(basename "$conf" .conf)
    [ -r "/sys/fs/cgroup/lxc/$id/memory.current" ] || continue
    lim=$(awk '/^\[/{exit} /^memory:/{print $2; exit}' "$conf"); cr_is_num "$lim" || lim=512
    cur=$(cat "/sys/fs/cgroup/lxc/$id/memory.current" 2>/dev/null); cr_is_num "$cur" || cur=0
    g=$((lim * 1024 - cur / 1024)); [ "$g" -gt 0 ] && total=$((total + g))
  done
  echo "$total"
}
GROWTH_KB=$(guest_growth_kb)
MEM_TOTAL_KB=$(meminfo_kb MemTotal); AVAIL_KB=$(meminfo_kb MemAvailable)
SWAP_USED_PRE_KB=$(( $(meminfo_kb SwapTotal) - $(meminfo_kb SwapFree) ))
ARC_KB="n/a"; ARC_NOTE=""
if [ -r /proc/spl/kstat/zfs/arcstats ]; then
  ARC_KB=$(awk '$1=="size"{printf "%d", $3/1024}' /proc/spl/kstat/zfs/arcstats)
  ARC_NOTE="ZFS ARC is $((ARC_KB/1024)) MiB; it is not counted as free memory, so test sizes are conservative"
  cr_log "$ARC_NOTE"
fi
[ $((CR_RUNNING_VMS + CR_RUNNING_CTS)) -gt 0 ] && cr_warn "$CR_RUNNING_VMS VM(s) / $CR_RUNNING_CTS CT(s) running: they use RAM bandwidth (scores may read low) and up to $((GROWTH_KB/1024)) MiB more RAM is kept free for them"

# Stress size
FREE_FOR_TEST_KB=$(( AVAIL_KB - RESERVE_KB - GROWTH_KB ))
# Size cap grows with the time available (big-RAM hosts): enough time to cover
# the tested memory several times with all the verify methods.
if [ "$DURATION" -ge 600 ]; then STRESS_CAP_GIB=256; elif [ "$DURATION" -ge 300 ]; then STRESS_CAP_GIB=128; else STRESS_CAP_GIB=64; fi
STRESS_KB=$(min $(( AVAIL_KB * 40 / 100 )) "$FREE_FOR_TEST_KB")
if [ -n "$STRESS_MB_REQ" ]; then
  STRESS_KB=$(min "$STRESS_KB" $((STRESS_MB_REQ * 1024)))
elif [ "$STRESS_KB" -gt $((STRESS_CAP_GIB * GIB_KB)) ]; then
  cr_log "stress size capped to ${STRESS_CAP_GIB} GiB for a ${DURATION}s run (40% of available would be $((STRESS_KB / GIB_KB)) GiB; longer runs or --stress-mb test more)"
  STRESS_KB=$((STRESS_CAP_GIB * GIB_KB))
fi
[ "$STRESS_KB" -lt 0 ] && STRESS_KB=0
STRESS_MB=$((STRESS_KB / 1024))
cr_log "memory: total $((MEM_TOTAL_KB/1024)) MiB, available $((AVAIL_KB/1024)) MiB, guest growth $((GROWTH_KB/1024)) MiB -> stress size $STRESS_MB MiB"

{
  echo "MemTotal_kB=$MEM_TOTAL_KB MemAvailable_kB=$AVAIL_KB SwapUsed_kB=$SWAP_USED_PRE_KB ARC_kB=$ARC_KB"
  echo "guest_growth_kB=$GROWTH_KB reserve_kB=$RESERVE_KB stress_MiB=$STRESS_MB"
  echo "running VMs=$CR_RUNNING_VMS CTs=$CR_RUNNING_CTS"
  echo "caches: L1d=$L1D L2max=$L2MAX L3inst=$L3INST L3total=$L3TOTAL all=$CACHETOTAL min_ws=$MIN_WS"
  echo "dimms=$DIMM_COUNT sizes=[$DIMM_SIZES] type=$DIMM_TYPE configured=$DIMM_SPEED rated=$DIMM_RATED ecc=$ECC parts=[$DIMM_PARTS] locators=[$DIMM_LOCATORS]"
  echo "theoretical_GBps(one DIMM per channel)=$THEO_GBS per_channel=$PER_CH_GBS bound=$BW_BOUND_GBS"
  echo "cpu: $CR_MODEL cores=$CR_CORES threads=$CR_NPROC hybrid=$CR_HYBRID"
  echo "tools: stress-ng=$(stress-ng --version 2>/dev/null | head -1) gcc=$(gcc -dumpfullversion 2>/dev/null) sysbench=$(sysbench --version 2>/dev/null) memtester=$HAVE_MEMTESTER"
  free -m
} > "$OUT/inventory.txt" 2>&1

# bandwidth validity check: valid if working set >= MIN_WS and below the physical bound
# sets BW_OK (true|false) and BW_REASON; call directly, not in $(...)
bw_check() { # GBps working_set_bytes
  BW_OK=false; BW_REASON=""
  if ! cr_is_num "${1-}"; then BW_REASON="no result"; return; fi
  if [ "${2:-0}" -lt "$MIN_WS" ]; then BW_REASON="working set $(( ${2:-0}/1048576 )) MiB < 4x CPU cache ($((MIN_WS/1048576)) MiB): cache-resident, not RAM"; return; fi
  if cr_is_num "$BW_BOUND_GBS" && awk -v v="$1" -v b="$BW_BOUND_GBS" 'BEGIN{exit !(v>b)}'; then
    BW_REASON="exceeds the DIMMs' theoretical peak ($THEO_GBS GB/s): measurement artefact (cache), not RAM"; return
  fi
  BW_OK=true
}

# ---- compile STREAM + latency --------------------------------------------------------------
STREAM_BIN=""; LAT_BIN=""; STREAM_OMP=0
if [ "$HAVE_GCC" -eq 1 ] && [ -r "$SCRIPT_DIR/stream.c" ] && [ -r "$SCRIPT_DIR/latency.c" ]; then
  for flags in "-O3 -march=native -fopenmp" "-O3 -fopenmp" "-O3 -march=native" "-O3"; do
    # shellcheck disable=SC2086
    if gcc $flags -o "$OUT/bin/stream" "$SCRIPT_DIR/stream.c" -lm >> "$OUT/compile.log" 2>&1; then
      STREAM_BIN="$OUT/bin/stream"; [[ $flags == *fopenmp* ]] && STREAM_OMP=1
      cr_log "compiled stream with: $flags"; break
    fi
  done
  gcc -O2 -o "$OUT/bin/latency" "$SCRIPT_DIR/latency.c" >> "$OUT/compile.log" 2>&1 && LAT_BIN="$OUT/bin/latency"
  [ -z "$STREAM_BIN" ] && cr_warn "stream.c failed to compile (see compile.log)"
  [ -z "$LAT_BIN" ] && cr_warn "latency.c failed to compile (see compile.log)"
  [ -n "$STREAM_BIN" ] && [ "$STREAM_OMP" -eq 0 ] && cr_warn "OpenMP not available to gcc: STREAM runs single-threaded only"
else
  [ "$HAVE_GCC" -eq 0 ] && cr_log "gcc not available"
fi

DMESG_MARK=$(cr_dmesg_mark)
CSV="$OUT/telemetry-1s.csv"
CR_KILL_FILE="$OUT/.killpid"; : > "$CR_KILL_FILE"
cr_sampler_start "$CSV" "$OUT"
cr_phase idle; sleep 3

# ---- 1. stress phase ------------------------------------------------------------------------
ST_RC="n/a"; ST_OPS="n/a"; ST_PASSED="n/a"; ST_FAILED="n/a"; ST_WORKERS=0; ST_TESTED_MB="n/a"; ST_ERRLINES=0; ST_SEMANTICS="n/a"; WATCHDOG=0
if [ "$HAVE_STRESS" -eq 0 ]; then
  cr_skip "stress-vm" "stress-ng not installed and could not be installed"
elif [ "$STRESS_MB" -lt 256 ]; then
  cr_skip "stress-vm" "not enough free RAM to test safely (would be ${STRESS_MB} MiB; host keeps 4 GiB + guest growth free)"
else
  # Probe --vm-bytes semantics (total vs per-worker) with a harmless 2 x 32/64 MiB run
  probe=$(timeout 30 stress-ng --vm 2 --vm-bytes 64M --vm-keep --timeout 2s -v 2>&1)
  per=$(grep -oE 'using [0-9.]+[KMG]? per stressor instance' <<<"$probe" | head -1 | grep -oE '[0-9.]+[KMG]?')
  ST_SEMANTICS=per-worker
  if [ -n "$per" ]; then
    per_mb=$(awk -v v="$per" 'BEGIN{n=v+0; u=substr(v,length(v)); if(u=="G")n*=1024; else if(u=="K")n/=1024; printf "%d", n}')
    [ "$per_mb" -lt 48 ] && ST_SEMANTICS=total
  fi
  ST_WORKERS=$(min "$CR_CORES" $((STRESS_MB / 64)))
  [ "$ST_WORKERS" -lt 1 ] && ST_WORKERS=1
  if [ "$ST_SEMANTICS" = total ]; then VMB="${STRESS_MB}M"; else VMB="$((STRESS_MB / ST_WORKERS))M"; fi
  cr_log "STRESS: stress-ng --vm $ST_WORKERS --vm-bytes $VMB (semantics: $ST_SEMANTICS => ~${STRESS_MB} MiB total) --vm-method all --verify for ${DURATION}s"
  cr_phase stress
  timeout --kill-after=30 $((DURATION + 180)) stress-ng --vm "$ST_WORKERS" --vm-bytes "$VMB" --vm-method all --verify --vm-keep \
    --timeout "${DURATION}s" --metrics --times --tz -Y "$OUT/stress-vm.yaml" > "$OUT/stress-vm.log" 2>&1 &
  SPID=$!; echo "$SPID" > "$CR_KILL_FILE"
  wait "$SPID"; ST_RC=$?
  : > "$CR_KILL_FILE"
  cr_phase cooldown
  tail -25 "$OUT/stress-vm.log"
  ST_OPS=$(awk '/bogo-ops-per-second-real-time:/{print $2; exit}' "$OUT/stress-vm.yaml" 2>/dev/null)
  cr_is_num "$ST_OPS" || ST_OPS=$(awk '/metrc:/ && $4=="vm" && $5 ~ /^[0-9]+$/ {print $9; exit}' "$OUT/stress-vm.log")
  cr_is_num "$ST_OPS" || ST_OPS="n/a"
  ST_PASSED=$(grep -oE 'passed: [0-9]+' "$OUT/stress-vm.log" | head -1 | awk '{print $2}'); : "${ST_PASSED:=n/a}"
  ST_FAILED=$(grep -oE 'failed: [0-9]+' "$OUT/stress-vm.log" | head -1 | awk '{print $2}'); : "${ST_FAILED:=n/a}"
  tot=$(grep -oE '\(total [0-9.]+[KMG]?' "$OUT/stress-vm.log" | head -1 | grep -oE '[0-9.]+[KMG]?')
  if [ -n "$tot" ]; then
    ST_TESTED_MB=$(awk -v v="$tot" 'BEGIN{n=v+0; u=substr(v,length(v)); if(u=="G")n*=1024; else if(u=="K")n/=1024; printf "%d", n}')
  else
    if [ "$ST_SEMANTICS" = total ]; then ST_TESTED_MB=${VMB%M}; else ST_TESTED_MB=$(( ${VMB%M} * ST_WORKERS )); fi
  fi
  ST_ERRLINES=$(grep -iE 'fail:|miscompar|bit error|corrupt|verif.*(fail|error)' "$OUT/stress-vm.log" | grep -vcE 'failed: 0|untrustworthy: 0')
  [ -s "$OUT/watchdog.txt" ] && { WATCHDOG=1; cr_warn "memory watchdog stopped the stress early (MemAvailable fell below 1.5 GiB) - see watchdog.txt"; }
  cr_log "stress-vm rc=$ST_RC ops/s=$ST_OPS passed=$ST_PASSED failed=$ST_FAILED tested=${ST_TESTED_MB} MiB error-lines=$ST_ERRLINES"
  if [ "$ST_ERRLINES" -gt 0 ] || { cr_is_num "$ST_FAILED" && [ "$ST_FAILED" -gt 0 ]; }; then
    cr_error "stress-ng vm --verify reported failures/miscompares (possible memory error) - see stress-vm.log"
  elif [ "$ST_RC" -ne 0 ] && [ "$WATCHDOG" -eq 0 ]; then
    cr_warn "stress-ng exited with rc=$ST_RC but reported no miscompares - see stress-vm.log"
  fi
fi
sleep 5

# current safe working budget for benchmarks (re-read; guests may have changed)
bench_cap_kb() {
  local a; a=$(meminfo_kb MemAvailable)
  min $(( a * 25 / 100 )) $(( a - RESERVE_KB - GROWTH_KB ))
}

# ---- 2. STREAM -----------------------------------------------------------------------------
declare -a STREAM_JSON=()
BEST_TRIAD="n/a"; BEST_TRIAD_LABEL=""; STREAM_ERR=0
if [ -n "$STREAM_BIN" ]; then
  CAP_KB=$(bench_cap_kb)
  WANT_ARR=$(max $((MIN_WS)) $((800 * 1000 * 1000)))
  ARR=$(min "$WANT_ARR" $(( CAP_KB * 1024 / 3 )))
  if [ "$ARR" -lt $((64 * 1024 * 1024)) ]; then
    cr_skip "stream" "not enough free RAM for STREAM arrays"
  else
    ELEM=$((ARR / 8)); WS=$((ARR * 3))
    [ "$ARR" -lt "$MIN_WS" ] && cr_warn "STREAM arrays limited to $((ARR/1048576)) MiB by free RAM (< 4x cache): results marked invalid"
    # P-core first threads (hybrid) and per-run configs
    PPLACES=""
    if [ "$CR_HYBRID" -eq 1 ]; then
      PPLACES=$(lscpu -p=CPU,CORE 2>/dev/null | grep -v '^#' | awk -F, -v s=" $CR_PSET " 'index(s," "$1" ") && !seen[$2]++ {printf "%s{%s}", sep, $1; sep=","}')
    fi
    RUNS=("1t|1|{$CR_FIRST_PCPU}|true")
    if [ "$STREAM_OMP" -eq 1 ]; then
      [ -n "$PPLACES" ] && RUNS+=("pcores|$CR_PCORES|$PPLACES|true")
      RUNS+=("cores|$CR_CORES|cores|spread")
      [ "$CR_NPROC" -gt "$CR_CORES" ] && RUNS+=("all|$CR_NPROC|threads|spread")
      # one run per NUMA node: threads = that node's physical cores, pinned there
      if [ ${#NUMA_IDS[@]} -gt 1 ]; then
        for nid in "${NUMA_IDS[@]}"; do
          NPL=$(lscpu -p=CPU,CORE,NODE 2>/dev/null | grep -v '^#' | awk -F, -v n="$nid" '$3==n && !seen[$2]++ {printf "%s{%s}", sep, $1; sep=","}')
          NTH=$(printf '%s' "$NPL" | tr ',' '\n' | grep -c '{')
          [ "${NTH:-0}" -ge 1 ] && RUNS+=("node$nid|$NTH|$NPL|true|$nid")
        done
      fi
    else
      cr_skip "stream-multithread" "built without OpenMP"
    fi
    for r in "${RUNS[@]}"; do
      IFS='|' read -r lbl thr places bind node <<<"$r"
      cr_phase "stream-$lbl"
      cr_log "STREAM $lbl: $thr thread(s), 3 x $((ARR/1048576)) MiB arrays${node:+ (NUMA node $node)}"
      NUMA_PFX=()
      [ -n "$node" ] && [ "$HAVE_NUMACTL" -eq 1 ] && NUMA_PFX=(numactl --membind="$node")
      timeout --kill-after=10 300 "${NUMA_PFX[@]+"${NUMA_PFX[@]}"}" env OMP_NUM_THREADS="$thr" OMP_PLACES="$places" OMP_PROC_BIND="$bind" \
        "$STREAM_BIN" "$ELEM" 10 > "$OUT/stream-$lbl.txt" 2>&1
      rc=$?
      cat "$OUT/stream-$lbl.txt"
      triad=$(awk '/^Triad/{split($2,a,"="); printf "%.1f", a[2]/1000; exit}' "$OUT/stream-$lbl.txt")
      copy=$(awk '/^Copy/{split($2,a,"="); printf "%.1f", a[2]/1000; exit}' "$OUT/stream-$lbl.txt")
      valid_line=$(grep -o 'validation=[a-zA-Z]*' "$OUT/stream-$lbl.txt" | cut -d= -f2)
      bw_check "$triad" "$ARR"; v=$BW_OK; reason=$BW_REASON
      if [ "$valid_line" = FAILED ]; then v=false; reason="STREAM self-check FAILED (wrong values read back)"; STREAM_ERR=1
        cr_error "STREAM $lbl: values read back were wrong (possible memory error) - see stream-$lbl.txt"; fi
      [ "$rc" -ne 0 ] && [ "$valid_line" != FAILED ] && { v=false; reason="rc=$rc"; cr_warn "STREAM $lbl exited rc=$rc"; }
      ref=$THEO_GBS
      [ -n "$node" ] && cr_is_num "$THEO_GBS" && ref=$(cr_calc "$THEO_GBS/${#NUMA_IDS[@]}" "%.1f")
      STREAM_JSON+=("{ \"run\": $(cr_jstr "$lbl"), \"threads\": $(cr_jnum "$thr"), \"numa_node\": $(cr_jnum "$node"), \"triad_gbs\": $(cr_jnum "$triad"), \"copy_gbs\": $(cr_jnum "$copy"), \"array_mib\": $((ARR/1048576)), \"valid\": $v, \"invalid_reason\": $(cr_jstr "$reason"), \"reference_gbs\": $(cr_jnum "$ref"), \"pct_of_theoretical\": $(cr_jnum "$(cr_pct "$triad" "$ref")") }")
      # per-node runs are reported, the best-of score is whole-machine bandwidth
      if [ -z "$node" ] && [ "$v" = true ] && cr_is_num "$triad"; then
        if ! cr_is_num "$BEST_TRIAD" || awk -v a="$triad" -v b="$BEST_TRIAD" 'BEGIN{exit !(a>b)}'; then BEST_TRIAD=$triad; BEST_TRIAD_LABEL=$lbl; fi
      fi
      cr_phase rest; sleep 3
    done
  fi
else
  cr_skip "stream" "gcc / stream.c not available"
fi

# ---- 3. stress-ng stream ---------------------------------------------------------------------
SNG_GBS="n/a"; SNG_READ="n/a"; SNG_WRITE="n/a"; SNG_VALID=false; SNG_REASON=""
if [ "$HAVE_STRESS" -eq 1 ]; then
  cr_phase sng-stream
  L3OPT=()
  [ "$L3TOTAL" -ge 1048576 ] && L3OPT=(--stream-l3-size "$(( (L3TOTAL + 1048575) / 1048576 ))M")
  cr_log "stress-ng --stream $CR_NPROC ${L3OPT[*]+"${L3OPT[*]}"}, 20 s"
  timeout --kill-after=10 120 stress-ng --stream "$CR_NPROC" "${L3OPT[@]+"${L3OPT[@]}"}" --timeout 20s --metrics -Y "$OUT/stress-stream.yaml" > "$OUT/stress-stream.log" 2>&1
  read -r SNG_READ SNG_WRITE <<<"$(awk '/memory rate:/{ for(i=1;i<=NF;i++){ if($(i+1)=="MB" && $(i+2) ~ /^read/) r+=$i; if($(i+1)=="MB" && $(i+2) ~ /^write/) w+=$i } n++ } END{ if(n) printf "%.1f %.1f", r/1000, w/1000; else print "n/a n/a" }' "$OUT/stress-stream.log")"
  if ! cr_is_num "$SNG_READ"; then
    read -r SNG_READ SNG_WRITE <<<"$(awk -v n="$CR_NPROC" '/MB per sec memory read rate/{for(i=1;i<=NF;i++) if($i ~ /^[0-9.]+$/ && $(i+1)=="MB"){r=$i}} /MB per sec memory write rate/{for(i=1;i<=NF;i++) if($i ~ /^[0-9.]+$/ && $(i+1)=="MB"){w=$i}} END{ if(r!="") printf "%.1f %.1f", r*n/1000, w*n/1000; else print "n/a n/a"}' "$OUT/stress-stream.log")"
  fi
  if cr_is_num "$SNG_READ" && cr_is_num "$SNG_WRITE"; then
    SNG_GBS=$(cr_calc "$SNG_READ+$SNG_WRITE" "%.1f")
    # stress-ng sizes its arrays from the L3 size we pass: always >= L3, treat the bound check as the validity test
    bw_check "$SNG_GBS" "$MIN_WS"; SNG_VALID=$BW_OK; SNG_REASON=$BW_REASON
  fi
  cr_log "stress-ng stream: read $SNG_READ + write $SNG_WRITE = $SNG_GBS GB/s (valid=$SNG_VALID)"
  cr_phase rest; sleep 3
fi

# ---- 4. sysbench memory ------------------------------------------------------------------------
SB1_GBS="n/a"; SB1_VALID=false; SB1_REASON=""; SBR_GBS="n/a"; SBR_VALID=false; SBR_REASON=""; SB_BLK_MB=0
if [ "$HAVE_SYSBENCH" -eq 1 ]; then
  CAP_KB=$(bench_cap_kb)
  SB_BLK_MB=$(max 1024 $(( (MIN_WS + 1048575) / 1048576 )))
  SB_BLK_MB=$(min "$SB_BLK_MB" $(( CAP_KB / 1024 )))
  if [ "$SB_BLK_MB" -lt 64 ]; then
    cr_skip "sysbench-memory" "not enough free RAM"
  else
    PIN=(); [ "$CR_HYBRID" -eq 1 ] && command -v taskset >/dev/null 2>&1 && PIN=(taskset -c "$CR_FIRST_PCPU")
    cr_phase sysbench-1t-seq-read
    cr_log "sysbench memory 1 thread seq read, block ${SB_BLK_MB} MiB, 10 s"
    timeout 60 "${PIN[@]+"${PIN[@]}"}" sysbench memory --threads=1 --memory-block-size="${SB_BLK_MB}M" --memory-total-size=100000G \
      --memory-oper=read --memory-access-mode=seq --time=10 run > "$OUT/sysbench-1t-seq-read.txt" 2>&1
    SB1_GBS=$(grep -oE '\(([0-9.]+) MiB/sec\)' "$OUT/sysbench-1t-seq-read.txt" | head -1 | grep -oE '[0-9.]+' | awk '{printf "%.1f", $1*1.048576/1000}')
    bw_check "$SB1_GBS" $((SB_BLK_MB * 1048576)); SB1_VALID=$BW_OK; SB1_REASON=$BW_REASON
    cr_phase rest; sleep 2
    SBT=$CR_CORES
    SBR_BLK=$(min 512 $(( CAP_KB / 1024 / SBT )))
    if [ "$SBR_BLK" -ge 16 ]; then
      cr_phase sysbench-mt-rnd-read
      cr_log "sysbench memory $SBT threads random read, block ${SBR_BLK} MiB/thread, 10 s (informational)"
      timeout 60 sysbench memory --threads="$SBT" --memory-block-size="${SBR_BLK}M" --memory-total-size=100000G \
        --memory-oper=read --memory-access-mode=rnd --time=10 run > "$OUT/sysbench-mt-rnd-read.txt" 2>&1
      SBR_GBS=$(grep -oE '\(([0-9.]+) MiB/sec\)' "$OUT/sysbench-mt-rnd-read.txt" | head -1 | grep -oE '[0-9.]+' | awk '{printf "%.1f", $1*1.048576/1000}')
      bw_check "$SBR_GBS" $((SBR_BLK * SBT * 1048576)); SBR_VALID=$BW_OK; SBR_REASON=$BW_REASON
    fi
    : "${SB1_GBS:=n/a}" "${SBR_GBS:=n/a}"
    cr_log "sysbench: 1t seq read $SB1_GBS GB/s (valid=$SB1_VALID), ${SBT}t rnd read $SBR_GBS GB/s (valid=$SBR_VALID)"
    cr_phase rest; sleep 2
  fi
else
  cr_skip "sysbench-memory" "sysbench not installed and could not be installed"
fi

# ---- 5. latency ladder -----------------------------------------------------------------------------
declare -a LAT_JSON=() NUMA_LAT_JSON=()
DRAM_NS="n/a"; DRAM_KB=0
if [ -n "$LAT_BIN" ]; then
  CAP_KB=$(bench_cap_kb); LAT_MAX_KB=$(( CAP_KB * 8 / 9 / 2 ))   # buffer + 1/8 index, halved for margin
  SIZES=$( { echo $((L1D/2/1024)); echo $((L2MAX/2/1024)); echo $((L3INST/2/1024)); echo $((4*L3TOTAL/1024)); echo 262144; echo 1048576; echo 4194304; } \
           | awk -v m="$LAT_MAX_KB" '$1>=4 && $1<=m' | sort -n | uniq)
  DRAM_MIN_KB=$(max 262144 $((8 * L3TOTAL / 1024)))
  cr_phase latency
  : > "$OUT/latency.txt"
  for kb in $SIZES; do
    if [ "$kb" -le $((L1D/1024)) ]; then lvl=L1; elif [ "$kb" -le $((L2MAX/1024)) ]; then lvl=L2
    elif [ "$kb" -le $((L3INST/1024)) ]; then lvl=L3; elif [ "$kb" -ge "$DRAM_MIN_KB" ]; then lvl=DRAM; else lvl="L3/DRAM mix"; fi
    line=$(timeout 180 taskset -c "$CR_FIRST_PCPU" "$LAT_BIN" "$kb" 2>&1 || timeout 180 "$LAT_BIN" "$kb" 2>&1)
    echo "$line level=$lvl" | tee -a "$OUT/latency.txt"
    ns=$(grep -oE 'ns_per_load=[0-9.]+' <<<"$line" | cut -d= -f2)
    LAT_JSON+=("{ \"buffer_kb\": $kb, \"level\": $(cr_jstr "$lvl"), \"ns\": $(cr_jnum "$ns") }")
    if [ "$lvl" = DRAM ] && cr_is_num "$ns"; then DRAM_NS=$ns; DRAM_KB=$kb; fi
  done
  [ "$DRAM_NS" = n/a ] && cr_warn "no DRAM-sized latency buffer fitted in free RAM (need >= $((DRAM_MIN_KB/1024)) MiB); DRAM latency not measured"
  # local vs remote DRAM latency on multi-NUMA hosts (needs numactl; not installed by this script)
  if [ ${#NUMA_IDS[@]} -gt 1 ] && [ "$DRAM_KB" -gt 0 ]; then
    if [ "$HAVE_NUMACTL" -eq 1 ]; then
      for nid in "${NUMA_IDS[@]}"; do
        line=$(timeout 180 numactl --cpunodebind="${NUMA_IDS[0]}" --membind="$nid" "$LAT_BIN" "$DRAM_KB" 2>&1)
        ns=$(grep -oE 'ns_per_load=[0-9.]+' <<<"$line" | cut -d= -f2)
        echo "numa cpu_node=${NUMA_IDS[0]} mem_node=$nid $line" | tee -a "$OUT/latency.txt"
        NUMA_LAT_JSON+=("{ \"cpu_node\": ${NUMA_IDS[0]}, \"mem_node\": $nid, \"ns\": $(cr_jnum "$ns") }")
      done
    else
      cr_skip "numa-latency" "numactl not installed (local vs remote DRAM latency not measured)"
    fi
  fi
  cr_log "DRAM latency: $DRAM_NS ns (buffer $((DRAM_KB/1024)) MiB)"
  cr_phase rest; sleep 2
else
  cr_skip "latency" "gcc / latency.c not available"
fi

# ---- 6. memtester -------------------------------------------------------------------------------------
MT_MB=0; MT_CAP=0; MT_RC="n/a"; MT_OK=0; MT_FAIL=0; MT_STATE="skipped"
if [ "$SKIP_MEMTESTER" -eq 1 ]; then
  cr_skip "memtester" "--skip-memtester given"
elif [ "$HAVE_MEMTESTER" -eq 0 ]; then
  cr_skip "memtester" "memtester not installed and could not be installed"
else
  CAP_KB=$(bench_cap_kb)
  MT_MB=$(min 4096 $(( $(meminfo_kb MemAvailable) / 1024 / 10 )) $(( CAP_KB / 1024 )))
  MT_CAP=$(max 30 "$(min "$DURATION" 300)")
  if [ "$MT_MB" -lt 64 ]; then
    cr_skip "memtester" "not enough free RAM"
  else
    cr_phase memtester
    cr_log "memtester ${MT_MB}M, 1 pass, time cap ${MT_CAP}s"
    timeout --kill-after=10 "$MT_CAP" memtester "${MT_MB}M" 1 > "$OUT/memtester.raw" 2>&1
    MT_RC=$?
    tr '\b' '\n' < "$OUT/memtester.raw" | sed 's/ *$//' | grep -v '^$' | grep -vE '^(setting|testing) +[0-9]+$|^[-\\|/]$' > "$OUT/memtester.txt"
    rm -f "$OUT/memtester.raw"
    echo "memtester rc=$MT_RC (124 = stopped at the ${MT_CAP}s time cap)" >> "$OUT/memtester.txt"
    MT_OK=$(grep -cE '(^|:[[:space:]]*)ok$' "$OUT/memtester.txt"); MT_FAIL=$(grep -ciE 'FAILURE' "$OUT/memtester.txt")
    if [ "$MT_FAIL" -gt 0 ] || { [ "$MT_RC" -ne 0 ] && [ "$MT_RC" -ne 124 ] && [ "$MT_RC" -ne 137 ] && [ $(( MT_RC & 6 )) -ne 0 ]; }; then
      MT_STATE=fail; cr_error "memtester reported FAILURE (memory error) - see memtester.txt"
    elif [ "$MT_RC" -eq 124 ] || [ "$MT_RC" -eq 137 ]; then MT_STATE=partial-pass
    elif [ "$MT_RC" -eq 0 ]; then MT_STATE=pass
    else MT_STATE=error; cr_warn "memtester exited rc=$MT_RC (allocation/lock problem?) - see memtester.txt"; fi
    cr_log "memtester: $MT_STATE, $MT_OK subtests ok, $MT_FAIL failures"
    tail -5 "$OUT/memtester.txt"
  fi
fi
cr_phase rest; sleep 3
cr_sampler_stop
rm -f "$CR_KILL_FILE"

# ---- 7. health post ------------------------------------------------------------------------------------
edac_dump "$OUT/edac-post.txt"
read -r EDAC_CE_POST EDAC_UE_POST <<<"$(edac_counts)"
EDAC_DELTA="n/a"
if cr_is_num "$EDAC_CE_PRE" && cr_is_num "$EDAC_CE_POST"; then
  EDAC_DELTA=$(( EDAC_CE_POST - EDAC_CE_PRE + EDAC_UE_POST - EDAC_UE_PRE ))
  [ "$EDAC_DELTA" -gt 0 ] && cr_error "EDAC error counters increased by $EDAC_DELTA (CE $EDAC_CE_PRE->$EDAC_CE_POST, UE $EDAC_UE_PRE->$EDAC_UE_POST)"
fi
read -r HWERR SOFTERR <<<"$(cr_dmesg_new "$DMESG_MARK" "$OUT/dmesg-new.txt")"
[ "${HWERR:-0}" -gt 0 ] 2>/dev/null && cr_error "$HWERR kernel hardware-error line(s) (MCE/EDAC) during the test - see dmesg-new-hw-errors.txt"
[ "${SOFTERR:-0}" -gt 0 ] 2>/dev/null && cr_warn "$SOFTERR kernel warning line(s) (OOM/lockup) during the test - see dmesg-new-hw-errors.txt"
SWAP_MAX=$(cr_stat "$CSV" '.*' "$COL_SWAP" max)
if cr_is_num "$SWAP_MAX" && [ "${SWAP_MAX%.*}" -gt $(( SWAP_USED_PRE_KB / 1024 + 256 )) ]; then
  cr_warn "swap use rose from $((SWAP_USED_PRE_KB/1024)) MiB to ${SWAP_MAX} MiB during the test"
fi

s() { cr_stat "$CSV" "$1" "$2" "$3"; }
IDLE_USED=$(s idle "$COL_USED" avg)
ST_USED_MAX=$(s stress "$COL_USED" max); ST_AVAIL_MIN=$(s stress "$COL_AVAIL" min)
ST_W_AVG=$(s stress "$COL_PKGW" avg); ST_W_MAX=$(s stress "$COL_PKGW" max)
ST_T_AVG=$(s stress "$COL_TEMP" avg); ST_T_MAX=$(s stress "$COL_TEMP" max); ST_MHZ=$(s stress "$COL_MHZ" avg)
ST_N=$(s stress "$COL_USED" n)
ALL_T_MAX=$(s '.*' "$COL_TEMP" max); ALL_W_MAX=$(s '.*' "$COL_PKGW" max)
ST_RSS_DELTA="n/a"; cr_is_num "$ST_USED_MAX" && cr_is_num "$IDLE_USED" && ST_RSS_DELTA=$(cr_calc "$ST_USED_MAX-$IDLE_USED" "%.0f")

BEST_PCT=$(cr_pct "$BEST_TRIAD" "$THEO_GBS")
SOCK_STRESS_JSON=$(cr_sock_json "$OUT/telemetry-socket-1s.csv" stress)
SOCK_STREAM_JSON=$(cr_sock_json "$OUT/telemetry-socket-1s.csv" 'stream-.*')
STATUS=ok
[ ${#CR_WARNINGS[@]} -gt 0 ] && STATUS=warn
[ ${#CR_ERRORS[@]} -gt 0 ] && STATUS=fail
INTEGRITY=pass
{ [ "$ST_ERRLINES" -gt 0 ] || [ "$STREAM_ERR" -eq 1 ] || [ "$MT_STATE" = fail ] || { cr_is_num "$EDAC_DELTA" && [ "$EDAC_DELTA" -gt 0 ]; } || [ "${HWERR:-0}" -gt 0 ]; } && INTEGRITY=fail
{ [ "$HAVE_STRESS" -eq 0 ] || [ "$STRESS_MB" -lt 256 ]; } && [ "$INTEGRITY" = pass ] && INTEGRITY=not-tested
FINISHED=$(date -Is)

join_json() { local IFS=','; printf '[%s]' "$*"; }

{
  printf '{\n'
  printf '  "part": "ram",\n  "schema": 1,\n  "status": %s,\n  "data_integrity": %s,\n' "$(cr_jstr "$STATUS")" "$(cr_jstr "$INTEGRITY")"
  printf '  "started": %s,\n  "finished": %s,\n  "duration_s": %s,\n' "$(cr_jstr "$STARTED")" "$(cr_jstr "$FINISHED")" "$DURATION"
  printf '  "host": {\n'
  printf '    "mem_total_mib": %s, "mem_available_mib_start": %s, "swap_used_mib_start": %s, "zfs_arc_mib": %s,\n' $((MEM_TOTAL_KB/1024)) $((AVAIL_KB/1024)) $((SWAP_USED_PRE_KB/1024)) "$(cr_jnum "$( cr_is_num "$ARC_KB" && echo $((ARC_KB/1024)) )")"
  printf '    "dimm_count": %s, "dimm_sizes": %s, "dimm_type": %s, "configured_mts": %s, "rated_mts": %s,\n' "$DIMM_COUNT" "$(cr_jstr "$DIMM_SIZES")" "$(cr_jstr "$DIMM_TYPE")" "$(cr_jnum "$DIMM_SPEED")" "$(cr_jnum "$DIMM_RATED")"
  printf '    "dimm_parts": %s, "dimm_locators": %s, "ecc": %s,\n' "$(cr_jstr "$DIMM_PARTS")" "$(cr_jstr "$DIMM_LOCATORS")" "$(cr_jstr "$ECC")"
  printf '    "theoretical_gbs_one_dimm_per_channel": %s, "per_channel_gbs": %s,\n' "$(cr_jnum "$THEO_GBS")" "$(cr_jnum "$PER_CH_GBS")"
  printf '    "cpu_model": %s, "cores": %s, "threads": %s, "hybrid": %s,\n' "$(cr_jstr "$CR_MODEL")" "$CR_CORES" "$CR_NPROC" "$(cr_jbool "$CR_HYBRID")"
  printf '    "cache_bytes": { "l1d": %s, "l2_max": %s, "l3_instance": %s, "l3_total": %s, "all": %s }, "min_valid_working_set_mib": %s,\n' "$L1D" "$L2MAX" "$L3INST" "$L3TOTAL" "$CACHETOTAL" $((MIN_WS/1048576))
  printf '    "sockets": %s, "numa_node_count": %s, "numa_nodes": %s,\n' "$(cr_jnum "$CR_SOCKETS")" "${#NUMA_IDS[@]}" "$NUMA_JSON"
  printf '    "dimm_slots": %s, "dimm_max_capacity": %s, "dimms": %s,\n' "$DIMM_SLOTS" "$(cr_jstr "$DIMM_MAX_CAP")" "$DIMM_LIST_JSON"
  printf '    "running_vms": %s, "running_cts": %s, "guest_growth_reserved_mib": %s\n  },\n' "$CR_RUNNING_VMS" "$CR_RUNNING_CTS" $((GROWTH_KB/1024))
  printf '  "stress": {\n'
  printf '    "tool": "stress-ng --vm --vm-method all --verify --vm-keep", "seconds": %s, "workers": %s, "vm_bytes_arg": %s, "vm_bytes_semantics": %s,\n' "$DURATION" "$ST_WORKERS" "$(cr_jstr "${VMB:-n/a}")" "$(cr_jstr "$ST_SEMANTICS")"
  printf '    "size_cap_gib": %s, "planned_mib": %s, "tested_mib": %s, "mem_used_rise_mib": %s, "mem_available_min_mib": %s,\n' "$( [ -n "$STRESS_MB_REQ" ] && echo null || echo "$STRESS_CAP_GIB")" "$STRESS_MB" "$(cr_jnum "$ST_TESTED_MB")" "$(cr_jnum "$ST_RSS_DELTA")" "$(cr_jnum "$ST_AVAIL_MIN")"
  printf '    "rc": %s, "bogo_ops_per_s": %s, "workers_passed": %s, "workers_failed": %s, "verify_error_lines": %s, "watchdog_fired": %s,\n' "$(cr_jnum "$ST_RC")" "$(cr_jnum "$ST_OPS")" "$(cr_jnum "$ST_PASSED")" "$(cr_jnum "$ST_FAILED")" "$ST_ERRLINES" "$(cr_jbool "$WATCHDOG")"
  printf '    "cpu_pkg_w_avg": %s, "cpu_pkg_w_max": %s, "cpu_temp_c_avg": %s, "cpu_temp_c_max": %s, "avg_mhz": %s, "samples": %s\n  },\n' "$(cr_jnum "$ST_W_AVG")" "$(cr_jnum "$ST_W_MAX")" "$(cr_jnum "$ST_T_AVG")" "$(cr_jnum "$ST_T_MAX")" "$(cr_jnum "$ST_MHZ")" "$(cr_jnum "$ST_N")"
  printf '  "per_socket": { "telemetry_csv": "telemetry-socket-1s.csv", "stress": %s, "stream": %s },\n' "$SOCK_STRESS_JSON" "$SOCK_STREAM_JSON"
  printf '  "stream": %s,\n' "$(join_json "${STREAM_JSON[@]+"${STREAM_JSON[@]}"}")"
  printf '  "stream_best_triad_gbs": %s, "stream_best_run": %s, "stream_best_pct_of_theoretical": %s,\n' "$(cr_jnum "$BEST_TRIAD")" "$(cr_jstr "$BEST_TRIAD_LABEL")" "$(cr_jnum "$BEST_PCT")"
  printf '  "stress_ng_stream": { "read_gbs": %s, "write_gbs": %s, "total_gbs": %s, "valid": %s, "invalid_reason": %s },\n' "$(cr_jnum "$SNG_READ")" "$(cr_jnum "$SNG_WRITE")" "$(cr_jnum "$SNG_GBS")" "$SNG_VALID" "$(cr_jstr "$SNG_REASON")"
  printf '  "sysbench": { "seq_read_1t_gbs": %s, "seq_read_1t_block_mib": %s, "seq_read_1t_valid": %s, "seq_read_1t_invalid_reason": %s,\n' "$(cr_jnum "$SB1_GBS")" "$SB_BLK_MB" "$SB1_VALID" "$(cr_jstr "$SB1_REASON")"
  printf '                "rnd_read_mt_gbs": %s, "rnd_read_mt_valid": %s, "rnd_read_mt_invalid_reason": %s, "note": "random read is informational only" },\n' "$(cr_jnum "$SBR_GBS")" "$SBR_VALID" "$(cr_jstr "$SBR_REASON")"
  printf '  "latency": { "dram_ns": %s, "dram_buffer_mib": %s, "ladder": %s, "numa": %s, "note": "4 KiB pages: DRAM figure includes TLB misses, typically 5-15 ns above vendor idle latency" },\n' "$(cr_jnum "$DRAM_NS")" $((DRAM_KB/1024)) "$(join_json "${LAT_JSON[@]+"${LAT_JSON[@]}"}")" "$(join_json "${NUMA_LAT_JSON[@]+"${NUMA_LAT_JSON[@]}"}")"
  printf '  "memtester": { "state": %s, "size_mib": %s, "time_cap_s": %s, "rc": %s, "subtests_ok": %s, "failures": %s },\n' "$(cr_jstr "$MT_STATE")" "$MT_MB" "$MT_CAP" "$(cr_jnum "$MT_RC")" "$MT_OK" "$MT_FAIL"
  printf '  "edac": { "ce_before": %s, "ue_before": %s, "ce_after": %s, "ue_after": %s, "increase": %s },\n' "$(cr_jnum "$EDAC_CE_PRE")" "$(cr_jnum "$EDAC_UE_PRE")" "$(cr_jnum "$EDAC_CE_POST")" "$(cr_jnum "$EDAC_UE_POST")" "$(cr_jnum "$EDAC_DELTA")"
  printf '  "kernel_hw_error_lines": %s, "kernel_warning_lines": %s, "swap_used_mib_max": %s,\n' "$(cr_jnum "${HWERR:-0}")" "$(cr_jnum "${SOFTERR:-0}")" "$(cr_jnum "$SWAP_MAX")"
  printf '  "peaks": { "cpu_temp_c_max": %s, "cpu_pkg_w_max": %s },\n' "$(cr_jnum "$ALL_T_MAX")" "$(cr_jnum "$ALL_W_MAX")"
  printf '  "scores": [\n'
  printf '    { "name": "STREAM Triad best (%s)", "value": %s, "unit": "GB/s", "pct_of_expected": %s, "reference": "theoretical peak %s GB/s (%s MT/s x 8 B x %s DIMMs, assumes one DIMM per channel); typical real-world is 75-90%% of peak" },\n' "$BEST_TRIAD_LABEL" "$(cr_jnum "$BEST_TRIAD")" "$(cr_jnum "$BEST_PCT")" "$THEO_GBS" "$DIMM_SPEED" "$DIMM_COUNT"
  printf '    { "name": "stress-ng stream (read+write)", "value": %s, "unit": "GB/s", "pct_of_expected": %s, "reference": "theoretical peak; cross-check for STREAM" },\n' "$(cr_jnum "$( [ "$SNG_VALID" = true ] && echo "$SNG_GBS")")" "$(cr_jnum "$( [ "$SNG_VALID" = true ] && cr_pct "$SNG_GBS" "$THEO_GBS")")"
  printf '    { "name": "sysbench 1-thread sequential read", "value": %s, "unit": "GB/s", "pct_of_expected": null, "reference": "typical single-core DDR4 15-25, DDR5 25-35 GB/s" },\n' "$(cr_jnum "$( [ "$SB1_VALID" = true ] && echo "$SB1_GBS")")"
  printf '    { "name": "DRAM latency (pointer chase)", "value": %s, "unit": "ns", "pct_of_expected": null, "reference": "this method typically 75-100 ns (DDR4/DDR5 desktop), 100-140 ns (servers)" },\n' "$(cr_jnum "$DRAM_NS")"
  printf '    { "name": "data integrity (stress-ng verify + STREAM check + memtester + EDAC/MCE)", "value": %s, "unit": "pass/fail", "pct_of_expected": %s, "reference": "0 errors expected" }\n' "$(cr_jstr "$INTEGRITY")" "$( [ "$INTEGRITY" = pass ] && echo 100 || { [ "$INTEGRITY" = fail ] && echo 0 || echo null; } )"
  printf '  ],\n'
  printf '  "notes": %s,\n' "$(cr_jarr "Results marked valid=false are cache-resident or above the physical peak and must not be scored." "${ARC_NOTE:-no ZFS ARC}")"
  printf '  "errors": %s,\n' "$(cr_jarr "${CR_ERRORS[@]+"${CR_ERRORS[@]}"}")"
  printf '  "warnings": %s,\n' "$(cr_jarr "${CR_WARNINGS[@]+"${CR_WARNINGS[@]}"}")"
  printf '  "skipped": %s,\n' "$(cr_jarr "${CR_SKIPPED[@]+"${CR_SKIPPED[@]}"}")"
  printf '  "files": { "telemetry_csv": "telemetry-1s.csv", "socket_telemetry_csv": "telemetry-socket-1s.csv", "log": "run.log" }\n'
  printf '}\n'
} > "$OUT/summary.json"

{
  echo "RAM test - $((MEM_TOTAL_KB/1024)) MiB, $DIMM_COUNT x ($DIMM_SIZES) $DIMM_TYPE @ $DIMM_SPEED MT/s, ECC: $ECC ($DIMM_SLOTS slots, ${#NUMA_IDS[@]} NUMA node(s), $CR_SOCKETS socket(s))"
  echo "status: $STATUS   data integrity: $INTEGRITY   started $STARTED   finished $FINISHED"
  echo "stress ${DURATION}s: stress-ng vm x$ST_WORKERS, ${ST_TESTED_MB} MiB tested (planned $STRESS_MB), $ST_OPS ops/s, passed=$ST_PASSED failed=$ST_FAILED, verify-error lines=$ST_ERRLINES"
  echo "  CPU package ${ST_W_AVG}/${ST_W_MAX} W avg/max, ${ST_T_AVG}/${ST_T_MAX} C avg/max; mem used rise ${ST_RSS_DELTA} MiB, min available ${ST_AVAIL_MIN} MiB"
  echo "STREAM Triad best: $BEST_TRIAD GB/s ($BEST_TRIAD_LABEL) = ${BEST_PCT}% of theoretical $THEO_GBS GB/s"
  for j in "${STREAM_JSON[@]+"${STREAM_JSON[@]}"}"; do echo "  $j"; done
  echo "stress-ng stream: $SNG_GBS GB/s (read $SNG_READ + write $SNG_WRITE), valid=$SNG_VALID $SNG_REASON"
  echo "sysbench: 1t seq read $SB1_GBS GB/s (valid=$SB1_VALID $SB1_REASON); mt rnd read $SBR_GBS GB/s (informational)"
  echo "latency: DRAM $DRAM_NS ns; ladder: $(tr '\n' ';' < "$OUT/latency.txt" 2>/dev/null)"
  echo "memtester: $MT_STATE (${MT_MB} MiB, cap ${MT_CAP}s, rc=$MT_RC, ok=$MT_OK, failures=$MT_FAIL)"
  echo "EDAC: CE $EDAC_CE_PRE->$EDAC_CE_POST, UE $EDAC_UE_PRE->$EDAC_UE_POST; kernel hw-error lines ${HWERR:-0}, warnings ${SOFTERR:-0}; swap max ${SWAP_MAX} MiB"
  for x in "${CR_ERRORS[@]+"${CR_ERRORS[@]}"}"; do echo "ERROR: $x"; done
  for x in "${CR_WARNINGS[@]+"${CR_WARNINGS[@]}"}"; do echo "WARNING: $x"; done
  for x in "${CR_SKIPPED[@]+"${CR_SKIPPED[@]}"}"; do echo "SKIPPED: $x"; done
} > "$OUT/summary.txt"
cat "$OUT/summary.txt"
cr_log "RAM test done -> $OUT/summary.json"
exit 0
