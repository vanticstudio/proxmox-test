#!/usr/bin/env bash
# =============================================================================
# gpu.sh - GPU stress + benchmark for a Proxmox VE host (part 3 of 5: GPU)
#
# Usage (run as root, on the Proxmox host, after scp to /root/pve-stresstest/):
#   gpu.sh --duration SECONDS --out DIR [--gpu SPEC | --all] [--bench-timeout SEC]
#          [--no-clpeak]
#   gpu.sh --list            print every GPU found (index, PCI, driver, testable)
#
#   --duration      sustained stress-phase length in seconds (30/60/300/600).
#                   REQUIRED. This is only the stress phase; the benchmark
#                   sub-tests below add a bounded, fixed extra on top.
#   --out           output directory (created if missing). REQUIRED.
#   --gpu SPEC      which GPU to test (default: the first display/3D-class
#                   device bound to nvidia/amdgpu/i915/xe). SPEC is one of:
#                     N           index in the --list enumeration (all VGA/3D/
#                                 Display PCI devices in PCI order, from 0)
#                     nvidia:N    NVIDIA GPU with nvidia-smi index N
#                     card:N      DRM device /sys/class/drm/cardN (AMD/Intel;
#                                 also works for NVIDIA); drm:N is an alias
#                     PCI address 0000:XX:00.0 (from lspci -D) or XX:00.0
#   --all           test EVERY GPU one after another, each with its own stress
#                   phase, telemetry and summary in DIR/gpu<N>/ (N = --list
#                   index; summary.json + stress-tel.csv there). GPUs bound to
#                   vfio-pci (VM passthrough), nouveau or a non-compute driver
#                   (e.g. a BMC display) get a gpu<N>/summary.json with status
#                   "skipped" and the reason, so every card appears in the
#                   report. DIR/summary.json is then an aggregate:
#                   {"part":"gpu","mode":"all","gpus":[{...per-GPU summary...}]}.
#   --bench-timeout hard wall-clock cap per benchmark sub-test (default 180 s).
#   --no-clpeak     skip the clpeak benchmark even if it is installed.
#
# WHAT IT MEASURES
#   1. Detection: every VGA/3D-class PCI device and its bound kernel driver.
#      A GPU bound to vfio-pci (passed through to a VM) is NEVER touched -
#      poking it would disrupt the guest. No usable GPU -> summary.json
#      status "skipped" with the reason, still exit 0. A GPU that LXC
#      containers use (/dev/dri or /dev/nvidia* in their config) is still
#      tested, with a warning (their GPU work competes with the test).
#   2. Stress phase (DURATION seconds): a sustained 100% compute load so you
#      can see whether the card holds its clocks, stays within thermal limits
#      and throws no driver errors.
#        All vendors: hashcat on the OpenCL backend (CUDA/HIP backends OFF -
#                see LESSONS) running a fixed mask attack against a deliberately
#                unfindable dummy MD5 digest, with --runtime=DURATION. The hash
#                is never found; the run is purely a steady GPU load generator.
#        AMD (amdgpu) / Intel (i915, xe), discrete and integrated: the GPU's
#                OpenCL device is found first (see OPENCL ON AMD/INTEL below)
#                and hashcat/clpeak only ever see that one runtime and device.
#                If hashcat cannot use the device (runtime too old, kernel build
#                failure), the vendor-neutral fallback load is clpeak's compute
#                + bandwidth kernels in a loop for DURATION (stress_method
#                "clpeak-loop"). No usable OpenCL device at all -> the stress
#                phase is "skipped" with the exact reason (idle telemetry only).
#      Telemetry once per second to DIR/stress-tel.csv for the whole phase:
#        NVIDIA : nvidia-smi (pstate, temp, power.draw, power.limit, SM/mem/
#                 graphics clocks, gpu+mem util, fan, VRAM used, throttle
#                 reasons, PCIe gen/width).
#        AMD/Intel: telemetry.sh gpu_query_ext (sysfs + hwmon): edge/junction/
#                 memory temp, power (+ its source), core clock and its max,
#                 memory clock, busy %, VRAM/GTT used, fan, power limit, PCIe
#                 link, Intel throttle reasons. Integrated GPUs: power is the
#                 RAPL "uncore" domain (Intel) or the APU package (AMD), both
#                 shared with the CPU. Intel busy % needs intel_gpu_top
#                 (intel-gpu-tools, optional). Missing sensor -> "n/a".
#   3. Scores (all vendors): hashcat -b benchmark for modes 0 (MD5),
#                1000 (NTLM), 1400 (SHA2-256), 22000 (WPA) - each bounded by
#                --bench-timeout; plus clpeak (FP32/FP64/INT/bandwidth) on the
#                GPU's own OpenCL platform and device.
#
# OPENCL ON AMD/INTEL (no drivers are ever installed; amdgpu/i915/xe are in-kernel)
#   - Needs a userland OpenCL runtime from the host's apt repos (prep.sh installs
#     it): Mesa rusticl (mesa-opencl-icd; radeonsi for AMD needs Mesa 23.1+,
#     iris for Intel Gen8+, the xe driver needs Mesa 24.1+), Intel
#     compute-runtime (intel-opencl-icd, Debian 12 only), or a ROCm / Clover
#     runtime that is already installed. Preference: AMD ROCm > rusticl >
#     Clover; Intel compute-runtime > rusticl.
#   - RUSTICL_ENABLE=radeonsi,iris is exported (rusticl lists NO device without
#     it; an existing value is kept), plus RUSTICL_FEATURES=fp64 on AMD.
#   - Each ICD in /etc/OpenCL/vendors (except pocl and NVIDIA) is probed on its
#     own with clinfo through a private OCL_ICD_VENDORS directory; the device is
#     matched by PCI address (cl_khr_pci_bus_info / topology), else by vendor ID
#     and position. The chosen ICD's directory stays in OCL_ICD_VENDORS for
#     hashcat and clpeak, so no other GPU (e.g. an NVIDIA card) and no CPU
#     runtime is loaded. Needs the GPU's DRM render node (/dev/dri/renderD*).
#   - hashcat may refuse a Mesa device as "unstable" and ask for --force: it is
#     retried once with --force and a warning is recorded.
#   - GPU driver errors: new kernel lines for this PCI address (amdgpu ring
#     timeouts / GPU resets / page faults, i915 GPU HANG / resets, xe job
#     timeouts / GT resets), counted before and after.
#
# TIME IT TAKES
#   ~ DURATION + (up to 4 x bench-timeout for hashcat) + ~60 s clpeak
#   + a few seconds of detection. With defaults and --duration 30 that is
#   typically 3-6 minutes depending on how fast the benchmarks converge.
#   --all: that per testable GPU (run one after another, never in parallel,
#   so each card's figures are its own); non-testable GPUs take ~1 s.
#
# SAFETY
#   Read-only with respect to the system: never changes power limits, clocks,
#   persistence mode, BIOS or kernel params; never starts/stops guests; never
#   touches a vfio-bound GPU; never loads or unloads kernel modules. hashcat's
#   90 C temperature-abort watchdog stays on. All installs are the caller's job
#   (prep step); this script only USES tools and records which were missing.
#
# LESSONS (known pitfalls on recent PVE / Debian):
#   - The CUDA backend needs NVRTC, which is usually absent on a bare Proxmox
#     host, so hashcat's CUDA backend errors out. We force OpenCL with
#     --backend-ignore-cuda and -D 2 (OpenCL device-type = GPU); on AMD/Intel
#     also --backend-ignore-hip when hashcat knows it.
#   - hashcat refuses to start on a wrongly sized hash, so the dummy MD5 target
#     is exactly 32 hex chars.
#   - clpeak must be pointed at the GPU's OpenCL platform: Debian's hashcat
#     package pulls in pocl (a CPU OpenCL runtime) as a hard dependency, and an
#     unrestricted clpeak also benchmarks the CPU (adds tens of seconds). We pick the platform
#     by name (clinfo -l) and parse only that platform's block, taking the best
#     vector width (float..float16), not the last one.
#   - Only "NVRM: Xid" lines are GPU errors; a bare "xid" grep can also match
#     unrelated kernel boot lines (other drivers can print "XID" too). Xid lines are counted before and after.
#   - hashcat speeds are parsed from the text after the FIRST colon of the
#     Speed line (a greedy match grabbed "Vec:8").
#   - hashcat/pocl/NVIDIA/Mesa/compute-runtime kernel caches are redirected into
#     the skill's working dir (XDG_*_HOME, POCL_CACHE_DIR, CUDA_CACHE_PATH) so
#     nothing is left in /root/.cache, /root/.local/share or /root/.nv.
#   - AMD/Intel expose no NVIDIA-style throttle bitmask: stress.stats records
#     the core clock against its max (clock_vs_max_pct) and Intel's throttle
#     reasons; judge throttling from clock sag + temperature.
#
# Per-GPU summary.json also records "index", "nvidia_index", "drm_card",
# "driver", "gpu_type" (discrete/integrated), "render_node", "opencl"
# (platform, device, icd, match, env), "stress_method" (hashcat / clpeak-loop
# / none), "power_note" and "gpu_error_lines_before/after" (AMD/Intel), so
# the report can match each result to the inventory.
#
# summary.json is always written; exit code is 0 on success even when a
# sub-test is unavailable (each such case is recorded as skipped with a reason).
#
# DEVELOPER-ONLY test hook (never set on a real host): PVE_STRESS_SYSFS_ROOT=DIR
# reads /sys, /dev/dri, /etc/OpenCL/vendors and /etc/pve/lxc from DIR/... (also
# passed on to telemetry.sh), so the AMD/Intel code paths can be run against a
# fake host with fake clinfo/hashcat/clpeak on PATH. Reads only; unset = real /.
# See docs/developing.md.
# =============================================================================

set -u

# ---------------------------------------------------------------------------
# Args
# ---------------------------------------------------------------------------
DURATION=""
OUT=""
GPU_ADDR=""
BENCH_TIMEOUT=180
RUN_CLPEAK=1
GPU_SPEC=""
ALL=0
LIST=0

die() { echo "gpu.sh: ERROR: $*" >&2; exit 2; }
# Developer-only fake root for reads (see header); "" = the real /.
SYSROOT="${PVE_STRESS_SYSFS_ROOT:-}"; SYSROOT="${SYSROOT%/}"

