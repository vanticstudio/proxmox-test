#!/usr/bin/env bash
# =============================================================================
# prep.sh - step 0 of the proxmox-hardware-stress-test sweep.
#
# Usage (as root ON the Proxmox host, after copying scripts/ to /root/pve-stresstest/):
#   bash /root/pve-stresstest/prep.sh --out DIR [--duration SECONDS]
#        [--baseline-seconds N] [--no-install] [--plan-only]
#        [--gpu-tools auto|yes|no] [--amd-intel-opencl]
#
#   --out DIR             Run root, e.g. /root/pve-stresstest/run-YYYYMMDD-HHMM.
#                         Later scripts use DIR/01-cpu, DIR/02-ram, ...
#   --duration SECONDS    The per-part stress length the user chose (30/60/300/600).
#                         Recorded in hardware.json; drives the plan estimates.
#   --baseline-seconds N  Idle telemetry length (default 30, 10..300).
#   --no-install          Detect + baseline only; install nothing.
#   --plan-only           Detect + inventory + test plan ONLY: no installs, no
#                         apt update, no idle baseline, no load. Writes
#                         hardware.json, inventory.json/.md, plan.json/.md and
#                         prints the plan; run this first and show it to the user.
#   --gpu-tools MODE      auto (default): install the GPU test tools for every GPU
#                         the host drives itself: NVIDIA (nvidia driver) ->
#                         hashcat ocl-icd-libopencl1 clinfo clpeak; AMD (amdgpu)
#                         and Intel (i915/xe), discrete or integrated -> the same
#                         plus the right userland OpenCL runtime for the Debian
#                         release and GPU generation (Mesa rusticl via
#                         mesa-opencl-icd, Intel compute-runtime via
#                         intel-opencl-icd where packaged, AMD radeonsi from
#                         <codename>-backports on Debian 12 when that suite is
#                         configured) and intel-gpu-tools for Intel busy %.
#                         yes: as auto, plus the NVIDIA set even without a usable
#                         GPU; no: never install GPU tools.
#   --amd-intel-opencl    Accepted for compatibility; no effect (AMD/Intel
#                         OpenCL is now part of --gpu-tools auto).
#
# What it does
#   1. Detects hardware -> DIR/hardware.json: CPU (vendor/model/cores/threads/
#      hybrid P/E, microcode, governor, RAPL limits, sensor sources), RAM (size,
#      DIMMs, speed, ECC via dmidecode), GPUs (PCI + driver + nvidia-smi /
#      sysfs, and whether each can be tested from the host), physical disks
#      (nvme/ssd/hdd, model, SMART brief), mounted filesystems with free space
#      and which disks they live on, Proxmox storages, ZFS (version, ARC,
#      Direct-IO support), PVE / Debian / kernel versions, root fs type,
#      guests (qm list / pct list) and the tool paths.
#   1b. Full inventory + test plan (inventory.py, python3): every CPU socket,
#      DIMM slot (incl. empty), GPU, storage controller (SATA/NVMe/SAS/RAID),
#      storage device (incl. disks hidden behind hardware RAID, via smartctl
#      --scan-open), NIC, and fans/PSU/sensors when readable -> DIR/inventory.json
#      + inventory.md (serials/MACs masked). One test unit per testable item
#      -> DIR/plan.json + plan.md: CPU -> RAM -> each GPU -> each SSD (NVMe
#      first) -> each HDD, each disk with method write+read (test file) /
#      read-only raw / skip + reason, ready-to-run commands and time estimates.
#      Also extends hardware.json (system/board/bios, sockets, controllers,
#      NICs, per-disk usage + plan). With --plan-only prep stops here.
#   2. Installs the test tools from the configured Debian/Proxmox apt repos
#      only (stress-ng sysbench 7-zip fio nvme-cli smartmontools lm-sensors
#      linux-cpupower dmidecode pciutils memtester gcc libc6-dev python3, plus
#      hashcat ocl-icd-libopencl1 clinfo clpeak for a GPU, plus the AMD/Intel
#      OpenCL runtime packages, see --gpu-tools). Packages that were NOT
#      installed before (dependencies included) are appended to
#      DIR/installed-packages.txt so cleanup.sh removes exactly those.
#      Never installs or touches GPU drivers, kernel modules, DKMS, kernels or
#      firmware. Each AMD/Intel runtime package is first simulated (apt-get -s):
#      it is NOT installed if apt would pull a kernel/firmware/DKMS/microcode
#      package or upgrade a package already on the host (cleanup could not undo
#      that); the GPU is then "limited" with that reason in the plan. Per GPU,
#      hardware.json records "integrated", "render_node" and "opencl" (runtime,
#      packages, state: present / will-install / installed / unavailable /
#      blocked / failed / unsupported / not-installed, note).
#   3. Baseline in DIR/00-baseline/: idle telemetry (1 Hz CSV: CPU W / C / MHz /
#      busy %, RAM, every GPU, every disk temp + I/O), SMART snapshots of every
#      disk, RAPL limits, governor, sensors, dmidecode, hardware error counters
#      and kernel error log, turbostat 5 s (if available), summary.json.
#
# What it does NOT do: no stress, no writes to block devices, no BIOS / power
# limit / governor / kernel changes, no guest start/stop. Running guests keep
# running and are recorded (they add load to the baseline - reported).
#
# Time: ~1-3 min for apt (first run), + baseline-seconds (30 s) + ~10-20 s of
# snapshots. Exit 0 on success (missing sensors/tools are recorded, not fatal);
# exit 1 only for bad usage, not root, or unwritable DIR.
#
# Developer-only: PVE_STRESS_SYSFS_ROOT=DIR (via telemetry.sh's TEL_ROOT) makes the
# GPU detection and OpenCL checks read DIR/sys, DIR/etc/OpenCL/vendors and
# DIR/etc/os-release instead of the real files. Never set it on a real host;
# see docs/developing.md.
# =============================================================================
set -u
set -o pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=telemetry.sh
. "$SCRIPT_DIR/telemetry.sh" || { echo "FATAL: cannot source $SCRIPT_DIR/telemetry.sh" >&2; exit 1; }

OUT="" DURATION="" BASE_S=30 DO_INSTALL=1 GPU_TOOLS=auto AMD_OPENCL=0 PLAN_ONLY=0

usage() { sed -n '4,33p' "$0" | sed 's/^# \{0,1\}//'; }
need_arg() { [[ $# -ge 2 && -n ${2:-} ]] || { echo "Missing value for $1" >&2; usage >&2; exit 1; }; }

while (($#)); do
    case $1 in
        --out) need_arg "$@"; OUT=$2; shift 2 ;;
        --duration) need_arg "$@"; DURATION=$2; shift 2 ;;
        --baseline-seconds) need_arg "$@"; BASE_S=$2; shift 2 ;;
        --no-install) DO_INSTALL=0; shift ;;
        --plan-only) PLAN_ONLY=1; DO_INSTALL=0; shift ;;
        --gpu-tools) need_arg "$@"; GPU_TOOLS=$2; shift 2 ;;
        --amd-intel-opencl) AMD_OPENCL=1; shift ;;   # compatibility alias: no effect any more
        -h|--help) usage; exit 0 ;;
        *) echo "Unknown argument: $1" >&2; usage >&2; exit 1 ;;
    esac
done

