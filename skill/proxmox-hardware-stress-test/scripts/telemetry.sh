#!/usr/bin/env bash
# =============================================================================
# telemetry.sh - shared sensor / CSV / JSON helpers for the
#                proxmox-hardware-stress-test skill.
#
# SOURCE this file, do not execute it:
#     SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
#     . "$SCRIPT_DIR/telemetry.sh"
#     tel_init                      # once, in the main shell, before anything else
#     trap 'tel_sampler_stop; tel_cleanup' EXIT   # (your own trap; this file sets none)
#
# Runs on the Proxmox VE host as root (PVE 8/9, Debian 12/13, bash >= 5).
# Works on Intel and AMD CPUs, NVIDIA / AMD / Intel GPUs (or none), NVMe /
# SATA SSD / HDD. Every sensor that is missing yields the literal string
# "n/a" - no function in this file ever exits the caller or returns non-zero
# because a sensor is absent. Nothing here writes to block devices or changes
# any power / frequency / BIOS / kernel setting: it is read-only telemetry.
#
# ---------------------------------------------------------------------------
# STABLE PUBLIC INTERFACE (other scripts rely on these names and outputs)
# ---------------------------------------------------------------------------
# Setup
#   tel_init                 Detect sensors once (RAPL, CPU temp, hybrid cores,
#                            GPUs). Sets the TEL_* variables below. Idempotent.
#   tel_cleanup              Remove the private state dir (call from EXIT trap).
#
# CPU (all print ONE line, comma separated where several values)
#   cpu_power                "pkg_w,core_w" averaged since the previous call
#                            (first call primes and prints "n/a,n/a").
#                            Source: powercap intel-rapl (Intel AND AMD Zen),
#                            else hwmon amd_energy. Package domains are summed
#                            over sockets. Core may be n/a (e.g. some AMD).
#   cpu_temp                 Package temperature in C (1 decimal), max over
#                            sockets/CCDs: coretemp "Package id N", k10temp /
#                            zenpower Tdie (else Tctl), else thermal zone
#                            x86_pkg_temp, else acpitz (approximate).
#   cpu_sockets              Number of populated CPU sockets (physical packages).
#   cpu_power_sockets        Package W per socket, "w0,w1,..." in TEL_SOCKET_IDS
#                            order, averaged since the previous call (own state,
#                            independent of cpu_power; first call: all n/a).
#                            cpu_power's pkg_w is the SUM of these.
#   cpu_temp_sockets         Package C per socket, "t0,t1,..." (max of that
#                            socket's sensors). cpu_temp is the MAX of these.
#   cpu_mhz                  "avg,min,max" current MHz over all logical CPUs.
#   cpu_mhz_hybrid           "pcore_avg,ecore_avg" MHz on Intel hybrid CPUs,
#                            "n/a,n/a" otherwise.
#   cpu_busy                 Host CPU busy % since previous call (from /proc/stat;
#                            first call prints n/a). Includes guest load.
#   cpu_throttle             "core_events,pkg_events" (Intel thermal_throttle
#                            counters: sum of core counts, max package count),
#                            "n/a,n/a" if the counters do not exist.
#   load1                    1-minute load average.
#
# Memory
#   mem_usage                "used_mb,avail_mb,swap_used_mb"
#
# GPU
#   gpu_count                Number of GPUs the telemetry can read (0 = none).
#   gpu_list                 One line per GPU: "idx kind id name" (kind =
#                            nvidia|amd|intel; id = nvidia index or drm card path)
#   gpu_query [IDX]          10 fields, in TEL_GPU_FIELDS order:
#                            temp_c,power_w,core_mhz,mem_mhz,util_pct,
#                            mem_used_mib,fan_pct,throttle,pstate,power_limit_w
#                            (NVIDIA via nvidia-smi; AMD/Intel via sysfs/hwmon,
#                            derived from gpu_query_ext; pstate is n/a there).
#   gpu_query_ext IDX        AMD/Intel only (NVIDIA: all n/a): 17 fields in
#                            TEL_GPU_EXT_FIELDS order:
#                            temp_c,power_w,sclk_mhz,busy_pct,vram_used_mib,
#                            fan_rpm,pcie_link,junction_c,mem_temp_c,mclk_mhz,
#                            max_mhz,mem_busy_pct,gtt_used_mib,fan_pct,
#                            power_limit_w,power_source,throttle
#                            amdgpu: hwmon temp1/2/3 (edge/junction/mem), power1_
#                            average|input (uW), power1_cap, freq1/2_input or
#                            pp_dpm_sclk/mclk, gpu_busy_percent, mem_busy_percent,
#                            mem_info_vram_used / gtt_used, fan1_input, pwm1.
#                            i915: gt_act_freq_mhz / gt_max_freq_mhz, gt/gt0/
#                            throttle_reason_*; xe: tile*/gt*/freq*/act_freq,
#                            max_freq, throttle/reason_*; hwmon power1_* or the
#                            energy1_input counter (uJ, averaged between calls).
#                            Integrated Intel GPUs without hwmon: RAPL "uncore"
#                            energy (power_source says "shared with CPU"); AMD
#                            APUs: hwmon power is the whole APU package (also
#                            marked shared). AMD/Intel expose no NVIDIA-style
#                            throttle bitmask: "throttle" is the list of active
#                            Intel throttle reasons (e.g. pl1|thermal), "none",
#                            or n/a (AMD); judge AMD by sclk vs max_mhz + temp.
#                            busy_pct on Intel comes only from the optional
#                            gpu_util_helper_start (intel_gpu_top), else n/a.
#   gpu_index_for_pci ADDR   Telemetry index of the GPU at PCI ADDR (empty if none).
#   gpu_is_integrated_pci ADDR [NAME]
#                            Prints 1 for an integrated GPU (Intel iGPU at
#                            00:02.0; AMD APU by lspci code name, or <= 1 GiB
#                            VRAM carve-out), else 0.
#   gpu_util_helper_start IDX FILE / gpu_util_helper_stop
#                            Optional busy-% helper, used only if installed:
#                            intel_gpu_top -J (Intel) or radeontop (AMD, only
#                            when gpu_busy_percent is missing). gpu_query /
#                            gpu_query_ext read its latest sample from FILE.
#
# Disks (DEV = sda | nvme0n1 | /dev/sda ...)
#   disk_temp DEV            Temperature in C (integer) or n/a. NVMe/drivetemp
#                            hwmon first (cheap), else smartctl -n standby
#                            (does not wake a sleeping HDD).
#   disk_io DEV              "read_mbps,write_mbps,r_iops,w_iops,util_pct"
#                            since the previous call (first call: all n/a).
#   disk_kind DEV            nvme | ssd | hdd | virtual
#   path_disks PATH          Whole-disk names under the filesystem holding PATH
#                            (follows LVM / md / LUKS; ZFS via zpool status).
#   fs_type PATH, fs_avail_bytes PATH, fs_size_bytes PATH
#   disk_smart_snapshot DEV FILE   smartctl -a (+ nvme smart-log) into FILE
#   smart_brief FILE         key=value lines parsed from a smartctl -a text
#                            file: health power_on_hours temp_c percent_used
#                            media_errors critical_warning available_spare
#                            data_written_tb unsafe_shutdowns reallocated
#                            pending offline_uncorrectable crc_errors
#
# Hardware error counters (diff before/after a stress phase)
#   hw_error_snapshot        key=value lines: mce_lines edac_ce edac_ue
#                            aer_cor aer_nonfatal aer_fatal kernel_err_lines
#                            throttle_core throttle_pkg
#   hw_error_diff A B        Prints "key before -> after" for keys that grew.
#
# CSV
#   csv_init FILE HEADER     Write header line (overwrites FILE).
#   csv_row FILE FIELD...    Append FIELDs joined by ","; empty -> n/a. Fields
#                            may themselves be "a,b" outputs of the functions
#                            above. Use csv_safe for free text.
#   csv_safe TEXT            TEXT with commas/newlines replaced (for labels).
#   csv_stats FILE COLUMN    "n min avg max" over numeric cells of COLUMN
#                            (header name); "0 n/a n/a n/a" when none.
#   csv_stats_json FILE COLUMN   {"n":..,"min":..,"avg":..,"max":..} (null if none)
#
# Background 1 Hz sampler
#   tel_sampler_start FILE [GROUP...]
#        GROUPs: cpu  mem  gpu[:IDX]  disk:DEV  sockets   (default: cpu mem)
#        "sockets" adds cpu_s<ID>_pkg_w,cpu_s<ID>_temp_c per socket (use it on
#        multi-socket hosts; the cpu group keeps the summed/hottest values).
#        Columns: ts,elapsed_s,phase,<group columns...>  (see tel_header).
#        Sets TEL_SAMPLER_PID. Stops by itself if the calling script dies.
#   tel_sampler_stop         Stop the sampler started above (safe to repeat).
#   tel_phase NAME           Label written in the "phase" column from now on.
#   tel_header GROUP...      Print the CSV header the sampler would use.
#
# JSON / summary
#   json_escape S, json_str S (quoted), json_num V (number or null),
#   json_bool V (true for 1/true/yes), json_arr_str ITEM... (["a","b"])
#   tel_warn MSG / tel_error MSG / tel_skip TEST REASON
#        Print to stderr and append to TEL_WARNINGS / TEL_ERRORS / TEL_SKIPPED
#        (call these in the MAIN shell, not inside $(...), or the record is lost).
#   summary_write FILE PART DURATION_S METRICS_JSON [STATUS] [EXTRA_JSON_MEMBERS]
#        Writes {"part","status","duration_s","generated","metrics",
#        "warnings","errors","skipped"[,extra]}. STATUS defaults to
#        error (if errors) / partial (if skipped) / ok.
#   tel_log MSG / tel_die MSG   (tel_die exits 1)
#
# Test files (disk tests)
#   TEL_TESTFILE_PREFIX      "pve-stresstest-fio" - every disk test file MUST
#                            start with this name so cleanup.sh can find it.
#   testfile_register PATH   Record PATH in $STRESS_HOME/.testfiles.
#
# Variables set by tel_init (read-only for callers)
#   TEL_RAPL_SRC  TEL_CPU_TEMP_SRC  TEL_HYBRID(0/1)  TEL_PCORES TEL_ECORES
#   TEL_SOCKETS (count)  TEL_SOCKET_IDS[] (physical package ids, sorted)
#   TEL_RAPL_PKG_SOCK[] / TEL_CPU_TEMP_SOCK[] (socket id of each sensor file)
#   TEL_GPU_KINDS[] TEL_GPU_IDS[] TEL_GPU_NAMES[] TEL_GPU_PCI[]
#   TEL_GPU_INTEGRATED[] (1/0)  TEL_STATE_DIR  TEL_RAPL_UNCORE (path or "")
#   TEL_GPU_FIELDS  (the 10 gpu_query column names)
#   TEL_GPU_EXT_FIELDS (the 17 gpu_query_ext column names)
#   STRESS_HOME (default /root/pve-stresstest; override before sourcing)
#   TEL_ROOT  "" on a real host (see the developer-only hook below)
#
# DEVELOPER-ONLY test hook (never set on a real host): PVE_STRESS_SYSFS_ROOT=DIR
# makes the GPU and RAPL sysfs reads (GPU detection, gpu_query_ext,
# gpu_is_integrated_pci, RAPL incl. "uncore") read DIR/sys/... instead of /sys/...,
# so the AMD/Intel GPU code can be exercised against a fake sysfs tree on any
# machine. Reads only; unset or "/" = the real /sys. See docs/developing.md.
#
# Cost: one sample of all groups takes ~50-200 ms (smartctl on SATA disks
# and nvidia-smi dominate). Nothing here runs for a fixed time by itself.
# =============================================================================