# A value-taking flag at the end of the line (no value) is a usage error, not a hang.
need_val() { [ $# -ge 2 ] && [ -n "$2" ] && [ "${2#--}" = "$2" ] || die "$1 needs a value"; }
while [ $# -gt 0 ]; do
  case "$1" in
    --duration)      need_val "$@"; DURATION="$2"; shift 2 ;;
    --out)           need_val "$@"; OUT="$2"; shift 2 ;;
    --gpu)           need_val "$@"; GPU_SPEC="$2"; shift 2 ;;
    --all)           ALL=1; shift ;;
    --list)          LIST=1; shift ;;
    --bench-timeout) need_val "$@"; BENCH_TIMEOUT="$2"; shift 2 ;;
    --no-clpeak)     RUN_CLPEAK=0; shift ;;
    -h|--help)       sed -n '2,/^# =====/p' "$0"; exit 0 ;;
    *)               die "unknown argument: $1" ;;
  esac
done

# ---------------------------------------------------------------------------
# GPU enumeration (sysfs; read-only). Every PCI display-class device (0x03xxxx)
# in PCI order. Fills G_ADDR G_DRV G_VEND G_NAME G_NVIDX G_CARD G_TESTABLE G_WHY.
# ---------------------------------------------------------------------------
G_ADDR=(); G_DRV=(); G_VEND=(); G_NAME=(); G_NVIDX=(); G_CARD=(); G_TESTABLE=(); G_WHY=()
norm_pci() { # 01:00.0 | 00000000:01:00.0 | 0000:01:00.0 -> 0000:01:00.0 (lowercase)
  local a; a=$(printf '%s' "${1:-}" | tr 'A-F' 'a-f' | tr -d ' ')
  case "$a" in
    [0-9a-f][0-9a-f]:[0-9a-f][0-9a-f].[0-7]) a="0000:$a" ;;
    [0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]:*) a="${a#????}" ;;
  esac
  printf '%s' "$a"
}
enumerate_gpus() {
  local d a cls drv ven name i nvmap="" c card
  if command -v nvidia-smi >/dev/null 2>&1; then
    nvmap=$(nvidia-smi --query-gpu=index,pci.bus_id --format=csv,noheader 2>/dev/null | while IFS=, read -r i a; do
      printf '%s %s\n' "$(norm_pci "$a")" "$(printf '%s' "$i" | tr -d ' ')"; done)
  fi
  for d in "${GPU_SH_PCI_ROOT:-$SYSROOT/sys/bus/pci/devices}"/*; do   # overrides only for testing
    [ -r "$d/class" ] || continue
    cls=$(cat "$d/class" 2>/dev/null)
    case "$cls" in 0x03*) ;; *) continue ;; esac
    a=$(basename "$d")
    drv=$(basename "$(readlink -f "$d/driver" 2>/dev/null)" 2>/dev/null); [ -n "$drv" ] && [ "$drv" != driver ] || drv=none
    ven=$(cat "$d/vendor" 2>/dev/null)
    name=""
    command -v lspci >/dev/null 2>&1 && name=$(lspci -s "$a" 2>/dev/null | head -1 | sed -E 's/^[^ ]+ [^:]+: //')
    [ -n "$name" ] || name="PCI $ven:$(cat "$d/device" 2>/dev/null)"
    card=""
    for c in "$d"/drm/card[0-9]*; do [ -e "$c" ] && { card="${c##*/card}"; break; }; done
    i=$(printf '%s\n' "$nvmap" | awk -v a="$a" '$1==a{print $2; exit}')
    G_ADDR+=("$a"); G_DRV+=("$drv"); G_NAME+=("$name"); G_NVIDX+=("$i"); G_CARD+=("$card")
    case "$drv" in
      nvidia)        G_VEND+=(nvidia); G_TESTABLE+=(yes); G_WHY+=("") ;;
      amdgpu)        G_VEND+=(amd);    G_TESTABLE+=(yes); G_WHY+=("") ;;
      i915|xe)       G_VEND+=(intel);  G_TESTABLE+=(yes); G_WHY+=("") ;;
      vfio-pci)      G_VEND+=(vfio);   G_TESTABLE+=(no);  G_WHY+=("bound to vfio-pci (passed through to a VM); never touched") ;;
      nouveau)       G_VEND+=(nvidia); G_TESTABLE+=(no);  G_WHY+=("nouveau driver has no compute support; the proprietary NVIDIA driver is needed") ;;
      none)          G_VEND+=(unknown); G_TESTABLE+=(no); G_WHY+=("no kernel driver bound") ;;
      *)             G_VEND+=(other);  G_TESTABLE+=(no);  G_WHY+=("driver $drv has no GPU compute support (e.g. BMC / basic display adapter)") ;;
    esac
  done
}
enumerate_gpus

if [ "$LIST" -eq 1 ]; then
  printf '%-4s %-13s %-8s %-9s %-9s %-6s %-5s %s\n' IDX PCI VENDOR DRIVER TESTABLE NV_IDX CARD NAME
  for i in "${!G_ADDR[@]}"; do
    printf '%-4s %-13s %-8s %-9s %-9s %-6s %-5s %s\n' "$i" "${G_ADDR[$i]}" "${G_VEND[$i]}" "${G_DRV[$i]}" "${G_TESTABLE[$i]}" \
      "${G_NVIDX[$i]:--}" "${G_CARD[$i]:--}" "${G_NAME[$i]}${G_WHY[$i]:+  [${G_WHY[$i]}]}"
  done
  [ "${#G_ADDR[@]}" -gt 0 ] || echo "(no display-class PCI devices found)"
  exit 0
fi

# Resolve --gpu SPEC to a PCI address (GPU_ADDR) and remember the list index.
G_INDEX=""
if [ -n "$GPU_SPEC" ]; then
  [ "$ALL" -eq 1 ] && die "--gpu and --all are mutually exclusive"
  case "$GPU_SPEC" in
    nvidia:*) n="${GPU_SPEC#nvidia:}"
      for i in "${!G_ADDR[@]}"; do [ "${G_NVIDX[$i]}" = "$n" ] && G_INDEX=$i; done
      [ -n "$G_INDEX" ] || die "no NVIDIA GPU with nvidia-smi index $n (see gpu.sh --list)" ;;
    card:*|drm:*) n="${GPU_SPEC#*:}"
      for i in "${!G_ADDR[@]}"; do [ "${G_CARD[$i]}" = "$n" ] && G_INDEX=$i; done
      [ -n "$G_INDEX" ] || die "no GPU behind /sys/class/drm/card$n (see gpu.sh --list)" ;;
    *:*) a="$(norm_pci "$GPU_SPEC")"
      for i in "${!G_ADDR[@]}"; do [ "${G_ADDR[$i]}" = "$a" ] && G_INDEX=$i; done
      [ -n "$G_INDEX" ] || die "no display-class GPU at PCI address $a (see gpu.sh --list)"
      GPU_ADDR="$a" ;;
    *[!0-9]*|'') die "--gpu must be N, nvidia:N, card:N or a PCI address (see gpu.sh --list)" ;;
    *) [ "$GPU_SPEC" -lt "${#G_ADDR[@]}" ] || die "--gpu $GPU_SPEC: only ${#G_ADDR[@]} GPU(s) found (see gpu.sh --list)"
      G_INDEX=$GPU_SPEC ;;
  esac
  [ -n "$G_INDEX" ] && GPU_ADDR="${G_ADDR[$G_INDEX]}"
fi

[ -n "$DURATION" ] || die "--duration is required"
[ -n "$OUT" ]      || die "--out is required"
case "$DURATION" in
  ''|*[!0-9]*) die "--duration must be an integer number of seconds" ;;
esac
[ "$DURATION" -ge 1 ] || die "--duration must be >= 1"
case "$BENCH_TIMEOUT" in
  ''|*[!0-9]*) die "--bench-timeout must be an integer number of seconds" ;;
esac

mkdir -p "$OUT" || die "cannot create output dir: $OUT"
OUT="$(cd "$OUT" && pwd)"

LOG="$OUT/gpu.log"
SUMMARY="$OUT/summary.json"
: > "$LOG"

log() { echo "[$(date '+%F %T')] $*" | tee -a "$LOG"; }

# Try to source a shared telemetry helper if the skill ships one (optional).
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
if [ -f "$SCRIPT_DIR/telemetry.sh" ]; then
  # shellcheck disable=SC1091
  . "$SCRIPT_DIR/telemetry.sh" 2>/dev/null || true
fi
# AMD/Intel sensors come from telemetry.sh; without it they read n/a instead of failing.
if ! command -v gpu_query_ext >/dev/null 2>&1; then
  TEL_GPU_EXT_FIELDS="temp_c,power_w,sclk_mhz,busy_pct,vram_used_mib,fan_rpm,pcie_link"
  tel_init() { :; }; tel_cleanup() { :; }; gpu_index_for_pci() { :; }; gpu_is_integrated_pci() { echo 0; }
  gpu_query_ext() { echo "n/a,n/a,n/a,n/a,n/a,n/a,n/a"; }; gpu_util_helper_start() { :; }; gpu_util_helper_stop() { :; }
fi

have() { command -v "$1" >/dev/null 2>&1; }

# JSON string escaper (quotes + backslashes; strips newlines).
jesc() { printf '%s' "${1:-}" | tr '\n' ' ' | sed 's/\\/\\\\/g; s/"/\\"/g'; }

# Collectors for the summary. Each entry is a finished JSON object string.
WARNINGS=()
ERRORS=()
SCORES=()        # "name": { ... }
add_warn()  { WARNINGS+=("$(jesc "$1")"); log "WARN: $1"; }
add_err()   { ERRORS+=("$(jesc "$1")"); log "ERROR: $1"; }
add_score() { SCORES+=("$1"); }

