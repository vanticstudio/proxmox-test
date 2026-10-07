#!/usr/bin/env bash
# =============================================================================
# cpu.sh - CPU stress + benchmark for a Proxmox VE host (part 1 of 5: CPU)
#
# Usage (run as root ON the Proxmox host, after scp to /root/pve-stresstest/):
#   cpu.sh --duration SECONDS --out DIR [--no-install] [--no-turbostat]
#
#   --duration      sustained stress-phase length in seconds (30/60/300/600).
#                   REQUIRED (10..3600). The benchmarks below add a bounded,
#                   fixed extra on top of it.
#   --out           output directory (created if missing). REQUIRED.
#   --no-install    never apt-get install missing tools; skip their sub-tests.
#   --no-turbostat  do not run turbostat alongside the stress phase.
#
# WHAT IT MEASURES (in this order)
#   0. Inventory (read-only): model, vendor, sockets/cores/threads, hybrid
#      P/E-core layout (Intel: /sys/devices/cpu_core + cpu_atom), max clock,
#      governor/driver, microcode, RAPL power limits, running guests count.
#      Health "pre": thermal-throttle counters, dmesg line count.
#   1. Idle telemetry, 5 s.
#   2. STRESS PHASE (DURATION s): stress-ng --cpu <all threads>
#      --cpu-method matrixprod --metrics-brief --tz. Result = bogo-ops/s,
#      workers passed/failed. turbostat (if installed) logs per-CPU busy MHz,
#      temps and package watts every 5 s next to it.
#   3. sysbench cpu (prime 20000): 1 thread, 10 s, then all threads, 10 s.
#      The 1-thread run also measures the single-core boost clock reached
#      (max MHz seen) as % of the CPU's advertised max frequency.
#   4. 7-Zip built-in benchmark: multi-thread (7z b 3 -mmt<threads>) and
#      single thread (7z b 1 -mmt1). Score = "Tot:" rating in MIPS.
#   5. Throttle counters after; perf-per-watt for each workload; dmesg
#      hardware errors (MCE etc.) that appeared during the test.
#
#   SCALING: every load uses ALL online CPUs of ALL sockets (stress-ng --cpu
#   <threads>, sysbench/7-Zip at <threads>); a restricted CPU affinity is
#   detected and reported. Per-socket figures (package W, temp, MHz, busy %)
#   go to DIR/telemetry-socket-1s.csv (one row per socket per second) and
#   "per_socket" in summary.json; PL1/PL2 are summed over all packages.
#
#   Telemetry once per second for the whole run -> DIR/telemetry-1s.csv,
#   with a "phase" column naming the running sub-test. Uses the shared
#   scripts/telemetry.sh sampler (groups "cpu mem": ts,elapsed_s,phase,
#   cpu_pkg_w,cpu_core_w,cpu_temp_c,cpu_avg_mhz,cpu_min_mhz,cpu_max_mhz,
#   cpu_pcore_mhz,cpu_ecore_mhz,cpu_busy_pct,cpu_core_throttle,
#   cpu_pkg_throttle,load1,mem_used_mb,mem_avail_mb,swap_used_mb) when that
#   file is present; otherwise a built-in sampler with the columns
#   time,elapsed_s,phase,pkg_W,core_W,pkg_temp_C,avg_MHz,max_MHz,
#   pcore_avg_MHz,ecore_avg_MHz,load1,mem_used_MB,mem_avail_MB,swap_used_MB.
#   Power = RAPL via powercap (Intel, and AMD Zen on kernels exposing it),
#   temp = coretemp "Package id 0" / k10temp Tdie|Tctl / zenpower /
#   x86_pkg_temp thermal zone. Any missing sensor is written as "n/a".
#   Samples outside 0..2000 W (RAPL counter-wrap artefacts) become "n/a".
#
# TIME IT TAKES
#   ~ DURATION + 5 s idle + 10 s cooldown + 2 x 10 s sysbench + 7-Zip
#   (multi ~20-60 s, single ~15-60 s) + ~30 s of pauses
#   => roughly DURATION + 2 to 3.5 minutes (each 7-Zip run hard-capped at 600 s).
#
# OUTPUTS (in DIR)
#   summary.json            key metrics, scores, per_socket, errors, warnings, skipped
#   telemetry-socket-1s.csv per-socket 1 s telemetry (ts,elapsed_s,phase,socket,
#                           pkg_w,temp_c,avg_mhz,busy_pct)
#   summary.txt             the same in plain English
#   run.log                 full console log
#   telemetry-1s.csv        1 s telemetry, "phase" column marks each sub-test
#   stress-ng.log/.yaml, sysbench-1t.txt, sysbench-mt.txt, 7z-mt.txt, 7z-1t.txt,
#   turbostat-stress.txt, throttle-pre/-post-stress/-post.txt, inventory.txt,
#   dmesg-new.txt, dmesg-new-hw-errors.txt, rapl-limits.txt, apt-install.log
#
# SAFETY
#   Never changes BIOS, power limits, governor, EPP or kernel parameters; never
#   starts or stops guests (running guests are only counted, because they
#   compete with the benchmarks and lower the scores). Packages are installed
#   from the distro repos only (apt) and every package that was NOT installed
#   before is appended to DIR/../installed-packages.txt so cleanup can remove
#   exactly those.
#
# EXIT CODES
#   0 = finished (even if some sub-tests were skipped - see summary.json)
#   2 = bad usage / not root / not Linux
#
# LIBRARY MODE
#   ram.sh reuses the helpers here: `CR_LIB_ONLY=1 . cpu.sh` defines the cr_*
#   functions and returns without running anything.
#
# LESSONS (known pitfalls on recent PVE / Debian):
#   - RAPL energy counters wrap, which can produce a bogus multi-megawatt sample. Wrap is
#     corrected with max_energy_range_uj and implausible samples are dropped.
#   - Many Intel desktop CPUs sit at the PL1/PL2 power limit under all-core load, so
#     all-core clocks below the spec "all-core turbo" are normal, not a fault.
#   - On hybrid Intel the E-cores run ~1 GHz lower than P-cores; report both.
# =============================================================================

set -u
set -o pipefail

# ----------------------------------------------------------------------------
# Shared helpers (cr_ prefix). Also used by ram.sh in library mode.
# ----------------------------------------------------------------------------
CR_WARNINGS=()
CR_ERRORS=()
CR_SKIPPED=()
CR_SAMPLER_PID=""
CR_WATCHDOG_PID=""
CR_SAMPLE_FLAG=""
CR_PHASE_FILE=""
CR_KILL_FILE=""
CR_MEM_FLOOR_KB=0
CR_CSV_HEADER="time,elapsed_s,phase,pkg_W,core_W,pkg_temp_C,avg_MHz,max_MHz,pcore_avg_MHz,ecore_avg_MHz,load1,mem_used_MB,mem_avail_MB,swap_used_MB"

cr_log()  { printf '[%(%H:%M:%S)T] %s\n' -1 "$*"; }
cr_warn() { CR_WARNINGS+=("$*"); cr_log "WARNING: $*"; }
cr_error(){ CR_ERRORS+=("$*"); cr_log "ERROR: $*"; }
cr_skip() { CR_SKIPPED+=("$1: $2"); cr_log "SKIPPED $1: $2"; }
cr_die()  { echo "ERROR: $*" >&2; exit 2; }

cr_is_num() { [[ ${1-} =~ ^-?[0-9]+(\.[0-9]+)?([eE][-+]?[0-9]+)?$ ]]; }

# JSON helpers (no jq/python dependency)
cr_jstr() {
  local s=${1-}
  s=${s//\\/\\\\}; s=${s//\"/\\\"}; s=${s//$'\n'/\\n}; s=${s//$'\r'/}; s=${s//$'\t'/\\t}
  s=$(printf '%s' "$s" | tr -d '\000-\010\013\014\016-\037')
  printf '"%s"' "$s"
}
cr_jnum() { if cr_is_num "${1-}"; then printf '%s' "$1"; else printf 'null'; fi; }
cr_jbool() { case "${1-}" in 1|true|yes) printf 'true';; 0|false|no) printf 'false';; *) printf 'null';; esac; }
cr_jarr() { # cr_jarr item... -> JSON array of strings
  local first=1 x
  printf '['
  for x in "$@"; do
    [ $first -eq 1 ] || printf ', '
    first=0; cr_jstr "$x"
  done
  printf ']'
}

# Float maths via awk. cr_calc '<expr>' [printf-format]
cr_calc() { awk "BEGIN{ printf \"${2:-%.2f}\", ($1) }" 2>/dev/null || printf 'n/a'; }
# cr_div a b [fmt]  -> a/b or n/a
cr_div() {
  if cr_is_num "${1-}" && cr_is_num "${2-}" && awk -v b="$2" 'BEGIN{exit !(b+0!=0)}'; then
    cr_calc "$1/$2" "${3:-%.2f}"
  else printf 'n/a'; fi
}
# cr_pct value reference -> value/reference*100 (1 decimal) or n/a
# (cr_div only accepts plain numbers, so multiply first - passing "$1*100" made it always n/a)
cr_pct() { if cr_is_num "${1-}" && cr_is_num "${2-}"; then cr_div "$(cr_calc "$1*100" '%.6f')" "$2" "%.1f"; else printf 'n/a'; fi; }

# Expand a cpulist like "0-15,32,40-47" into "0 1 ... 15 32 40 ... 47"
cr_expand() {
  local list=${1-} part a b out=""
  local IFS=,
  for part in $list; do
    if [[ $part =~ ^([0-9]+)-([0-9]+)$ ]]; then
      a=${BASH_REMATCH[1]}; b=${BASH_REMATCH[2]}
      while [ "$a" -le "$b" ]; do out+="$a "; a=$((a+1)); done
    elif [[ $part =~ ^[0-9]+$ ]]; then out+="$part "
    fi
  done
  printf '%s' "${out% }"
}

cr_require_root_linux() {
  [ "$(uname -s)" = Linux ] || cr_die "this script must run on the Linux (Proxmox) host"
  [ "$(id -u)" -eq 0 ] || cr_die "run as root (it reads RAPL energy counters, dmesg and dmidecode)"
  [ "${BASH_VERSINFO[0]}" -ge 4 ] || cr_die "bash 4+ required"
}