[[ $EUID -eq 0 ]] || tel_die "run as root on the Proxmox host"
[[ -n $OUT ]] || { usage >&2; tel_die "--out DIR is required"; }
[[ $OUT == /* ]] || OUT="$PWD/$OUT"
[[ $BASE_S =~ ^[0-9]+$ ]] && ((BASE_S >= 10 && BASE_S <= 300)) || tel_die "--baseline-seconds must be 10..300"
if [[ -n $DURATION ]]; then
    [[ $DURATION =~ ^[0-9]+$ ]] && ((DURATION > 0)) || tel_die "--duration must be a positive integer (seconds)"
    case $DURATION in 30|60|300|600) ;; *) tel_warn "duration $DURATION s is not one of the standard 30/60/300/600" ;; esac
fi
case $GPU_TOOLS in auto|yes|no) ;; *) tel_die "--gpu-tools must be auto, yes or no" ;; esac

B="$OUT/00-baseline"
mkdir -p "$B" || tel_die "cannot create $B"
mkdir -p "$STRESS_HOME" && : > "$STRESS_HOME/.pve-stresstest-root"
export LC_ALL=C
export DEBIAN_FRONTEND=noninteractive
START_ISO=$(date -Is)
date -Is > "$B/timestamp.txt"
tel_log "prep: output in $OUT$( ((PLAN_ONLY)) && echo ' (plan only: no installs, no baseline)')"

# ============================================================================ 1. GPU detection via sysfs (no tools needed)
GPU_SLOTS=() GPU_VEND=() GPU_DEVID=() GPU_DRV=() GPU_KIND=() GPU_TESTABLE=() GPU_REASON=() GPU_NAME=()
GPU_INTEG=() GPU_RNODE=() GPU_OCL_RT=() GPU_OCL_STATE=() GPU_OCL_PKGS=() GPU_OCL_BPO=() GPU_OCL_NOTE=()
NVIDIA_USABLE=0 AMDINTEL_PRESENT=0
for dev in "$TEL_ROOT"/sys/bus/pci/devices/*; do
    cls=$(_tel_read "$dev/class") || continue
    [[ $cls == 0x03* ]] || continue
    slot=${dev##*/}
    v=$(_tel_read "$dev/vendor") || v=""
    did=$(_tel_read "$dev/device") || did=""
    drv=""
    [[ -e $dev/driver ]] && drv=$(basename "$(readlink -f "$dev/driver")")
    name=""
    command -v lspci >/dev/null 2>&1 && name=$(lspci -s "$slot" 2>/dev/null | sed 's/^[^ ]* //; s/^[^:]*: //')
    kind=other testable=no reason=""
    case $v in
        0x10de) kind=nvidia
            case $drv in
                nvidia)
                    if command -v nvidia-smi >/dev/null 2>&1 && nvidia-smi -L >/dev/null 2>&1; then
                        testable=yes; NVIDIA_USABLE=1
                    else reason="nvidia driver bound but nvidia-smi does not work"; fi ;;
                vfio-pci) reason="passed through to a VM (vfio-pci) - cannot be tested from the host" ;;
                nouveau) reason="open-source nouveau driver - no compute support; proprietary NVIDIA driver needed" ;;
                "") reason="no driver bound" ;;
                *) reason="driver $drv - not supported for compute tests" ;;
            esac ;;
        0x1002) kind=amd
            case $drv in
                amdgpu) testable=limited; AMDINTEL_PRESENT=1
                    reason="OpenCL runtime not checked yet" ;;   # decided by plan_amd_intel_runtimes below
                radeon) reason="legacy radeon driver (pre-GCN card) - no OpenCL runtime for it; not usable for compute" ;;
                vfio-pci) reason="passed through to a VM (vfio-pci) - cannot be tested from the host" ;;
                *) reason="driver ${drv:-none} - not usable for compute" ;;
            esac ;;
        0x8086) kind=intel
            case $drv in
                i915|xe) testable=limited; AMDINTEL_PRESENT=1
                    reason="OpenCL runtime not checked yet" ;;   # decided by plan_amd_intel_runtimes below
                vfio-pci) reason="passed through to a VM (vfio-pci) - cannot be tested from the host" ;;
                *) reason="driver ${drv:-none} - not usable for compute" ;;
            esac ;;
        0x1a03|0x102b|0x1234|0x1b36|0x15ad) kind=basic-display; reason="BMC / basic display adapter - not a compute GPU" ;;
        *) reason="unknown GPU vendor $v" ;;
    esac
    GPU_SLOTS+=("$slot"); GPU_VEND+=("$v"); GPU_DEVID+=("$did"); GPU_DRV+=("${drv:-none}")
    GPU_KIND+=("$kind"); GPU_TESTABLE+=("$testable"); GPU_REASON+=("$reason"); GPU_NAME+=("${name:-unknown}")
    rn=""; for r in "$dev"/drm/renderD[0-9]*; do [[ -e $r ]] && { rn=${r##*/}; break; }; done
    GPU_INTEG+=("$(gpu_is_integrated_pci "$slot" "$name")"); GPU_RNODE+=("$rn")
    GPU_OCL_RT+=(""); GPU_OCL_STATE+=("not-applicable"); GPU_OCL_PKGS+=(""); GPU_OCL_BPO+=(0); GPU_OCL_NOTE+=("")
done
tel_log "GPUs found: ${#GPU_SLOTS[@]} (NVIDIA usable from host: $NVIDIA_USABLE)"

# ============================================================================ 2. package install
# python3 is needed by disk.sh's summary writer (present on stock PVE; listed so a minimal host gets it).
REQ=(stress-ng sysbench fio nvme-cli smartmontools lm-sensors linux-cpupower dmidecode pciutils memtester gcc libc6-dev python3)
SEVENZ_ALT=()
command -v 7z >/dev/null 2>&1 || command -v 7zz >/dev/null 2>&1 || SEVENZ_ALT=(p7zip-full 7zip)
PKG_ALREADY=() PKG_NEW_REQ=() PKG_UNAVAIL=() PKG_FAILED=() NEWLY=() PKG_BLOCKED=() BPO_NEW=()
APT_UPDATE_OK=na
pkg_installed() { [[ $(dpkg-query -W -f='${db:Status-Abbrev}' "$1" 2>/dev/null) == ii* ]]; }
pkg_candidate() {
    local c
    c=$(apt-cache policy "$1" 2>/dev/null | awk '/Candidate:/{print $2; exit}')
    [[ -n $c && $c != "(none)" ]]
}
pkg_cand_ver() { apt-cache policy "$1" 2>/dev/null | awk '/Candidate:/{ if ($2 != "(none)") print $2; exit}'; }
pkg_inst_ver() { pkg_installed "$1" && dpkg-query -W -f='${Version}' "$1" 2>/dev/null; }
# Newest version of $1 offered by a *-backports suite that is configured on the host (or empty).
pkg_bpo_ver() { apt-cache madison "$1" 2>/dev/null | awk -F'|' '$3 ~ /-backports/ { gsub(/ /,"",$2); print $2; exit }'; }
ver_ge() { [[ -n ${1:-} && -n ${2:-} ]] && dpkg --compare-versions "$1" ge "$2" 2>/dev/null; }
icd_present() { compgen -G "$TEL_ROOT/etc/OpenCL/vendors/$1" >/dev/null 2>&1; }
DEB_CODENAME=$( (. "$TEL_ROOT/etc/os-release" 2>/dev/null; printf '%s' "${VERSION_CODENAME:-}") )

# Intel GPUs older than Gen8 (Sandy/Ivy Bridge, Haswell, Bay Trail and earlier) use the crocus/i965
# Mesa drivers: neither rusticl nor Intel's compute-runtime supports them.
intel_pre_gen8() {
    case ${1,,} in
        0x01??|0x04??|0x0a??|0x0c??|0x0d??|0x0f??|0x29??|0x2a??|0x2e??|0xa0??|0x0042|0x0046) return 0 ;;
    esac
    return 1
}

# Simulate installing ONE package (+ its dependencies). Refuse when apt would pull a
# kernel / firmware / DKMS / microcode / bootloader package, or upgrade a package that is
# already installed (cleanup.sh removes only new packages, so an upgrade could not be undone).
declare -A SIMC=()     # package simulation verdicts: "ok" or the reason it is blocked
NOKERNEL_RE='^(linux-(image|headers|modules|kbuild|support)|proxmox-kernel|proxmox-default-kernel|proxmox-headers|proxmox-default-headers|pve-kernel|pve-headers|pve-firmware|firmware-.*|.*-dkms|dkms|amd64-microcode|intel-microcode|grub.*|shim.*)'
SIM_REASON=""
sim_ok() {
    local out bad up
    SIM_REASON=""
    out=$(LC_ALL=C apt-get -s -q install --no-install-recommends "$@" 2>&1) || {
        SIM_REASON="apt cannot install it: $(grep -m1 -E '^E:' <<<"$out" | cut -c1-160)"; return 1; }
    bad=$(awk '$1=="Inst"{print $2}' <<<"$out" | grep -E "$NOKERNEL_RE" | tr '\n' ' ')
    [[ -n $bad ]] && { SIM_REASON="apt would also install kernel/firmware/DKMS packages (${bad% }), which this skill never does"; return 1; }
    up=$(awk '$1=="Inst" && $3 ~ /^\[/{print $2}' <<<"$out" | tr '\n' ' ')
    [[ -n $up ]] && { SIM_REASON="apt would upgrade packages already on the host (${up% }), which cleanup could not undo; update the host first (apt full-upgrade) or install the runtime yourself"; return 1; }
    return 0
}

# Decide, per AMD (amdgpu) / Intel (i915, xe) GPU, which userland OpenCL runtime makes it
# testable, and which packages that needs. Sets GPU_OCL_* and GPU_TESTABLE/GPU_REASON, and
# appends to GPU_PKGS / GPU_BPO_PKGS. MODE: plan (nothing installed yet) | final (after apt).
plan_amd_intel_runtimes() {
    local mode=${1:-plan} i k drv did rt st pk bpo note mi mc mb ni nc need nmesa why p key okp got
    mi=$(pkg_inst_ver mesa-opencl-icd); mc=$(pkg_cand_ver mesa-opencl-icd); mb=$(pkg_bpo_ver mesa-opencl-icd)
    ni=$(pkg_inst_ver intel-opencl-icd); nc=$(pkg_cand_ver intel-opencl-icd)
    AMDINTEL_WANTS_TOOLS=0
    for i in "${!GPU_SLOTS[@]}"; do
        k=${GPU_KIND[$i]} drv=${GPU_DRV[$i]} did=${GPU_DEVID[$i]}
        case "$k:$drv" in amd:amdgpu|intel:i915|intel:xe) ;; *) continue ;; esac
        rt="" st="" pk="" bpo=0 note="" why=""
        if [[ $k == amd ]]; then
            need="23.1~"   # rusticl's radeonsi backend arrived in Mesa 23.1
            if icd_present 'amdocl*.icd'; then rt="AMD ROCm OpenCL (already installed)"; st=present
            elif ver_ge "$mi" "$need"; then rt="Mesa rusticl (radeonsi), mesa-opencl-icd $mi"; st=present
            elif ver_ge "$mc" "$need"; then rt="Mesa rusticl (radeonsi), mesa-opencl-icd $mc"; st=install; pk=mesa-opencl-icd
            elif ver_ge "$mb" "$need"; then rt="Mesa rusticl (radeonsi), mesa-opencl-icd $mb from ${DEB_CODENAME:-?}-backports"; st=install; pk=mesa-opencl-icd; bpo=1
            elif [[ -n $mi || -n $mc ]]; then
                rt="Mesa Clover (legacy OpenCL 1.1) only"; st=$([[ -n $mi ]] && echo present || echo install); [[ -z $mi ]] && pk=mesa-opencl-icd
                note="Mesa ${mi:-$mc} has no rusticl support for AMD (needs Mesa 23.1+; on Debian 12 add ${DEB_CODENAME:-bookworm}-backports to the host's apt sources); only the legacy Clover runtime is available, which hashcat usually rejects - clpeak may still run"
            else st=unavailable; why="no AMD OpenCL runtime package (mesa-opencl-icd) in the host's configured apt repos; telemetry only"
            fi
        else
            if intel_pre_gen8 "$did"; then
                st=unsupported; why="Intel GPU generation 7 or older (device $did): no rusticl or compute-runtime OpenCL support; telemetry only"
            else
                need="22.3~"; [[ $drv == xe ]] && need="24.1~"   # iris on the xe kernel driver needs Mesa 24.1+
                nmesa=""
                if icd_present 'intel*.icd' || [[ -n $ni ]]; then rt="Intel compute-runtime (already installed)"; st=present
                elif [[ $drv == i915 && -n $nc ]]; then rt="Intel compute-runtime (intel-opencl-icd $nc)"; st=install; pk=intel-opencl-icd
                fi
                if ver_ge "$mi" "$need"; then nmesa="Mesa rusticl (iris), mesa-opencl-icd $mi"; [[ -z $st ]] && st=present
                elif ver_ge "$mc" "$need"; then nmesa="Mesa rusticl (iris), mesa-opencl-icd $mc"; pk="${pk:+$pk }mesa-opencl-icd"; [[ -z $st ]] && st=install
                elif ver_ge "$mb" "$need"; then nmesa="Mesa rusticl (iris), mesa-opencl-icd $mb from ${DEB_CODENAME:-?}-backports"; pk="${pk:+$pk }mesa-opencl-icd"; bpo=1; [[ -z $st ]] && st=install
                fi
                rt="${rt}${rt:+${nmesa:+; fallback }}${nmesa}"
                # a working runtime is already there: install nothing (and don't name a Mesa that isn't installed)
                [[ $st == present ]] && { pk=""; bpo=0; [[ -z $mi ]] && rt=${rt%%; fallback*}; }
                if [[ -z $st ]]; then
                    st=unavailable
                    if [[ $drv == xe && -n $nc ]]; then nmesa="intel-opencl-icd $nc is offered but this skill only uses it with the i915 driver"
                    else nmesa="intel-opencl-icd is not available from them (it is not packaged for Debian 13)"; fi
                    why="no Intel OpenCL runtime package for this GPU in the host's configured apt repos (rusticl iris needs mesa-opencl-icd >= ${need%\~}; $nmesa); telemetry only"
                fi
            fi
        fi
        # GPU tools disabled, or no installs in this run
        if [[ $st == install && $GPU_TOOLS == no ]]; then st=not-installed; why="OpenCL runtime ($rt) not installed: --gpu-tools no"
        elif [[ $st == install ]] && ((!DO_INSTALL && !PLAN_ONLY)); then st=not-installed; why="OpenCL runtime ($rt) not installed: --no-install"
        fi
        # Simulate each package once (read-only, so also in plan-only mode); the final pass
        # reuses the verdicts so a blocked package is reported as blocked, not as failed.
        if [[ $st == install ]]; then
            okp=""
            for p in $pk; do
                key=$p.$bpo
                if [[ -z ${SIMC[$key]:-} ]]; then
                    if [[ $mode != plan ]]; then SIMC[$key]=ok
                    elif ((bpo)) && [[ $p == mesa-opencl-icd ]]; then sim_ok -t "${DEB_CODENAME}-backports" "$p"; SIMC[$key]=${SIM_REASON:-ok}
                    else sim_ok "$p"; SIMC[$key]=${SIM_REASON:-ok}; fi
                fi
                if [[ ${SIMC[$key]} == ok ]]; then okp="${okp:+$okp }$p"
                else
                    [[ $mode == plan ]] && PKG_BLOCKED+=("$p: ${SIMC[$key]}")
                    note="${note:+$note; }$p not installed: ${SIMC[$key]}"
                fi
            done
            pk=$okp
            if [[ -z $pk ]]; then st=blocked; why="OpenCL runtime not installed - $note"; note=""; fi
        fi
        if [[ $mode == final && $st == install ]]; then
            got=""
            for p in $pk; do pkg_installed "$p" && got="${got:+$got }$p"; done
            if [[ -n $got ]]; then st=installed
            elif ((DO_INSTALL)); then st=failed; why="OpenCL runtime package(s) $pk failed to install (see 00-baseline/apt-install.log); telemetry only"
            fi
        fi
        case $st in
            present|install|installed)
                if [[ $rt == *Clover* ]]; then GPU_TESTABLE[$i]=limited; GPU_REASON[$i]="$note"
                else GPU_TESTABLE[$i]=yes; GPU_REASON[$i]=""; fi
                AMDINTEL_WANTS_TOOLS=1 ;;
            *)  GPU_TESTABLE[$i]=limited; GPU_REASON[$i]=$why ;;
        esac
        GPU_OCL_RT[$i]=$rt; GPU_OCL_STATE[$i]=$st; GPU_OCL_PKGS[$i]=$pk; GPU_OCL_BPO[$i]=$bpo; GPU_OCL_NOTE[$i]=$note
        if [[ $st == install && $mode == plan ]]; then
            for p in $pk; do
                if ((bpo)) && [[ $p == mesa-opencl-icd ]]; then GPU_BPO_PKGS+=("$p"); else GPU_PKGS+=("$p"); fi
            done
        fi
        # intel_gpu_top gives Intel's busy % (no sysfs counter); optional, only if it installs cleanly.
        if [[ $k == intel && $AMDINTEL_WANTS_TOOLS == 1 && $GPU_TOOLS != no && $mode == plan ]] && ! pkg_installed intel-gpu-tools && [[ -n $(pkg_cand_ver intel-gpu-tools) ]]; then
            if [[ -z ${SIMC[igt]:-} ]]; then sim_ok intel-gpu-tools; SIMC[igt]=${SIM_REASON:-ok}; fi
            [[ ${SIMC[igt]} == ok ]] && GPU_PKGS+=(intel-gpu-tools)
        fi
    done
    return 0
}