# ---------------------------------------------------------------------------
# --all: one child run per GPU (own stress phase, telemetry, summary), then an
# aggregate DIR/summary.json that embeds every per-GPU summary.
# ---------------------------------------------------------------------------
if [ "$ALL" -eq 1 ]; then
  log "=== GPU part (--all): ${#G_ADDR[@]} display-class device(s) ==="
  rank() { case "$1" in fail) echo 4 ;; warn) echo 3 ;; ok) echo 2 ;; skipped) echo 1 ;; *) echo 0 ;; esac; }
  CHILD_ARGS=(--duration "$DURATION" --bench-timeout "$BENCH_TIMEOUT")
  [ "$RUN_CLPEAK" -eq 0 ] && CHILD_ARGS+=(--no-clpeak)
  AGG_STATUS="skipped"; TESTED=0; TESTABLE=0; GPU_OBJS=()
  for i in "${!G_ADDR[@]}"; do
    sub="$OUT/gpu$i"; mkdir -p "$sub"
    [ "${G_TESTABLE[$i]}" = yes ] && TESTABLE=$((TESTABLE + 1))
    log "--- GPU $i: ${G_ADDR[$i]} ${G_NAME[$i]} (driver ${G_DRV[$i]}, testable ${G_TESTABLE[$i]}) ---"
    bash "$0" "${CHILD_ARGS[@]}" --gpu "$i" --out "$sub" > "$sub/console.log" 2>&1
    rc=$?
    st=""
    [ -s "$sub/summary.json" ] && st=$(sed -n 's/^  "status": "\([a-z_]*\)",$/\1/p' "$sub/summary.json" | head -1)
    if [ -z "$st" ]; then
      st="fail"; add_err "GPU $i (${G_ADDR[$i]}): gpu.sh child run wrote no summary (rc=$rc); see gpu$i/console.log"
      child='null'
    else
      child=$(cat "$sub/summary.json")
    fi
    [ "$st" != skipped ] && TESTED=$((TESTED + 1))
    [ "$(rank "$st")" -gt "$(rank "$AGG_STATUS")" ] && AGG_STATUS="$st"
    log "GPU $i result: status=$st"
    GPU_OBJS+=("{ \"index\": $i, \"pci\": \"$(jesc "${G_ADDR[$i]}")\", \"name\": \"$(jesc "${G_NAME[$i]}")\", \"vendor\": \"$(jesc "${G_VEND[$i]}")\", \"driver\": \"$(jesc "${G_DRV[$i]}")\", \"testable\": \"${G_TESTABLE[$i]}\", \"not_testable_reason\": \"$(jesc "${G_WHY[$i]}")\", \"nvidia_index\": ${G_NVIDX[$i]:-null}, \"drm_card\": ${G_CARD[$i]:-null}, \"dir\": \"gpu$i\", \"status\": \"$(jesc "$st")\", \"summary\": $child }")
  done
  AGG_REASON=""
  [ "${#G_ADDR[@]}" -eq 0 ] && AGG_REASON="no GPU present (no display-class PCI device)"
  [ "${#G_ADDR[@]}" -gt 0 ] && [ "$TESTED" -eq 0 ] && AGG_REASON="no GPU could be tested (passthrough / non-compute driver / missing tools); see gpus[].summary.skip_reason"
  {
    printf '{\n  "part": "gpu",\n  "mode": "all",\n  "status": "%s",\n  "skip_reason": "%s",\n' "$AGG_STATUS" "$(jesc "$AGG_REASON")"
    printf '  "duration_s": %s,\n  "gpu_count": %s,\n  "testable_count": %s,\n  "tested_count": %s,\n  "gpus": [' "$DURATION" "${#G_ADDR[@]}" "$TESTABLE" "$TESTED"
    first=1
    for o in "${GPU_OBJS[@]+"${GPU_OBJS[@]}"}"; do
      if [ $first -eq 1 ]; then printf '\n    %s' "$o"; first=0; else printf ',\n    %s' "$o"; fi
    done
    printf '\n  ],\n  "warnings": ['
    first=1; for w in "${WARNINGS[@]+"${WARNINGS[@]}"}"; do [ $first -eq 1 ] || printf ', '; first=0; printf '"%s"' "$w"; done
    printf '],\n  "errors": ['
    first=1; for e in "${ERRORS[@]+"${ERRORS[@]}"}"; do [ $first -eq 1 ] || printf ', '; first=0; printf '"%s"' "$e"; done
    printf ']\n}\n'
  } > "$SUMMARY"
  log "wrote $SUMMARY (aggregate of ${#G_ADDR[@]} GPU(s), tested $TESTED, status=$AGG_STATUS)"
  exit 0
fi

# State filled in as we go.
STATUS="ok"             # ok | skipped
SKIP_REASON=""
VENDOR="unknown"        # nvidia | amd | intel | none
GPU_NAME=""
STRESS_STATUS="not_run" # ok | skipped | error
STRESS_REASON=""
STRESS_STATS=""
XID_BEFORE=""; XID_AFTER=""
NV_INDEX=""
CLPEAK_STATUS="not_run"
HASHCAT_STATUS="not_run"
STRESS_METHOD="none"    # hashcat | clpeak-loop | none
GPU_TYPE=""             # discrete | integrated
RENDER_NODE=""
POWER_NOTE=""
GERR_BEFORE=""; GERR_AFTER=""
OCL_JSON="null"         # AMD/Intel: chosen OpenCL platform/device

finish() {
  # Build summary.json from whatever we have, then exit 0 (unless a hard arg
  # error already exited 2 earlier).
  if [ "$STATUS" = ok ]; then
    if [ "${#ERRORS[@]}" -gt 0 ]; then STATUS="fail"
    elif [ "$STRESS_STATUS" = skipped ] && [ "$HASHCAT_STATUS" != ok ] && [ "$CLPEAK_STATUS" != ok ]; then STATUS="skipped"; SKIP_REASON="${SKIP_REASON:-$STRESS_REASON}"
    elif [ "${#WARNINGS[@]}" -gt 0 ]; then STATUS="warn"; fi
  fi
  {
    printf '{\n'
    printf '  "part": "gpu",\n'
    printf '  "status": "%s",\n' "$(jesc "$STATUS")"
    printf '  "skip_reason": "%s",\n' "$(jesc "$SKIP_REASON")"
    printf '  "duration_s": %s,\n' "$DURATION"
    printf '  "vendor": "%s",\n' "$(jesc "$VENDOR")"
    printf '  "gpu_name": "%s",\n' "$(jesc "$GPU_NAME")"
    printf '  "gpu_pci": "%s",\n' "$(jesc "$GPU_ADDR")"
    printf '  "index": %s, "nvidia_index": %s, "drm_card": %s, "driver": "%s",\n' \
      "${G_INDEX:-null}" "$( [ -n "${G_INDEX:-}" ] && echo "${G_NVIDX[$G_INDEX]:-null}" || echo null)" \
      "$( [ -n "${G_INDEX:-}" ] && echo "${G_CARD[$G_INDEX]:-null}" || echo null)" "$(jesc "${CHOSEN_DRV:-${G_DRV[${G_INDEX:-0}]:-}}")"
    printf '  "gpu_type": "%s", "render_node": "%s", "power_note": "%s",\n' \
      "$(jesc "$GPU_TYPE")" "$(jesc "$RENDER_NODE")" "$(jesc "$POWER_NOTE")"
    printf '  "opencl": %s,\n' "${OCL_JSON:-null}"
    printf '  "stress": { "status": "%s", "reason": "%s", "method": "%s", "telemetry_csv": "stress-tel.csv", "stats": %s },\n' \
      "$(jesc "$STRESS_STATUS")" "$(jesc "$STRESS_REASON")" "$(jesc "$STRESS_METHOD")" "${STRESS_STATS:-null}"
    printf '  "stress_method": "%s",\n' "$(jesc "$STRESS_METHOD")"
    printf '  "xid_lines_before": %s, "xid_lines_after": %s,\n' "${XID_BEFORE:-null}" "${XID_AFTER:-null}"
    printf '  "gpu_error_lines_before": %s, "gpu_error_lines_after": %s,\n' "${GERR_BEFORE:-null}" "${GERR_AFTER:-null}"
    printf '  "hashcat_benchmark_status": "%s",\n' "$(jesc "$HASHCAT_STATUS")"
    printf '  "clpeak_status": "%s",\n' "$(jesc "$CLPEAK_STATUS")"

    printf '  "scores": {'
    local i first=1
    for i in "${SCORES[@]:-}"; do
      [ -n "$i" ] || continue
      if [ $first -eq 1 ]; then printf '\n    %s' "$i"; first=0
      else printf ',\n    %s' "$i"; fi
    done
    [ $first -eq 1 ] && printf ' ' ; printf '\n  },\n'

    printf '  "warnings": ['
    first=1
    for i in "${WARNINGS[@]:-}"; do
      [ -n "$i" ] || continue
      if [ $first -eq 1 ]; then printf '"%s"' "$i"; first=0
      else printf ', "%s"' "$i"; fi
    done
    printf '],\n'

    printf '  "errors": ['
    first=1
    for i in "${ERRORS[@]:-}"; do
      [ -n "$i" ] || continue
      if [ $first -eq 1 ]; then printf '"%s"' "$i"; first=0
      else printf ', "%s"' "$i"; fi
    done
    printf ']\n'
    printf '}\n'
  } > "$SUMMARY"
  log "wrote $SUMMARY (status=$STATUS)"
  exit 0
}

# A GPU picked by --gpu that is not testable: skip with the precise reason.
if [ -n "${G_INDEX:-}" ] && [ "${G_TESTABLE[$G_INDEX]}" = no ]; then
  STATUS="skipped"; SKIP_REASON="GPU ${G_ADDR[$G_INDEX]}: ${G_WHY[$G_INDEX]}"
  VENDOR="none"; GPU_NAME="${G_NAME[$G_INDEX]}"; CHOSEN_DRV="${G_DRV[$G_INDEX]}"
  log "skipping: $SKIP_REASON"
  finish
fi

# ---------------------------------------------------------------------------
# 1. Detect GPUs and their drivers
# ---------------------------------------------------------------------------
log "=== GPU part: detection ==="
DETECT="$OUT/detect.txt"
: > "$DETECT"

if ! have lspci; then
  add_warn "lspci not found; GPU detection is limited"
fi

# Build a list of "PCIADDR|driver|description" for VGA/3D/Display class devices.
declare -a GPU_LINES=()
if have lspci; then
  # -D = full domain:bus:slot.func ; classes 0300 VGA, 0302 3D, 0380 Display
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    addr="${line%% *}"
    desc="${line#* }"
    desc="${desc#*: }"    # drop "VGA compatible controller: "
    drv="$(lspci -k -s "$addr" 2>/dev/null | awk -F': ' '/Kernel driver in use/{print $2; exit}')"
    [ -n "$drv" ] || drv="none"
    GPU_LINES+=("$addr|$drv|$desc")
    printf '%s\n' "PCI $addr  driver=$drv  $desc" >> "$DETECT"
  done < <(lspci -D 2>/dev/null | grep -iE 'VGA compatible controller|3D controller|Display controller')
fi

if [ "${#GPU_LINES[@]}" -eq 0 ]; then
  log "no VGA/3D/Display PCI devices found"
fi
cat "$DETECT" 2>/dev/null | tee -a "$LOG" >/dev/null