# --- package handling ---------------------------------------------------------
CR_APT_UPDATED=0
CR_NO_INSTALL=0
CR_PKG_RECORD=""
# cr_apt_install PKG -> installs one distro package, records what was new
cr_apt_install() {
  local pkg=$1 before after rc=1
  [ "$CR_NO_INSTALL" -eq 1 ] && { cr_log "not installing $pkg (--no-install)"; return 1; }
  command -v apt-get >/dev/null 2>&1 || { cr_log "apt-get not found, cannot install $pkg"; return 1; }
  if [ "$CR_APT_UPDATED" -eq 0 ]; then
    cr_log "apt-get update (once)"
    DEBIAN_FRONTEND=noninteractive apt-get update -qq >/dev/null 2>&1 || cr_log "apt-get update reported an error (continuing)"
    CR_APT_UPDATED=1
  fi
  apt-cache show "$pkg" >/dev/null 2>&1 || { cr_log "package $pkg not available in the configured repos"; return 1; }
  before=$(mktemp); after=$(mktemp)
  dpkg-query -W -f='${Package}\n' 2>/dev/null | sort -u > "$before"
  cr_log "installing $pkg from the distro repos"
  if DEBIAN_FRONTEND=noninteractive apt-get install -y -q --no-install-recommends "$pkg" >>"${OUT:-/tmp}/apt-install.log" 2>&1; then rc=0
  else cr_log "apt-get install $pkg failed (see apt-install.log)"; fi
  dpkg-query -W -f='${Package}\n' 2>/dev/null | sort -u > "$after"
  if [ -n "$CR_PKG_RECORD" ]; then
    { [ -f "$CR_PKG_RECORD" ] && cat "$CR_PKG_RECORD"; comm -13 "$before" "$after"; } | sed '/^$/d' | sort -u > "$CR_PKG_RECORD.tmp" \
      && mv "$CR_PKG_RECORD.tmp" "$CR_PKG_RECORD"
  fi
  rm -f "$before" "$after"
  hash -r
  return $rc
}
# cr_need CMD PKG [ALT_PKG...]  -> 0 if CMD is (now) available
cr_need() {
  local cmd=$1 pkg; shift
  command -v "$cmd" >/dev/null 2>&1 && return 0
  for pkg in "$@"; do
    cr_apt_install "$pkg" && command -v "$cmd" >/dev/null 2>&1 && return 0
  done
  command -v "$cmd" >/dev/null 2>&1
}

# --- topology / inventory -----------------------------------------------------
cr_detect_topology() {
  CR_NPROC=$(getconf _NPROCESSORS_ONLN 2>/dev/null || nproc)
  # A restricted CPU affinity (cgroup/cpuset/taskset) limits what we can load.
  local naff; naff=$(nproc 2>/dev/null)
  if cr_is_num "$naff" && [ "$naff" -lt "$CR_NPROC" ]; then
    cr_warn "CPU affinity restricts this shell to $naff of $CR_NPROC online CPUs; load tests use $naff"
    CR_NPROC=$naff
  fi
  CR_CORES=$(lscpu -p=CORE,SOCKET 2>/dev/null | grep -v '^#' | sort -u | wc -l)
  [ "${CR_CORES:-0}" -ge 1 ] 2>/dev/null || CR_CORES=$CR_NPROC
  CR_SOCKETS=$(lscpu -p=SOCKET 2>/dev/null | grep -v '^#' | sort -u | wc -l)
  [ "${CR_SOCKETS:-0}" -ge 1 ] 2>/dev/null || CR_SOCKETS=1
  CR_MODEL=$(awk -F: '/^model name/{sub(/^[ \t]+/,"",$2); print $2; exit}' /proc/cpuinfo)
  CR_VENDOR=$(awk -F: '/^vendor_id/{gsub(/[ \t]/,"",$2); print $2; exit}' /proc/cpuinfo)
  CR_MICROCODE=$(awk -F: '/^microcode/{gsub(/[ \t]/,"",$2); print $2; exit}' /proc/cpuinfo)
  CR_HYBRID=0; CR_PSET=""; CR_ESET=""
  if [ -r /sys/devices/cpu_core/cpus ] && [ -r /sys/devices/cpu_atom/cpus ]; then
    CR_PSET=$(cr_expand "$(cat /sys/devices/cpu_core/cpus)")
    CR_ESET=$(cr_expand "$(cat /sys/devices/cpu_atom/cpus)")
    [ -n "$CR_PSET" ] && [ -n "$CR_ESET" ] && CR_HYBRID=1
  fi
  CR_FIRST_PCPU=0
  if [ "$CR_HYBRID" -eq 1 ]; then CR_FIRST_PCPU=${CR_PSET%% *}; fi
  # counts of P/E physical cores
  CR_PCORES="n/a"; CR_ECORES="n/a"
  if [ "$CR_HYBRID" -eq 1 ]; then
    CR_PCORES=$(lscpu -p=CPU,CORE 2>/dev/null | grep -v '^#' | awk -F, -v s=" $CR_PSET " 'index(s," "$1" "){print $2}' | sort -u | wc -l)
    CR_ECORES=$(lscpu -p=CPU,CORE 2>/dev/null | grep -v '^#' | awk -F, -v s=" $CR_ESET " 'index(s," "$1" "){print $2}' | sort -u | wc -l)
  fi
  # NUMA nodes and per-socket layout (scales to any number of sockets/nodes)
  CR_NUMA_NODES=$(ls -d /sys/devices/system/node/node[0-9]* 2>/dev/null | wc -l)
  [ "${CR_NUMA_NODES:-0}" -ge 1 ] 2>/dev/null || CR_NUMA_NODES=1
  CR_SOCK_LAYOUT=$(lscpu -p=CPU,CORE,SOCKET,NODE 2>/dev/null | grep -v '^#' | awk -F, '
    { s=($3==""?0:$3); n[s]++; if (!seen[s","$2]++) c[s]++; if ($4!="" && !nd[s","$4]++) nodes[s]=nodes[s] (nodes[s]==""?"":"+") $4 }
    END { for (s in n) printf "%s %d %d %s\n", s, n[s], c[s], (nodes[s]==""?"-":nodes[s]) }' | sort -n)
  # "socket threads cores nodes" per line; fallback: one socket with everything
  [ -n "$CR_SOCK_LAYOUT" ] || CR_SOCK_LAYOUT="0 $CR_NPROC $CR_CORES 0"
  # max frequency (MHz)
  CR_MAX_MHZ=$(cat /sys/devices/system/cpu/cpu[0-9]*/cpufreq/cpuinfo_max_freq 2>/dev/null | sort -n | tail -1)
  if cr_is_num "$CR_MAX_MHZ"; then CR_MAX_MHZ=$((CR_MAX_MHZ/1000))
  else CR_MAX_MHZ=$(lscpu 2>/dev/null | awk -F: '/CPU max MHz/{gsub(/ /,"",$2); printf "%.0f", $2; exit}'); fi
  cr_is_num "$CR_MAX_MHZ" || CR_MAX_MHZ="n/a"
  CR_GOVERNOR=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null || echo n/a)
  CR_FREQ_DRIVER=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_driver 2>/dev/null || echo n/a)
  CR_EPP=$(cat /sys/devices/system/cpu/cpu0/cpufreq/energy_performance_preference 2>/dev/null || echo n/a)
  CR_NO_TURBO="n/a"
  [ -r /sys/devices/system/cpu/intel_pstate/no_turbo ] && CR_NO_TURBO=$(cat /sys/devices/system/cpu/intel_pstate/no_turbo)
  [ -r /sys/devices/system/cpu/cpufreq/boost ] && CR_NO_TURBO=$(( 1 - $(cat /sys/devices/system/cpu/cpufreq/boost) ))
  # cpufreq source for telemetry
  CR_FREQ_FILES=()
  local f
  for f in /sys/devices/system/cpu/cpu[0-9]*/cpufreq/scaling_cur_freq; do [ -r "$f" ] && CR_FREQ_FILES+=("$f"); done
  # running guests (read-only)
  CR_RUNNING_VMS=0; CR_RUNNING_CTS=0
  if command -v qm >/dev/null 2>&1; then CR_RUNNING_VMS=$(timeout 20 qm list 2>/dev/null | awk 'NR>1 && $3=="running"' | wc -l); fi
  if command -v pct >/dev/null 2>&1; then CR_RUNNING_CTS=$(timeout 20 pct list 2>/dev/null | awk 'NR>1 && $2=="running"' | wc -l); fi
}