# GPU package set for this run (NVIDIA tools + AMD/Intel runtimes). Called again after apt update.
compose_gpu_pkgs() {
    GPU_PKGS=() GPU_BPO_PKGS=() PKG_BLOCKED=() SIMC=()
    plan_amd_intel_runtimes plan
    [[ $GPU_TOOLS == no ]] && { GPU_PKGS=(); GPU_BPO_PKGS=(); return 0; }
    if [[ $GPU_TOOLS == yes ]] || [[ $NVIDIA_USABLE == 1 ]] || [[ ${AMDINTEL_WANTS_TOOLS:-0} == 1 ]]; then
        # Note: Debian's hashcat has a hard "Depends: pocl-opencl-icd | opencl-icd". The NVIDIA
        # .run installer provides the ICD file but no package, so apt pulls in pocl (a CPU
        # OpenCL runtime) plus several LLVM/SPIR-V libraries even with --no-install-recommends.
        # They are recorded and removed by cleanup.sh; gpu.sh never benchmarks the pocl device.
        GPU_PKGS+=(hashcat ocl-icd-libopencl1 clinfo clpeak)
    fi
    mapfile -t GPU_PKGS < <(printf '%s\n' "${GPU_PKGS[@]}" | awk 'NF && !s[$0]++')
    mapfile -t GPU_BPO_PKGS < <(printf '%s\n' "${GPU_BPO_PKGS[@]}" | awk 'NF && !s[$0]++')
    return 0
}
GPU_PKGS=() GPU_BPO_PKGS=()
compose_gpu_pkgs