# Pick a target. If --gpu given, honour it; else first non-vfio GPU.
pick_vendor_from_driver() {
  case "$1" in
    nvidia|nvidia_drm)         echo nvidia ;;
    nouveau)                   echo nouveau ;;
    amdgpu)                    echo amd ;;
    radeon)                    echo radeon ;;
    i915|xe)                   echo intel ;;
    vfio-pci)                  echo vfio ;;
    *)                         echo other ;;
  esac
}

CHOSEN=""
CHOSEN_DRV=""
if [ -n "$GPU_ADDR" ]; then
  for entry in ${GPU_LINES[@]+"${GPU_LINES[@]}"}; do
    a="${entry%%|*}"
    if [ "$a" = "$GPU_ADDR" ]; then
      rest="${entry#*|}"; CHOSEN_DRV="${rest%%|*}"; CHOSEN="$a"
      GPU_NAME="${entry##*|}"
      break
    fi
  done
  if [ -z "$CHOSEN" ] && [ -n "${G_INDEX:-}" ]; then   # lspci missing: use the sysfs enumeration
    CHOSEN="$GPU_ADDR"; CHOSEN_DRV="${G_DRV[$G_INDEX]}"; GPU_NAME="${G_NAME[$G_INDEX]}"
  fi
  [ -n "$CHOSEN" ] || add_warn "requested --gpu $GPU_ADDR not seen in lspci; proceeding by vendor tool detection"
else
  for entry in ${GPU_LINES[@]+"${GPU_LINES[@]}"}; do
    a="${entry%%|*}"; rest="${entry#*|}"; d="${rest%%|*}"
    v="$(pick_vendor_from_driver "$d")"
    if [ "$v" = "vfio" ]; then
      add_warn "GPU $a is bound to vfio-pci (passed through to a VM); skipping it"
      continue
    fi
    if [ "$v" = "nouveau" ]; then
      add_warn "GPU $a uses the nouveau driver (no compute support); skipping it"
      continue
    fi
    if [ "$v" = "nvidia" ] || [ "$v" = "amd" ] || [ "$v" = "intel" ]; then
      CHOSEN="$a"; CHOSEN_DRV="$d"; GPU_NAME="${entry##*|}"; break
    fi
  done
fi

if [ -n "$CHOSEN_DRV" ]; then
  GPU_ADDR="$CHOSEN"
  case "$(pick_vendor_from_driver "$CHOSEN_DRV")" in
    nvidia) VENDOR="nvidia" ;;
    amd)    VENDOR="amd" ;;
    intel)  VENDOR="intel" ;;
    vfio)   STATUS="skipped"; SKIP_REASON="selected GPU is bound to vfio-pci (VM passthrough); not touching it"; VENDOR="none"; finish ;;
    nouveau) STATUS="skipped"; SKIP_REASON="GPU uses the open-source nouveau driver (no compute support); the proprietary NVIDIA driver is needed"; VENDOR="none"; finish ;;
    radeon) STATUS="skipped"; SKIP_REASON="GPU uses the legacy radeon driver (pre-GCN card): no OpenCL runtime for it; not usable for compute"; VENDOR="none"; finish ;;
    *)      VENDOR="unknown" ;;
  esac
fi

# Fall back to vendor tools if lspci was unavailable or inconclusive.
if [ "$VENDOR" = "unknown" ] && [ -z "$CHOSEN" ]; then
  if have nvidia-smi && nvidia-smi -L >/dev/null 2>&1; then VENDOR="nvidia";
  elif have rocm-smi; then VENDOR="amd";
  elif [ -d "$SYSROOT/sys/class/drm/card0/device" ] && grep -qi amd "$SYSROOT/sys/class/drm/card0/device/uevent" 2>/dev/null; then VENDOR="amd";
  fi
fi

if [ -z "${G_INDEX:-}" ] && [ -n "$GPU_ADDR" ]; then
  for i in "${!G_ADDR[@]}"; do [ "${G_ADDR[$i]}" = "$GPU_ADDR" ] && G_INDEX=$i; done
fi
log "detected vendor: $VENDOR (driver=${CHOSEN_DRV:-?}, pci=${GPU_ADDR:-?}, index=${G_INDEX:-?}, name=${GPU_NAME:-?})"

if [ "$VENDOR" = "unknown" ] || [ "$VENDOR" = "none" ]; then
  STATUS="skipped"
  SKIP_REASON="no usable GPU found (no nvidia/amdgpu/i915/xe device, or only vfio-passthrough GPUs present)"
  finish
fi

# ---------------------------------------------------------------------------
# Telemetry helpers
# ---------------------------------------------------------------------------
TEL_PID=""

NVQ="timestamp,pstate,temperature.gpu,power.draw,power.limit,clocks.sm,clocks.mem,clocks.gr,utilization.gpu,utilization.memory,fan.speed,memory.used,clocks_throttle_reasons.active,pcie.link.gen.current,pcie.link.width.current"

start_telemetry() {
  local csv="$1"
  if [ "$VENDOR" = "nvidia" ] && have nvidia-smi; then
    # -lms 1000 = one sample per second. Header is emitted by nvidia-smi.
    nvidia-smi ${NVSEL[@]+"${NVSEL[@]}"} --query-gpu="$NVQ" --format=csv,nounits -lms 1000 > "$csv" 2>>"$LOG" &
    TEL_PID=$!
  else
    # AMD (amdgpu) / Intel (i915, xe): telemetry.sh's sysfs/hwmon reader for the
    # selected PCI device (not simply the first DRM card). The first 7 columns
    # after the timestamp keep the names of earlier versions.
    local ti
    ti="$(gpu_index_for_pci "$GPU_ADDR" 2>/dev/null)"
    [ -n "$ti" ] || add_warn "telemetry.sh does not list $GPU_ADDR; sensor columns will read n/a"
    {
      echo "timestamp,${TEL_GPU_EXT_FIELDS:-temp_c,power_w,sclk_mhz,busy_pct,vram_used_mib,fan_rpm,pcie_link}"
      # shellcheck disable=SC2034  # read by the sourced telemetry.sh energy helpers (own RAPL state)
      TEL_TAG=gpusampler
      while :; do
        echo "$(date '+%F %T'),$(gpu_query_ext "${ti:-none}" 2>/dev/null)"
        sleep 1
      done
    } > "$csv" 2>>"$LOG" &
    TEL_PID=$!
  fi
}

stop_telemetry() {
  [ -n "$TEL_PID" ] || return 0
  kill "$TEL_PID" 2>/dev/null
  wait "$TEL_PID" 2>/dev/null
  TEL_PID=""
}

# Make sure background telemetry (and the optional busy-% helper) never outlives the script.
cleanup() {
  stop_telemetry
  if [ "$VENDOR" != nvidia ]; then
    command -v gpu_util_helper_stop >/dev/null 2>&1 && gpu_util_helper_stop
    command -v tel_cleanup >/dev/null 2>&1 && tel_cleanup
  fi
}
trap cleanup EXIT
trap 'log "interrupted"; exit 130' INT TERM HUP

# Keep every cache/session file the GPU tools write inside the skill's working
# dir (removed by cleanup.sh), not in /root/.cache, /root/.local/share or /root/.nv.
GPU_CACHE="${STRESS_HOME:-/root/pve-stresstest}/.gpu-cache"
mkdir -p "$GPU_CACHE" 2>/dev/null && {
  export XDG_CACHE_HOME="$GPU_CACHE/cache" XDG_DATA_HOME="$GPU_CACHE/data" XDG_CONFIG_HOME="$GPU_CACHE/config"
  export POCL_CACHE_DIR="$GPU_CACHE/pocl" CUDA_CACHE_PATH="$GPU_CACHE/nv"
}
# Run hashcat from a scratch dir too (older builds write hashcat.log/.dictstat2 to cwd).
cd "$GPU_CACHE" 2>/dev/null || cd "$OUT" || true

# NVIDIA: query only the selected card; field name changed in newer drivers.
NVSEL=()
if [ "$VENDOR" = "nvidia" ] && have nvidia-smi; then
  if [ -n "${G_INDEX:-}" ] && [ -n "${G_NVIDX[$G_INDEX]:-}" ]; then
    NVSEL=(-i "${G_NVIDX[$G_INDEX]}")
  elif [ -n "$GPU_ADDR" ] && nvidia-smi -i "$GPU_ADDR" --query-gpu=name --format=csv,noheader >/dev/null 2>&1; then
    NVSEL=(-i "$GPU_ADDR")
  elif [ "$(nvidia-smi -L 2>/dev/null | grep -c '^GPU')" -gt 1 ]; then
    add_warn "could not select GPU $GPU_ADDR in nvidia-smi; telemetry covers all NVIDIA GPUs"
  fi
  if ! nvidia-smi ${NVSEL[@]+"${NVSEL[@]}"} --query-gpu=clocks_throttle_reasons.active --format=csv,noheader >/dev/null 2>&1; then
    NVQ="${NVQ/clocks_throttle_reasons.active/clocks_event_reasons.active}"
  fi
  NV_INDEX="$(nvidia-smi ${NVSEL[@]+"${NVSEL[@]}"} --query-gpu=index --format=csv,noheader 2>/dev/null | head -1 | tr -d ' ')"
fi

# Map the selected PCI device to hashcat's backend device number (multi-GPU hosts).
HC_DEV=()
pick_hashcat_device() {
  have hashcat || return 0
  local bdf="${GPU_ADDR#0000:}" info n ngpu
  info="$(timeout 60 hashcat -I --backend-ignore-cuda -D 2 2>/dev/null)"
  ngpu="$(printf '%s\n' "$info" | grep -cE 'Type\.+: *GPU')"
  n="$(printf '%s\n' "$info" | awk -v b="$bdf" '
        /Backend Device ID #[0-9]+/ { id=$NF; sub(/^#/,"",id); next }
        /PCI\.Addr\.BDF/ { v=$NF; sub(/^0000:/,"",v); if (tolower(v)==tolower(b)) { print id; exit } }')"
  if [ -n "$n" ]; then HC_DEV=(-d "$n"); log "hashcat device for $GPU_ADDR: #$n"
  elif [ "${ngpu:-0}" -gt 1 ]; then add_warn "could not map $GPU_ADDR to a hashcat device; hashcat loads all $ngpu OpenCL GPUs at once"
  fi
}
HC_EXTRA=()     # extra hashcat flags (AMD/Intel only: --backend-ignore-hip, --force); empty on NVIDIA
[ "$VENDOR" = nvidia ] && pick_hashcat_device
GPU_TYPE="discrete"
[ "$VENDOR" != nvidia ] && [ "$(gpu_is_integrated_pci "$GPU_ADDR" "$GPU_NAME" 2>/dev/null)" = 1 ] && GPU_TYPE="integrated"