# --- sensors ------------------------------------------------------------------
cr_detect_sensors() {
  CR_RAPL_PKG=""; CR_RAPL_CORE=""; CR_RAPL_MAX=0; CR_RAPL_ZONE=""
  local z n
  for z in /sys/class/powercap/intel-rapl:[0-9] /sys/class/powercap/intel-rapl:[0-9][0-9] /sys/class/powercap/amd-rapl:[0-9]; do
    [ -r "$z/name" ] || continue
    n=$(cat "$z/name" 2>/dev/null)
    if [[ $n == package-0* ]] && [ -r "$z/energy_uj" ] && cat "$z/energy_uj" >/dev/null 2>&1; then
      CR_RAPL_ZONE=$z; CR_RAPL_PKG=$z/energy_uj
      CR_RAPL_MAX=$(cat "$z/max_energy_range_uj" 2>/dev/null || echo 0)
      break
    fi
  done
  if [ -n "$CR_RAPL_ZONE" ]; then
    for z in "$CR_RAPL_ZONE"/*:[0-9]*; do
      [ -r "$z/name" ] || continue
      if [ "$(cat "$z/name" 2>/dev/null)" = core ] && cat "$z/energy_uj" >/dev/null 2>&1; then CR_RAPL_CORE=$z/energy_uj; break; fi
    done
  fi
  if [ "$CR_SOCKETS" -gt 1 ]; then
    if [ "${CR_USE_TEL:-0}" -eq 1 ]; then
      cr_log "multi-socket host ($CR_SOCKETS sockets): telemetry-1s.csv sums package power and takes the hottest package; per-socket figures are in telemetry-socket-1s.csv"
    else
      cr_warn "multi-socket host: telemetry-1s.csv (built-in sampler) covers socket 0 only; per-socket figures are in telemetry-socket-1s.csv"
    fi
  fi
  cr_socket_detect

  # Package temperature
  CR_TEMP_FILE=""; CR_TEMP_SRC="n/a"
  local h name lbl inp
  for h in /sys/class/hwmon/hwmon*; do
    name=$(cat "$h/name" 2>/dev/null) || continue
    case "$name" in
      coretemp)
        for lbl in "$h"/temp*_label; do
          [ -r "$lbl" ] || continue
          if [[ $(cat "$lbl") == "Package id 0" ]]; then CR_TEMP_FILE=${lbl%_label}_input; CR_TEMP_SRC="coretemp Package id 0"; break; fi
        done ;;
      k10temp|zenpower)
        local tdie="" tctl=""
        for lbl in "$h"/temp*_label; do
          [ -r "$lbl" ] || continue
          case "$(cat "$lbl")" in Tdie) tdie=${lbl%_label}_input;; Tctl) tctl=${lbl%_label}_input;; esac
        done
        if [ -n "$tdie" ]; then CR_TEMP_FILE=$tdie; CR_TEMP_SRC="$name Tdie"
        elif [ -n "$tctl" ]; then CR_TEMP_FILE=$tctl; CR_TEMP_SRC="$name Tctl"
        elif [ -r "$h/temp1_input" ]; then CR_TEMP_FILE=$h/temp1_input; CR_TEMP_SRC="$name temp1"; fi ;;
    esac
    [ -n "$CR_TEMP_FILE" ] && break
  done
  if [ -z "$CR_TEMP_FILE" ]; then
    for z in /sys/class/thermal/thermal_zone*; do
      if [ "$(cat "$z/type" 2>/dev/null)" = x86_pkg_temp ]; then CR_TEMP_FILE=$z/temp; CR_TEMP_SRC="thermal_zone x86_pkg_temp"; break; fi
    done
  fi
  if [ -z "$CR_RAPL_PKG" ]; then
    if [ "${CR_USE_TEL:-0}" -eq 1 ] && declare -F tel_init >/dev/null && tel_init && [ "${TEL_RAPL_SRC:-n/a}" != n/a ]; then
      CR_RAPL_PKG="($TEL_RAPL_SRC via telemetry.sh)"   # e.g. AMD amd_energy hwmon; label only
    else
      cr_warn "no RAPL / amd_energy package energy counter - CPU power will be n/a and perf-per-watt cannot be computed"
    fi
  fi
  [ -z "$CR_TEMP_FILE" ] && cr_warn "no CPU package temperature sensor found (coretemp/k10temp/zenpower/x86_pkg_temp) - temperature will be n/a"
  [ ${#CR_FREQ_FILES[@]} -eq 0 ] && cr_log "no cpufreq sysfs; clocks will come from /proc/cpuinfo"
  return 0
}

cr_rapl_limits() { # write RAPL limits (read-only) to a file
  local z f i
  for z in /sys/class/powercap/intel-rapl:* /sys/class/powercap/amd-rapl:*; do
    [ -d "$z" ] || continue
    echo "== $z name=$(cat "$z/name" 2>/dev/null) enabled=$(cat "$z/enabled" 2>/dev/null)"
    for f in "$z"/constraint_*_name; do
      [ -r "$f" ] || continue
      i=${f%_name}
      echo "  $(cat "$f"): limit_uw=$(cat "${i}_power_limit_uw" 2>/dev/null) window_us=$(cat "${i}_time_window_us" 2>/dev/null) max_uw=$(cat "${i}_max_power_uw" 2>/dev/null)"
    done
  done
}
# PL1/PL2 in W from package zone (n/a if absent)
# PL1/PL2 in W, summed over all CPU packages (sockets); n/a if absent.
# cr_rapl_pl long_term|short_term [SOCKET]  (SOCKET = that package only)
cr_rapl_pl() {
  local f i z n uw tot=0 found=0
  for z in /sys/class/powercap/intel-rapl:[0-9] /sys/class/powercap/intel-rapl:[0-9][0-9] /sys/class/powercap/amd-rapl:[0-9]; do
    [ -r "$z/name" ] || continue
    n=$(cat "$z/name" 2>/dev/null)
    [[ $n =~ ^package-([0-9]+)$ ]] || continue
    [ -n "${2-}" ] && [ "${BASH_REMATCH[1]}" != "$2" ] && continue
    for f in "$z"/constraint_*_name; do
      [ -r "$f" ] || continue
      if [ "$(cat "$f")" = "$1" ]; then
        i=${f%_name}; uw=$(cat "${i}_power_limit_uw" 2>/dev/null)
        cr_is_num "$uw" && { tot=$((tot + uw)); found=1; }
        break
      fi
    done
  done
  if [ "$found" -eq 1 ]; then cr_calc "$tot/1000000" "%.0f"; else printf 'n/a'; fi
}

# --- throttle counters ------------------------------------------------------------
# prints "core_sum pkg_sum" or "n/a n/a"; full listing into $1 if given
cr_throttle() {
  local files=(/sys/devices/system/cpu/cpu[0-9]*/thermal_throttle/core_throttle_count)
  if [ ! -r "${files[0]}" ]; then
    [ -n "${1-}" ] && echo "thermal_throttle counters not available on this CPU/kernel" > "$1"
    printf 'n/a n/a'; return
  fi
  if [ -n "${1-}" ]; then
    grep -H . /sys/devices/system/cpu/cpu[0-9]*/thermal_throttle/*_count 2>/dev/null > "$1"
  fi
  local c p
  c=$(cat /sys/devices/system/cpu/cpu[0-9]*/thermal_throttle/core_throttle_count 2>/dev/null | awk '{s+=$1} END{print s+0}')
  p=$(cat /sys/devices/system/cpu/cpu[0-9]*/thermal_throttle/package_throttle_count 2>/dev/null | awk '{s+=$1} END{print s+0}')
  printf '%s %s' "$c" "$p"
}

# --- dmesg hardware-error helpers ----------------------------------------------------
# HARD = real hardware faults (-> error). SOFT = worth a look (-> warning).
# "split lock" notices from guests are deliberately NOT matched (harmless).
# PCIe AER *corrected* errors are common and harmless on many consumer boards (ASPM,
# some NICs), so they are a warning, not a hardware failure; uncorrected ones stay hard.
CR_HWERR_RE='mce:|machine check|hardware error|edac.*\<(ce|ue)\>|edac.*error|uncorrect|\[hardware error\]'
CR_SOFTERR_RE='oom-kill|out of memory|page allocation fail|soft lockup|hard lockup|watchdog: bug|rcu.*stall|temperature above threshold|cpu clock throttled|package temperature.*throttl|aer: corrected|severity=corrected'
cr_dmesg_mark() { dmesg 2>/dev/null | wc -l; }
# cr_dmesg_new START_LINES OUTFILE -> prints "HARD SOFT" counts; writes new lines to OUTFILE
# and the matching ones to OUTFILE%.txt-hw-errors.txt
cr_dmesg_new() {
  local h s
  dmesg -T 2>/dev/null | tail -n +"$(( ${1:-0} + 1 ))" > "$2"
  h=$(grep -ciE "$CR_HWERR_RE" "$2" 2>/dev/null); h=${h:-0}
  s=$(grep -ciE "$CR_SOFTERR_RE" "$2" 2>/dev/null); s=${s:-0}
  grep -iE "$CR_HWERR_RE|$CR_SOFTERR_RE" "$2" > "${2%.txt}-hw-errors.txt" 2>/dev/null || true
  printf '%s %s' "$h" "$s"
}