# Guard against double sourcing.
if [[ -n ${_TEL_SOURCED:-} ]]; then return 0 2>/dev/null || exit 0; fi
_TEL_SOURCED=1

: "${STRESS_HOME:=/root/pve-stresstest}"
TEL_TESTFILE_PREFIX="pve-stresstest-fio"
TEL_NA="n/a"
TEL_GPU_FIELDS="temp_c,power_w,core_mhz,mem_mhz,util_pct,mem_used_mib,fan_pct,throttle,pstate,power_limit_w"
TEL_GPU_EXT_FIELDS="temp_c,power_w,sclk_mhz,busy_pct,vram_used_mib,fan_rpm,pcie_link,junction_c,mem_temp_c,mclk_mhz,max_mhz,mem_busy_pct,gtt_used_mib,fan_pct,power_limit_w,power_source,throttle"
TEL_GPU_UTIL_PID="" TEL_GPU_UTIL_FILE="" TEL_GPU_UTIL_IDX=""
TEL_WARNINGS=()
TEL_ERRORS=()
TEL_SKIPPED=()
TEL_SAMPLER_PID=""
# Developer-only fake root for GPU/RAPL sysfs reads (see header); "" = the real /.
TEL_ROOT=${PVE_STRESS_SYSFS_ROOT:-}; TEL_ROOT=${TEL_ROOT%/}
# Deterministic per-script state dir ($$ is the same in all subshells).
TEL_STATE_DIR="${TEL_STATE_DIR:-/tmp/pve-stresstest-tel.$$}"

# ----------------------------------------------------------------------------- logging
tel_log()   { printf '[%s] %s\n' "$(date +%T)" "$*" >&2; }
tel_warn()  { printf '[%s] WARNING: %s\n' "$(date +%T)" "$*" >&2; TEL_WARNINGS+=("$*"); }
tel_error() { printf '[%s] ERROR: %s\n' "$(date +%T)" "$*" >&2; TEL_ERRORS+=("$*"); }
tel_skip()  { printf '[%s] SKIPPED %s: %s\n' "$(date +%T)" "${1:-?}" "${2:-}" >&2; TEL_SKIPPED+=("${1:-?}|${2:-}"); }
tel_die()   { printf '[%s] FATAL: %s\n' "$(date +%T)" "$*" >&2; exit 1; }