# Xid (GPU driver error) lines are counted before and after; only NEW ones count.
xid_count() { dmesg 2>/dev/null | grep -c 'NVRM: Xid'; }
XID_BEFORE="$(xid_count)"

# ---------------------------------------------------------------------------
# AMD / Intel: render node, containers, OpenCL runtime + device, hashcat device
# ---------------------------------------------------------------------------
OCL_DIR=""; OCL_ICD=""; OCL_PLATFORM=""; OCL_PIDX=""; OCL_DEV_IDX=""; OCL_DEV_NAME=""; OCL_MATCH=""
OCL_SKIP_REASON=""; OCL_TRIED=""; HC_USABLE=0; TEL_IDX=""
# Kernel lines that mean a GPU driver error for THIS device (amdgpu / i915 / xe).
GERR_RE='ring [^ ]+ timeout|GPU reset|gpu reset|GPU HANG|GPU hang|[Rr]esetting (chip|GPU|engine)|page fault|VM_L2_PROTECTION_FAULT|Timedout job|GT[0-9]*: reset|reset failed|wedged'
gerr_count() { dmesg 2>/dev/null | grep -F "$GPU_ADDR" | grep -cE "$GERR_RE"; }

# Containers that get this GPU's /dev/dri nodes (all of /dev/dri, or this card / render node).
ct_sharing() {
  local conf id txt card="card${G_CARD[${G_INDEX:-0}]:-x}" rn="${RENDER_NODE:-none}" st out=""
  for conf in "$SYSROOT"/etc/pve/lxc/*.conf; do
    [ -r "$conf" ] || continue
    id="$(basename "$conf" .conf)"
    txt="$(awk '/^\[/{exit} {print}' "$conf" 2>/dev/null)"
    printf '%s\n' "$txt" | grep -q '/dev/dri' || continue
    if printf '%s\n' "$txt" | grep -qE "/dev/dri/(card|renderD)[0-9]+"; then
      printf '%s\n' "$txt" | grep -qE "/dev/dri/($card|$rn)([^0-9]|\$)" || continue
    fi
    st="$(pct status "$id" 2>/dev/null | awk '{print $2}')"
    out="$out${out:+, }container $id${st:+ ($st)}"
  done
  printf '%s' "$out"
}

# One device line per OpenCL device of one clinfo run:
# platform_index|device_index|type|vendor_id|pci|platform_name|device_name
clinfo_devices() {
  awk '
    function flush() { if (have) printf "%d|%d|%s|%s|%s|%s|%s\n", p-1, d, ty, vid, bdf, cur, nm; have=0 }
    /^NULL platform behavior/ { flush(); exit }
    /^  Platform Name / { pn=$0; sub(/^  Platform Name +/,"",pn); next }
    /^Number of devices/ { flush(); p++; d=-1; cur=pn; next }
    p && /^  Device Name / { flush(); d++; nm=$0; sub(/^  Device Name +/,"",nm); ty=""; vid=""; bdf=""; have=1; next }
    p && have && /^  Device Type / { ty=$NF }
    p && have && /^  Device Vendor ID / { vid=$NF }
    p && have && /(PCI bus info|Device Topology)/ { b=$NF; if (b ~ /^[0-9a-fA-F]+:[0-9a-fA-F:.]+$/) bdf=b }
    END { flush() }'
}

ocl_select() {
  local icd base dir out line p d ty vid bdf pname dname rank m want_vid best=999 my_ord=0 i n_same=0 r vo
  local -A vord=()
  [ -n "$RENDER_NODE" ] || { OCL_SKIP_REASON="no DRM render node (/dev/dri/renderD*) for $GPU_ADDR; OpenCL runtimes need it"; return 0; }
  have clinfo || { OCL_SKIP_REASON="clinfo is not installed (prep.sh installs it); it is needed to find this GPU's OpenCL device safely"; return 0; }
  case "$VENDOR" in amd) want_vid=0x1002 ;; *) want_vid=0x8086 ;; esac
  # Position of this GPU among the host's GPUs of the same vendor (for runtimes without PCI info).
  for i in "${!G_ADDR[@]}"; do
    [ "${G_VEND[$i]}" = "$VENDOR" ] && [ "${G_TESTABLE[$i]}" = yes ] || continue
    [ "${G_ADDR[$i]}" = "$GPU_ADDR" ] && my_ord=$n_same
    n_same=$((n_same + 1))
  done
  : > "$OUT/opencl-probe.txt"
  for icd in "$SYSROOT"/etc/OpenCL/vendors/*.icd; do
    [ -e "$icd" ] || continue
    base="$(basename "$icd" .icd)"
    case "$base" in *pocl*|*nvidia*|*NVIDIA*) continue ;; esac
    dir="$GPU_CACHE/icd/$base"; mkdir -p "$dir" && cp -f "$icd" "$dir/" 2>/dev/null || continue
    out="$(OCL_ICD_VENDORS="$dir" timeout 60 clinfo 2>&1)"
    printf '### %s (OCL_ICD_VENDORS=%s RUSTICL_ENABLE=%s)\n%s\n\n' "$icd" "$dir" "${RUSTICL_ENABLE:-}" "$out" >> "$OUT/opencl-probe.txt"
    OCL_TRIED="$OCL_TRIED${OCL_TRIED:+, }$base"
    while IFS='|' read -r p d ty vid bdf pname dname; do
      [ -n "$p" ] || continue
      [ "$ty" = GPU ] || continue
      case "$pname" in *"Portable Computing Language"*|*pocl*|*"CPU Runtime"*) continue ;; esac
      case "$VENDOR:$pname" in
        amd:*"AMD Accelerated Parallel Processing"*) rank=1 ;;
        intel:*"Intel(R) OpenCL"*) rank=1 ;;
        *:*rusticl*) rank=2 ;;
        amd:*Clover*) rank=3 ;;
        *) rank=4 ;;
      esac
      vid="$(printf '0x%04x' "$vid" 2>/dev/null)"
      if [ -n "$bdf" ]; then
        [ "$(norm_pci "$bdf")" = "$GPU_ADDR" ] || continue
        m="pci"
      else
        [ "$vid" = "$want_vid" ] || continue
        vo="${vord[$base.$p]:-0}"; vord[$base.$p]=$((vo + 1))
        # several GPUs of this vendor and no PCI info: take the one in the same position
        [ "$n_same" -le 1 ] || [ "$vo" -eq "$my_ord" ] || continue
        m="vendor"; rank=$((rank + 10))
      fi
      if [ "$rank" -lt "$best" ]; then
        best=$rank; OCL_DIR="$dir"; OCL_ICD="$icd"; OCL_PLATFORM="$pname"; OCL_PIDX="$p"; OCL_DEV_IDX="$d"; OCL_DEV_NAME="$dname"; OCL_MATCH="$m"
      fi
    done < <(printf '%s\n' "$out" | clinfo_devices)
  done
  if [ -z "$OCL_DIR" ]; then
    if [ -z "$OCL_TRIED" ]; then
      OCL_SKIP_REASON="no AMD/Intel OpenCL runtime installed (/etc/OpenCL/vendors has none); prep.sh --gpu-tools auto installs one when the host's apt repos have it"
    else
      OCL_SKIP_REASON="no installed OpenCL runtime exposes this GPU (tried: $OCL_TRIED; RUSTICL_ENABLE=${RUSTICL_ENABLE:-unset})"
      case "$VENDOR" in
        amd) OCL_SKIP_REASON="$OCL_SKIP_REASON. AMD via Mesa rusticl needs Mesa 23.1+ (Debian 12: bookworm-backports); legacy Clover only covers older cards" ;;
        intel) OCL_SKIP_REASON="$OCL_SKIP_REASON. Intel Gen7 (Haswell) and older have no rusticl/compute-runtime support; the xe driver needs Mesa 24.1+" ;;
      esac
    fi
    return 0
  fi
  [ "$OCL_MATCH" = vendor ] && [ "$n_same" -gt 1 ] && add_warn "OpenCL runtime gives no PCI address; device #$OCL_DEV_IDX on '$OCL_PLATFORM' was matched to $GPU_ADDR by vendor and position"
  export OCL_ICD_VENDORS="$OCL_DIR"
  log "OpenCL for $GPU_ADDR: platform #$OCL_PIDX '$OCL_PLATFORM' device #$OCL_DEV_IDX '$OCL_DEV_NAME' (ICD $OCL_ICD, matched by $OCL_MATCH)"
}

# hashcat device number of the chosen OpenCL device (only that ICD is visible now).
pick_hashcat_device_ocl() {
  have hashcat || return 0
  local bdf="${GPU_ADDR#0000:}" info n ngpu
  hashcat --help 2>/dev/null | grep -q -- '--backend-ignore-hip' && HC_EXTRA+=(--backend-ignore-hip)
  info="$(timeout 120 hashcat -I --backend-ignore-cuda ${HC_EXTRA[@]+"${HC_EXTRA[@]}"} -D 2 2>&1)"
  printf '%s\n' "$info" > "$OUT/hashcat-devices.txt"
  ngpu="$(printf '%s\n' "$info" | grep -cE 'Type\.+: *GPU')"
  n="$(printf '%s\n' "$info" | awk -v b="$bdf" -v nm="$OCL_DEV_NAME" '
        function out() { if (id != "" && ty == "GPU") { if (pci != "" && tolower(pci) == tolower(b)) { print id; done=1; exit } if (name == nm && byname == "") byname=id } }
        /OpenCL Platform ID #/ { out(); id=""; next }
        /Backend Device ID #[0-9]+/ { out(); id=$0; sub(/.*Backend Device ID #/,"",id); sub(/[^0-9].*/,"",id); ty=""; pci=""; name=""; next }
        id != "" && /^ +Type\.+:/ { ty=$NF }
        id != "" && /^ +Name\.+:/ { name=$0; sub(/^ +Name\.+: */,"",name) }
        id != "" && /PCI\.Addr\.BDF/ { pci=$NF; sub(/^0000:/,"",pci) }
        END { if (!done) { out(); if (!done && byname != "") print byname } }')"
  if [ -n "$n" ]; then HC_DEV=(-d "$n"); HC_USABLE=1; log "hashcat device for $GPU_ADDR: #$n"
  elif [ "${ngpu:-0}" -eq 1 ]; then HC_USABLE=1; log "hashcat sees exactly one GPU on '$OCL_PLATFORM'; using it"
  elif [ "${ngpu:-0}" -gt 1 ]; then add_warn "could not map $GPU_ADDR to one of $ngpu hashcat devices on '$OCL_PLATFORM'; hashcat is not used for this GPU"
  else log "hashcat lists no GPU device on '$OCL_PLATFORM' (see hashcat-devices.txt)"
  fi
}