# --- per-socket telemetry (any number of sockets) ---------------------------------
# telemetry-socket-1s.csv, long format, one row per socket per second:
#   ts,elapsed_s,phase,socket,pkg_w,temp_c,avg_mhz,busy_pct
# Power: powercap package-N zones (Intel; AMD Zen when exposed), else amd_energy
# Esocket<N>. Temp: coretemp "Package id N"; k10temp/zenpower instances are
# assigned to sockets in PCI order (one instance per socket). Missing -> n/a.
declare -A CR_SOCK_EF=() CR_SOCK_EMAX=() CR_SOCK_TF=()
CR_SOCK_IDS=(); CR_CPU_SOCK_MAP=""; CR_SOCK_PID=""
cr_socket_detect() {
  local c z n s h l lab i pick tctl
  CR_SOCK_EF=(); CR_SOCK_EMAX=(); CR_SOCK_TF=(); CR_CPU_SOCK_MAP=""
  for c in /sys/devices/system/cpu/cpu[0-9]*; do
    [ -r "$c/topology/physical_package_id" ] || continue
    CR_CPU_SOCK_MAP+="${c##*/cpu} $(cat "$c/topology/physical_package_id" 2>/dev/null)"$'\n'
  done
  [ -n "$CR_CPU_SOCK_MAP" ] || CR_CPU_SOCK_MAP=$(lscpu -p=CPU,SOCKET 2>/dev/null | grep -v '^#' | tr ',' ' ')$'\n'
  mapfile -t CR_SOCK_IDS < <(printf '%s' "$CR_CPU_SOCK_MAP" | awk 'NF==2{print $2}' | sort -nu)
  [ ${#CR_SOCK_IDS[@]} -gt 0 ] || CR_SOCK_IDS=(0)
  for z in /sys/class/powercap/intel-rapl:[0-9] /sys/class/powercap/intel-rapl:[0-9][0-9] /sys/class/powercap/amd-rapl:[0-9]; do
    [ -r "$z/name" ] && [ -r "$z/energy_uj" ] || continue
    n=$(cat "$z/name" 2>/dev/null)
    [[ $n =~ ^package-([0-9]+) ]] || continue
    s=${BASH_REMATCH[1]}
    cat "$z/energy_uj" >/dev/null 2>&1 || continue
    CR_SOCK_EF[$s]+="$z/energy_uj "; CR_SOCK_EMAX[$s]=$(cat "$z/max_energy_range_uj" 2>/dev/null || echo 0)
  done
  if [ ${#CR_SOCK_EF[@]} -eq 0 ]; then
    for h in /sys/class/hwmon/hwmon*; do
      [ "$(cat "$h/name" 2>/dev/null)" = amd_energy ] || continue
      for l in "$h"/energy*_label; do
        lab=$(cat "$l" 2>/dev/null)
        [[ $lab =~ ^Esocket([0-9]+)$ ]] && { CR_SOCK_EF[${BASH_REMATCH[1]}]+="${l%_label}_input "; CR_SOCK_EMAX[${BASH_REMATCH[1]}]=0; }
      done
    done
  fi
  for h in /sys/class/hwmon/hwmon*; do
    [ "$(cat "$h/name" 2>/dev/null)" = coretemp ] || continue
    for l in "$h"/temp*_label; do
      lab=$(cat "$l" 2>/dev/null)
      [[ $lab =~ ^Package\ id\ ([0-9]+)$ ]] && CR_SOCK_TF[${BASH_REMATCH[1]}]="${l%_label}_input"
    done
  done
  if [ ${#CR_SOCK_TF[@]} -eq 0 ]; then
    i=0
    while read -r h; do
      [ -n "$h" ] || continue
      pick=""; tctl=""
      for l in "$h"/temp*_label; do
        case "$(cat "$l" 2>/dev/null)" in Tdie) pick=${l%_label}_input ;; Tctl) tctl=${l%_label}_input ;; esac
      done
      [ -z "$pick" ] && pick=$tctl; [ -z "$pick" ] && [ -r "$h/temp1_input" ] && pick="$h/temp1_input"
      [ -n "$pick" ] && [ "$i" -lt ${#CR_SOCK_IDS[@]} ] && CR_SOCK_TF[${CR_SOCK_IDS[$i]}]="$pick"
      i=$((i + 1))
    done < <(for h in /sys/class/hwmon/hwmon*; do
               n=$(cat "$h/name" 2>/dev/null)
               if [ "$n" = k10temp ] || [ "$n" = zenpower ]; then echo "$(readlink -f "$h/device" 2>/dev/null) $h"; fi
             done | sort | awk '{print $2}')
  fi
  return 0
}
cr__sock_energy() { # "sock:uJ sock:uJ ..." (x when unreadable)
  local s f v sum out=""
  for s in "${CR_SOCK_IDS[@]}"; do
    sum=0
    if [ -z "${CR_SOCK_EF[$s]:-}" ]; then out+="$s:x "; continue; fi
    for f in ${CR_SOCK_EF[$s]}; do
      v=""; { read -r v < "$f"; } 2>/dev/null
      if [[ $v =~ ^[0-9]+$ ]]; then sum=$((sum + v)); else sum=x; break; fi
    done
    out+="$s:$sum "
  done
  printf '%s' "$out"
}
cr__cur_phase() {
  local f=$CR_PHASE_FILE ph=""
  [ "${CR_USE_TEL:-0}" -eq 1 ] && f="${TEL_STATE_DIR:-}/phase"
  [ -n "$f" ] && { read -r ph < "$f"; } 2>/dev/null
  printf '%s' "${ph:-run}"
}
cr__sock_loop() { # csv statefile
  local csv=$1 st=$2 tstart t0 t1 e0 e1 temps s emax=""
  for s in "${CR_SOCK_IDS[@]}"; do emax+="$s:${CR_SOCK_EMAX[$s]:-0} "; done
  printf '%s' "$CR_CPU_SOCK_MAP" > "$st.map"
  awk '/^cpu[0-9]+ /{t=0; for(i=2;i<=NF;i++)t+=$i; print substr($1,4), t, $5+$6}' /proc/stat > "$st.prev"
  cr__now; tstart=$CR_NOW; t0=$CR_NOW; e0=$(cr__sock_energy)
  while [ -f "$CR_SAMPLE_FLAG" ]; do
    sleep 1
    cr__now; t1=$CR_NOW; e1=$(cr__sock_energy)
    temps=""
    for s in "${CR_SOCK_IDS[@]}"; do cr__rd "${CR_SOCK_TF[$s]:-}"; temps+="$s:$CR_V "; done
    cr__freq_lines | awk -v ts="$(printf '%(%H:%M:%S)T' -1)" -v el="$(awk -v a="$t1" -v b="$tstart" 'BEGIN{printf "%.1f", a-b}')" \
      -v dt="$(awk -v a="$t1" -v b="$t0" 'BEGIN{printf "%.6f", a-b}')" -v ph="$(cr__cur_phase)" \
      -v e0="$e0" -v e1="$e1" -v emax="$emax" -v temps="$temps" -v ids="${CR_SOCK_IDS[*]}" -v mapf="$st.map" -v prevf="$st.prev" -v newf="$st.new" '
      function kv(str, arr,   n, i, p, a) { n=split(str, a, " "); for (i=1;i<=n;i++) { p=index(a[i],":"); if (p) arr[substr(a[i],1,p-1)]=substr(a[i],p+1) } }
      BEGIN {
        kv(e0, E0); kv(e1, E1); kv(emax, EM); kv(temps, T)
        while ((getline l < mapf) > 0) { split(l, m, " "); if (m[1] != "") sock[m[1]] = m[2] }
        while ((getline l < prevf) > 0) { split(l, m, " "); pt[m[1]] = m[2]; pi[m[1]] = m[3] }
        while ((getline l < "/proc/stat") > 0) {
          if (l !~ /^cpu[0-9]+ /) continue
          n = split(l, f, " "); c = substr(f[1], 4); t = 0; for (i=2;i<=n;i++) t += f[i]; idle = f[5] + f[6]
          print c, t, idle > newf
          if ((c in pt) && t - pt[c] > 0) { s = sock[c]; bs[s] += 100 * (1 - (idle - pi[c]) / (t - pt[c])); bn[s]++ }
        }
      }
      { split($0, q, ":"); path=q[1]; khz=q[2]+0; c=""; if (match(path, /\/cpu[0-9]+\//)) c=substr(path, RSTART+4, RLENGTH-5)
        if (c != "" && (c in sock)) { s=sock[c]; ms[s] += khz/1000; mn[s]++ } }
      END {
        ns = split(ids, I, " ")
        for (k=1; k<=ns; k++) {
          s = I[k]; w = "n/a"
          if ((s in E0) && (s in E1) && E0[s] != "x" && E1[s] != "x" && dt > 0) {
            d = E1[s] - E0[s]; if (d < 0 && EM[s] + 0 > 0) d += EM[s]
            if (d >= 0) { w = d / dt / 1e6; w = (w > 2000) ? "n/a" : sprintf("%.1f", w) }
          }
          tc = (T[s] ~ /^-?[0-9]+$/) ? sprintf("%.1f", T[s] / 1000) : "n/a"
          printf "%s,%s,%s,%s,%s,%s,%s,%s\n", ts, el, ph, s, w, tc, (mn[s] ? sprintf("%.0f", ms[s]/mn[s]) : "n/a"), (bn[s] ? sprintf("%.1f", bs[s]/bn[s]) : "n/a")
        }
      }' >> "$csv"
    mv -f "$st.new" "$st.prev" 2>/dev/null
    t0=$t1; e0=$e1
  done
  rm -f "$st.map" "$st.prev" "$st.new"
}
# cr_sock_json CSV PHASE_REGEX -> JSON array, one object per socket
cr_sock_json() {
  [ -s "$1" ] || { printf '[]'; return; }
  awk -F, -v ph="$2" -v layout="$(printf '%s' "$CR_SOCK_LAYOUT" | tr '\n' ';')" -v pl1s="${CR_SOCK_PL1:-}" '
    function num(v) { return (v ~ /^-?[0-9]+([.][0-9]+)?$/) }
    function st(k, v) { if (!num(v)) return; v += 0; n[k]++; sum[k] += v; if (n[k]==1 || v < mn[k]) mn[k] = v; if (n[k]==1 || v > mx[k]) mx[k] = v }
    function o(k, f) { if (!n[k]) return "null"; if (f=="avg") return sprintf("%.1f", sum[k]/n[k]); if (f=="max") return sprintf("%.1f", mx[k]); return sprintf("%.1f", mn[k]) }
    BEGIN { nl = split(layout, L, ";"); for (i=1;i<=nl;i++) { split(L[i], a, " "); if (a[1] != "") { thr[a[1]]=a[2]; cor[a[1]]=a[3]; nod[a[1]]=a[4] } }
            np = split(pl1s, P, " "); for (i=1;i<=np;i++) { split(P[i], b, ":"); pl1[b[1]] = b[2] } }
    NR > 1 && $3 ~ ("^(" ph ")$") { s=$4; seen[s]=1; st(s",w",$5); st(s",t",$6); st(s",m",$7); st(s",b",$8) }
    END {
      printf "["; first=1
      for (s in thr) all[s]=1; for (s in seen) all[s]=1
      cnt=0; for (s in all) ord[++cnt]=s+0
      for (i=1;i<=cnt;i++) for (j=i+1;j<=cnt;j++) if (ord[j] < ord[i]) { x=ord[i]; ord[i]=ord[j]; ord[j]=x }
      for (i=1;i<=cnt;i++) { s=ord[i]
        printf "%s{ \"socket\": %s, \"threads\": %s, \"cores\": %s, \"numa_nodes\": \"%s\", \"pl1_w\": %s, \"pkg_w_avg\": %s, \"pkg_w_max\": %s, \"temp_c_avg\": %s, \"temp_c_max\": %s, \"mhz_avg\": %s, \"mhz_min\": %s, \"busy_pct_avg\": %s, \"samples\": %d }", \
          (first ? "" : ", "), s, (thr[s]==""?"null":thr[s]), (cor[s]==""?"null":cor[s]), nod[s], (num(pl1[s]) ? pl1[s] : "null"), \
          o(s",w","avg"), o(s",w","max"), o(s",t","avg"), o(s",t","max"), o(s",m","avg"), o(s",m","min"), o(s",b","avg"), n[s",m"]
        first=0 }
      printf "]" }' "$1"
}

# --- telemetry sampler --------------------------------------------------------------
cr__now() { CR_NOW=${EPOCHREALTIME:-}; [ -n "$CR_NOW" ] || CR_NOW=$(date +%s.%N); }
cr__rd() { CR_V="n/a"; [ -n "${1-}" ] || return 0; { read -r CR_V < "$1"; } 2>/dev/null || CR_V="n/a"; [ -n "$CR_V" ] || CR_V="n/a"; }
cr__edelta() { # e0 e1 -> CR_D (uJ) or n/a
  if [[ ${1-} =~ ^[0-9]+$ && ${2-} =~ ^[0-9]+$ ]]; then
    CR_D=$(( $2 - $1 ))
    if [ "$CR_D" -lt 0 ]; then
      if [ "${CR_RAPL_MAX:-0}" -gt 0 ] 2>/dev/null; then CR_D=$(( CR_D + CR_RAPL_MAX )); else CR_D="n/a"; fi
    fi
  else CR_D="n/a"; fi
}
cr__freq_lines() {
  if [ ${#CR_FREQ_FILES[@]} -gt 0 ]; then
    grep -H . "${CR_FREQ_FILES[@]}" 2>/dev/null
  else
    awk -F: '/^processor/{p=$2+0} /^cpu MHz/{printf "/sys/devices/system/cpu/cpu%d/cpufreq/x:%d\n", p, $2*1000}' /proc/cpuinfo
  fi
}
cr__sampler_loop() {
  local csv=$1 tstart t0 t1 e0 e1 c0 c1 de dc tmp ph ld mt=0 ma=0 st=0 sf=0 k v _r pid
  cr__now; tstart=$CR_NOW; t0=$CR_NOW
  cr__rd "$CR_RAPL_PKG"; e0=$CR_V
  cr__rd "$CR_RAPL_CORE"; c0=$CR_V
  while [ -f "$CR_SAMPLE_FLAG" ]; do
    sleep 1
    cr__now; t1=$CR_NOW
    cr__rd "$CR_RAPL_PKG"; e1=$CR_V
    cr__rd "$CR_RAPL_CORE"; c1=$CR_V
    cr__edelta "$e0" "$e1"; de=$CR_D
    cr__edelta "$c0" "$c1"; dc=$CR_D
    cr__rd "$CR_TEMP_FILE"; tmp=$CR_V
    cr__rd "$CR_PHASE_FILE"; ph=$CR_V
    ld="n/a"; { read -r ld _r < /proc/loadavg; } 2>/dev/null
    while read -r k v _r; do
      case $k in MemTotal:) mt=$v;; MemAvailable:) ma=$v;; SwapTotal:) st=$v;; SwapFree:) sf=$v;; esac
    done < /proc/meminfo
    cr__freq_lines | awk -F: -v ts="$(printf '%(%H:%M:%S)T' -1)" -v t0="$t0" -v t1="$t1" -v ts0="$tstart" \
      -v de="$de" -v dc="$dc" -v tmp="$tmp" -v ph="$ph" -v ld="$ld" -v mt="$mt" -v ma="$ma" -v st="$st" -v sf="$sf" \
      -v ps=" ${CR_PSET:-} " -v es=" ${CR_ESET:-} " -v hy="${CR_HYBRID:-0}" '
      function pw(d,  w){ if (d=="n/a" || dt<=0) return "n/a"; w=d/dt/1e6; if (w<0 || w>2000) return "n/a"; return sprintf("%.1f", w) }
      {
        path=$1; khz=$2+0; c=-1; if (match(path, /\/cpu[0-9]+\//)) c=substr(path, RSTART+4, RLENGTH-5)
        mhz=khz/1000; n++; s+=mhz; if (mhz>mx) mx=mhz
        if (hy==1) { if (index(ps," " c " ")) {pn++; psum+=mhz} else if (index(es," " c " ")) {en++; esum+=mhz} }
      }
      END{
        dt=t1-t0
        avg=(n? sprintf("%.0f", s/n) : "n/a"); mxs=(n? sprintf("%.0f", mx) : "n/a")
        pa=(pn? sprintf("%.0f", psum/pn) : "n/a"); ea=(en? sprintf("%.0f", esum/en) : "n/a")
        t=(tmp ~ /^-?[0-9]+$/ ? sprintf("%.1f", tmp/1000) : "n/a")
        printf "%s,%.1f,%s,%s,%s,%s,%s,%s,%s,%s,%s,%.0f,%.0f,%.0f\n", ts, t1-ts0, ph, pw(de), pw(dc), t, avg, mxs, pa, ea, ld, (mt-ma)/1024, ma/1024, (st-sf)/1024
      }' >> "$csv"
    cr__watchdog_check "$ma" "$(dirname "$csv")"
    t0=$t1; e0=$e1; c0=$c1
  done
}
# memory watchdog (used by ram.sh): stop the workload if the host runs short
cr__watchdog_check() { # MemAvailable_kB dir
  local ma=${1:-0} pid
  if [ "${CR_MEM_FLOOR_KB:-0}" -gt 0 ] && [ "$ma" -gt 0 ] && [ "$ma" -lt "$CR_MEM_FLOOR_KB" ] && [ -n "${CR_KILL_FILE:-}" ] && [ -s "$CR_KILL_FILE" ]; then
    read -r pid < "$CR_KILL_FILE"
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
      printf '[%(%H:%M:%S)T] watchdog: MemAvailable %s kB < floor %s kB, sending SIGTERM to pid %s\n' -1 "$ma" "$CR_MEM_FLOOR_KB" "$pid" >> "$2/watchdog.txt"
      kill -TERM "$pid" 2>/dev/null
    fi
  fi
}
cr__watchdog_loop() { # dir ; only used together with the telemetry.sh sampler
  local k v _r ma
  while [ -f "$CR_SAMPLE_FLAG" ]; do
    sleep 1
    ma=0
    while read -r k v _r; do [ "$k" = MemAvailable: ] && { ma=$v; break; }; done < /proc/meminfo
    cr__watchdog_check "$ma" "$1"
  done
}
cr_phase() {
  if [ "$CR_USE_TEL" -eq 1 ]; then tel_phase "$1"
  elif [ -n "$CR_PHASE_FILE" ]; then echo "$1" > "$CR_PHASE_FILE"; fi
  return 0
}
# cr_sampler_start CSV [WORKDIR]: shared telemetry.sh sampler ("cpu mem" groups)
# when available, else the built-in one. Same idea, column names in COL_*.
cr_sampler_start() {
  local dir=${2:-$(dirname "$1")}
  CR_SAMPLE_FLAG="$dir/.sampling"; CR_PHASE_FILE="$dir/.phase"
  : > "$CR_SAMPLE_FLAG"
  CR_SOCK_CSV="$dir/telemetry-socket-1s.csv"
  echo "ts,elapsed_s,phase,socket,pkg_w,temp_c,avg_mhz,busy_pct" > "$CR_SOCK_CSV"
  [ ${#CR_SOCK_IDS[@]} -gt 0 ] || cr_socket_detect
  cr__sock_loop "$CR_SOCK_CSV" "$dir/.sockstate" &
  CR_SOCK_PID=$!
  if [ "$CR_USE_TEL" -eq 1 ]; then
    tel_phase idle
    tel_sampler_start "$1" cpu mem
    CR_SAMPLER_PID=""
    if [ "${CR_MEM_FLOOR_KB:-0}" -gt 0 ]; then cr__watchdog_loop "$dir" & CR_WATCHDOG_PID=$!; fi
  else
    echo idle > "$CR_PHASE_FILE"
    echo "$CR_CSV_HEADER" > "$1"
    cr__sampler_loop "$1" &
    CR_SAMPLER_PID=$!
  fi
}
cr_sampler_stop() {
  [ -n "$CR_SAMPLE_FLAG" ] && rm -f "$CR_SAMPLE_FLAG"
  if [ "$CR_USE_TEL" -eq 1 ]; then tel_sampler_stop; fi
  if [ -n "$CR_SAMPLER_PID" ]; then wait "$CR_SAMPLER_PID" 2>/dev/null; CR_SAMPLER_PID=""; fi
  if [ -n "${CR_WATCHDOG_PID:-}" ]; then wait "$CR_WATCHDOG_PID" 2>/dev/null; CR_WATCHDOG_PID=""; fi
  if [ -n "${CR_SOCK_PID:-}" ]; then wait "$CR_SOCK_PID" 2>/dev/null; CR_SOCK_PID=""; fi
  [ -n "$CR_PHASE_FILE" ] && rm -f "$CR_PHASE_FILE"
  return 0
}

# cr_stat CSV PHASE_REGEX COLUMN FN(avg|min|max|n) -> number or n/a
cr_stat() {
  [ -s "$1" ] || { printf 'n/a'; return; }
  awk -F, -v ph="$2" -v col="$3" -v fn="$4" '
    NR==1 { for (i=1;i<=NF;i++) if ($i==col) c=i; next }
    c && $3 ~ ("^(" ph ")$") && $c ~ /^-?[0-9]+([.][0-9]+)?$/ && !(col ~ /_[wW]$/ && ($c+0 > 2000 || $c+0 < 0)) { v=$c+0; n++; s+=v; if (n==1||v<mn) mn=v; if (n==1||v>mx) mx=v }
    END {
      if (!n) { printf "n/a"; exit }
      if (fn=="avg") printf "%.1f", s/n; else if (fn=="max") printf "%.1f", mx; else if (fn=="min") printf "%.1f", mn; else printf "%d", n
    }' "$1"
}

# Kill our background jobs on exit
cr_cleanup_jobs() {
  cr_sampler_stop
  [ "$CR_USE_TEL" -eq 1 ] && declare -F tel_cleanup >/dev/null && tel_cleanup
  local j
  # only our own background jobs (stress-ng/turbostat via timeout); never the tee logger
  for j in $(jobs -p 2>/dev/null); do kill -TERM "$j" 2>/dev/null; done
}

# --- shared telemetry (scripts/telemetry.sh), optional ------------------------------
CR_SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
CR_USE_TEL=0
if [ "${CR_NO_TELEMETRY_SH:-0}" != 1 ] && [ -r "$CR_SCRIPT_DIR/telemetry.sh" ]; then
  # shellcheck source=telemetry.sh
  if . "$CR_SCRIPT_DIR/telemetry.sh" && declare -F tel_sampler_start >/dev/null && declare -F tel_phase >/dev/null \
     && declare -F tel_sampler_stop >/dev/null; then
    CR_USE_TEL=1
  fi
fi
# CSV column names (telemetry.sh vs built-in sampler)
if [ "$CR_USE_TEL" -eq 1 ]; then
  COL_PKGW=cpu_pkg_w; COL_COREW=cpu_core_w; COL_TEMP=cpu_temp_c; COL_MHZ=cpu_avg_mhz; COL_MAXMHZ=cpu_max_mhz
  COL_PMHZ=cpu_pcore_mhz; COL_EMHZ=cpu_ecore_mhz; COL_USED=mem_used_mb; COL_AVAIL=mem_avail_mb; COL_SWAP=swap_used_mb
else
  COL_PKGW=pkg_W; COL_COREW=core_W; COL_TEMP=pkg_temp_C; COL_MHZ=avg_MHz; COL_MAXMHZ=max_MHz
  COL_PMHZ=pcore_avg_MHz; COL_EMHZ=ecore_avg_MHz; COL_USED=mem_used_MB; COL_AVAIL=mem_avail_MB; COL_SWAP=swap_used_MB
fi

# library mode: stop here when sourced by ram.sh
if [ "${CR_LIB_ONLY:-0}" = 1 ]; then
  return 0 2>/dev/null || exit 0
fi

# =============================================================================
# CPU test main
# =============================================================================
usage() { sed -n '3,40p' "$0" | sed 's/^# \{0,1\}//'; }

DURATION=""; OUT=""; NO_TURBOSTAT=0
while [ $# -gt 0 ]; do
  case "$1" in
    --duration) DURATION=${2-}; shift 2 || cr_die "--duration needs a value" ;;
    --out) OUT=${2-}; shift 2 || cr_die "--out needs a value" ;;
    --no-install) CR_NO_INSTALL=1; shift ;;
    --no-turbostat) NO_TURBOSTAT=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; cr_die "unknown argument: $1" ;;
  esac
done
[[ $DURATION =~ ^[0-9]+$ ]] && [ "$DURATION" -ge 10 ] && [ "$DURATION" -le 3600 ] || cr_die "--duration must be an integer 10..3600 (seconds)"
[ -n "$OUT" ] || cr_die "--out DIR is required"
cr_require_root_linux

mkdir -p "$OUT" || cr_die "cannot create $OUT"
OUT=$(cd "$OUT" && pwd)
CR_PKG_RECORD="$(dirname "$OUT")/installed-packages.txt"
exec > >(tee -a "$OUT/run.log") 2>&1
trap 'cr_cleanup_jobs' EXIT
trap 'cr_log "interrupted"; exit 130' INT TERM

STARTED=$(date -Is)
cr_log "CPU test starting: duration=${DURATION}s out=$OUT"

# ---- tools ----------------------------------------------------------------------
HAVE_STRESS=0; HAVE_SYSBENCH=0; SEVENZ=""
cr_need stress-ng stress-ng && HAVE_STRESS=1
cr_need sysbench sysbench && HAVE_SYSBENCH=1
find_7z() { local b; for b in 7z 7zz 7za; do command -v "$b" >/dev/null 2>&1 && { SEVENZ=$b; return 0; }; done; return 1; }
if ! find_7z; then
  for pkg in 7zip p7zip-full; do cr_apt_install "$pkg"; find_7z && break; done
fi
HAVE_TURBOSTAT=0
[ "$NO_TURBOSTAT" -eq 0 ] && command -v turbostat >/dev/null 2>&1 && HAVE_TURBOSTAT=1

# ---- inventory + health pre ----------------------------------------------------------
cr_detect_topology
cr_detect_sensors
cr_rapl_limits > "$OUT/rapl-limits.txt" 2>&1
PL1=$(cr_rapl_pl long_term); PL2=$(cr_rapl_pl short_term)   # summed over all sockets
CR_SOCK_PL1=""
for sk in "${CR_SOCK_IDS[@]}"; do CR_SOCK_PL1+="$sk:$(cr_rapl_pl long_term "$sk") "; done
{
  echo "model: $CR_MODEL"; echo "vendor: $CR_VENDOR"; echo "microcode: $CR_MICROCODE"
  echo "sockets: $CR_SOCKETS cores: $CR_CORES threads: $CR_NPROC numa_nodes: $CR_NUMA_NODES"
  echo "per-socket (socket threads cores numa-nodes):"; printf '%s\n' "$CR_SOCK_LAYOUT" | sed 's/^/  /'
  echo "per-socket PL1: ${CR_SOCK_PL1:-n/a}  power files: $(for sk in "${CR_SOCK_IDS[@]}"; do printf '%s=%s ' "$sk" "${CR_SOCK_EF[$sk]:-n/a}"; done)"
  echo "per-socket temp: $(for sk in "${CR_SOCK_IDS[@]}"; do printf '%s=%s ' "$sk" "${CR_SOCK_TF[$sk]:-n/a}"; done)"
  echo "hybrid: $CR_HYBRID pcpus: ${CR_PSET:-n/a} ecpus: ${CR_ESET:-n/a} pcores: $CR_PCORES ecores: $CR_ECORES"
  echo "max_mhz: $CR_MAX_MHZ governor: $CR_GOVERNOR driver: $CR_FREQ_DRIVER epp: $CR_EPP no_turbo: $CR_NO_TURBO"
  echo "rapl: pkg=${CR_RAPL_PKG:-n/a} core=${CR_RAPL_CORE:-n/a} PL1=${PL1}W PL2=${PL2}W"
  echo "temp sensor: $CR_TEMP_SRC (${CR_TEMP_FILE:-n/a})"
  echo "running guests: VMs=$CR_RUNNING_VMS CTs=$CR_RUNNING_CTS"
  echo "kernel: $(uname -r)"; echo "pve: $(pveversion 2>/dev/null || echo n/a)"
  echo "tools: stress-ng=$(stress-ng --version 2>/dev/null | head -1) sysbench=$(sysbench --version 2>/dev/null) 7z=${SEVENZ:-none} turbostat=$HAVE_TURBOSTAT"
  echo; lscpu 2>/dev/null
} > "$OUT/inventory.txt"
cr_log "CPU: $CR_MODEL | ${CR_SOCKETS} socket(s), ${CR_CORES} cores / ${CR_NPROC} threads, ${CR_NUMA_NODES} NUMA node(s) | hybrid=$CR_HYBRID | max ${CR_MAX_MHZ} MHz | temp=$CR_TEMP_SRC"
if [ $((CR_RUNNING_VMS + CR_RUNNING_CTS)) -gt 0 ]; then
  cr_warn "$CR_RUNNING_VMS VM(s) and $CR_RUNNING_CTS container(s) are running; they compete for CPU, so scores may read low (guests were not touched)"
fi
read -r THR_CORE_PRE THR_PKG_PRE <<<"$(cr_throttle "$OUT/throttle-pre.txt")"
DMESG_MARK=$(cr_dmesg_mark)

# ---- telemetry ---------------------------------------------------------------------
CSV="$OUT/telemetry-1s.csv"
cr_sampler_start "$CSV" "$OUT"
cr_phase idle; cr_log "idle baseline 5 s"; sleep 5

# ---- 1. stress phase -------------------------------------------------------------------
STRESS_RC="n/a"; STRESS_OPS="n/a"; STRESS_PASSED="n/a"; STRESS_FAILED="n/a"
if [ "$HAVE_STRESS" -eq 1 ]; then
  if [ "$HAVE_TURBOSTAT" -eq 1 ]; then
    iters=$(( DURATION / 5 )); [ "$iters" -lt 1 ] && iters=1
    turbostat --quiet --interval 5 --num_iterations "$iters" \
      --show Core,CPU,Busy%,Bzy_MHz,CoreTmp,PkgTmp,PkgWatt,CorWatt > "$OUT/turbostat-stress.txt" 2>&1 &
    TS_PID=$!
  fi
  cr_phase stress
  cr_log "STRESS: stress-ng --cpu $CR_NPROC --cpu-method matrixprod for ${DURATION}s"
  timeout --kill-after=30 $((DURATION + 120)) stress-ng --cpu "$CR_NPROC" --cpu-method matrixprod \
    --timeout "${DURATION}s" --metrics-brief --tz -Y "$OUT/stress-ng.yaml" > "$OUT/stress-ng.log" 2>&1 &
  wait $!; STRESS_RC=$?
  cr_phase cooldown
  if [ "$HAVE_TURBOSTAT" -eq 1 ]; then
    sleep 2; kill "$TS_PID" 2>/dev/null; wait "$TS_PID" 2>/dev/null
  fi
  STRESS_OPS=$(awk '/bogo-ops-per-second-real-time:/{print $2; exit}' "$OUT/stress-ng.yaml" 2>/dev/null)
  cr_is_num "$STRESS_OPS" || STRESS_OPS=$(awk '/metrc:/ && $4=="cpu" && $5 ~ /^[0-9]+$/ {print $9; exit}' "$OUT/stress-ng.log")
  cr_is_num "$STRESS_OPS" || STRESS_OPS="n/a"
  STRESS_PASSED=$(grep -oE 'passed: [0-9]+' "$OUT/stress-ng.log" | head -1 | awk '{print $2}')
  STRESS_FAILED=$(grep -oE 'failed: [0-9]+' "$OUT/stress-ng.log" | head -1 | awk '{print $2}')
  : "${STRESS_PASSED:=n/a}" "${STRESS_FAILED:=n/a}"
  cr_log "stress-ng rc=$STRESS_RC bogo-ops/s=$STRESS_OPS passed=$STRESS_PASSED failed=$STRESS_FAILED"
  tail -15 "$OUT/stress-ng.log"
  if [ "$STRESS_RC" -ne 0 ] || { cr_is_num "$STRESS_FAILED" && [ "$STRESS_FAILED" -gt 0 ]; }; then
    cr_error "stress-ng reported a failure (rc=$STRESS_RC, failed=$STRESS_FAILED) - see stress-ng.log"
  fi
else
  cr_skip "stress-ng" "stress-ng not installed and could not be installed"
fi
read -r THR_CORE_MID THR_PKG_MID <<<"$(cr_throttle "$OUT/throttle-post-stress.txt")"
cr_log "cooldown 10 s"; sleep 10

# ---- 2. sysbench ---------------------------------------------------------------------------
SB1="n/a"; SBMT="n/a"
if [ "$HAVE_SYSBENCH" -eq 1 ]; then
  cr_phase sysbench-1t; cr_log "sysbench cpu 1 thread, 10 s"
  PIN=()
  [ "$CR_HYBRID" -eq 1 ] && command -v taskset >/dev/null 2>&1 && PIN=(taskset -c "$CR_FIRST_PCPU")
  timeout 60 "${PIN[@]+"${PIN[@]}"}" sysbench cpu --cpu-max-prime=20000 --threads=1 --time=10 run > "$OUT/sysbench-1t.txt" 2>&1
  SB1=$(awk -F: '/events per second/{gsub(/ /,"",$2); print $2; exit}' "$OUT/sysbench-1t.txt")
  cr_phase rest; sleep 5
  cr_phase sysbench-mt; cr_log "sysbench cpu $CR_NPROC threads, 10 s"
  timeout 60 sysbench cpu --cpu-max-prime=20000 --threads="$CR_NPROC" --time=10 run > "$OUT/sysbench-mt.txt" 2>&1
  SBMT=$(awk -F: '/events per second/{gsub(/ /,"",$2); print $2; exit}' "$OUT/sysbench-mt.txt")
  cr_is_num "$SB1" || { SB1="n/a"; cr_warn "sysbench 1-thread produced no result (see sysbench-1t.txt)"; }
  cr_is_num "$SBMT" || { SBMT="n/a"; cr_warn "sysbench multi-thread produced no result (see sysbench-mt.txt)"; }
  cr_log "sysbench events/s: 1t=$SB1 ${CR_NPROC}t=$SBMT"
  cr_phase rest; sleep 10
else
  cr_skip "sysbench" "sysbench not installed and could not be installed"
fi

# ---- 3. 7-Zip ------------------------------------------------------------------------------
Z_MT="n/a"; Z_1T="n/a"
if [ -n "$SEVENZ" ]; then
  cr_phase 7zip-mt; cr_log "7-Zip benchmark, $CR_NPROC threads ($SEVENZ b 3 -mmt$CR_NPROC)"
  timeout --kill-after=10 600 "$SEVENZ" b 3 "-mmt$CR_NPROC" > "$OUT/7z-mt.txt" 2>&1; echo "rc=$?" >> "$OUT/7z-mt.txt"
  Z_MT=$(awk '/^Tot:/{print $NF; exit}' "$OUT/7z-mt.txt")
  cr_phase rest; sleep 10
  cr_phase 7zip-1t; cr_log "7-Zip benchmark, 1 thread ($SEVENZ b 1 -mmt1)"
  PIN=()
  [ "$CR_HYBRID" -eq 1 ] && command -v taskset >/dev/null 2>&1 && PIN=(taskset -c "$CR_FIRST_PCPU")
  timeout --kill-after=10 600 "${PIN[@]+"${PIN[@]}"}" "$SEVENZ" b 1 -mmt1 > "$OUT/7z-1t.txt" 2>&1
  echo "rc=$?" >> "$OUT/7z-1t.txt"
  Z_1T=$(awk '/^Tot:/{print $NF; exit}' "$OUT/7z-1t.txt")
  cr_is_num "$Z_MT" || { Z_MT="n/a"; cr_warn "7-Zip multi-thread produced no rating (see 7z-mt.txt)"; }
  cr_is_num "$Z_1T" || { Z_1T="n/a"; cr_warn "7-Zip single-thread produced no rating (see 7z-1t.txt)"; }
  cr_log "7-Zip MIPS: mt=$Z_MT 1t=$Z_1T"
  cr_phase rest; sleep 3
else
  cr_skip "7zip" "7z/7zz not installed and could not be installed (packages 7zip / p7zip-full)"
fi

cr_sampler_stop

# ---- health post -----------------------------------------------------------------------------
read -r THR_CORE_POST THR_PKG_POST <<<"$(cr_throttle "$OUT/throttle-post.txt")"
read -r HWERR SOFTERR <<<"$(cr_dmesg_new "$DMESG_MARK" "$OUT/dmesg-new.txt")"
[ "${HWERR:-0}" -gt 0 ] 2>/dev/null && cr_error "$HWERR kernel hardware-error line(s) (MCE/EDAC) appeared during the test (see dmesg-new-hw-errors.txt)"
[ "${SOFTERR:-0}" -gt 0 ] 2>/dev/null && cr_warn "$SOFTERR kernel warning line(s) (OOM/lockup/thermal) appeared during the test (see dmesg-new-hw-errors.txt)"
THR_DELTA="n/a"
if cr_is_num "$THR_CORE_PRE" && cr_is_num "$THR_CORE_POST"; then
  THR_DELTA=$(( (THR_CORE_POST - THR_CORE_PRE) + (THR_PKG_POST - THR_PKG_PRE) ))
  [ "$THR_DELTA" -gt 0 ] && cr_warn "thermal throttle counters increased by $THR_DELTA during the test (core $THR_CORE_PRE->$THR_CORE_POST, package $THR_PKG_PRE->$THR_PKG_POST)"
fi

# ---- telemetry stats ---------------------------------------------------------------------------
s() { cr_stat "$CSV" "$1" "$2" "$3"; }
IDLE_W=$(s idle "$COL_PKGW" avg); IDLE_T=$(s idle "$COL_TEMP" avg); IDLE_MHZ=$(s idle "$COL_MHZ" avg)
ST_W_AVG=$(s stress "$COL_PKGW" avg); ST_W_MAX=$(s stress "$COL_PKGW" max); ST_CW_AVG=$(s stress "$COL_COREW" avg)
ST_T_AVG=$(s stress "$COL_TEMP" avg); ST_T_MAX=$(s stress "$COL_TEMP" max)
ST_MHZ=$(s stress "$COL_MHZ" avg); ST_P_MHZ=$(s stress "$COL_PMHZ" avg); ST_E_MHZ=$(s stress "$COL_EMHZ" avg)
ST_N=$(s stress "$COL_MHZ" n); [ "$ST_N" = n/a ] && ST_N=$(s stress "$COL_TEMP" n)
ALL_T_MAX=$(s '.*' "$COL_TEMP" max); ALL_W_MAX=$(s '.*' "$COL_PKGW" max)
SB1_MAXMHZ=$(s sysbench-1t "$COL_MAXMHZ" max); SB1_W=$(s sysbench-1t "$COL_PKGW" avg)
SBMT_W=$(s sysbench-mt "$COL_PKGW" avg); SBMT_MHZ=$(s sysbench-mt "$COL_MHZ" avg); SBMT_T=$(s sysbench-mt "$COL_TEMP" max)
Z_MT_W=$(s 7zip-mt "$COL_PKGW" avg); Z_MT_T=$(s 7zip-mt "$COL_TEMP" max); Z_1T_MAXMHZ=$(s 7zip-1t "$COL_MAXMHZ" max)

SOCK_IDLE_JSON=$(cr_sock_json "$OUT/telemetry-socket-1s.csv" idle)
SOCK_STRESS_JSON=$(cr_sock_json "$OUT/telemetry-socket-1s.csv" stress)
SOCK_7Z_JSON=$(cr_sock_json "$OUT/telemetry-socket-1s.csv" 7zip-mt)
# a socket that stayed well below the others under all-thread load points at a scheduling/affinity or cooling problem
if [ "$CR_SOCKETS" -gt 1 ]; then
  SOCK_IMBAL=$(printf '%s' "$SOCK_STRESS_JSON" | grep -oE '"busy_pct_avg": [0-9.]+' | awk '{v=$2+0; if(n==0||v<mn)mn=v; if(v>mx)mx=v; n++} END{if(n>1 && mx-mn>15) printf "%.0f-%.0f", mn, mx}')
  [ -n "$SOCK_IMBAL" ] && cr_warn "per-socket load was uneven during the stress phase (busy % per socket ranged $SOCK_IMBAL); see per_socket in summary.json"
fi
BOOST_PCT=$(cr_pct "$SB1_MAXMHZ" "$CR_MAX_MHZ")
SB_SCALE=$(cr_div "$SBMT" "$SB1" "%.1f")
Z_SCALE=$(cr_div "$Z_MT" "$Z_1T" "%.1f")
OPS_PER_W=$(cr_div "$STRESS_OPS" "$ST_W_AVG" "%.1f")
Z_PER_W=$(cr_div "$Z_MT" "$Z_MT_W" "%.0f")
SB_PER_W=$(cr_div "$SBMT" "$SBMT_W" "%.1f")
POWER_LIMITED="n/a"
if cr_is_num "$ST_W_AVG" && cr_is_num "$PL1" && [ "$PL1" != 0 ]; then
  POWER_LIMITED=$(awk -v w="$ST_W_AVG" -v l="$PL1" 'BEGIN{print (w >= 0.95*l) ? "yes" : "no"}')
fi
TEMP_HEADROOM="n/a"
TJMAX="n/a"
[ -n "$CR_TEMP_FILE" ] && [ -r "${CR_TEMP_FILE%_input}_crit" ] && TJMAX=$(cat "${CR_TEMP_FILE%_input}_crit" 2>/dev/null)
[ -n "$CR_TEMP_FILE" ] && [ "$TJMAX" = n/a ] && [ -r "${CR_TEMP_FILE%_input}_max" ] && TJMAX=$(cat "${CR_TEMP_FILE%_input}_max" 2>/dev/null)
if cr_is_num "$TJMAX" && [ "$TJMAX" -gt 0 ] && cr_is_num "$ALL_T_MAX"; then
  TJMAX=$(cr_calc "$TJMAX/1000" "%.0f"); TEMP_HEADROOM=$(cr_calc "$TJMAX - $ALL_T_MAX" "%.0f")
else TJMAX="n/a"; fi

# ---- status ---------------------------------------------------------------------------------------
STATUS=ok
[ ${#CR_WARNINGS[@]} -gt 0 ] && STATUS=warn
[ ${#CR_ERRORS[@]} -gt 0 ] && STATUS=fail
if [ "$HAVE_STRESS" -eq 0 ] && [ "$HAVE_SYSBENCH" -eq 0 ] && [ -z "$SEVENZ" ]; then STATUS=skipped; fi
FINISHED=$(date -Is)

# ---- summary.json -----------------------------------------------------------------------------------
{
  printf '{\n'
  printf '  "part": "cpu",\n  "schema": 1,\n  "status": %s,\n' "$(cr_jstr "$STATUS")"
  printf '  "started": %s,\n  "finished": %s,\n  "duration_s": %s,\n' "$(cr_jstr "$STARTED")" "$(cr_jstr "$FINISHED")" "$DURATION"
  printf '  "host": {\n'
  printf '    "model": %s, "vendor": %s, "microcode": %s,\n' "$(cr_jstr "$CR_MODEL")" "$(cr_jstr "$CR_VENDOR")" "$(cr_jstr "$CR_MICROCODE")"
  printf '    "sockets": %s, "cores": %s, "threads": %s, "numa_nodes": %s,\n' "$(cr_jnum "$CR_SOCKETS")" "$(cr_jnum "$CR_CORES")" "$(cr_jnum "$CR_NPROC")" "$(cr_jnum "$CR_NUMA_NODES")"
  printf '    "hybrid": %s, "p_cores": %s, "e_cores": %s, "p_cpus": %s, "e_cpus": %s,\n' "$(cr_jbool "$CR_HYBRID")" "$(cr_jnum "$CR_PCORES")" "$(cr_jnum "$CR_ECORES")" "$(cr_jstr "$CR_PSET")" "$(cr_jstr "$CR_ESET")"
  printf '    "max_mhz": %s, "governor": %s, "freq_driver": %s, "epp": %s, "turbo_disabled": %s,\n' "$(cr_jnum "$CR_MAX_MHZ")" "$(cr_jstr "$CR_GOVERNOR")" "$(cr_jstr "$CR_FREQ_DRIVER")" "$(cr_jstr "$CR_EPP")" "$(cr_jstr "$CR_NO_TURBO")"
  printf '    "rapl_pl1_w": %s, "rapl_pl2_w": %s, "tjmax_c": %s,\n' "$(cr_jnum "$PL1")" "$(cr_jnum "$PL2")" "$(cr_jnum "$TJMAX")"
  printf '    "power_sensor": %s, "temp_sensor": %s,\n' "$(cr_jstr "${CR_RAPL_PKG:-n/a}")" "$(cr_jstr "$CR_TEMP_SRC")"
  printf '    "running_vms": %s, "running_cts": %s, "kernel": %s\n  },\n' "$(cr_jnum "$CR_RUNNING_VMS")" "$(cr_jnum "$CR_RUNNING_CTS")" "$(cr_jstr "$(uname -r)")"
  printf '  "idle": { "pkg_w_avg": %s, "pkg_temp_c_avg": %s, "avg_mhz": %s },\n' "$(cr_jnum "$IDLE_W")" "$(cr_jnum "$IDLE_T")" "$(cr_jnum "$IDLE_MHZ")"
  printf '  "stress": {\n'
  printf '    "tool": "stress-ng --cpu %s --cpu-method matrixprod", "seconds": %s, "rc": %s,\n' "$CR_NPROC" "$DURATION" "$(cr_jnum "$STRESS_RC")"
  printf '    "bogo_ops_per_s": %s, "workers_passed": %s, "workers_failed": %s, "samples": %s,\n' "$(cr_jnum "$STRESS_OPS")" "$(cr_jnum "$STRESS_PASSED")" "$(cr_jnum "$STRESS_FAILED")" "$(cr_jnum "$ST_N")"
  printf '    "pkg_w_avg": %s, "pkg_w_max": %s, "core_w_avg": %s,\n' "$(cr_jnum "$ST_W_AVG")" "$(cr_jnum "$ST_W_MAX")" "$(cr_jnum "$ST_CW_AVG")"
  printf '    "pkg_temp_c_avg": %s, "pkg_temp_c_max": %s,\n' "$(cr_jnum "$ST_T_AVG")" "$(cr_jnum "$ST_T_MAX")"
  printf '    "all_core_mhz_avg": %s, "pcore_mhz_avg": %s, "ecore_mhz_avg": %s,\n' "$(cr_jnum "$ST_MHZ")" "$(cr_jnum "$ST_P_MHZ")" "$(cr_jnum "$ST_E_MHZ")"
  printf '    "at_power_limit": %s\n  },\n' "$(cr_jstr "$POWER_LIMITED")"
  printf '  "per_socket": {\n    "telemetry_csv": "telemetry-socket-1s.csv",\n    "idle": %s,\n    "stress": %s,\n    "7zip_mt": %s\n  },\n' "$SOCK_IDLE_JSON" "$SOCK_STRESS_JSON" "$SOCK_7Z_JSON"
  printf '  "benchmarks": {\n'
  printf '    "sysbench_1t_events_s": %s, "sysbench_mt_events_s": %s, "sysbench_mt_threads": %s, "sysbench_scaling_x": %s,\n' "$(cr_jnum "$SB1")" "$(cr_jnum "$SBMT")" "$CR_NPROC" "$(cr_jnum "$SB_SCALE")"
  printf '    "sysbench_1t_max_mhz": %s, "boost_pct_of_max": %s, "sysbench_1t_pkg_w_avg": %s,\n' "$(cr_jnum "$SB1_MAXMHZ")" "$(cr_jnum "$BOOST_PCT")" "$(cr_jnum "$SB1_W")"
  printf '    "sysbench_mt_pkg_w_avg": %s, "sysbench_mt_mhz_avg": %s, "sysbench_mt_temp_c_max": %s,\n' "$(cr_jnum "$SBMT_W")" "$(cr_jnum "$SBMT_MHZ")" "$(cr_jnum "$SBMT_T")"
  printf '    "7zip_binary": %s, "7zip_mt_mips": %s, "7zip_1t_mips": %s, "7zip_scaling_x": %s,\n' "$(cr_jstr "${SEVENZ:-none}")" "$(cr_jnum "$Z_MT")" "$(cr_jnum "$Z_1T")" "$(cr_jnum "$Z_SCALE")"
  printf '    "7zip_mt_pkg_w_avg": %s, "7zip_mt_temp_c_max": %s, "7zip_1t_max_mhz": %s\n  },\n' "$(cr_jnum "$Z_MT_W")" "$(cr_jnum "$Z_MT_T")" "$(cr_jnum "$Z_1T_MAXMHZ")"
  printf '  "efficiency": { "stress_ops_per_w": %s, "7zip_mips_per_w": %s, "sysbench_mt_events_per_w": %s },\n' "$(cr_jnum "$OPS_PER_W")" "$(cr_jnum "$Z_PER_W")" "$(cr_jnum "$SB_PER_W")"
  printf '  "peaks": { "pkg_temp_c_max": %s, "pkg_w_max": %s, "temp_headroom_c": %s },\n' "$(cr_jnum "$ALL_T_MAX")" "$(cr_jnum "$ALL_W_MAX")" "$(cr_jnum "$TEMP_HEADROOM")"
  printf '  "throttle": { "core_before": %s, "pkg_before": %s, "core_after_stress": %s, "pkg_after_stress": %s, "core_after": %s, "pkg_after": %s, "increase": %s },\n' \
    "$(cr_jnum "$THR_CORE_PRE")" "$(cr_jnum "$THR_PKG_PRE")" "$(cr_jnum "$THR_CORE_MID")" "$(cr_jnum "$THR_PKG_MID")" "$(cr_jnum "$THR_CORE_POST")" "$(cr_jnum "$THR_PKG_POST")" "$(cr_jnum "$THR_DELTA")"
  printf '  "kernel_hw_error_lines": %s, "kernel_warning_lines": %s,\n' "$(cr_jnum "${HWERR:-0}")" "$(cr_jnum "${SOFTERR:-0}")"
  printf '  "scores": [\n'
  printf '    { "name": "stress-ng matrixprod all threads", "value": %s, "unit": "bogo-ops/s", "pct_of_expected": null, "reference": "no cross-machine reference; pass = 0 failed workers, no throttling" },\n' "$(cr_jnum "$STRESS_OPS")"
  printf '    { "name": "7-Zip multi-thread", "value": %s, "unit": "MIPS", "pct_of_expected": null, "reference": "compare with published 7-Zip results for this CPU model" },\n' "$(cr_jnum "$Z_MT")"
  printf '    { "name": "7-Zip single-thread", "value": %s, "unit": "MIPS", "pct_of_expected": null, "reference": "compare with published 7-Zip single-thread results" },\n' "$(cr_jnum "$Z_1T")"
  printf '    { "name": "sysbench cpu 1 thread", "value": %s, "unit": "events/s", "pct_of_expected": null, "reference": "published sysbench prime=20000 results" },\n' "$(cr_jnum "$SB1")"
  printf '    { "name": "sysbench cpu all threads", "value": %s, "unit": "events/s", "pct_of_expected": null, "reference": "scaling vs 1 thread (sysbench_scaling_x)" },\n' "$(cr_jnum "$SBMT")"
  printf '    { "name": "single-core boost clock", "value": %s, "unit": "MHz", "pct_of_expected": %s, "reference": "advertised max frequency %s MHz" }\n' "$(cr_jnum "$SB1_MAXMHZ")" "$(cr_jnum "$BOOST_PCT")" "$CR_MAX_MHZ"
  printf '  ],\n'
  printf '  "errors": %s,\n' "$(cr_jarr "${CR_ERRORS[@]+"${CR_ERRORS[@]}"}")"
  printf '  "warnings": %s,\n' "$(cr_jarr "${CR_WARNINGS[@]+"${CR_WARNINGS[@]}"}")"
  printf '  "skipped": %s,\n' "$(cr_jarr "${CR_SKIPPED[@]+"${CR_SKIPPED[@]}"}")"
  printf '  "files": { "telemetry_csv": "telemetry-1s.csv", "socket_telemetry_csv": "telemetry-socket-1s.csv", "log": "run.log" }\n'
  printf '}\n'
} > "$OUT/summary.json"

# ---- summary.txt ------------------------------------------------------------------------------------
{
  echo "CPU test - $CR_MODEL ($CR_CORES cores / $CR_NPROC threads$( [ "$CR_HYBRID" -eq 1 ] && echo ", hybrid $CR_PCORES P + $CR_ECORES E"))"
  echo "status: $STATUS   started $STARTED   finished $FINISHED"
  echo "idle: ${IDLE_W} W, ${IDLE_T} C, ${IDLE_MHZ} MHz"
  echo "stress ${DURATION}s (stress-ng matrixprod x$CR_NPROC): ${STRESS_OPS} bogo-ops/s, passed=$STRESS_PASSED failed=$STRESS_FAILED"
  echo "  power avg/max ${ST_W_AVG}/${ST_W_MAX} W (PL1 ${PL1} W, at limit: $POWER_LIMITED), core ${ST_CW_AVG} W"
  echo "  temp avg/max ${ST_T_AVG}/${ST_T_MAX} C (TjMax ${TJMAX} C), clocks all ${ST_MHZ} MHz, P ${ST_P_MHZ} MHz, E ${ST_E_MHZ} MHz"
  printf '%s' "$SOCK_STRESS_JSON" | grep -oE '\{[^}]*\}' | sed -E 's/[{}"]//g' | awk -F', ' '{ printf "  socket:"; for(i=1;i<=NF;i++){ split($i,a,": "); if(a[1] ~ /^(socket|threads|pkg_w_avg|pkg_w_max|temp_c_max|mhz_avg|busy_pct_avg)$/) printf " %s=%s", a[1], a[2] } print "" }'
  echo "sysbench events/s: 1t ${SB1} (max clock ${SB1_MAXMHZ} MHz = ${BOOST_PCT}% of ${CR_MAX_MHZ}), ${CR_NPROC}t ${SBMT} (scaling ${SB_SCALE}x)"
  echo "7-Zip MIPS: mt ${Z_MT} (avg ${Z_MT_W} W, max ${Z_MT_T} C), 1t ${Z_1T} (scaling ${Z_SCALE}x)"
  echo "perf/W: stress ${OPS_PER_W} ops/s/W, 7-Zip ${Z_PER_W} MIPS/W, sysbench ${SB_PER_W} ev/s/W"
  echo "throttle counters (core+pkg) before ${THR_CORE_PRE}+${THR_PKG_PRE}, after ${THR_CORE_POST}+${THR_PKG_POST} (increase ${THR_DELTA})"
  echo "kernel hardware-error lines during test: ${HWERR:-0} (warnings: ${SOFTERR:-0})"
  for x in "${CR_ERRORS[@]+"${CR_ERRORS[@]}"}"; do echo "ERROR: $x"; done
  for x in "${CR_WARNINGS[@]+"${CR_WARNINGS[@]}"}"; do echo "WARNING: $x"; done
  for x in "${CR_SKIPPED[@]+"${CR_SKIPPED[@]}"}"; do echo "SKIPPED: $x"; done
} > "$OUT/summary.txt"
cat "$OUT/summary.txt"
cr_log "CPU test done -> $OUT/summary.json"
exit 0