# ----------------------------------------------------------------------------- small utils
_tel_now() {
    if [[ -n ${EPOCHREALTIME:-} ]]; then printf '%s\n' "${EPOCHREALTIME/,/.}"; else date +%s.%N; fi
}
# Read the first line of a file, quietly. Returns 1 if unreadable/empty.
_tel_read() {
    local _v=""
    { IFS= read -r _v < "$1"; } 2>/dev/null || [[ -n $_v ]] || return 1
    [[ -n $_v ]] || return 1
    printf '%s' "$_v"
}
_tel_isnum() { [[ ${1:-} =~ ^-?[0-9]+([.][0-9]+)?$ ]]; }
# Expand a kernel cpulist ("0-15,32-47") into space-separated ids.
_tel_expand_cpulist() {
    local list=${1:-} part a b i out=()
    local IFS=,
    for part in $list; do
        if [[ $part == *-* ]]; then a=${part%-*}; b=${part#*-}
            for ((i = a; i <= b; i++)); do out+=("$i"); done
        elif [[ -n $part ]]; then out+=("$part"); fi
    done
    IFS=' '; printf '%s' "${out[*]}"
}
_tel_dev() { local d=${1#/dev/}; printf '%s' "${d##*/}"; }

# ----------------------------------------------------------------------------- init
tel_init() {
    [[ -n ${TEL_INITIALISED:-} ]] && return 0
    mkdir -p "$TEL_STATE_DIR" 2>/dev/null || { TEL_STATE_DIR=$(mktemp -d) || TEL_STATE_DIR=/tmp; }
    _tel_detect_sockets
    _tel_detect_rapl
    _tel_detect_cpu_temp
    _tel_detect_hybrid
    _tel_detect_gpus
    TEL_INITIALISED=1
    return 0
}
tel_cleanup() {
    [[ -n ${TEL_STATE_DIR:-} && $TEL_STATE_DIR == /tmp/pve-stresstest-tel.* ]] && rm -rf -- "$TEL_STATE_DIR"
    return 0
}

# Physical packages (sockets) present: TEL_SOCKETS + sorted TEL_SOCKET_IDS.
_tel_detect_sockets() {
    TEL_SOCKET_IDS=()
    local ids
    ids=$(cat /sys/devices/system/cpu/cpu[0-9]*/topology/physical_package_id 2>/dev/null | sort -n -u)
    [[ -n $ids ]] && mapfile -t TEL_SOCKET_IDS <<<"$ids"
    ((${#TEL_SOCKET_IDS[@]})) || TEL_SOCKET_IDS=(0)
    TEL_SOCKETS=${#TEL_SOCKET_IDS[@]}
    return 0
}

_tel_detect_rapl() {
    TEL_RAPL_PKG=(); TEL_RAPL_PKG_MAX=(); TEL_RAPL_PKG_SOCK=(); TEL_RAPL_CORE=(); TEL_RAPL_CORE_MAX=(); TEL_RAPL_SRC="n/a"
    TEL_RAPL_UNCORE=""; TEL_RAPL_UNCORE_MAX=0
    local z name v mx h l lab
    for z in "$TEL_ROOT"/sys/class/powercap/intel-rapl:[0-9]*; do
        [[ -d $z ]] || continue
        v=$(_tel_read "$z/energy_uj") || continue
        _tel_isnum "$v" || continue
        name=$(_tel_read "$z/name") || continue
        mx=$(_tel_read "$z/max_energy_range_uj") || mx=0
        case $name in
            # "package-N" (or "package-N-die-M" on multi-die parts): N = socket id
            package-*) TEL_RAPL_PKG+=("$z/energy_uj"); TEL_RAPL_PKG_MAX+=("$mx")
                       v=${name#package-}; v=${v%%-*}; [[ $v =~ ^[0-9]+$ ]] || v=0; TEL_RAPL_PKG_SOCK+=("$v") ;;
            core)      TEL_RAPL_CORE+=("$z/energy_uj"); TEL_RAPL_CORE_MAX+=("$mx") ;;
            # client Intel CPUs: the integrated GPU's share of the package (first one only)
            uncore)    [[ -z $TEL_RAPL_UNCORE ]] && { TEL_RAPL_UNCORE="$z/energy_uj"; TEL_RAPL_UNCORE_MAX=$mx; } ;;
        esac
    done
    if ((${#TEL_RAPL_PKG[@]})); then TEL_RAPL_SRC="powercap-rapl"; return 0; fi
    # Older AMD kernels: amd_energy hwmon (uJ, 64-bit accumulated, no wrap handling needed)
    for h in "$TEL_ROOT"/sys/class/hwmon/hwmon*; do
        [[ $(_tel_read "$h/name") == amd_energy ]] || continue
        for l in "$h"/energy*_label; do
            [[ -r $l ]] || continue
            lab=$(_tel_read "$l")
            [[ $lab == Esocket* ]] || continue
            v=${lab#Esocket}; [[ $v =~ ^[0-9]+$ ]] || v=0
            TEL_RAPL_PKG+=("${l%_label}_input"); TEL_RAPL_PKG_MAX+=(0); TEL_RAPL_PKG_SOCK+=("$v")
        done
    done
    ((${#TEL_RAPL_PKG[@]})) && TEL_RAPL_SRC="amd_energy"
    return 0
}

# Socket id for the I-th of N sensors that are ordered by socket (k10temp nodes,
# x86_pkg_temp zones): spreads N sensors evenly over the sockets.
_tel_sock_of() {
    local i=$1 n=$2 k
    ((n > 0)) || n=1
    k=$((i * TEL_SOCKETS / n)); ((k >= TEL_SOCKETS)) && k=$((TEL_SOCKETS - 1))
    printf '%s' "${TEL_SOCKET_IDS[$k]:-0}"
}

_tel_detect_cpu_temp() {
    TEL_CPU_TEMP_FILES=(); TEL_CPU_TEMP_SOCK=(); TEL_CPU_TEMP_SRC="n/a"
    local h n l lab pick tctl z t k10=() i sid
    for h in /sys/class/hwmon/hwmon*; do
        n=$(_tel_read "$h/name") || continue
        case $n in
            coretemp)
                for l in "$h"/temp*_label; do
                    [[ -r $l ]] || continue
                    lab=$(_tel_read "$l")
                    if [[ $lab == "Package id"* ]]; then
                        sid=${lab#Package id }; [[ $sid =~ ^[0-9]+$ ]] || sid=0
                        TEL_CPU_TEMP_FILES+=("${l%_label}_input"); TEL_CPU_TEMP_SOCK+=("$sid")
                    fi
                done
                [[ ${#TEL_CPU_TEMP_FILES[@]} -gt 0 ]] && TEL_CPU_TEMP_SRC="coretemp-package"
                ;;
            k10temp|zenpower)
                pick=""; tctl=""
                for l in "$h"/temp*_label; do
                    [[ -r $l ]] || continue
                    lab=$(_tel_read "$l")
                    [[ $lab == Tdie ]] && pick="${l%_label}_input"
                    [[ $lab == Tctl ]] && tctl="${l%_label}_input"
                done
                [[ -z $pick ]] && pick=$tctl
                [[ -z $pick && -r $h/temp1_input ]] && pick="$h/temp1_input"
                # one k10temp per socket (per die on Zen 1): order by PCI address
                [[ -n $pick ]] && k10+=("$(readlink -f "$h/device" 2>/dev/null)|$pick|$n")
                ;;
        esac
    done
    if ((${#k10[@]})); then
        i=0
        while IFS='|' read -r _ pick n; do
            TEL_CPU_TEMP_FILES+=("$pick"); TEL_CPU_TEMP_SOCK+=("$(_tel_sock_of "$i" "${#k10[@]}")"); TEL_CPU_TEMP_SRC="$n"; i=$((i + 1))
        done < <(printf '%s\n' "${k10[@]}" | sort)
    fi
    ((${#TEL_CPU_TEMP_FILES[@]})) && return 0
    # coretemp without a Package sensor (some Atom/Xeon-D): use all core sensors (max);
    # the hwmon's platform device is coretemp.<package id>
    for h in /sys/class/hwmon/hwmon*; do
        [[ $(_tel_read "$h/name") == coretemp ]] || continue
        sid=$(basename "$(readlink -f "$h/device" 2>/dev/null)"); sid=${sid##*.}; [[ $sid =~ ^[0-9]+$ ]] || sid=0
        for t in "$h"/temp*_input; do [[ -r $t ]] && { TEL_CPU_TEMP_FILES+=("$t"); TEL_CPU_TEMP_SOCK+=("$sid"); }; done
    done
    if ((${#TEL_CPU_TEMP_FILES[@]})); then TEL_CPU_TEMP_SRC="coretemp-cores-max"; return 0; fi
    local zs=()
    for z in /sys/class/thermal/thermal_zone*; do
        [[ $(_tel_read "$z/type") == x86_pkg_temp ]] && zs+=("$z/temp")
    done
    for i in "${!zs[@]}"; do TEL_CPU_TEMP_FILES+=("${zs[$i]}"); TEL_CPU_TEMP_SOCK+=("$(_tel_sock_of "$i" "${#zs[@]}")"); done
    if ((${#TEL_CPU_TEMP_FILES[@]})); then TEL_CPU_TEMP_SRC="thermal-x86_pkg_temp"; return 0; fi
    for z in /sys/class/thermal/thermal_zone*; do
        [[ $(_tel_read "$z/type") == acpitz ]] && { TEL_CPU_TEMP_FILES+=("$z/temp"); TEL_CPU_TEMP_SOCK+=("${TEL_SOCKET_IDS[0]:-0}"); break; }
    done
    ((${#TEL_CPU_TEMP_FILES[@]})) && TEL_CPU_TEMP_SRC="acpitz-approximate"
    return 0
}

_tel_detect_hybrid() {
    TEL_HYBRID=0; TEL_PCORES=""; TEL_ECORES=""
    local p e
    p=$(_tel_read /sys/devices/cpu_core/cpus) || p=""
    e=$(_tel_read /sys/devices/cpu_atom/cpus) || e=""
    if [[ -n $p && -n $e ]]; then
        TEL_HYBRID=1
        TEL_PCORES=$(_tel_expand_cpulist "$p")
        TEL_ECORES=$(_tel_expand_cpulist "$e")
    fi
    return 0
}

_tel_detect_gpus() {
    TEL_GPU_KINDS=(); TEL_GPU_IDS=(); TEL_GPU_NAMES=(); TEL_GPU_PCI=(); TEL_GPU_INTEGRATED=(); TEL_NV_THR="clocks_throttle_reasons.active"
    local line idx name c vendor drv bus pci
    if command -v nvidia-smi >/dev/null 2>&1 && nvidia-smi -L >/dev/null 2>&1; then
        while IFS=, read -r idx bus name; do
            idx=${idx// /}; name=${name# }; bus=${bus// /}
            [[ -n $idx ]] || continue
            bus=${bus,,}; [[ $bus =~ ^[0-9a-f]{8}: ]] && bus=${bus#????}
            TEL_GPU_KINDS+=(nvidia); TEL_GPU_IDS+=("$idx"); TEL_GPU_NAMES+=("$name"); TEL_GPU_PCI+=("$bus"); TEL_GPU_INTEGRATED+=(0)
        done < <(nvidia-smi --query-gpu=index,pci.bus_id,name --format=csv,noheader 2>/dev/null)
        if nvidia-smi --query-gpu=clocks_event_reasons.active --format=csv,noheader >/dev/null 2>&1; then
            TEL_NV_THR="clocks_event_reasons.active"
        fi
    fi
    for c in "$TEL_ROOT"/sys/class/drm/card*; do
        [[ $c =~ /card[0-9]+$ ]] || continue
        vendor=$(_tel_read "$c/device/vendor") || continue
        drv=$(basename "$(readlink -f "$c/device/driver" 2>/dev/null)" 2>/dev/null)
        pci=$(basename "$(readlink -f "$c/device" 2>/dev/null)" 2>/dev/null)
        case "$vendor:$drv" in
            0x1002:amdgpu) TEL_GPU_KINDS+=(amd);   TEL_GPU_IDS+=("$c"); TEL_GPU_NAMES+=("AMD GPU ${c##*/}") ;;
            0x8086:i915|0x8086:xe) TEL_GPU_KINDS+=(intel); TEL_GPU_IDS+=("$c"); TEL_GPU_NAMES+=("Intel GPU ${c##*/} ($drv)") ;;
            *) continue ;;
        esac
        TEL_GPU_PCI+=("$pci"); TEL_GPU_INTEGRATED+=("$(gpu_is_integrated_pci "$pci")")
    done
    return 0
}

# 1 if the GPU at PCI address $1 is integrated (shares RAM and power with the CPU), else 0.
# Intel: the iGPU always sits at 0000:00:02.0 (Arc cards are elsewhere). AMD: APU code
# names in the lspci name ($2, or looked up), else a VRAM carve-out of <= 1 GiB.
gpu_is_integrated_pci() {
    local a=${1:-} name=${2:-} d v vt
    d="$TEL_ROOT/sys/bus/pci/devices/$a"
    v=$(_tel_read "$d/vendor") || { echo 0; return 0; }
    case $v in
        0x8086) [[ $a == 0000:00:02.0 ]] && echo 1 || echo 0; return 0 ;;
        0x1002) ;;
        *) echo 0; return 0 ;;
    esac
    [[ -z $name ]] && command -v lspci >/dev/null 2>&1 && name=$(lspci -s "$a" 2>/dev/null | head -n1)
    if [[ $name =~ (Renoir|Cezanne|Lucienne|Barcelo|Rembrandt|Phoenix|Hawk[[:space:]]Point|Raphael|Granite[[:space:]]Ridge|Strix|Krackan|Mendocino|Picasso|Raven|Van[[:space:]]Gogh|Dali|Pollock|Stoney|Carrizo|Kaveri|Kabini|Mullins|Beema|Godavari|Cyan[[:space:]]Skillfish|Vega[[:space:]]Mobile|Radeon[[:space:]][678][0-9]0M|Radeon[[:space:]]8060S) ]]; then
        echo 1; return 0
    fi
    vt=$(_tel_read "$d/mem_info_vram_total") || vt=""
    if _tel_isnum "$vt" && ((vt > 0 && vt <= 1073741824)); then echo 1; else echo 0; fi
}

# Telemetry index of the GPU at PCI address $1 (any form: 01:00.0, 0000:01:00.0).
gpu_index_for_pci() {
    tel_init
    local a=${1:-} i
    a=${a,,}
    [[ $a =~ ^[0-9a-f]{2}:[0-9a-f]{2}\.[0-7]$ ]] && a="0000:$a"
    for i in "${!TEL_GPU_PCI[@]}"; do [[ ${TEL_GPU_PCI[$i]} == "$a" ]] && { echo "$i"; return 0; }; done
    return 0
}

# ----------------------------------------------------------------------------- CPU
cpu_power() {
    tel_init
    if ((${#TEL_RAPL_PKG[@]} == 0)); then echo "n/a,n/a"; return 0; fi
    local st="$TEL_STATE_DIR/rapl.${TEL_TAG:-main}" now cur f v prev=""
    now=$(_tel_now); cur="$now"
    for f in "${TEL_RAPL_PKG[@]}"; do v=$(_tel_read "$f") || v=x; cur+=" $v"; done
    for f in "${TEL_RAPL_CORE[@]}"; do v=$(_tel_read "$f") || v=x; cur+=" $v"; done
    [[ -r $st ]] && prev=$(<"$st")
    printf '%s\n' "$cur" > "$st" 2>/dev/null
    if [[ -z $prev ]]; then echo "n/a,n/a"; return 0; fi
    awk -v cur="$cur" -v prev="$prev" -v np="${#TEL_RAPL_PKG[@]}" -v nc="${#TEL_RAPL_CORE[@]}" \
        -v mx="${TEL_RAPL_PKG_MAX[*]} ${TEL_RAPL_CORE_MAX[*]}" 'BEGIN{
        split(cur,c," "); split(prev,p," "); split(mx,m," ");
        dt=c[1]-p[1]; if(dt<=0){print "n/a,n/a"; exit}
        pk=0; pok=1; for(i=1;i<=np;i++){ if(c[i+1]=="x"||p[i+1]=="x"){pok=0;continue}
            d=c[i+1]-p[i+1]; if(d<0 && m[i]>0) d+=m[i]; if(d<0) pok=0; pk+=d }
        co=0; cok=(nc>0); for(i=1;i<=nc;i++){ j=np+i; if(c[j+1]=="x"||p[j+1]=="x"){cok=0;continue}
            d=c[j+1]-p[j+1]; if(d<0 && m[j]>0) d+=m[j]; if(d<0) cok=0; co+=d }
        printf "%s,%s\n", (pok?sprintf("%.1f",pk/dt/1e6):"n/a"), (cok?sprintf("%.1f",co/dt/1e6):"n/a") }'
}

cpu_temp() {
    tel_init
    if ((${#TEL_CPU_TEMP_FILES[@]} == 0)); then echo "n/a"; return 0; fi
    local f v mx=""
    for f in "${TEL_CPU_TEMP_FILES[@]}"; do
        v=$(_tel_read "$f") || continue
        [[ $v =~ ^-?[0-9]+$ ]] || continue
        if [[ -z $mx ]] || ((v > mx)); then mx=$v; fi
    done
    if [[ -z $mx ]]; then echo "n/a"; return 0; fi
    printf '%d.%d\n' $((mx / 1000)) $(((mx % 1000) / 100))
}

cpu_sockets() { tel_init; echo "${TEL_SOCKETS:-1}"; }

# Per-socket package power, "w0,w1,..." in TEL_SOCKET_IDS order.
cpu_power_sockets() {
    tel_init
    local na="" s
    for s in "${TEL_SOCKET_IDS[@]}"; do na+="${na:+,}n/a"; done
    if ((${#TEL_RAPL_PKG[@]} == 0)); then echo "$na"; return 0; fi
    local st="$TEL_STATE_DIR/raplsock.${TEL_TAG:-main}" now cur f v prev=""
    now=$(_tel_now); cur="$now"
    for f in "${TEL_RAPL_PKG[@]}"; do v=$(_tel_read "$f") || v=x; cur+=" $v"; done
    [[ -r $st ]] && prev=$(<"$st")
    printf '%s\n' "$cur" > "$st" 2>/dev/null
    if [[ -z $prev ]]; then echo "$na"; return 0; fi
    awk -v cur="$cur" -v prev="$prev" -v mx="${TEL_RAPL_PKG_MAX[*]}" -v sk="${TEL_RAPL_PKG_SOCK[*]}" \
        -v ids="${TEL_SOCKET_IDS[*]}" 'BEGIN{
        split(cur,c," "); split(prev,p," "); split(mx,m," "); n=split(sk,k," "); ns=split(ids,id," ");
        dt=c[1]-p[1];
        for(i=1;i<=n;i++){ s=k[i]; if(c[i+1]=="x"||p[i+1]=="x"||dt<=0){bad[s]=1;continue}
            d=c[i+1]-p[i+1]; if(d<0 && m[i]>0) d+=m[i]; if(d<0){bad[s]=1;continue} e[s]+=d; seen[s]=1 }
        for(j=1;j<=ns;j++){ s=id[j]; printf "%s%s", (j>1?",":""), ((seen[s] && !bad[s])?sprintf("%.1f",e[s]/dt/1e6):"n/a") }
        print "" }'
}

# Per-socket package temperature, "t0,t1,..." in TEL_SOCKET_IDS order.
cpu_temp_sockets() {
    tel_init
    local i v s out="" mx
    declare -A M=()
    for i in "${!TEL_CPU_TEMP_FILES[@]}"; do
        v=$(_tel_read "${TEL_CPU_TEMP_FILES[$i]}") || continue
        [[ $v =~ ^-?[0-9]+$ ]] || continue
        s=${TEL_CPU_TEMP_SOCK[$i]:-0}
        if [[ -z ${M[$s]:-} ]] || ((v > M[$s])); then M[$s]=$v; fi
    done
    for s in "${TEL_SOCKET_IDS[@]}"; do
        mx=${M[$s]:-}
        if [[ -z $mx ]]; then out+="${out:+,}n/a"
        else out+="${out:+,}$(printf '%d.%d' $((mx / 1000)) $(((mx % 1000) / 100)))"; fi
    done
    echo "$out"
}

cpu_mhz() {
    local out
    out=$(cat /sys/devices/system/cpu/cpu[0-9]*/cpufreq/scaling_cur_freq 2>/dev/null |
        awk '/^[0-9]+$/{v=$1/1000; s+=v; n++; if(n==1||v<mn)mn=v; if(v>mx)mx=v} END{if(n) printf "%.0f,%.0f,%.0f\n",s/n,mn,mx}')
    if [[ -z $out ]]; then
        out=$(awk -F: '/^cpu MHz/{v=$2+0; s+=v; n++; if(n==1||v<mn)mn=v; if(v>mx)mx=v} END{if(n) printf "%.0f,%.0f,%.0f\n",s/n,mn,mx}' /proc/cpuinfo 2>/dev/null)
    fi
    echo "${out:-n/a,n/a,n/a}"
}

cpu_mhz_hybrid() {
    tel_init
    if [[ ${TEL_HYBRID:-0} != 1 ]]; then echo "n/a,n/a"; return 0; fi
    awk -v p=" $TEL_PCORES " -v e=" $TEL_ECORES " '
        FNR==1{ id=""; n=split(FILENAME,a,"/"); for(k=1;k<=n;k++) if(a[k] ~ /^cpu[0-9]+$/){ id=substr(a[k],4); break } }
        /^[0-9]+$/{ v=$1/1000; if(index(p," "id" ")){ps+=v;pn++} else if(index(e," "id" ")){es+=v;en++} }
        END{ printf "%s,%s\n", (pn?sprintf("%.0f",ps/pn):"n/a"), (en?sprintf("%.0f",es/en):"n/a") }' \
        /sys/devices/system/cpu/cpu[0-9]*/cpufreq/scaling_cur_freq 2>/dev/null || echo "n/a,n/a"
}

cpu_busy() {
    tel_init
    local st="$TEL_STATE_DIR/stat.${TEL_TAG:-main}" cur prev=""
    cur=$(awk '/^cpu /{t=0; for(i=2;i<=NF;i++)t+=$i; print t, $5+$6; exit}' /proc/stat)
    [[ -r $st ]] && prev=$(<"$st")
    printf '%s\n' "$cur" > "$st" 2>/dev/null
    if [[ -z $prev || -z $cur ]]; then echo "n/a"; return 0; fi
    awk -v c="$cur" -v p="$prev" 'BEGIN{split(c,a," "); split(p,b," "); dt=a[1]-b[1]; di=a[2]-b[2];
        if(dt<=0){print "n/a"; exit} printf "%.1f\n", 100*(dt-di)/dt }'
}

cpu_throttle() {
    local core pkg
    core=$(cat /sys/devices/system/cpu/cpu[0-9]*/thermal_throttle/core_throttle_count 2>/dev/null | awk '{s+=$1;n++} END{if(n)print s}')
    pkg=$(cat /sys/devices/system/cpu/cpu[0-9]*/thermal_throttle/package_throttle_count 2>/dev/null | awk '{if($1>m)m=$1;n++} END{if(n)print m+0}')
    echo "${core:-n/a},${pkg:-n/a}"
}

load1() { local a; read -r a _ < /proc/loadavg 2>/dev/null; echo "${a:-n/a}"; }

# ----------------------------------------------------------------------------- memory
mem_usage() {
    awk '/^MemTotal:/{t=$2} /^MemAvailable:/{a=$2} /^SwapTotal:/{st=$2} /^SwapFree:/{sf=$2}
         END{ if(t) printf "%.0f,%.0f,%.0f\n",(t-a)/1024,a/1024,(st-sf)/1024; else print "n/a,n/a,n/a" }' /proc/meminfo 2>/dev/null
}

# ----------------------------------------------------------------------------- GPU
gpu_count() { tel_init; echo "${#TEL_GPU_KINDS[@]}"; }
gpu_list() {
    tel_init
    local i
    for i in "${!TEL_GPU_KINDS[@]}"; do echo "$i ${TEL_GPU_KINDS[$i]} ${TEL_GPU_IDS[$i]} ${TEL_GPU_NAMES[$i]}"; done
}
_TEL_GPU_NA="n/a,n/a,n/a,n/a,n/a,n/a,n/a,n/a,n/a,n/a"

# Divide integer-ish VALUE by DIV, print with DEC decimals, or n/a.
_tel_div() {
    _tel_isnum "${1:-}" || { echo "n/a"; return 0; }
    awk -v v="$1" -v d="$2" -v k="${3:-0}" 'BEGIN{printf "%.*f\n", k, v/d}'
}

gpu_query() {
    tel_init
    local idx=${1:-0} kind id
    if ((idx >= ${#TEL_GPU_KINDS[@]})); then echo "$_TEL_GPU_NA"; return 0; fi
    kind=${TEL_GPU_KINDS[$idx]}; id=${TEL_GPU_IDS[$idx]}
    case $kind in
        nvidia) _tel_gpu_nvidia "$id" ;;
        amd|intel) _tel_gpu_from_ext "$idx" ;;
        *)      echo "$_TEL_GPU_NA" ;;
    esac
}

_TEL_GPU_EXT_NA="n/a,n/a,n/a,n/a,n/a,n/a,n/a,n/a,n/a,n/a,n/a,n/a,n/a,n/a,n/a,n/a,n/a"
gpu_query_ext() {
    tel_init
    local idx=${1:-}
    if ! [[ $idx =~ ^[0-9]+$ ]] || ((idx >= ${#TEL_GPU_KINDS[@]})); then echo "$_TEL_GPU_EXT_NA"; return 0; fi
    case ${TEL_GPU_KINDS[$idx]} in
        amd|intel) _tel_gpu_ext "$idx" ;;
        *) echo "$_TEL_GPU_EXT_NA" ;;
    esac
}

# The 10 gpu_query fields for an AMD/Intel GPU, mapped from the 17 extended ones.
_tel_gpu_from_ext() {
    local e; local -a f
    e=$(_tel_gpu_ext "$1")
    IFS=, read -r -a f <<<"$e"
    # temp, power, core MHz, mem MHz, util, VRAM used, fan %, throttle, pstate, power limit
    echo "${f[0]:-n/a},${f[1]:-n/a},${f[2]:-n/a},${f[9]:-n/a},${f[3]:-n/a},${f[4]:-n/a},${f[13]:-n/a},${f[16]:-n/a},n/a,${f[14]:-n/a}"
}

# Average W from a cumulative energy counter in uJ (hwmon energy1_input, RAPL energy_uj)
# since the previous call with the same KEY; first call prints n/a. $3 = wrap value (0 = none).
_tel_energy_w() {
    local key=$1 f=$2 mx=${3:-0} st now v prev=""
    v=$(_tel_read "$f") || { echo n/a; return 0; }
    _tel_isnum "$v" || { echo n/a; return 0; }
    st="$TEL_STATE_DIR/energy.${TEL_TAG:-main}.$key"
    now=$(_tel_now)
    [[ -r $st ]] && prev=$(<"$st")
    printf '%s %s\n' "$now" "$v" > "$st" 2>/dev/null
    [[ -n $prev ]] || { echo n/a; return 0; }
    awk -v c="$now $v" -v p="$prev" -v m="$mx" 'BEGIN{ split(c,a," "); split(p,b," "); dt=a[1]-b[1]; d=a[2]-b[2];
        if(d<0 && m>0) d+=m; if(dt<=0 || d<0){ print "n/a"; exit } printf "%.1f\n", d/dt/1e6 }'
}

# Active Intel throttle reasons from DIR (status file ST, reason files PRE*): "pl1|thermal", "none" or n/a.
_tel_intel_throttle() {
    local dir=$1 pre=$2 st=$3 s f n out=""
    s=$(_tel_read "$dir/$st") || { echo n/a; return 0; }
    [[ $s == 0 ]] && { echo none; return 0; }
    for f in "$dir/$pre"*; do
        [[ -r $f ]] || continue
        n=${f##*/}; n=${n#"$pre"}
        [[ $n == status || $f == "$dir/$st" ]] && continue
        [[ $(_tel_read "$f") == 1 ]] && out+="${out:+|}$n"
    done
    echo "${out:-active}"
}

# Latest busy % from the optional helper (intel_gpu_top -J / radeontop dump), or n/a.
_tel_util_from_helper() {
    local idx=$1 f=${TEL_GPU_UTIL_FILE:-} v=""
    [[ -n $f && ${TEL_GPU_UTIL_IDX:-} == "$idx" && -s $f ]] || { echo n/a; return 0; }
    if [[ ${TEL_GPU_KINDS[$idx]} == intel ]]; then
        # max engine busy of the last (possibly partial) sample
        v=$(tail -c 8192 "$f" 2>/dev/null | awk '/"engines"/{m=-1; on=1; next}
            on && /"busy"/{ x=$0; sub(/.*"busy"[^0-9]*/,"",x); x+=0; if(x>m) m=x }
            END{ if(on && m>=0) printf "%.0f", m }')
    else
        v=$(tail -n 1 "$f" 2>/dev/null | sed -n 's/.*gpu \([0-9.]*\)%.*/\1/p' | awk '{printf "%.0f", $1}')
    fi
    echo "${v:-n/a}"
}

# Optional background busy-% helper (only if the tool is installed; never installs it).
gpu_util_helper_start() {
    tel_init
    local idx=${1:-} file=${2:-} c pci bus ni=0 k
    gpu_util_helper_stop
    [[ $idx =~ ^[0-9]+$ && -n $file ]] || return 0
    ((idx < ${#TEL_GPU_KINDS[@]})) || return 0
    c=${TEL_GPU_IDS[$idx]}; pci=${TEL_GPU_PCI[$idx]:-}
    case ${TEL_GPU_KINDS[$idx]} in
        intel)
            command -v intel_gpu_top >/dev/null 2>&1 || return 0
            intel_gpu_top -J -s 1000 -d "drm:/dev/dri/${c##*/}" > "$file" 2>/dev/null &
            TEL_GPU_UTIL_PID=$!
            sleep 1.5
            if ! kill -0 "$TEL_GPU_UTIL_PID" 2>/dev/null; then
                # older intel-gpu-tools without device filters: only safe with one Intel GPU
                for k in "${TEL_GPU_KINDS[@]}"; do [[ $k == intel ]] && ni=$((ni + 1)); done
                TEL_GPU_UTIL_PID=""
                if ((ni == 1)); then intel_gpu_top -J -s 1000 > "$file" 2>/dev/null & TEL_GPU_UTIL_PID=$!; fi
            fi ;;
        amd)
            [[ -r $c/device/gpu_busy_percent ]] && return 0      # sysfs already has it
            command -v radeontop >/dev/null 2>&1 || return 0
            bus=${pci#*:}; bus=${bus%%:*}
            radeontop -d "$file" -i 1 -b "${bus:-0}" > /dev/null 2>&1 &
            TEL_GPU_UTIL_PID=$! ;;
        *) return 0 ;;
    esac
    [[ -n $TEL_GPU_UTIL_PID ]] && { TEL_GPU_UTIL_FILE=$file; TEL_GPU_UTIL_IDX=$idx; }
    return 0
}
gpu_util_helper_stop() {
    if [[ -n ${TEL_GPU_UTIL_PID:-} ]]; then
        kill "$TEL_GPU_UTIL_PID" 2>/dev/null
        wait "$TEL_GPU_UTIL_PID" 2>/dev/null
        TEL_GPU_UTIL_PID=""
    fi
    TEL_GPU_UTIL_FILE="" TEL_GPU_UTIL_IDX=""     # no stale busy % after the helper stopped
    return 0
}

# AMD/Intel sensors from sysfs/hwmon -> the 17 TEL_GPU_EXT_FIELDS. Missing -> n/a.
_tel_gpu_ext() {
    local idx=$1 c d h="" f l lab v key kind integ
    local t=n/a jt=n/a mt=n/a p=n/a ps=n/a cm="" mx="" mm="" u=n/a mu=n/a vu=n/a gu=n/a fr=n/a fp=n/a pl=n/a link=n/a thr=n/a
    kind=${TEL_GPU_KINDS[$idx]}; c=${TEL_GPU_IDS[$idx]}; d="$c/device"; integ=${TEL_GPU_INTEGRATED[$idx]:-0}
    key=${TEL_GPU_PCI[$idx]:-gpu$idx}; key=${key//[:.]/_}
    for f in "$d"/hwmon/hwmon*; do [[ -d $f ]] && { h=$f; break; }; done
    if [[ -n $h ]]; then
        for l in "$h"/temp*_label; do
            [[ -r $l ]] || continue
            lab=$(_tel_read "$l") || continue
            v=$(_tel_div "$(_tel_read "${l%_label}_input")" 1000 0)
            [[ $v == n/a ]] && continue
            case ${lab,,} in
                edge|pkg|package|gpu) [[ $t == n/a ]] && t=$v ;;
                junction|hotspot)     jt=$v ;;
                mem|vram)             mt=$v ;;
            esac
        done
        [[ $t == n/a ]] && t=$(_tel_div "$(_tel_read "$h/temp1_input")" 1000 0)
        if v=$(_tel_read "$h/power1_average") && _tel_isnum "$v" && [[ $v != 0 ]]; then p=$(_tel_div "$v" 1000000 1); ps=hwmon
        elif v=$(_tel_read "$h/power1_input") && _tel_isnum "$v"; then p=$(_tel_div "$v" 1000000 1); ps=hwmon
        elif [[ -r $h/energy1_input ]]; then p=$(_tel_energy_w "gpu$key" "$h/energy1_input"); ps=hwmon-energy
        fi
        v=$(_tel_read "$h/power1_cap") || v=$(_tel_read "$h/power1_max") || v=""
        pl=$(_tel_div "$v" 1000000 0); [[ $pl == 0 ]] && pl=n/a
        fr=$(_tel_read "$h/fan1_input") || fr=n/a
        if v=$(_tel_read "$h/pwm1") && [[ $v =~ ^[0-9]+$ ]]; then fp=$(_tel_div "$((v * 100))" 255 0); fi
    fi
    case $kind in
        amd)
            v=$(_tel_read "$h/freq1_input") && cm=$(_tel_div "$v" 1000000 0)
            [[ -n $cm && $cm != n/a ]] || cm=$(awk '/\*/{gsub(/[^0-9]/,"",$2); print $2; exit}' "$d/pp_dpm_sclk" 2>/dev/null)
            mx=$(awk 'NF>=2{x=$2} END{gsub(/[^0-9]/,"",x); print x}' "$d/pp_dpm_sclk" 2>/dev/null)
            v=$(_tel_read "$h/freq2_input") && mm=$(_tel_div "$v" 1000000 0)
            [[ -n $mm && $mm != n/a ]] || mm=$(awk '/\*/{gsub(/[^0-9]/,"",$2); print $2; exit}' "$d/pp_dpm_mclk" 2>/dev/null)
            u=$(_tel_read "$d/gpu_busy_percent") || u=n/a
            mu=$(_tel_read "$d/mem_busy_percent") || mu=n/a
            vu=$(_tel_div "$(_tel_read "$d/mem_info_vram_used")" 1048576 0)
            gu=$(_tel_div "$(_tel_read "$d/mem_info_gtt_used")" 1048576 0)
            [[ $p != n/a && $integ == 1 ]] && ps="hwmon (APU package; shared with CPU)"
            ;;
        intel)
            cm=$(_tel_read "$c/gt_act_freq_mhz") || cm=$(_tel_read "$c/gt_cur_freq_mhz") || cm=""
            mx=$(_tel_read "$c/gt_max_freq_mhz") || mx=$(_tel_read "$c/gt_RP0_freq_mhz") || mx=""
            if [[ -z $cm ]]; then
                for f in "$d"/tile*/gt*/freq*/act_freq; do
                    [[ -r $f ]] || continue
                    cm=$(_tel_read "$f"); mx=$(_tel_read "${f%/*}/max_freq") || mx=$(_tel_read "${f%/*}/rp0_freq") || mx=""
                    break
                done
            fi
            if [[ -r $c/gt/gt0/throttle_reason_status ]]; then thr=$(_tel_intel_throttle "$c/gt/gt0" throttle_reason_ throttle_reason_status)
            else
                for f in "$d"/tile*/gt*/freq*/throttle; do
                    [[ -r $f/status ]] && { thr=$(_tel_intel_throttle "$f" reason_ status); break; }
                done
            fi
            u=$(_tel_util_from_helper "$idx")
            if [[ $ps == n/a && $integ == 1 && -n ${TEL_RAPL_UNCORE:-} ]]; then
                p=$(_tel_energy_w "uncore" "$TEL_RAPL_UNCORE" "${TEL_RAPL_UNCORE_MAX:-0}"); ps="rapl-uncore (shared with CPU package)"
            fi
            ;;
    esac
    [[ $u == n/a && $kind == amd ]] && u=$(_tel_util_from_helper "$idx")
    # integrated GPUs (root-complex endpoints) report "Unknown" / x0: no PCIe link to show
    v=$(_tel_read "$d/current_link_speed") && [[ $v != Unknown* ]] && link="$v x$(_tel_read "$d/current_link_width" || echo '?')"
    link=${link//,/;}
    echo "${t:-n/a},${p:-n/a},${cm:-n/a},${u:-n/a},${vu:-n/a},${fr:-n/a},${link:-n/a},${jt:-n/a},${mt:-n/a},${mm:-n/a},${mx:-n/a},${mu:-n/a},${gu:-n/a},${fp:-n/a},${pl:-n/a},${ps:-n/a},${thr:-n/a}"
}

_tel_gpu_nvidia() {
    local out
    out=$(nvidia-smi -i "$1" --query-gpu=temperature.gpu,power.draw,clocks.sm,clocks.mem,utilization.gpu,memory.used,fan.speed,"$TEL_NV_THR",pstate,power.limit \
        --format=csv,noheader,nounits 2>/dev/null | head -n1)
    if [[ -z $out ]]; then echo "$_TEL_GPU_NA"; return 0; fi
    awk -F',' '{ for(i=1;i<=10;i++){ g=$i; gsub(/^[ \t]+|[ \t]+$/,"",g);
        if(g==""||g~/N\/A|Not Supported|Unknown|Error|\[/) g="n/a"; printf "%s%s",(i>1?",":""),g } print "" }' <<<"$out"
}

# ----------------------------------------------------------------------------- disks
disk_kind() {
    local d; d=$(_tel_dev "$1")
    case $d in
        nvme*) echo nvme; return 0 ;;
        vd*|xvd*) echo virtual; return 0 ;;
    esac
    case $(_tel_read "/sys/block/$d/queue/rotational") in
        0) echo ssd ;;
        1) echo hdd ;;
        *) echo "n/a" ;;
    esac
}

disk_temp() {
    local d f v out
    d=$(_tel_dev "$1")
    for f in /sys/block/"$d"/device/hwmon*/temp1_input /sys/block/"$d"/device/hwmon/hwmon*/temp1_input; do
        [[ -r $f ]] || continue
        v=$(_tel_read "$f") || continue
        [[ $v =~ ^-?[0-9]+$ ]] && { echo $(((v + 500) / 1000)); return 0; }
    done
    if command -v smartctl >/dev/null 2>&1; then
        out=$(smartctl -n standby -A "/dev/$d" 2>/dev/null | awk '
            $1=="194"{ if(match($10,/^[0-9]+/)) t194=substr($10,1,RLENGTH) }
            $1=="190"{ if(match($10,/^[0-9]+/)) t190=substr($10,1,RLENGTH) }
            /^Temperature:/{ t=$2 }
            /^Current Drive Temperature:/{ t=$4 }
            END{ if(t194!="") print t194; else if(t!="") print t; else if(t190!="") print t190 }')
        [[ $out =~ ^[0-9]+$ ]] && { echo "$out"; return 0; }
    fi
    echo "n/a"
}

disk_io() {
    tel_init
    local d st now line prev=""
    d=$(_tel_dev "$1")
    st="$TEL_STATE_DIR/io.${TEL_TAG:-main}.$d"
    now=$(_tel_now)
    line=$(awk -v d="$d" '$3==d{print $4,$6,$8,$10,$13; exit}' /proc/diskstats 2>/dev/null)
    if [[ -z $line ]]; then echo "n/a,n/a,n/a,n/a,n/a"; return 0; fi
    [[ -r $st ]] && prev=$(<"$st")
    printf '%s %s\n' "$now" "$line" > "$st" 2>/dev/null
    if [[ -z $prev ]]; then echo "n/a,n/a,n/a,n/a,n/a"; return 0; fi
    awk -v c="$now $line" -v p="$prev" 'BEGIN{ split(c,a," "); split(p,b," "); dt=a[1]-b[1];
        if(dt<=0){print "n/a,n/a,n/a,n/a,n/a"; exit}
        u=(a[6]-b[6])/(dt*10); if(u>100)u=100
        printf "%.1f,%.1f,%.0f,%.0f,%.0f\n",(a[3]-b[3])*512/1e6/dt,(a[5]-b[5])*512/1e6/dt,(a[2]-b[2])/dt,(a[4]-b[4])/dt,u }'
}

fs_type()        { findmnt -n -o FSTYPE --target "$1" 2>/dev/null | head -n1; }
fs_avail_bytes() { df -B1 --output=avail "$1" 2>/dev/null | awk 'NR==2{print $1}'; }
fs_size_bytes()  { df -B1 --output=size "$1" 2>/dev/null | awk 'NR==2{print $1}'; }

path_disks() {
    local p=$1 src fstype pool dev real pk
    src=$(findmnt -n -o SOURCE --target "$p" 2>/dev/null | head -n1)
    fstype=$(findmnt -n -o FSTYPE --target "$p" 2>/dev/null | head -n1)
    [[ -n $src ]] || return 0
    if [[ $fstype == zfs ]]; then
        pool=${src%%/*}
        command -v zpool >/dev/null 2>&1 || return 0
        zpool status -LP "$pool" 2>/dev/null | awk '$1 ~ /^\/dev\//{print $1}' | while read -r dev; do
            real=$(readlink -f "$dev")
            pk=$(lsblk -n -d -o PKNAME "$real" 2>/dev/null | head -n1)
            [[ -z $pk ]] && pk=$(lsblk -n -s -r -o NAME,TYPE "$real" 2>/dev/null | awk '$2=="disk"{print $1; exit}')
            echo "${pk:-${real##*/}}"
        done | sort -u | tr '\n' ' ' | sed 's/ $//'
    else
        [[ $src == /dev/* ]] || return 0
        lsblk -n -s -r -o NAME,TYPE "$src" 2>/dev/null | awk '$2=="disk"{print $1}' | sort -u | tr '\n' ' ' | sed 's/ $//'
    fi
    echo
}

disk_smart_snapshot() {
    local d f; d=$(_tel_dev "$1"); f=$2
    {
        echo "# $(date -Is) smartctl -a /dev/$d"
        if command -v smartctl >/dev/null 2>&1; then smartctl -a "/dev/$d" 2>&1; else echo "smartctl not installed"; fi
        if [[ $d == nvme* ]] && command -v nvme >/dev/null 2>&1; then
            echo; echo "# nvme smart-log /dev/$d"; nvme smart-log "/dev/$d" 2>&1
        fi
    } > "$f" 2>&1
    return 0
}

smart_brief() {
    local f=$1
    [[ -r $f ]] || return 0
    awk '
    function num(s){ gsub(/,/,"",s); if(match(s,/^[0-9]+/)) return substr(s,1,RLENGTH); return "" }
    /overall-health self-assessment test result:/{ h=$NF }
    /^SMART Health Status:/{ h=$NF }
    /^Critical Warning:/{ cw=$3 }
    /^Temperature:/{ t=$2 }
    /^Available Spare:/{ sp=$3; sub(/%/,"",sp) }
    /^Percentage Used:/{ pu=$3; sub(/%/,"",pu) }
    /^Data Units Written:/{ du=num($4); if(du!="") dw=sprintf("%.2f", du*512000/1e12) }
    /^Power On Hours:/{ poh=num($4) }
    /^Unsafe Shutdowns:/{ us=num($3) }
    /^Media and Data Integrity Errors:/{ me=num($6) }
    $1=="5"  && NF>=10 { re=num($10) }
    $1=="9"  && NF>=10 { poh=num($10) }
    $1=="194"&& NF>=10 { t=num($10) }
    $1=="197"&& NF>=10 { pe=num($10) }
    $1=="198"&& NF>=10 { ou=num($10) }
    $1=="199"&& NF>=10 { crc=num($10) }
    END{
        printf "health=%s\npower_on_hours=%s\ntemp_c=%s\npercent_used=%s\nmedia_errors=%s\ncritical_warning=%s\navailable_spare=%s\ndata_written_tb=%s\nunsafe_shutdowns=%s\nreallocated=%s\npending=%s\noffline_uncorrectable=%s\ncrc_errors=%s\n",
            (h==""?"n/a":h),(poh==""?"n/a":poh),(t==""?"n/a":t),(pu==""?"n/a":pu),(me==""?"n/a":me),(cw==""?"n/a":cw),
            (sp==""?"n/a":sp),(dw==""?"n/a":dw),(us==""?"n/a":us),(re==""?"n/a":re),(pe==""?"n/a":pe),(ou==""?"n/a":ou),(crc==""?"n/a":crc)
    }' "$f"
}

# ----------------------------------------------------------------------------- HW error counters
hw_error_snapshot() {
    local mce ce ue cor nf fa kerr thr
    mce=$(dmesg 2>/dev/null | grep -ciE 'machine check|mce: \[hardware error\]|hardware error')
    ce=$(cat /sys/devices/system/edac/mc/mc*/ce_count 2>/dev/null | awk '{s+=$1} END{print s+0}')
    ue=$(cat /sys/devices/system/edac/mc/mc*/ue_count 2>/dev/null | awk '{s+=$1} END{print s+0}')
    cor=$(cat /sys/bus/pci/devices/*/aer_dev_correctable 2>/dev/null | awk '$1=="TOTAL_ERR_COR"{s+=$2} END{print s+0}')
    nf=$(cat /sys/bus/pci/devices/*/aer_dev_nonfatal 2>/dev/null | awk '$1=="TOTAL_ERR_NONFATAL"{s+=$2} END{print s+0}')
    fa=$(cat /sys/bus/pci/devices/*/aer_dev_fatal 2>/dev/null | awk '$1=="TOTAL_ERR_FATAL"{s+=$2} END{print s+0}')
    kerr=$(journalctl -k -b -p 3 --no-pager -q 2>/dev/null | wc -l)
    thr=$(cpu_throttle)
    printf 'mce_lines=%s\nedac_ce=%s\nedac_ue=%s\naer_cor=%s\naer_nonfatal=%s\naer_fatal=%s\nkernel_err_lines=%s\nthrottle_core=%s\nthrottle_pkg=%s\n' \
        "${mce:-0}" "${ce:-0}" "${ue:-0}" "${cor:-0}" "${nf:-0}" "${fa:-0}" "${kerr:-0}" "${thr%%,*}" "${thr##*,}"
}

hw_error_diff() {
    awk -F= 'FNR==NR{a[$1]=$2; next} ($1 in a) && a[$1] ~ /^[0-9]+$/ && $2 ~ /^[0-9]+$/ && $2+0 > a[$1]+0 { print $1" "a[$1]" -> "$2 }' "$1" "$2" 2>/dev/null
}

# ----------------------------------------------------------------------------- CSV
csv_init() { printf '%s\n' "$2" > "$1"; }
csv_safe() { local s=${1-}; s=${s//,/;}; s=${s//$'\n'/ }; s=${s//$'\r'/}; printf '%s' "$s"; }
csv_row() {
    local f=$1 out="" x first=1; shift
    for x in "$@"; do
        [[ -z $x ]] && x="n/a"
        if ((first)); then out=$x; first=0; else out+=",$x"; fi
    done
    printf '%s\n' "$out" >> "$f"
}
csv_stats() {
    awk -F, -v c="$2" 'NR==1{for(i=1;i<=NF;i++) if($i==c) k=i; next}
        k && $k ~ /^-?[0-9]+([.][0-9]+)?$/ { v=$k+0; n++; s+=v; if(n==1||v<mn)mn=v; if(n==1||v>mx)mx=v }
        END{ if(n) printf "%d %.2f %.2f %.2f\n", n, mn, s/n, mx; else print "0 n/a n/a n/a" }' "$1" 2>/dev/null || echo "0 n/a n/a n/a"
}
csv_stats_json() {
    local n mn av mx
    read -r n mn av mx < <(csv_stats "$1" "$2")
    printf '{"n":%s,"min":%s,"avg":%s,"max":%s}' "${n:-0}" "$(json_num "$mn")" "$(json_num "$av")" "$(json_num "$mx")"
}

# ----------------------------------------------------------------------------- JSON
json_escape() {
    local s=${1-}
    s=${s//\\/\\\\}; s=${s//\"/\\\"}; s=${s//$'\n'/\\n}; s=${s//$'\r'/}; s=${s//$'\t'/\\t}
    s=$(printf '%s' "$s" | LC_ALL=C tr -d '\000-\010\013\014\016-\037')
    printf '%s' "$s"
}
json_str() { printf '"%s"' "$(json_escape "${1-}")"; }
json_num() {
    local v=${1-}
    if [[ $v =~ ^-?(0|[1-9][0-9]*)([.][0-9]+)?([eE][-+]?[0-9]+)?$ ]]; then printf '%s' "$v"
    elif [[ $v =~ ^-?[0-9]*[.]?[0-9]+$ ]]; then awk -v v="$v" 'BEGIN{printf "%.10g", v+0}'
    else printf 'null'; fi
}
json_bool() { case ${1-} in 1|true|yes|TRUE|Yes) printf 'true' ;; *) printf 'false' ;; esac; }
json_arr_str() {
    local x out="" first=1
    for x in "$@"; do
        if ((first)); then out=$(json_str "$x"); first=0; else out+=",$(json_str "$x")"; fi
    done
    printf '[%s]' "$out"
}

summary_write() {
    local f=$1 part=$2 dur=$3 metrics=${4:-} status=${5:-} extra=${6:-} w e s sk="" first=1 name reason
    [[ -z $metrics ]] && metrics='{}'
    if [[ -z $status ]]; then
        if ((${#TEL_ERRORS[@]})); then status=error
        elif ((${#TEL_SKIPPED[@]})); then status=partial
        else status=ok; fi
    fi
    w=$(json_arr_str "${TEL_WARNINGS[@]}")
    e=$(json_arr_str "${TEL_ERRORS[@]}")
    for s in "${TEL_SKIPPED[@]}"; do
        name=${s%%|*}; reason=${s#*|}
        if ((first)); then first=0; else sk+=","; fi
        sk+="{\"test\":$(json_str "$name"),\"reason\":$(json_str "$reason")}"
    done
    {
        printf '{\n  "part": %s,\n  "status": %s,\n  "duration_s": %s,\n  "generated": %s,\n' \
            "$(json_str "$part")" "$(json_str "$status")" "$(json_num "$dur")" "$(json_str "$(date -Is)")"
        printf '  "metrics": %s,\n  "warnings": %s,\n  "errors": %s,\n  "skipped": [%s]' "$metrics" "$w" "$e" "$sk"
        [[ -n $extra ]] && printf ',\n  %s' "$extra"
        printf '\n}\n'
    } > "$f"
}

# ----------------------------------------------------------------------------- test files
testfile_register() {
    mkdir -p "$STRESS_HOME" 2>/dev/null
    printf '%s\n' "$1" >> "$STRESS_HOME/.testfiles" 2>/dev/null
    return 0
}

# ----------------------------------------------------------------------------- sampler
tel_phase() { tel_init; csv_safe "${1:-}" > "$TEL_STATE_DIR/phase" 2>/dev/null; }

tel_header() {
    local g h="ts,elapsed_s,phase" d i
    [[ $# -eq 0 ]] && set -- cpu mem
    for g in "$@"; do
        case $g in
            cpu) h+=",cpu_pkg_w,cpu_core_w,cpu_temp_c,cpu_avg_mhz,cpu_min_mhz,cpu_max_mhz,cpu_pcore_mhz,cpu_ecore_mhz,cpu_busy_pct,cpu_core_throttle,cpu_pkg_throttle,load1" ;;
            mem) h+=",mem_used_mb,mem_avail_mb,swap_used_mb" ;;
            sockets)
                tel_init
                for i in "${TEL_SOCKET_IDS[@]}"; do h+=",cpu_s${i}_pkg_w"; done
                for i in "${TEL_SOCKET_IDS[@]}"; do h+=",cpu_s${i}_temp_c"; done ;;
            gpu|gpu:*)
                i=0; [[ $g == gpu:* ]] && i=${g#gpu:}
                h+=",$(printf '%s' "$TEL_GPU_FIELDS" | sed "s/[^,]*/gpu${i}_&/g")" ;;
            disk:*)
                d=$(_tel_dev "${g#disk:}")
                h+=",${d}_temp_c,${d}_read_mbps,${d}_write_mbps,${d}_r_iops,${d}_w_iops,${d}_util_pct" ;;
        esac
    done
    printf '%s\n' "$h"
}

_tel_sample_groups() {
    local g out="" i
    for g in "$@"; do
        case $g in
            cpu) out+=",$(cpu_power),$(cpu_temp),$(cpu_mhz),$(cpu_mhz_hybrid),$(cpu_busy),$(cpu_throttle),$(load1)" ;;
            mem) out+=",$(mem_usage)" ;;
            sockets) out+=",$(cpu_power_sockets),$(cpu_temp_sockets)" ;;
            gpu|gpu:*) i=0; [[ $g == gpu:* ]] && i=${g#gpu:}; out+=",$(gpu_query "$i")" ;;
            disk:*) out+=",$(disk_temp "${g#disk:}"),$(disk_io "${g#disk:}")" ;;
        esac
    done
    printf '%s' "$out"
}

tel_sampler_start() {
    tel_init
    local file=$1; shift
    [[ $# -eq 0 ]] && set -- cpu mem
    tel_sampler_stop
    tel_header "$@" > "$file"
    [[ -s $TEL_STATE_DIR/phase ]] || printf 'run' > "$TEL_STATE_DIR/phase"
    local parent=$BASHPID
    (
        TEL_TAG="s$BASHPID"
        trap 'exit 0' TERM INT
        _tel_sample_groups "$@" > /dev/null          # prime rate counters
        local start i=0 now d ph el
        start=$(_tel_now)
        while :; do
            i=$((i + 1))
            now=$(_tel_now)
            d=$(awk -v s="$start" -v i="$i" -v n="$now" 'BEGIN{d=s+i-n; if(d<0.05)d=0.05; printf "%.3f", d}')
            sleep "$d"
            kill -0 "$parent" 2>/dev/null || exit 0
            ph=$(<"$TEL_STATE_DIR/phase") 2>/dev/null || ph=run
            now=$(_tel_now)
            el=$(awk -v s="$start" -v n="$now" 'BEGIN{printf "%.1f", n-s}')
            printf '%s,%s,%s%s\n' "$(date +%T)" "$el" "${ph:-run}" "$(_tel_sample_groups "$@")" >> "$file"
        done
    ) &
    TEL_SAMPLER_PID=$!
    return 0
}

tel_sampler_stop() {
    if [[ -n ${TEL_SAMPLER_PID:-} ]]; then
        kill "$TEL_SAMPLER_PID" 2>/dev/null
        wait "$TEL_SAMPLER_PID" 2>/dev/null
        TEL_SAMPLER_PID=""
    fi
    return 0
}