if [ "$VENDOR" = amd ] || [ "$VENDOR" = intel ]; then
  tel_init 2>/dev/null
  TEL_IDX="$(gpu_index_for_pci "$GPU_ADDR")"
  for r in "$SYSROOT/sys/bus/pci/devices/$GPU_ADDR"/drm/renderD[0-9]*; do [ -e "$r" ] && { RENDER_NODE="${r##*/}"; break; }; done
  [ -n "$RENDER_NODE" ] && [ ! -e "$SYSROOT/dev/dri/$RENDER_NODE" ] && add_warn "/dev/dri/$RENDER_NODE does not exist although sysfs lists it"
  shared="$(ct_sharing)"
  [ -n "$shared" ] && add_warn "this GPU is also used by $shared; their GPU work competes with the test and can lower the scores (they are not stopped)"
  if [ "$GPU_TYPE" = integrated ]; then
    if [ "$VENDOR" = intel ]; then
      if [ -n "${TEL_RAPL_UNCORE:-}" ]; then POWER_NOTE="integrated GPU: power is the CPU package's RAPL 'uncore' domain (GPU + uncore), shared with the CPU"
      else POWER_NOTE="integrated GPU: no separate power sensor; its power is part of the CPU package power"; fi
    else
      POWER_NOTE="APU: the amdgpu power reading is the whole APU package (CPU + GPU), shared with the CPU"
    fi
    POWER_NOTE="$POWER_NOTE; memory is shared system RAM, so bandwidth compares with the RAM, not a VRAM spec"
  fi
  # rusticl lists no device unless enabled; keep a value the user set.
  export RUSTICL_ENABLE="${RUSTICL_ENABLE:-radeonsi,iris}"
  [ "$VENDOR" = amd ] && export RUSTICL_FEATURES="${RUSTICL_FEATURES:-fp64}"
  export NEO_CACHE_DIR="$GPU_CACHE/neo" MESA_SHADER_CACHE_DIR="$GPU_CACHE/mesa"
  ocl_select
  if [ -n "$OCL_DIR" ]; then
    pick_hashcat_device_ocl
    OCL_JSON="{ \"platform\": \"$(jesc "$OCL_PLATFORM")\", \"platform_index\": ${OCL_PIDX:-null}, \"device\": \"$(jesc "$OCL_DEV_NAME")\", \"device_index\": ${OCL_DEV_IDX:-null}, \"icd\": \"$(jesc "$OCL_ICD")\", \"match\": \"$(jesc "$OCL_MATCH")\", \"rusticl_enable\": \"$(jesc "${RUSTICL_ENABLE:-}")\", \"hashcat_device\": \"$(jesc "${HC_DEV[*]:-}")\", \"tried\": \"$(jesc "$OCL_TRIED")\" }"
  else
    OCL_JSON="{ \"platform\": null, \"skip_reason\": \"$(jesc "$OCL_SKIP_REASON")\", \"tried\": \"$(jesc "$OCL_TRIED")\", \"rusticl_enable\": \"$(jesc "${RUSTICL_ENABLE:-}")\" }"
    log "OpenCL: $OCL_SKIP_REASON"
  fi
  GERR_BEFORE="$(gerr_count)"
  {
    echo "===== PRE-TEST ($(date '+%F %T %Z')) ====="
    echo "GPU: $GPU_NAME  pci=$GPU_ADDR  driver=$CHOSEN_DRV (in-kernel, $(uname -r))  type=$GPU_TYPE  render node=${RENDER_NODE:-none}"
    echo "--- sensors ($TEL_GPU_EXT_FIELDS) ---"
    gpu_query_ext "${TEL_IDX:-none}"
    echo "--- OpenCL ---"
    if [ -n "$OCL_DIR" ]; then echo "platform '$OCL_PLATFORM' device '$OCL_DEV_NAME' (ICD $OCL_ICD, matched by $OCL_MATCH), RUSTICL_ENABLE=${RUSTICL_ENABLE:-}"
    else echo "none: $OCL_SKIP_REASON"; fi
    echo "--- GPU driver error lines for $GPU_ADDR this boot: $GERR_BEFORE ---"
    dmesg 2>/dev/null | grep -F "$GPU_ADDR" | grep -E "$GERR_RE" | tail -5
  } > "$OUT/pre-health.txt" 2>>"$LOG"
fi

# ---------------------------------------------------------------------------
# Pre-test health snapshot (NVIDIA; AMD/Intel wrote theirs above)
# ---------------------------------------------------------------------------
if [ "$VENDOR" = "nvidia" ] && have nvidia-smi; then
  {
    echo "===== PRE-TEST ($(date '+%F %T %Z')) ====="
    nvidia-smi ${NVSEL[@]+"${NVSEL[@]}"} --query-gpu="$NVQ" --format=csv,nounits 2>/dev/null
    echo "--- driver / name ---"
    nvidia-smi ${NVSEL[@]+"${NVSEL[@]}"} --query-gpu=name,driver_version,power.max_limit --format=csv,noheader 2>/dev/null
    echo "--- recent nvidia/Xid kernel messages ---"
    dmesg 2>/dev/null | grep 'NVRM: Xid' | tail -5
    echo "(NVRM: Xid lines this boot: $XID_BEFORE)"
  } > "$OUT/pre-health.txt" 2>>"$LOG"
  # Prefer the marketing name from nvidia-smi over the lspci chip name.
  NVNAME="$(nvidia-smi ${NVSEL[@]+"${NVSEL[@]}"} --query-gpu=name --format=csv,noheader 2>/dev/null | head -1)"
  [ -n "$NVNAME" ] && GPU_NAME="$NVNAME"
fi

# ---------------------------------------------------------------------------
# 2. Stress phase
# ---------------------------------------------------------------------------
log "=== GPU stress phase: ${DURATION}s ==="

# An unfindable dummy MD5 digest (exactly 32 hex chars). The mask run will
# never match it; it is only here to give hashcat a valid target so the GPU
# runs flat out for DURATION seconds.
DUMMY_MD5="ffffffffffffffffffffffffffffffff"

if [ "$VENDOR" = nvidia ]; then
  if have hashcat; then
    STRESS_METHOD="hashcat"
    start_telemetry "$OUT/stress-tel.csv"
    log "stress: hashcat OpenCL load generator (--runtime=$DURATION)"
    # -D 2  = OpenCL device type GPU only
    # --backend-ignore-cuda avoids the CUDA/NVRTC path that is missing on hosts
    # -m 0 MD5, -a 3 mask, -w 4 highest workload, potfile disabled
    if timeout --kill-after=30 $((DURATION + 300)) hashcat --backend-ignore-cuda -D 2 ${HC_DEV[@]+"${HC_DEV[@]}"} --potfile-disable \
          -m 0 -a 3 -w 4 --runtime="$DURATION" \
          "$DUMMY_MD5" '?a?a?a?a?a?a?a?a' \
          > "$OUT/stress-hashcat.txt" 2>&1; then
      STRESS_STATUS="ok"
    else
      rc=$?
      # hashcat exits non-zero when the runtime limit aborts the (unfindable) run;
      # that is the expected, successful outcome. Only treat a device/init
      # failure as an error.
      if grep -qiE "No devices found|No OpenCL|clGetPlatformIDs" "$OUT/stress-hashcat.txt" 2>/dev/null \
           && ! grep -qiE "Runtime limit reached|Aborted \(Runtime\)|Exhausted" "$OUT/stress-hashcat.txt" 2>/dev/null; then
        # No usable OpenCL device (e.g. AMD/Intel without an OpenCL runtime): not a hardware fault.
        STRESS_STATUS="skipped"; STRESS_METHOD="none"
        STRESS_REASON="hashcat found no usable OpenCL GPU device (rc=$rc); see stress-hashcat.txt"
        add_warn "$STRESS_REASON"
      elif grep -qiE "cuInit|ERROR" "$OUT/stress-hashcat.txt" 2>/dev/null \
           && ! grep -qiE "Runtime limit reached|Aborted \(Runtime\)|Exhausted" "$OUT/stress-hashcat.txt" 2>/dev/null; then
        STRESS_STATUS="error"
        STRESS_REASON="hashcat could not run on the GPU (rc=$rc); see stress-hashcat.txt"
        add_err "$STRESS_REASON"
      else
        STRESS_STATUS="ok"
      fi
    fi
    stop_telemetry

    # Pull a quick peak summary out of the telemetry for the log.
    if [ "$VENDOR" = "nvidia" ] && [ -s "$OUT/stress-tel.csv" ]; then
      # columns: 3 temp, 4 power, 5 limit, 6 sm clock, 9 util; skip the first 3 s (ramp-up)
      STRESS_STATS="$(awk -F', *' 'NR>4 && $9+0>=50 { n++; t+=$3; p+=$4; c+=$6; u+=$9
          if ($3+0>mt) mt=$3+0; if ($4+0>mp) mp=$4+0; if (n==1||$6+0<mc) mc=$6+0; pl=$5 }
        END { if (n) printf "{ \"samples_loaded\": %d, \"temp_c_avg\": %.1f, \"temp_c_max\": %.0f, \"power_w_avg\": %.1f, \"power_w_max\": %.1f, \"power_limit_w\": %s, \"sm_mhz_avg\": %.0f, \"sm_mhz_min\": %.0f, \"util_pct_avg\": %.1f }", n, t/n, mt, p/n, mp, (pl ~ /^[0-9.]+$/ ? pl : "null"), c/n, mc, u/n }' "$OUT/stress-tel.csv")"
      [ -n "$STRESS_STATS" ] || add_warn "GPU utilisation never reached 50% during the stress phase (see stress-tel.csv)"
      log "stress stats: ${STRESS_STATS:-none}"
    fi
  else
    STRESS_STATUS="skipped"
    STRESS_REASON="hashcat not installed"
    add_warn "hashcat not installed; GPU stress phase skipped"
    # Still record idle telemetry so the report has sensor data.
    start_telemetry "$OUT/stress-tel.csv"
    sleep "$DURATION"
    stop_telemetry
  fi