# What a full prep run would install (shown in the plan before anything is installed).
PKG_MISSING=()
for p in "${REQ[@]}" "${GPU_PKGS[@]}" "${GPU_BPO_PKGS[@]}"; do pkg_installed "$p" || PKG_MISSING+=("$p"); done
((${#SEVENZ_ALT[@]})) && PKG_MISSING+=("7zip (or p7zip-full)")
mapfile -t PKG_MISSING < <(printf '%s\n' "${PKG_MISSING[@]}" | awk 'NF && !s[$0]++')
printf '%s\n' "${PKG_MISSING[@]}" | awk 'NF' > "$B/packages-to-install.txt"

dpkg-query -W -f='${db:Status-Abbrev} ${Package}\n' 2>/dev/null | awk '{print $1, $2}' | sort -k2 > "$B/pre-install-pkgstatus.txt"
awk '$1 ~ /^ii/{print $2}' "$B/pre-install-pkgstatus.txt" | sort -u > "$B/pre-install-pkglist.txt"

if ((DO_INSTALL)); then
    tel_log "apt-get update ..."
    # Short timeouts so a host without internet fails fast instead of hanging for minutes.
    APT_NET=(-o Acquire::Retries=1 -o Acquire::http::Timeout=20 -o Acquire::https::Timeout=20)
    if timeout 300 apt-get "${APT_NET[@]}" update -q > "$B/apt-update.log" 2>&1; then APT_UPDATE_OK=yes
    else
        APT_UPDATE_OK=partial
        tel_warn "apt-get update reported errors (often the enterprise repo without a subscription); continuing with the repos that worked - see 00-baseline/apt-update.log"
    fi
    compose_gpu_pkgs     # re-plan the AMD/Intel OpenCL runtimes with fresh package lists
    for p in "${REQ[@]}" "${GPU_PKGS[@]}"; do
        if pkg_installed "$p"; then PKG_ALREADY+=("$p")
        elif pkg_candidate "$p"; then PKG_NEW_REQ+=("$p")
        else PKG_UNAVAIL+=("$p"); fi
    done
    if ((${#SEVENZ_ALT[@]})); then
        got=""
        for p in "${SEVENZ_ALT[@]}"; do pkg_candidate "$p" && { got=$p; break; }; done
        if [[ -n $got ]]; then PKG_NEW_REQ+=("$got"); else PKG_UNAVAIL+=("7-zip(p7zip-full|7zip)"); fi
    fi
    # de-duplicate
    mapfile -t PKG_NEW_REQ < <(printf '%s\n' "${PKG_NEW_REQ[@]}" | awk 'NF && !s[$0]++')
    if ((${#PKG_NEW_REQ[@]})); then
        tel_log "installing: ${PKG_NEW_REQ[*]}"
        if ! apt-get install -y -q --no-install-recommends "${APT_NET[@]}" -o DPkg::Lock::Timeout=300 "${PKG_NEW_REQ[@]}" > "$B/apt-install.log" 2>&1; then
            tel_warn "bulk apt install failed; retrying packages one by one"
            for p in "${PKG_NEW_REQ[@]}"; do
                pkg_installed "$p" && continue
                apt-get install -y -q --no-install-recommends "${APT_NET[@]}" -o DPkg::Lock::Timeout=300 "$p" >> "$B/apt-install.log" 2>&1 || PKG_FAILED+=("$p")
            done
        fi
    else
        tel_log "all required tools already installed"
        : > "$B/apt-install.log"
    fi
    # AMD/Intel runtime from <codename>-backports (Debian 12 AMD), only after its simulation passed.
    BPO_NEW=()
    for p in "${GPU_BPO_PKGS[@]}"; do pkg_installed "$p" || BPO_NEW+=("$p"); done
    if ((${#BPO_NEW[@]})); then
        tel_log "installing from ${DEB_CODENAME}-backports: ${BPO_NEW[*]}"
        apt-get install -y -q --no-install-recommends -t "${DEB_CODENAME}-backports" "${APT_NET[@]}" -o DPkg::Lock::Timeout=300 "${BPO_NEW[@]}" >> "$B/apt-install.log" 2>&1 ||
            PKG_FAILED+=("${BPO_NEW[@]}")
    fi
    ((${#PKG_BLOCKED[@]})) && tel_warn "GPU OpenCL runtime package(s) not installed for safety: ${PKG_BLOCKED[*]}"
    ((${#PKG_UNAVAIL[@]})) && tel_warn "not available from the configured repos: ${PKG_UNAVAIL[*]} (the matching sub-tests will be skipped)"
    ((${#PKG_FAILED[@]})) && tel_warn "failed to install: ${PKG_FAILED[*]} (see 00-baseline/apt-install.log)"
else
    tel_log "--no-install/--plan-only: skipping package installation"
fi

dpkg-query -W -f='${db:Status-Abbrev} ${Package}\n' 2>/dev/null | awk '$1 ~ /^ii/{print $2}' | sort -u > "$B/post-install-pkglist.txt"
mapfile -t NEWLY < <(comm -13 "$B/pre-install-pkglist.txt" "$B/post-install-pkglist.txt")
# Merge (never overwrite) so a second prep run cannot forget earlier installs.
LEDGER="$OUT/installed-packages.txt"
if ((PLAN_ONLY)); then
    NEWLY=()     # nothing can have been installed; leave any existing ledger untouched
else
{ [[ -r $LEDGER ]] && cat "$LEDGER"; printf '%s\n' "${NEWLY[@]}"; } | awk 'NF' | sort -u > "$LEDGER.tmp" && mv "$LEDGER.tmp" "$LEDGER"
# Packages that had leftover config ("rc") before -> cleanup uses remove, not purge.
RCPKGS=$(awk '$1 ~ /^rc/{print $2}' "$B/pre-install-pkgstatus.txt" | sort -u | comm -12 - <(printf '%s\n' "${NEWLY[@]}" | sort -u))
if [[ -n $RCPKGS ]]; then
    { [[ -r $OUT/installed-packages.rc.txt ]] && cat "$OUT/installed-packages.rc.txt"; printf '%s\n' "$RCPKGS"; } | awk 'NF' | sort -u > "$OUT/installed-packages.rc.tmp" &&
        mv "$OUT/installed-packages.rc.tmp" "$OUT/installed-packages.rc.txt"
fi
tel_log "newly installed packages (incl. dependencies): ${#NEWLY[@]} -> $LEDGER"
fi

# Final AMD/Intel GPU status (did the runtime package really get installed?).
plan_amd_intel_runtimes final
for i in "${!GPU_SLOTS[@]}"; do
    case ${GPU_OCL_STATE[$i]} in
        blocked|failed|unavailable|unsupported|not-installed) tel_warn "GPU ${GPU_SLOTS[$i]} (${GPU_NAME[$i]}): ${GPU_REASON[$i]}" ;;
    esac
    [[ -n ${GPU_OCL_NOTE[$i]} ]] && tel_warn "GPU ${GPU_SLOTS[$i]} (${GPU_NAME[$i]}): ${GPU_OCL_NOTE[$i]}"
done

# ============================================================================ 3. telemetry init (after lm-sensors etc.)
tel_init
cleanup_on_exit() { tel_sampler_stop; tel_cleanup; }
trap cleanup_on_exit EXIT
trap 'tel_log "interrupted"; exit 130' INT TERM

# ============================================================================ 4. hardware detection
lscpu_f() { LC_ALL=C lscpu 2>/dev/null | awk -F: -v k="$1" '$1==k{sub(/^[ \t]+/,"",$2); print $2; exit}'; }

# --- host
HOSTNAME_S=$(hostname 2>/dev/null)
PVE_FULL=$(pveversion 2>/dev/null | head -n1)
PVE_VER=$(sed -n 's#^pve-manager/\([^/ ]*\).*#\1#p' <<<"$PVE_FULL")
[[ -z $PVE_FULL ]] && tel_warn "pveversion not found - this does not look like a Proxmox VE host (continuing)"
DEB_VER=$(_tel_read /etc/debian_version) || DEB_VER=""
KERNEL=$(uname -r)
VIRT=$(systemd-detect-virt 2>/dev/null) || VIRT=none
[[ -n $VIRT && $VIRT != none ]] && tel_warn "running inside a virtual machine ($VIRT): results describe the VM, not the hardware"
ROOT_FS=$(fs_type /)
ROOT_SRC=$(findmnt -n -o SOURCE / 2>/dev/null | head -n1)
UPTIME_S=$(awk '{printf "%d", $1}' /proc/uptime)

# --- CPU
CPU_VENDOR_ID=$(lscpu_f "Vendor ID")
case $CPU_VENDOR_ID in GenuineIntel) CPU_VENDOR=intel ;; AuthenticAMD|HygonGenuine) CPU_VENDOR=amd ;; *) CPU_VENDOR=other ;; esac
CPU_MODEL=$(lscpu_f "Model name")
CPU_FAMILY=$(lscpu_f "CPU family"); CPU_MODEL_ID=$(lscpu_f "Model"); CPU_STEPPING=$(lscpu_f "Stepping")
CPU_SOCKETS=$(lscpu_f "Socket(s)"); CPU_CPS=$(lscpu_f "Core(s) per socket"); CPU_TPC=$(lscpu_f "Thread(s) per core")
CPU_THREADS=$(nproc --all 2>/dev/null || lscpu_f "CPU(s)")
CPU_CORES=""
[[ $CPU_SOCKETS =~ ^[0-9]+$ && $CPU_CPS =~ ^[0-9]+$ ]] && CPU_CORES=$((CPU_SOCKETS * CPU_CPS))
# hybrid Intel: lscpu's "Core(s) per socket" is unreliable -> count from sysfs topology
if [[ ${TEL_HYBRID:-0} == 1 ]]; then
    CPU_CORES=$(cat /sys/devices/system/cpu/cpu[0-9]*/topology/core_cpus_list 2>/dev/null | sort -u | wc -l)
fi
CPU_MAXMHZ=$(lscpu_f "CPU max MHz"); CPU_MINMHZ=$(lscpu_f "CPU min MHz")
CPU_UCODE=$(awk -F: '/^microcode/{gsub(/ /,"",$2); print $2; exit}' /proc/cpuinfo)
CPU_FLAGS=$(awk -F: '/^flags/{print $2; exit}' /proc/cpuinfo)
has_flag() { [[ " $CPU_FLAGS " == *" $1 "* ]] && echo 1 || echo 0; }
SCALING_DRIVER=$(_tel_read /sys/devices/system/cpu/cpu0/cpufreq/scaling_driver) || SCALING_DRIVER=n/a
GOVERNOR=$(_tel_read /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor) || GOVERNOR=n/a
EPP=$(_tel_read /sys/devices/system/cpu/cpu0/cpufreq/energy_performance_preference) || EPP=n/a
BOOST=n/a
if v=$(_tel_read /sys/devices/system/cpu/intel_pstate/no_turbo); then [[ $v == 0 ]] && BOOST=on || BOOST=off
elif v=$(_tel_read /sys/devices/system/cpu/cpufreq/boost); then [[ $v == 1 ]] && BOOST=on || BOOST=off
elif v=$(_tel_read /sys/devices/system/cpu/cpu0/cpufreq/boost); then [[ $v == 1 ]] && BOOST=on || BOOST=off; fi
PL1="" PL2=""
for z in /sys/class/powercap/intel-rapl:0; do
    [[ -d $z ]] || continue
    for f in "$z"/constraint_*_name; do
        [[ -r $f ]] || continue
        n=$(_tel_read "$f"); i=${f%_name}
        lim=$(_tel_read "${i}_power_limit_uw") || lim=""
        case $n in long_term) PL1=$(_tel_div "$lim" 1000000 0) ;; short_term) PL2=$(_tel_div "$lim" 1000000 0) ;; esac
    done
done
THROTTLE_AVAIL=0; [[ $(cpu_throttle) != "n/a,n/a" ]] && THROTTLE_AVAIL=1
PCORE_LIST=$(_tel_read /sys/devices/cpu_core/cpus) || PCORE_LIST=""
ECORE_LIST=$(_tel_read /sys/devices/cpu_atom/cpus) || ECORE_LIST=""

# --- memory
MEM_TOTAL_MB=$(awk '/^MemTotal:/{printf "%d", $2/1024}' /proc/meminfo)
MEM_AVAIL_MB=$(awk '/^MemAvailable:/{printf "%d", $2/1024}' /proc/meminfo)
SWAP_TOTAL_MB=$(awk '/^SwapTotal:/{printf "%d", $2/1024}' /proc/meminfo)
dmidecode -t memory > "$B/dmidecode-memory.txt" 2>&1 || true
dmidecode -t bios -t baseboard -t system > "$B/dmidecode-board.txt" 2>&1 || true
MEM_ECC=$(awk -F': ' '/Error Correction Type:/{print $2; exit}' "$B/dmidecode-memory.txt")
MEM_MAXCAP=$(awk -F': ' '/Maximum Capacity:/{print $2; exit}' "$B/dmidecode-memory.txt")
DIMMS_TSV=$(awk -F': ' '
    function trim(s){ gsub(/^[ \t]+|[ \t]+$/,"",s); return s }
    function emit(){ if(seen) print loc "|" size "|" type "|" spd "|" cfg "|" man "|" part "|" rank "|" volt }
    /^Memory Device$/ { emit(); seen=1; loc=size=type=spd=cfg=man=part=rank=volt=""; next }
    /^Handle / { if(seen){ emit(); seen=0 } next }
    seen && /^\tLocator:/ { loc=trim($2) }
    seen && /^\tSize:/ { size=trim($2) }
    seen && /^\tType:/ { type=trim($2) }
    seen && /^\tSpeed:/ { spd=trim($2) }
    seen && /^\tConfigured Memory Speed:/ { cfg=trim($2) }
    seen && /^\tConfigured Clock Speed:/ { if(cfg=="") cfg=trim($2) }
    seen && /^\tManufacturer:/ { man=trim($2) }
    seen && /^\tPart Number:/ { part=trim($2) }
    seen && /^\tRank:/ { rank=trim($2) }
    seen && /^\tConfigured Voltage:/ { volt=trim($2) }
    END { emit() }' "$B/dmidecode-memory.txt")
DIMMS_JSON="" SLOTS=0 POPULATED=0
while IFS='|' read -r loc size type spd cfg man part rank volt; do
    [[ -z $loc && -z $size ]] && continue
    SLOTS=$((SLOTS + 1))
    pop=1; [[ $size == "No Module Installed" || $size == "Not Installed" || -z $size ]] && pop=0
    ((pop)) && POPULATED=$((POPULATED + 1))
    ((pop)) || continue
    size_mb=$(awk -v s="$size" 'BEGIN{n=s+0; if(s~/TB/)n*=1048576; else if(s~/GB/)n*=1024; printf "%d", n}')
    spd_n=$(grep -oE '^[0-9]+' <<<"$spd"); cfg_n=$(grep -oE '^[0-9]+' <<<"$cfg")
    [[ -n $DIMMS_JSON ]] && DIMMS_JSON+=","
    DIMMS_JSON+=$(printf '{"locator":%s,"size_mb":%s,"type":%s,"rated_mts":%s,"configured_mts":%s,"manufacturer":%s,"part":%s,"rank":%s,"voltage":%s}' \
        "$(json_str "$loc")" "$(json_num "$size_mb")" "$(json_str "$type")" "$(json_num "$spd_n")" "$(json_num "$cfg_n")" \
        "$(json_str "$man")" "$(json_str "$part")" "$(json_str "$rank")" "$(json_str "$volt")")
done <<<"$DIMMS_TSV"
[[ $SLOTS == 0 ]] && tel_warn "dmidecode returned no memory devices (RAM speed/DIMM layout unknown)"

# --- GPUs (enrich with nvidia-smi / sysfs link info)
OPENCL_NV_ICD=0
ls "$TEL_ROOT"/etc/OpenCL/vendors/*nvidia* >/dev/null 2>&1 && OPENCL_NV_ICD=1
GPUS_JSON=""
for i in "${!GPU_SLOTS[@]}"; do
    slot=${GPU_SLOTS[$i]}; dev=$TEL_ROOT/sys/bus/pci/devices/$slot
    lmax="$(_tel_read "$dev/max_link_speed") x$(_tel_read "$dev/max_link_width")"
    lcur="$(_tel_read "$dev/current_link_speed") x$(_tel_read "$dev/current_link_width")"
    extra=""
    if [[ ${GPU_KIND[$i]} == nvidia && ${GPU_TESTABLE[$i]} == yes ]]; then
        busid=$(sed 's/^0000://' <<<"$slot")
        nv=$(nvidia-smi --query-gpu=pci.bus_id,index,name,driver_version,memory.total,power.limit,power.default_limit,power.max_limit,pcie.link.gen.max,pcie.link.width.max,vbios_version \
            --format=csv,noheader,nounits 2>/dev/null | awk -F', ' -v b="$busid" 'toupper($1) ~ toupper(b)"$"' | head -n1)
        if [[ -n $nv ]]; then
            IFS=',' read -r _ nidx nname ndrv nmem npl npld nplm ngen nwid nvb <<<"${nv//, /,}"
            GPU_NAME[$i]=$nname
            extra=$(printf ',"nvidia":{"index":%s,"driver":%s,"vram_mib":%s,"power_limit_w":%s,"power_default_w":%s,"power_max_w":%s,"pcie_gen_max":%s,"pcie_width_max":%s,"vbios":%s,"opencl_icd":%s}' \
                "$(json_num "$nidx")" "$(json_str "$ndrv")" "$(json_num "$nmem")" "$(json_num "$npl")" "$(json_num "$npld")" "$(json_num "$nplm")" \
                "$(json_num "$ngen")" "$(json_num "$nwid")" "$(json_str "$nvb")" "$(json_bool "$OPENCL_NV_ICD")")
            [[ $OPENCL_NV_ICD == 0 ]] && tel_warn "NVIDIA GPU ${GPU_NAME[$i]}: no OpenCL ICD in /etc/OpenCL/vendors - hashcat/clpeak will not see it (the .run installer or nvidia-opencl-icd provides it)"
        fi
    elif [[ ${GPU_KIND[$i]} == amd ]]; then
        vram=$(_tel_read "$dev/mem_info_vram_total") && extra=",\"vram_mib\":$(_tel_div "$vram" 1048576 0)"
    fi
    if [[ ${GPU_OCL_STATE[$i]} != not-applicable ]]; then
        extra+=$(printf ',"opencl":{"runtime":%s,"state":%s,"packages":%s,"backports":%s,"note":%s}' \
            "$(json_str "${GPU_OCL_RT[$i]}")" "$(json_str "${GPU_OCL_STATE[$i]}")" "$(json_arr_str ${GPU_OCL_PKGS[$i]})" \
            "$(json_bool "${GPU_OCL_BPO[$i]}")" "$(json_str "${GPU_OCL_NOTE[$i]}")")
    fi
    [[ -n $GPUS_JSON ]] && GPUS_JSON+=","
    GPUS_JSON+=$(printf '{"slot":%s,"vendor":%s,"vendor_id":%s,"device_id":%s,"name":%s,"driver":%s,"testable":%s,"reason":%s,"pcie_max":%s,"pcie_current":%s,"integrated":%s,"render_node":%s%s}' \
        "$(json_str "$slot")" "$(json_str "${GPU_KIND[$i]}")" "$(json_str "${GPU_VEND[$i]}")" "$(json_str "${GPU_DEVID[$i]}")" \
        "$(json_str "${GPU_NAME[$i]}")" "$(json_str "${GPU_DRV[$i]}")" "$(json_str "${GPU_TESTABLE[$i]}")" "$(json_str "${GPU_REASON[$i]}")" \
        "$(json_str "$lmax")" "$(json_str "$lcur")" "$(json_bool "${GPU_INTEG[$i]}")" "$(json_str "${GPU_RNODE[$i]}")" "$extra")
done
TEL_GPUS_JSON=""
for i in "${!TEL_GPU_KINDS[@]}"; do
    [[ -n $TEL_GPUS_JSON ]] && TEL_GPUS_JSON+=","
    TEL_GPUS_JSON+=$(printf '{"tel_index":%s,"kind":%s,"id":%s,"name":%s}' "$i" "$(json_str "${TEL_GPU_KINDS[$i]}")" "$(json_str "${TEL_GPU_IDS[$i]}")" "$(json_str "${TEL_GPU_NAMES[$i]}")")
done

# --- disks
ROOT_DISKS=" $(path_disks /) "
DISKS=()
for b in /sys/block/*; do
    n=${b##*/}
    case $n in loop*|ram*|zram*|dm-*|md*|zd*|rbd*|nbd*|sr*|fd*|nvme*c*n*) continue ;; esac
    [[ -e $b/device ]] || continue
    DISKS+=("$n")
done
DISKS_JSON=""
for n in "${DISKS[@]}"; do
    b=/sys/block/$n
    size=$(( $(_tel_read "$b/size" || echo 0) * 512 ))
    kind=$(disk_kind "$n")
    model=$(lsblk -dno MODEL "/dev/$n" 2>/dev/null | sed 's/[[:space:]]*$//')
    serial=$(lsblk -dno SERIAL "/dev/$n" 2>/dev/null | sed 's/[[:space:]]*$//')
    tran=$(lsblk -dno TRAN "/dev/$n" 2>/dev/null | sed 's/[[:space:]]*$//')
    rev=$(lsblk -dno REV "/dev/$n" 2>/dev/null | sed 's/[[:space:]]*$//')
    disk_smart_snapshot "$n" "$B/smart-$n.txt"
    smartctl -l error "/dev/$n" > "$B/smart-errlog-$n.txt" 2>&1 || true
    declare -A S=()
    while IFS='=' read -r k v; do [[ -n $k ]] && S[$k]=$v; done < <(smart_brief "$B/smart-$n.txt")
    link=""
    if [[ $kind == nvme ]]; then
        pdev=$(readlink -f "$b/device/device" 2>/dev/null)
        [[ -n $pdev ]] && link=$(printf ',"pcie_max":%s,"pcie_current":%s' \
            "$(json_str "$(_tel_read "$pdev/max_link_speed") x$(_tel_read "$pdev/max_link_width")")" \
            "$(json_str "$(_tel_read "$pdev/current_link_speed") x$(_tel_read "$pdev/current_link_width")")")
    fi
    isroot=0; [[ $ROOT_DISKS == *" $n "* ]] && isroot=1
    [[ ${S[health]:-n/a} == FAILED* ]] && tel_warn "disk $n ($model): SMART overall health FAILED - consider NOT stress-testing it; back up first"
    [[ ${S[critical_warning]:-0x00} != 0x00 && ${S[critical_warning]:-n/a} != n/a ]] && tel_warn "disk $n ($model): NVMe critical warning ${S[critical_warning]}"
    for k in reallocated pending offline_uncorrectable media_errors; do
        [[ ${S[$k]:-n/a} =~ ^[0-9]+$ ]] && ((S[$k] > 0)) && tel_warn "disk $n ($model): SMART $k = ${S[$k]}"
    done
    [[ $tran == usb ]] && tel_warn "disk $n ($model) is on USB - results limited by the USB bridge"
    [[ -n $DISKS_JSON ]] && DISKS_JSON+=","
    DISKS_JSON+=$(printf '{"name":%s,"kind":%s,"size_bytes":%s,"model":%s,"serial":%s,"transport":%s,"firmware":%s,"root_disk":%s%s,"smart":{"health":%s,"power_on_hours":%s,"temp_c":%s,"percent_used":%s,"media_errors":%s,"critical_warning":%s,"available_spare_pct":%s,"data_written_tb":%s,"unsafe_shutdowns":%s,"reallocated":%s,"pending":%s,"offline_uncorrectable":%s,"crc_errors":%s}}' \
        "$(json_str "$n")" "$(json_str "$kind")" "$size" "$(json_str "$model")" "$(json_str "$serial")" "$(json_str "$tran")" "$(json_str "$rev")" "$(json_bool "$isroot")" "$link" \
        "$(json_str "${S[health]:-n/a}")" "$(json_num "${S[power_on_hours]:-}")" "$(json_num "${S[temp_c]:-}")" "$(json_num "${S[percent_used]:-}")" \
        "$(json_num "${S[media_errors]:-}")" "$(json_str "${S[critical_warning]:-n/a}")" "$(json_num "${S[available_spare]:-}")" "$(json_num "${S[data_written_tb]:-}")" \
        "$(json_num "${S[unsafe_shutdowns]:-}")" "$(json_num "${S[reallocated]:-}")" "$(json_num "${S[pending]:-}")" "$(json_num "${S[offline_uncorrectable]:-}")" "$(json_num "${S[crc_errors]:-}")")
    unset S
done
[[ ${#DISKS[@]} -eq 0 ]] && tel_warn "no physical disks found in /sys/block"

# --- Proxmox storages (name -> path for dir-type storages)
declare -A STORE_PATH=()
if [[ -r /etc/pve/storage.cfg ]]; then
    while IFS=$'\t' read -r sname spath; do [[ -n $sname ]] && STORE_PATH[$sname]=$spath; done < <(
        awk '/^[a-z0-9]+: /{split($0,a,": "); name=a[2]} /^[ \t]+path /{print name "\t" $2}' /etc/pve/storage.cfg)
fi
# storage -> mountpoint that holds its path (so "local" maps to "/" when /var/lib/vz is on root)
declare -A STORE_MNT=()
for sname in "${!STORE_PATH[@]}"; do
    [[ -e ${STORE_PATH[$sname]} ]] || continue
    STORE_MNT[$sname]=$(findmnt -n -o TARGET --target "${STORE_PATH[$sname]}" 2>/dev/null | head -n1)
done
pvesm status > "$B/pvesm-status.txt" 2>&1 || true
PVESM_JSON=""
while read -r sname stype sstat stot sused savail _; do
    [[ -n $PVESM_JSON ]] && PVESM_JSON+=","
    PVESM_JSON+=$(printf '{"name":%s,"type":%s,"status":%s,"total_kib":%s,"used_kib":%s,"avail_kib":%s,"path":%s}' \
        "$(json_str "$sname")" "$(json_str "$stype")" "$(json_str "$sstat")" "$(json_num "$stot")" "$(json_num "$sused")" "$(json_num "$savail")" \
        "$(json_str "${STORE_PATH[$sname]:-}")")
done < <(awk 'NR>1 && NF>=6' "$B/pvesm-status.txt" 2>/dev/null)

# --- mounted filesystems usable for disk test files
findmnt -rn -o TARGET,SOURCE,FSTYPE,OPTIONS > "$B/findmnt.txt" 2>/dev/null || true
lsblk -o NAME,TYPE,SIZE,ROTA,TRAN,MODEL,FSTYPE,MOUNTPOINTS > "$B/lsblk.txt" 2>&1 || lsblk > "$B/lsblk.txt" 2>&1
FS_JSON=""
declare -A SEEN_T=()
while read -r t s f o; do
    t=$(printf '%b' "$t"); s=$(printf '%b' "$s")
    case $f in ext4|ext3|xfs|btrfs|zfs|f2fs) ;; *) continue ;; esac
    case $t in /proc*|/sys*|/run*|/dev*|/var/lib/lxc*|/etc/pve*) continue ;; esac
    [[ $f == zfs && $s =~ (subvol-|basevol-) ]] && continue
    [[ ",$o," == *",ro,"* ]] && continue
    [[ -n ${SEEN_T[$t]:-} ]] && continue
    SEEN_T[$t]=1
    sz=$(fs_size_bytes "$t"); av=$(fs_avail_bytes "$t")
    dks=$(path_disks "$t")
    kinds=""; for d in $dks; do kinds+="$(disk_kind "$d") "; done
    stores=""; for sname in "${!STORE_MNT[@]}"; do [[ ${STORE_MNT[$sname]} == "$t" ]] && stores+="$sname "; done
    [[ -n $FS_JSON ]] && FS_JSON+=","
    FS_JSON+=$(printf '{"mountpoint":%s,"source":%s,"fstype":%s,"size_bytes":%s,"avail_bytes":%s,"disks":%s,"disk_kinds":%s,"pve_storages":%s}' \
        "$(json_str "$t")" "$(json_str "$s")" "$(json_str "$f")" "$(json_num "$sz")" "$(json_num "$av")" \
        "$(json_arr_str $dks)" "$(json_arr_str $(tr ' ' '\n' <<<"$kinds" | awk 'NF && !s[$0]++'))" "$(json_arr_str $stores)")
done < "$B/findmnt.txt"

# --- ZFS
ZFS_JSON='{"present":false}'
if [[ -d /sys/module/zfs ]] || command -v zpool >/dev/null 2>&1; then
    zver=$(_tel_read /sys/module/zfs/version) || zver=$(zfs version 2>/dev/null | sed -n 's/^zfs-kmod-//p; s/^zfs-//p' | head -n1)
    zmaj=$(sed -E 's/^([0-9]+)\.([0-9]+).*/\1/' <<<"$zver"); zmin=$(sed -E 's/^([0-9]+)\.([0-9]+).*/\2/' <<<"$zver")
    zdio=0; [[ $zmaj =~ ^[0-9]+$ && $zmin =~ ^[0-9]+$ ]] && ((zmaj > 2 || (zmaj == 2 && zmin >= 3))) && zdio=1
    arcmax=$(_tel_read /sys/module/zfs/parameters/zfs_arc_max) || arcmax=""
    read -r arc_c_max arc_size < <(awk '$1=="c_max"{c=$3} $1=="size"{s=$3} END{print c+0, s+0}' /proc/spl/kstat/zfs/arcstats 2>/dev/null)
    zpool list -H -o name,size,alloc,free,health > "$B/zpool-list.txt" 2>&1 || true
    zpool status -LP > "$B/zpool-status.txt" 2>&1 || true
    pools=$(awk -F'\t' 'NF>=5{printf "%s{\"name\":\"%s\",\"size\":\"%s\",\"alloc\":\"%s\",\"free\":\"%s\",\"health\":\"%s\"}", (n++?",":""), $1,$2,$3,$4,$5}' "$B/zpool-list.txt")
    ZFS_JSON=$(printf '{"present":true,"version":%s,"direct_io_supported":%s,"arc_max_param_bytes":%s,"arc_c_max_bytes":%s,"arc_size_bytes":%s,"pools":[%s],"note":%s}' \
        "$(json_str "$zver")" "$(json_bool "$zdio")" "$(json_num "$arcmax")" "$(json_num "${arc_c_max:-}")" "$(json_num "${arc_size:-}")" "$pools" \
        "$(json_str "On ZFS, file-based fio reads can be served from ARC (RAM). Use direct=1 (honoured from OpenZFS 2.3) and/or a test file larger than the ARC; zfs compression must not see compressible data (fio writes random buffers by default).")")
fi

# --- guests
{ echo "### qm list"; qm list 2>&1; echo; echo "### pct list"; pct list 2>&1; } > "$B/guests.txt" 2>&1
VM_TOTAL=0 VM_RUN=0 VM_RUN_MEM=0 CT_TOTAL=0 CT_RUN=0 RUNNING_JSON=""
if command -v qm >/dev/null 2>&1; then
    while read -r id name status mem _; do
        [[ $id =~ ^[0-9]+$ ]] || continue
        VM_TOTAL=$((VM_TOTAL + 1))
        if [[ $status == running ]]; then
            VM_RUN=$((VM_RUN + 1)); [[ $mem =~ ^[0-9]+$ ]] && VM_RUN_MEM=$((VM_RUN_MEM + mem))
            [[ -n $RUNNING_JSON ]] && RUNNING_JSON+=","
            RUNNING_JSON+=$(printf '{"type":"vm","id":%s,"name":%s,"mem_mb":%s}' "$id" "$(json_str "$name")" "$(json_num "$mem")")
        fi
    done < <(qm list 2>/dev/null | awk 'NR>1')
fi
if command -v pct >/dev/null 2>&1; then
    while read -r line; do
        id=$(awk '{print $1}' <<<"$line"); status=$(awk '{print $2}' <<<"$line"); name=$(awk '{print $NF}' <<<"$line")
        [[ $id =~ ^[0-9]+$ ]] || continue
        CT_TOTAL=$((CT_TOTAL + 1))
        if [[ $status == running ]]; then
            CT_RUN=$((CT_RUN + 1))
            [[ -n $RUNNING_JSON ]] && RUNNING_JSON+=","
            RUNNING_JSON+=$(printf '{"type":"ct","id":%s,"name":%s}' "$id" "$(json_str "$name")")
        fi
    done < <(pct list 2>/dev/null | awk 'NR>1')
fi
((VM_RUN + CT_RUN > 0)) && tel_warn "$VM_RUN VM(s) and $CT_RUN container(s) are running; they keep running and share the hardware, so scores may be slightly lower"

# --- tools
TOOLS_JSON=""
for t in stress-ng sysbench 7z 7zz fio nvme smartctl sensors cpupower turbostat gcc memtester dmidecode lspci hashcat clinfo clpeak nvidia-smi rocm-smi intel_gpu_top radeontop; do
    p=$(command -v "$t" 2>/dev/null) || p=""
    [[ -n $TOOLS_JSON ]] && TOOLS_JSON+=","
    if [[ -n $p ]]; then TOOLS_JSON+="$(json_str "$t"):$(json_str "$p")"; else TOOLS_JSON+="$(json_str "$t"):null"; fi
done
VERS_JSON=$(printf '{"stress-ng":%s,"sysbench":%s,"fio":%s,"smartctl":%s}' \
    "$(json_str "$(stress-ng --version 2>/dev/null | head -n1)")" "$(json_str "$(sysbench --version 2>/dev/null | head -n1)")" \
    "$(json_str "$(fio --version 2>/dev/null | head -n1)")" "$(json_str "$(smartctl --version 2>/dev/null | head -n1)")")

# --- write hardware.json
HW="$OUT/hardware.json"
{
printf '{\n'
printf '  "schema": 1,\n  "generated": %s,\n  "requested_duration_s": %s,\n' "$(json_str "$START_ISO")" "$(json_num "$DURATION")"
printf '  "host": {"hostname":%s,"pve_version":%s,"pveversion":%s,"debian_version":%s,"kernel":%s,"virtualization":%s,"root_fs":%s,"root_source":%s,"root_disks":%s,"uptime_s":%s},\n' \
    "$(json_str "$HOSTNAME_S")" "$(json_str "$PVE_VER")" "$(json_str "$PVE_FULL")" "$(json_str "$DEB_VER")" "$(json_str "$KERNEL")" \
    "$(json_str "$VIRT")" "$(json_str "$ROOT_FS")" "$(json_str "$ROOT_SRC")" "$(json_arr_str $ROOT_DISKS)" "$(json_num "$UPTIME_S")"
printf '  "cpu": {"vendor":%s,"vendor_id":%s,"model":%s,"family":%s,"model_id":%s,"stepping":%s,"sockets":%s,"cores":%s,"threads":%s,"threads_per_core":%s,"max_mhz":%s,"min_mhz":%s,"hybrid":%s,"pcores_cpulist":%s,"ecores_cpulist":%s,"microcode":%s,"scaling_driver":%s,"governor":%s,"epp":%s,"boost":%s,"flags":{"avx2":%s,"avx512f":%s,"aes":%s,"sha_ni":%s},"rapl_source":%s,"rapl_pl1_w":%s,"rapl_pl2_w":%s,"temp_source":%s,"throttle_counters":%s},\n' \
    "$(json_str "$CPU_VENDOR")" "$(json_str "$CPU_VENDOR_ID")" "$(json_str "$CPU_MODEL")" "$(json_num "$CPU_FAMILY")" "$(json_num "$CPU_MODEL_ID")" "$(json_num "$CPU_STEPPING")" \
    "$(json_num "$CPU_SOCKETS")" "$(json_num "$CPU_CORES")" "$(json_num "$CPU_THREADS")" "$(json_num "$CPU_TPC")" "$(json_num "$CPU_MAXMHZ")" "$(json_num "$CPU_MINMHZ")" \
    "$(json_bool "$TEL_HYBRID")" "$(json_str "$PCORE_LIST")" "$(json_str "$ECORE_LIST")" "$(json_str "$CPU_UCODE")" "$(json_str "$SCALING_DRIVER")" \
    "$(json_str "$GOVERNOR")" "$(json_str "$EPP")" "$(json_str "$BOOST")" \
    "$(json_bool "$(has_flag avx2)")" "$(json_bool "$(has_flag avx512f)")" "$(json_bool "$(has_flag aes)")" "$(json_bool "$(has_flag sha_ni)")" \
    "$(json_str "$TEL_RAPL_SRC")" "$(json_num "$PL1")" "$(json_num "$PL2")" "$(json_str "$TEL_CPU_TEMP_SRC")" "$(json_bool "$THROTTLE_AVAIL")"
printf '  "memory": {"total_mb":%s,"available_mb":%s,"swap_total_mb":%s,"ecc":%s,"max_capacity":%s,"slots":%s,"populated":%s,"dimms":[%s]},\n' \
    "$(json_num "$MEM_TOTAL_MB")" "$(json_num "$MEM_AVAIL_MB")" "$(json_num "$SWAP_TOTAL_MB")" "$(json_str "$MEM_ECC")" "$(json_str "$MEM_MAXCAP")" "$SLOTS" "$POPULATED" "$DIMMS_JSON"
printf '  "gpus": [%s],\n  "telemetry_gpus": [%s],\n' "$GPUS_JSON" "$TEL_GPUS_JSON"
printf '  "disks": [%s],\n  "filesystems": [%s],\n  "pve_storage": [%s],\n  "zfs": %s,\n' "$DISKS_JSON" "$FS_JSON" "$PVESM_JSON" "$ZFS_JSON"
printf '  "guests": {"vms_total":%s,"vms_running":%s,"vms_running_mem_mb":%s,"cts_total":%s,"cts_running":%s,"running":[%s]},\n' \
    "$VM_TOTAL" "$VM_RUN" "$VM_RUN_MEM" "$CT_TOTAL" "$CT_RUN" "$RUNNING_JSON"
printf '  "tools": {%s},\n  "tool_versions": %s,\n' "$TOOLS_JSON" "$VERS_JSON"
printf '  "install": {"apt_update":%s,"already_installed":%s,"requested_new":%s,"backports":%s,"unavailable":%s,"failed":%s,"blocked_for_safety":%s,"newly_installed_incl_deps":%s,"ledger":%s}\n' \
    "$(json_str "$APT_UPDATE_OK")" "$(json_arr_str "${PKG_ALREADY[@]}")" "$(json_arr_str "${PKG_NEW_REQ[@]}")" "$(json_arr_str "${BPO_NEW[@]}")" "$(json_arr_str "${PKG_UNAVAIL[@]}")" \
    "$(json_arr_str "${PKG_FAILED[@]}")" "$(json_arr_str "${PKG_BLOCKED[@]}")" "$(json_arr_str "${NEWLY[@]}")" "$(json_str "$LEDGER")"
printf '}\n'
} > "$HW"
if command -v python3 >/dev/null 2>&1; then
    python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$HW" 2>"$B/hardware-json-error.txt" ||
        tel_error "hardware.json is not valid JSON (see 00-baseline/hardware-json-error.txt)"
fi
tel_log "wrote $HW"

# ============================================================================ 4b. full inventory + test plan
run_inventory() {
    local mode=full
    ((PLAN_ONLY)) && mode=plan-only
    if ! command -v python3 >/dev/null 2>&1; then
        tel_error "python3 not found: inventory.json / plan.json not written (python3 ships with Proxmox VE; install it with apt)"
        return 0
    fi
    if [[ ! -r $SCRIPT_DIR/inventory.py ]]; then
        tel_error "inventory.py missing next to prep.sh: inventory.json / plan.json not written"
        return 0
    fi
    printf '%s\n' "${TEL_WARNINGS[@]}" | awk 'NF' > "$B/prep-warnings.txt"
    local args=(--out "$OUT" --mode "$mode" --warnings-file "$B/prep-warnings.txt" --packages-file "$B/packages-to-install.txt")
    [[ -n $DURATION ]] && args+=(--duration "$DURATION")
    tel_log "inventory + test plan ..."
    if ! timeout 900 python3 "$SCRIPT_DIR/inventory.py" "${args[@]}" 2> "$B/inventory-error.txt"; then
        tel_error "inventory.py failed (see 00-baseline/inventory-error.txt); hardware.json is still valid"
    fi
    [[ -s $B/inventory-error.txt ]] || rm -f "$B/inventory-error.txt"
    return 0
}
run_inventory

if ((PLAN_ONLY)); then
    echo
    echo "=================== PLAN ONLY (nothing installed, no load) ==================="
    echo "Host:      $HOSTNAME_S  PVE ${PVE_VER:-?}  kernel $KERNEL  root fs $ROOT_FS"
    if [[ -r $OUT/plan.md ]]; then cat "$OUT/plan.md"; else echo "plan.md not written - see warnings/errors"; fi
    if ((${#TEL_ERRORS[@]})); then echo "Errors:"; for e in "${TEL_ERRORS[@]}"; do echo "  - $e"; done; fi
    echo "Files:     $HW, $OUT/inventory.json, $OUT/inventory.md, $OUT/plan.json, $OUT/plan.md"
    echo "=============================================================================="
    exit 0
fi

# ============================================================================ 5. baseline snapshots
tel_log "baseline snapshots ..."
{ uname -a; echo; grep -m1 microcode /proc/cpuinfo; journalctl -k -b --no-pager -q 2>/dev/null | grep -i microcode | head -n5; echo; lscpu; } > "$B/system-cpu.txt" 2>&1
{
    command -v cpupower >/dev/null 2>&1 && cpupower frequency-info 2>&1
    echo
    for c in /sys/devices/system/cpu/cpu[0-9]*; do
        [[ -d $c/cpufreq ]] || continue
        printf '%s gov=%s epp=%s driver=%s min=%s max=%s\n' "${c##*/}" "$(_tel_read "$c/cpufreq/scaling_governor")" \
            "$(_tel_read "$c/cpufreq/energy_performance_preference")" "$(_tel_read "$c/cpufreq/scaling_driver")" \
            "$(_tel_read "$c/cpufreq/scaling_min_freq")" "$(_tel_read "$c/cpufreq/scaling_max_freq")"
    done
    echo "intel_pstate no_turbo=$(_tel_read /sys/devices/system/cpu/intel_pstate/no_turbo) status=$(_tel_read /sys/devices/system/cpu/intel_pstate/status)"
    echo "amd_pstate status=$(_tel_read /sys/devices/system/cpu/amd_pstate/status) cpufreq/boost=$(_tel_read /sys/devices/system/cpu/cpufreq/boost)"
} > "$B/governor-epp.txt" 2>&1
{
    found=0
    for z in /sys/class/powercap/intel-rapl:*; do
        [[ -d $z ]] || continue; found=1
        echo "== $z name=$(_tel_read "$z/name") enabled=$(_tel_read "$z/enabled")"
        for f in "$z"/constraint_*_name; do
            [[ -r $f ]] || continue; i=${f%_name}
            echo "  $(_tel_read "$f"): limit_uw=$(_tel_read "${i}_power_limit_uw") window_us=$(_tel_read "${i}_time_window_us") max_uw=$(_tel_read "${i}_max_power_uw")"
        done
    done
    ((found)) || echo "no powercap RAPL domains (power limits unknown); telemetry source: $TEL_RAPL_SRC"
} > "$B/rapl-limits.txt" 2>&1
free -m > "$B/free.txt" 2>&1
sensors > "$B/sensors.txt" 2>&1 || echo "sensors unavailable" >> "$B/sensors.txt"
command -v lspci >/dev/null 2>&1 && lspci -nnk > "$B/lspci.txt" 2>&1
if command -v nvidia-smi >/dev/null 2>&1; then nvidia-smi -q > "$B/nvidia-smi-q.txt" 2>&1 || true; fi
if command -v rocm-smi >/dev/null 2>&1; then rocm-smi -a > "$B/rocm-smi.txt" 2>&1 || true; fi
{
    dmesg -T 2>/dev/null | grep -iE 'mce|machine check|edac|hardware error|aer|pcie bus error|nvme.*(error|timeout)|ata[0-9].*(error|exception)|i/o error|thermal|throttl|nvrm: xid'
    echo "--- journal kernel prio<=3 this boot:"
    journalctl -k -b -p 3 --no-pager -q 2>/dev/null | tail -n 80
} > "$B/hw-errors.txt" 2>&1
hw_error_snapshot > "$B/hw-counters.txt"
{ for f in /sys/devices/system/cpu/cpu[0-9]*/thermal_throttle/*_throttle_count; do [[ -r $f ]] && echo "$f $(_tel_read "$f")"; done; } > "$B/throttle-counts.txt" 2>&1
declare -A HC=()
while IFS='=' read -r k v; do HC[$k]=$v; done < "$B/hw-counters.txt"
((${HC[edac_ue]:-0} > 0)) && tel_warn "EDAC reports ${HC[edac_ue]} uncorrectable memory errors since boot"
((${HC[edac_ce]:-0} > 0)) && tel_warn "EDAC reports ${HC[edac_ce]} corrected memory errors since boot"
((${HC[aer_fatal]:-0} + ${HC[aer_nonfatal]:-0} > 0)) && tel_warn "PCIe AER uncorrectable errors logged since boot (fatal ${HC[aer_fatal]}, non-fatal ${HC[aer_nonfatal]})"
((${HC[mce_lines]:-0} > 0)) && tel_warn "kernel log has ${HC[mce_lines]} machine-check / hardware-error lines since boot (see 00-baseline/hw-errors.txt)"

# ============================================================================ 6. idle telemetry
GROUPS_=(cpu mem)
((${TEL_SOCKETS:-1} > 1)) && GROUPS_+=(sockets)
for i in "${!TEL_GPU_KINDS[@]}"; do GROUPS_+=("gpu:$i"); done
for n in "${DISKS[@]}"; do GROUPS_+=("disk:$n"); done
tel_log "idle baseline: ${BASE_S}s of 1 Hz telemetry (${GROUPS_[*]}) - do not start heavy work now"
tel_phase idle
tel_sampler_start "$B/idle-telemetry.csv" "${GROUPS_[@]}"
sleep "$BASE_S.6"
tel_sampler_stop
if command -v turbostat >/dev/null 2>&1 && [[ $CPU_VENDOR != other ]]; then
    turbostat --quiet --show Busy%,Bzy_MHz,PkgTmp,PkgWatt,CorWatt --interval 5 --num_iterations 1 > "$B/turbostat-idle-5s.txt" 2>&1 ||
        tel_log "turbostat not usable on this CPU/kernel (ignored)"
fi

# ============================================================================ 7. summary
CSV="$B/idle-telemetry.csv"
read -r _ _ busy_avg _ < <(csv_stats "$CSV" cpu_busy_pct)
read -r _ _ temp_avg temp_max < <(csv_stats "$CSV" cpu_temp_c)
_tel_isnum "$busy_avg" && awk -v b="$busy_avg" 'BEGIN{exit !(b>15)}' &&
    tel_warn "host is not idle (average CPU busy ${busy_avg}%); running guests/services will lower CPU scores"
_tel_isnum "$temp_avg" && awk -v t="$temp_avg" 'BEGIN{exit !(t>60)}' &&
    tel_warn "CPU idles hot (${temp_avg} C average) - check cooling before long tests"
_tel_isnum "$MEM_AVAIL_MB" && _tel_isnum "$MEM_TOTAL_MB" && ((MEM_AVAIL_MB * 4 < MEM_TOTAL_MB)) &&
    tel_warn "only ${MEM_AVAIL_MB} MB of ${MEM_TOTAL_MB} MB RAM available; the RAM test will be limited to free memory"
[[ $TEL_RAPL_SRC == n/a ]] && tel_skip "cpu-power-telemetry" "no RAPL / amd_energy power counters readable"
[[ $TEL_CPU_TEMP_SRC == n/a ]] && tel_skip "cpu-temp-telemetry" "no CPU temperature sensor found (coretemp/k10temp/thermal zone)"

M="{\"cpu_pkg_w\":$(csv_stats_json "$CSV" cpu_pkg_w),\"cpu_core_w\":$(csv_stats_json "$CSV" cpu_core_w),\"cpu_temp_c\":$(csv_stats_json "$CSV" cpu_temp_c),\"cpu_avg_mhz\":$(csv_stats_json "$CSV" cpu_avg_mhz),\"cpu_busy_pct\":$(csv_stats_json "$CSV" cpu_busy_pct),\"mem_avail_mb\":$(csv_stats_json "$CSV" mem_avail_mb)"
for i in "${!TEL_GPU_KINDS[@]}"; do
    M+=",\"gpu${i}_power_w\":$(csv_stats_json "$CSV" "gpu${i}_power_w"),\"gpu${i}_temp_c\":$(csv_stats_json "$CSV" "gpu${i}_temp_c")"
done
for n in "${DISKS[@]}"; do M+=",\"${n}_temp_c\":$(csv_stats_json "$CSV" "${n}_temp_c")"; done
if ((${TEL_SOCKETS:-1} > 1)); then
    for s in "${TEL_SOCKET_IDS[@]}"; do
        M+=",\"cpu_s${s}_pkg_w\":$(csv_stats_json "$CSV" "cpu_s${s}_pkg_w"),\"cpu_s${s}_temp_c\":$(csv_stats_json "$CSV" "cpu_s${s}_temp_c")"
    done
fi
M+=",\"guests_running\":$((VM_RUN + CT_RUN)),\"sensors\":{\"rapl\":$(json_str "$TEL_RAPL_SRC"),\"cpu_temp\":$(json_str "$TEL_CPU_TEMP_SRC"),\"gpus\":${#TEL_GPU_KINDS[@]}}}"
summary_write "$B/summary.json" baseline "$BASE_S" "$M" "" "\"hw_counters\": {$(awk -F= '{printf "%s\"%s\":%s", (n++?",":""), $1, ($2 ~ /^[0-9]+$/ ? $2 : "null")}' "$B/hw-counters.txt")}"

echo
echo "=================== PREP SUMMARY ==================="
echo "Host:      $HOSTNAME_S  PVE ${PVE_VER:-?}  kernel $KERNEL  root fs $ROOT_FS"
echo "CPU:       $CPU_MODEL ($CPU_VENDOR, ${CPU_CORES:-?} cores / $CPU_THREADS threads${PCORE_LIST:+, P-cores $PCORE_LIST E-cores $ECORE_LIST})"
echo "Sensors:   power=$TEL_RAPL_SRC  temp=$TEL_CPU_TEMP_SRC  PL1=${PL1:-n/a} W PL2=${PL2:-n/a} W"
echo "RAM:       ${MEM_TOTAL_MB} MB total, ${MEM_AVAIL_MB} MB available, $POPULATED/$SLOTS slots, ECC: ${MEM_ECC:-unknown}"
for i in "${!GPU_SLOTS[@]}"; do
    echo "GPU:       ${GPU_SLOTS[$i]} ${GPU_NAME[$i]} [${GPU_DRV[$i]}]$( [[ ${GPU_INTEG[$i]} == 1 ]] && echo ' integrated') testable=${GPU_TESTABLE[$i]} ${GPU_REASON[$i]}"
    [[ -n ${GPU_OCL_RT[$i]} ]] && echo "           OpenCL: ${GPU_OCL_RT[$i]} (${GPU_OCL_STATE[$i]})"
done
for n in "${DISKS[@]}"; do echo "Disk:      $n $(disk_kind "$n") $(lsblk -dno SIZE,MODEL "/dev/$n" 2>/dev/null | xargs)"; done
echo "Guests:    VMs running $VM_RUN/$VM_TOTAL, CTs running $CT_RUN/$CT_TOTAL"
echo "Idle:      CPU busy avg ${busy_avg:-n/a}%  temp avg ${temp_avg:-n/a} C (max ${temp_max:-n/a})  $(read -r _ _ a _ < <(csv_stats "$CSV" cpu_pkg_w); echo "pkg ${a} W")"
echo "Installed: ${#NEWLY[@]} new package(s) recorded in $LEDGER"
if [[ -r $OUT/plan.json ]]; then
    python3 -c 'import json,sys; p=json.load(open(sys.argv[1])); c=p["counts"]; print("Plan:      %d test unit(s), %d skipped, %d optional, est. total %s -> %s" % (c["test_units"], c["skipped_units"], c["optional_units"], p["estimate"]["total_human"], sys.argv[1].rsplit("/",1)[0] + "/plan.md"))' "$OUT/plan.json" 2>/dev/null
fi
echo "Warnings:  ${#TEL_WARNINGS[@]}"; for w in "${TEL_WARNINGS[@]}"; do echo "  - $w"; done
echo "Files:     $HW, $OUT/inventory.json/.md, $OUT/plan.json/.md, $B/"
echo "===================================================="
exit 0