else
  # ---- AMD / Intel -----------------------------------------------------------
  # hashcat outcome from its output + exit code: ok | force | nodev | temp | error
  hc_outcome() {
    local f="$1" rc="$2"
    if grep -qiE "Temperature limit on GPU" "$f" 2>/dev/null; then echo temp
    elif grep -qiE "Runtime limit reached|Aborted \(Runtime\)|Status\.+: (Exhausted|Running|Aborted \(Runtime\))" "$f" 2>/dev/null; then echo ok
    elif [ "$rc" -eq 0 ] || [ "$rc" -eq 1 ] || [ "$rc" -eq 4 ]; then echo ok
    elif grep -q -- "--force" "$f" 2>/dev/null; then echo force
    elif grep -qiE "No devices found|No devices left|No OpenCL|clGetPlatformIDs|CL_PLATFORM_NOT_FOUND|Skipping" "$f" 2>/dev/null; then echo nodev
    else echo error; fi
  }
  hc_stress() {
    timeout --kill-after=30 $((DURATION + 300)) hashcat --backend-ignore-cuda ${HC_EXTRA[@]+"${HC_EXTRA[@]}"} -D 2 ${HC_DEV[@]+"${HC_DEV[@]}"} --potfile-disable \
      -m 0 -a 3 -w 4 --runtime="$DURATION" "$DUMMY_MD5" '?a?a?a?a?a?a?a?a' > "$OUT/stress-hashcat.txt" 2>&1
  }
  HC_STATE="not_run"
  if [ -n "$OCL_SKIP_REASON" ]; then
    STRESS_STATUS="skipped"; STRESS_REASON="$OCL_SKIP_REASON"
    add_warn "GPU stress phase skipped: $OCL_SKIP_REASON (idle telemetry only)"
    start_telemetry "$OUT/stress-tel.csv"
    sleep "$DURATION"
    stop_telemetry
  else
    # Busy-% helper first: the CSV sampler is a forked subshell and only sees the
    # helper's file if it is already running when the sampler starts.
    gpu_util_helper_start "${TEL_IDX:-none}" "$OUT/gpu-busy-helper.log"
    start_telemetry "$OUT/stress-tel.csv"
    if have hashcat && [ "$HC_USABLE" -eq 1 ]; then
      log "stress: hashcat OpenCL load generator on '$OCL_PLATFORM' (--runtime=$DURATION)"
      hc_stress; rc=$?
      HC_STATE="$(hc_outcome "$OUT/stress-hashcat.txt" "$rc")"
      if [ "$HC_STATE" = force ]; then
        add_warn "hashcat flagged the '$OCL_PLATFORM' OpenCL runtime as unsupported/unstable; retried with --force (scores may be lower than with the vendor's own runtime)"
        HC_EXTRA+=(--force)
        mv -f "$OUT/stress-hashcat.txt" "$OUT/stress-hashcat-noforce.txt" 2>/dev/null
        hc_stress; rc=$?
        HC_STATE="$(hc_outcome "$OUT/stress-hashcat.txt" "$rc")"
        [ "$HC_STATE" = force ] && HC_STATE="error"
      fi
      case "$HC_STATE" in
        ok)   STRESS_STATUS="ok"; STRESS_METHOD="hashcat" ;;
        temp) STRESS_STATUS="ok"; STRESS_METHOD="hashcat"
              add_err "hashcat stopped the stress phase: the GPU reached its 90 C abort temperature (cooling problem); see stress-hashcat.txt" ;;
        *)    add_warn "hashcat could not run on this GPU's OpenCL runtime ($HC_STATE, rc=$rc; see stress-hashcat.txt); not a hardware fault by itself" ;;
      esac
    elif ! have hashcat; then
      add_warn "hashcat not installed; using the clpeak fallback load if possible"
    else
      log "hashcat has no device for $GPU_ADDR on '$OCL_PLATFORM' (see hashcat-devices.txt); using the clpeak fallback load"
    fi
    # Vendor-neutral fallback: clpeak's compute + bandwidth kernels in a loop on the same device.
    if [ "$STRESS_STATUS" != ok ]; then
      if [ "$RUN_CLPEAK" -eq 1 ] && have clpeak; then
        CLP_LOOP_ARGS=(-p "$OCL_PIDX" -d "$OCL_DEV_IDX")
        clpeak --help 2>&1 | grep -q -- '--compute-sp' && CLP_LOOP_ARGS+=(--compute-sp --global-bandwidth)
        log "stress: clpeak loop on '$OCL_PLATFORM' device #$OCL_DEV_IDX for ${DURATION}s (vendor-neutral fallback)"
        : > "$OUT/stress-clpeak.txt"
        deadline=$((SECONDS + DURATION)); loops=0
        while [ "$SECONDS" -lt "$deadline" ]; do
          t0=$SECONDS
          timeout --kill-after=10 $((deadline - SECONDS + 30)) clpeak "${CLP_LOOP_ARGS[@]}" >> "$OUT/stress-clpeak.txt" 2>&1
          rc=$?
          if [ "$rc" -ne 0 ] && [ "$rc" -ne 124 ]; then break; fi
          loops=$((loops + 1))
          [ $((SECONDS - t0)) -lt 1 ] && sleep 1
        done
        if [ "$loops" -gt 0 ]; then
          STRESS_STATUS="ok"; STRESS_METHOD="clpeak-loop"
          add_warn "stress phase used looped clpeak kernels ($loops run(s)) instead of hashcat: a burstier, slightly lighter load"
          [ "$SECONDS" -lt "$deadline" ] && add_warn "clpeak stopped with rc=$rc after $loops run(s), before the stress phase ended (see stress-clpeak.txt)"
        else
          STRESS_STATUS="skipped"; STRESS_REASON="neither hashcat nor clpeak could run on '$OCL_PLATFORM' (see stress-hashcat.txt / stress-clpeak.txt)"
          add_warn "$STRESS_REASON"
        fi
      else
        STRESS_STATUS="skipped"
        STRESS_REASON="hashcat could not use this GPU and clpeak is $( [ "$RUN_CLPEAK" -eq 1 ] && echo 'not installed' || echo 'disabled (--no-clpeak)')"
        add_warn "$STRESS_REASON"
        sleep "$DURATION"     # idle telemetry, so the report still has sensor data
      fi
    fi
    gpu_util_helper_stop
    stop_telemetry
  fi

  # Loaded-phase statistics from the sysfs CSV (header-driven; n/a cells skipped).
  # Rows with busy >= 50% when a busy column exists, else every row after the first 3 s.
  if [ -s "$OUT/stress-tel.csv" ] && [ "$STRESS_STATUS" = ok ]; then
    STRESS_STATS="$(awk -F, -v gtype="$GPU_TYPE" '
      function isn(x) { return x ~ /^-?[0-9]+(\.[0-9]+)?$/ }
      NR==1 { for (i=1; i<=NF; i++) c[$i]=i; next }
      { L[NR]=$0 }
      END {
        ub=0
        for (r=5; r<=NR; r++) { split(L[r], f, ","); if (c["busy_pct"] && isn(f[c["busy_pct"]])) { ub=1; break } }
        for (r=5; r<=NR; r++) {
          split(L[r], f, ",")
          if (ub && !(isn(f[c["busy_pct"]]) && f[c["busy_pct"]]+0 >= 50)) continue
          n++
          v=f[c["temp_c"]];        if (isn(v)) { tn++; t+=v; if (tn==1 || v+0>mt) mt=v+0 }
          v=f[c["power_w"]];       if (isn(v)) { pn++; p+=v; if (pn==1 || v+0>mp) mp=v+0 }
          v=f[c["sclk_mhz"]];      if (isn(v)) { cn++; cs+=v; if (cn==1 || v+0<mc) mc=v+0 }
          v=f[c["max_mhz"]];       if (isn(v) && v+0>mx) mx=v+0
          v=f[c["busy_pct"]];      if (isn(v)) { un++; us+=v }
          v=f[c["junction_c"]];    if (isn(v) && (!hj || v+0>mj)) { mj=v+0; hj=1 }
          v=f[c["mem_temp_c"]];    if (isn(v) && (!hm || v+0>mm)) { mm=v+0; hm=1 }
          v=f[c["vram_used_mib"]]; if (isn(v) && (!hv || v+0>mv)) { mv=v+0; hv=1 }
          v=f[c["power_limit_w"]]; if (isn(v)) pl=v+0
          v=f[c["power_source"]];  if (v != "" && v != "n/a") psrc=v
          v=f[c["throttle"]];      if (v != "" && v != "n/a") { tk=1; if (v != "none") thr++ }
        }
        if (!n) exit
        printf "{ \"samples_loaded\": %d, \"util_filter\": \"%s\", ", n, (ub ? "busy >= 50%" : "none (no busy % sensor): all samples after 3 s")
        printf "\"temp_c_avg\": %s, \"temp_c_max\": %s, ", (tn ? sprintf("%.1f", t/tn) : "null"), (tn ? sprintf("%.0f", mt) : "null")
        printf "\"power_w_avg\": %s, \"power_w_max\": %s, \"power_limit_w\": %s, ", (pn ? sprintf("%.1f", p/pn) : "null"), (pn ? sprintf("%.1f", mp) : "null"), (pl != "" ? pl : "null")
        printf "\"sm_mhz_avg\": %s, \"sm_mhz_min\": %s, \"core_max_mhz\": %s, ", (cn ? sprintf("%.0f", cs/cn) : "null"), (cn ? sprintf("%.0f", mc) : "null"), (mx ? sprintf("%.0f", mx) : "null")
        printf "\"clock_vs_max_pct\": %s, ", ((cn && mx) ? sprintf("%.1f", 100*(cs/cn)/mx) : "null")
        printf "\"util_pct_avg\": %s, ", (un ? sprintf("%.1f", us/un) : "null")
        printf "\"junction_c_max\": %s, \"mem_temp_c_max\": %s, \"vram_used_mib_max\": %s, ", (hj ? mj : "null"), (hm ? mm : "null"), (hv ? mv : "null")
        printf "\"throttle_samples\": %s, \"power_source\": \"%s\", \"gpu_type\": \"%s\" }", (tk ? thr+0 : "null"), (psrc != "" ? psrc : "n/a"), gtype
      }' "$OUT/stress-tel.csv")"
    [ -n "$STRESS_STATS" ] || add_warn "GPU utilisation never reached 50% during the stress phase (see stress-tel.csv)"
    log "stress stats: ${STRESS_STATS:-none}"
  fi
fi

# ---------------------------------------------------------------------------
# 3a. hashcat benchmark scores
# ---------------------------------------------------------------------------
run_bench() {
  # $1 = mode, $2 = label
  local mode="$1" label="$2" out="$OUT/bench-${1}-${2}.txt"
  log "benchmark: hashcat -m $mode ($label)"
  if have timeout; then
    timeout "${BENCH_TIMEOUT}s" hashcat -b --backend-ignore-cuda ${HC_EXTRA[@]+"${HC_EXTRA[@]}"} -D 2 ${HC_DEV[@]+"${HC_DEV[@]}"} -m "$mode" \
      > "$out" 2>&1
  else
    hashcat -b --backend-ignore-cuda ${HC_EXTRA[@]+"${HC_EXTRA[@]}"} -D 2 ${HC_DEV[@]+"${HC_DEV[@]}"} -m "$mode" > "$out" 2>&1
  fi
  # First Speed line, e.g. "Speed.#1.........: 12345.6 MH/s (10.00ms) @ Accel:64 ... Vec:8".
  # Take the text after the FIRST colon (a greedy .*: grabbed the "Vec:8" value).
  local speed val unit hs
  speed="$(grep -m1 -E '^Speed\.#' "$out" 2>/dev/null | sed -E 's/^[^:]*: *//; s/ *\(.*//')"
  val="$(printf '%s' "$speed" | awk '{print $1}')"; unit="$(printf '%s' "$speed" | awk '{print $2}')"
  hs="$(awk -v v="$val" -v u="$unit" 'BEGIN{ m=1; if(u~/^kH/)m=1e3; else if(u~/^MH/)m=1e6; else if(u~/^GH/)m=1e9; else if(u~/^TH/)m=1e12; if (v ~ /^[0-9.]+$/) printf "%.0f", v*m }')"
  if [ -n "$speed" ] && [ -n "$hs" ]; then
    add_score "\"hashcat_${label}\": { \"mode\": $mode, \"speed\": \"$(jesc "$speed")\", \"value\": $val, \"unit\": \"$(jesc "$unit")\", \"hashes_per_s\": $hs }"
    log "  -> $label: $speed"
  else
    add_warn "hashcat benchmark mode $mode ($label) produced no speed line (timeout or device error)"
  fi
}

if [ "$VENDOR" = nvidia ]; then
  if have hashcat; then
    HASHCAT_STATUS="ok"
    run_bench 0     md5
    run_bench 1000  ntlm
    run_bench 1400  sha256
    run_bench 22000 wpa
  else
    HASHCAT_STATUS="skipped"
  fi
elif [ "${HC_STATE:-not_run}" = ok ]; then
  # AMD/Intel: only when hashcat really ran on this device in the stress phase
  # (not after a temperature abort: no more load on a card that hit 90 C).
  nsc=${#SCORES[@]}
  run_bench 0     md5
  run_bench 1000  ntlm
  run_bench 1400  sha256
  run_bench 22000 wpa
  if [ "${#SCORES[@]}" -gt "$nsc" ]; then HASHCAT_STATUS="ok"; else HASHCAT_STATUS="error"; fi
else
  HASHCAT_STATUS="skipped"
  have hashcat && [ -z "$OCL_SKIP_REASON" ] && log "hashcat benchmarks skipped: hashcat could not run on '$OCL_PLATFORM' in the stress phase"
fi

# ---------------------------------------------------------------------------
# 3b. clpeak
# ---------------------------------------------------------------------------
if [ "$RUN_CLPEAK" -eq 1 ] && have clpeak && [ "$VENDOR" != nvidia ] && [ -n "$OCL_SKIP_REASON" ]; then
  CLPEAK_STATUS="skipped"
  log "clpeak skipped: $OCL_SKIP_REASON"
elif [ "$RUN_CLPEAK" -eq 1 ] && [ "${HC_STATE:-}" = temp ]; then
  # same rule as the hashcat benchmarks: no more load on a card that hit 90 C
  CLPEAK_STATUS="skipped"
  log "clpeak skipped: the GPU reached hashcat's 90 C abort temperature in the stress phase"
elif [ "$RUN_CLPEAK" -eq 1 ] && have clpeak; then
  log "benchmark: clpeak"
  CLP="$OUT/clpeak.txt"
  # Platform name pattern for the GPU's OpenCL platform (never pocl = CPU).
  case "$VENDOR" in
    nvidia) PLAT_RE='NVIDIA' ;;
    amd)    PLAT_RE='AMD|rusticl|Clover' ;;
    intel)  PLAT_RE='Intel|rusticl' ;;
    *)      PLAT_RE='NVIDIA|AMD|Intel|rusticl|Clover' ;;
  esac
  CLP_ARGS=()
  if [ "$VENDOR" != nvidia ] && [ -n "$OCL_DIR" ]; then
    # Only the chosen ICD is visible (OCL_ICD_VENDORS), so take any platform name.
    PLAT_RE='.'
    CLP_ARGS=(-p "$OCL_PIDX" -d "$OCL_DEV_IDX")
  elif have clinfo; then
    # "Platform #0: NVIDIA CUDA" ; clpeak numbers platforms the same way (from 0)
    PIDX="$(clinfo -l 2>/dev/null | awk -v re="$PLAT_RE" '/^Platform #[0-9]+:/ { if ($0 ~ re && $0 !~ /Portable Computing|pocl/) { i=$2; gsub(/[^0-9]/,"",i); print i; exit } }')"
    if [ -n "$PIDX" ]; then
      DIDX=0
      # NVIDIA OpenCL orders devices like nvidia-smi (PCI bus order)
      [ "$VENDOR" = nvidia ] && [ -n "${NV_INDEX:-}" ] && DIDX="$NV_INDEX"
      CLP_ARGS=(-p "$PIDX" -d "$DIDX")
    fi
  fi
  run_clpeak() {
    if have timeout; then timeout "${BENCH_TIMEOUT}s" clpeak "$@" > "$CLP" 2>&1
    else clpeak "$@" > "$CLP" 2>&1; fi
  }
  # best value over all vector widths of one section, inside the GPU platform block only.
  # Any other text line ends the section, so "No double precision support! Skipped"
  # (common on Intel GPUs) gives no FP64 value instead of the next section's numbers.
  clp_best() {
    awk -v re="$PLAT_RE" -v sec="$1" '
      /^Platform:/ { inp = ($0 ~ re && $0 !~ /Portable Computing|pocl/); dev=0; next }
      inp && /^  Device:/ { dev++; next }
      inp && dev==1 && index($0, sec) { f=1; next }
      f && /^[[:space:]]*$/ { if (got) exit; next }
      f && !/:/ { exit }
      f && /:/ { v=$NF; if (v ~ /^[0-9.]+$/) { if (!got || v+0>m) m=v+0; got=1 } else if (got) exit }
      END { if (got) printf "%.2f", m }' "$CLP" 2>/dev/null
  }
  run_clpeak ${CLP_ARGS[@]+"${CLP_ARGS[@]}"}
  fp32="$(clp_best 'Single-precision compute')"
  if [ -z "$fp32" ] && [ ${#CLP_ARGS[@]} -gt 0 ]; then
    log "clpeak with ${CLP_ARGS[*]} gave no result; retrying without platform selection"
    run_clpeak; fp32="$(clp_best 'Single-precision compute')"
  fi
  if [ -s "$CLP" ] && [ -n "$fp32" ]; then
    CLPEAK_STATUS="ok"
    bw="$(clp_best 'Global memory bandwidth')"
    fp64="$(clp_best 'Double-precision compute')"
    int32="$(clp_best 'Integer compute (GIOPS)')"
    add_score "\"clpeak_fp32_gflops\": $fp32"
    [ -n "$bw" ]    && add_score "\"clpeak_vram_bw_gbps\": $bw"
    [ -n "$fp64" ]  && add_score "\"clpeak_fp64_gflops\": $fp64"
    [ -n "$int32" ] && add_score "\"clpeak_int32_giops\": $int32"
    log "  -> clpeak (best vector width) FP32=${fp32} GFLOPS, VRAM BW=${bw:-?} GB/s, FP64=${fp64:-?}, INT32=${int32:-?}"
  else
    CLPEAK_STATUS="error"
    add_warn "clpeak produced no output (timeout or no OpenCL device)"
  fi
elif [ "$RUN_CLPEAK" -eq 1 ]; then
  CLPEAK_STATUS="skipped"
  add_warn "clpeak not installed; skipping that benchmark"
else
  CLPEAK_STATUS="skipped"
fi

# ---------------------------------------------------------------------------
# Post-test health snapshot
# ---------------------------------------------------------------------------
if [ "$VENDOR" = "nvidia" ] && have nvidia-smi; then
  {
    echo "===== POST-TEST ($(date '+%F %T %Z')) ====="
    nvidia-smi ${NVSEL[@]+"${NVSEL[@]}"} --query-gpu="$NVQ" --format=csv,nounits 2>/dev/null
    echo "--- NVRM: Xid kernel messages (GPU driver errors) ---"
    XID_AFTER="$(xid_count)"
    echo "(NVRM: Xid lines this boot: before $XID_BEFORE, after $XID_AFTER)"
    dmesg 2>/dev/null | grep 'NVRM: Xid' | tail -n "$(( XID_AFTER - XID_BEFORE > 0 ? XID_AFTER - XID_BEFORE : 0 ))"
  } > "$OUT/post-health.txt" 2>>"$LOG"
  XID_AFTER="$(xid_count)"
  if [ "${XID_AFTER:-0}" -gt "${XID_BEFORE:-0}" ] 2>/dev/null; then
    add_err "$((XID_AFTER - XID_BEFORE)) new NVIDIA Xid (GPU driver error) message(s) during the test; see post-health.txt"
  fi
fi

if [ "$VENDOR" = amd ] || [ "$VENDOR" = intel ]; then
  GERR_AFTER="$(gerr_count)"
  {
    echo "===== POST-TEST ($(date '+%F %T %Z')) ====="
    echo "--- sensors ($TEL_GPU_EXT_FIELDS) ---"
    gpu_query_ext "${TEL_IDX:-none}"
    echo "--- GPU driver error lines for $GPU_ADDR this boot: before $GERR_BEFORE, after $GERR_AFTER ---"
    dmesg 2>/dev/null | grep -F "$GPU_ADDR" | grep -E "$GERR_RE" | tail -n "$(( GERR_AFTER - GERR_BEFORE > 0 ? GERR_AFTER - GERR_BEFORE : 0 ))"
  } > "$OUT/post-health.txt" 2>>"$LOG"
  if [ "${GERR_AFTER:-0}" -gt "${GERR_BEFORE:-0}" ] 2>/dev/null; then
    add_err "$((GERR_AFTER - GERR_BEFORE)) new $CHOSEN_DRV GPU error line(s) (ring timeout / GPU hang / reset / page fault) during the test; see post-health.txt"
  fi
fi

log "=== GPU part complete ==="
finish
