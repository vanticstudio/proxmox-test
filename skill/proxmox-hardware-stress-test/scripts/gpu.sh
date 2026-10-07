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
#      status "skipped" with the reason, still exit 0.
#   2. Stress phase (DURATION seconds): a sustained 100% compute load so you
#      can see whether the card holds its clocks, stays within thermal limits
#      and throws no driver errors.
#        NVIDIA: hashcat on the OpenCL backend (CUDA backend forced OFF - see
#                LESSONS) running a fixed mask attack against a deliberately
#                unfindable dummy MD5 digest, with --runtime=DURATION. The hash
#                is never found; the run is purely a steady GPU load generator.
#        AMD/Intel: the same, only if a working OpenCL ICD + hashcat device is
#                present; otherwise the stress phase is recorded as skipped.
#      Telemetry once per second to DIR/stress-tel.csv for the whole phase:
#        NVIDIA : nvidia-smi (pstate, temp, power.draw, power.limit, SM/mem/
#                 graphics clocks, gpu+mem util, fan, VRAM used, throttle
#                 reasons, PCIe gen/width).
#        AMD/Intel: amdgpu/i915 sysfs+hwmon (temp, power when exposed, sclk,
#                 busy %, VRAM used, fan, PCIe link). Missing sensor -> "n/a".
#   3. Scores:
#        NVIDIA: hashcat -b benchmark for modes 0 (MD5), 1000 (NTLM),
#                1400 (SHA2-256), 22000 (WPA) - each bounded by --bench-timeout;
#                plus clpeak (FP32/FP64/INT/bandwidth) if installed.
#        AMD/Intel: clpeak if installed; hashcat -b if a device is usable.
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
#   touches a vfio-bound GPU. hashcat's 90 C temperature-abort watchdog stays
#   on. All installs are the caller's job (prep step); this script only USES
#   tools and records which were missing.
#
# LESSONS (known pitfalls with NVIDIA cards on recent PVE / Debian):
#   - The CUDA backend needs NVRTC, which is usually absent on a bare Proxmox
#     host, so hashcat's CUDA backend errors out. We force OpenCL with
#     --backend-ignore-cuda and -D 2 (OpenCL device-type = GPU).
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
#   - hashcat/pocl/NVIDIA kernel caches are redirected into the skill's working
#     dir (XDG_*_HOME, POCL_CACHE_DIR, CUDA_CACHE_PATH) so nothing is left in
#     /root/.cache, /root/.local/share or /root/.nv after cleanup.
#
# Per-GPU summary.json also records "index", "nvidia_index", "drm_card" and
# "driver", so the report can match each result to the inventory.
#
# summary.json is always written; exit code is 0 on success even when a
# sub-test is unavailable (each such case is recorded as skipped with a reason).
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
    -h|--help)       sed -n '2,90p' "$0"; exit 0 ;;
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
  for d in "${GPU_SH_PCI_ROOT:-/sys/bus/pci/devices}"/*; do   # override only for testing
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
    printf '  "stress": { "status": "%s", "reason": "%s", "telemetry_csv": "stress-tel.csv", "stats": %s },\n' \
      "$(jesc "$STRESS_STATUS")" "$(jesc "$STRESS_REASON")" "${STRESS_STATS:-null}"
    printf '  "xid_lines_before": %s, "xid_lines_after": %s,\n' "${XID_BEFORE:-null}" "${XID_AFTER:-null}"
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
    amdgpu|radeon)             echo amd ;;
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
    *)      VENDOR="unknown" ;;
  esac
fi

# Fall back to vendor tools if lspci was unavailable or inconclusive.
if [ "$VENDOR" = "unknown" ] && [ -z "$CHOSEN" ]; then
  if have nvidia-smi && nvidia-smi -L >/dev/null 2>&1; then VENDOR="nvidia";
  elif have rocm-smi; then VENDOR="amd";
  elif [ -d /sys/class/drm/card0/device ] && grep -qi amd /sys/class/drm/card0/device/uevent 2>/dev/null; then VENDOR="amd";
  fi
fi

if [ -z "${G_INDEX:-}" ] && [ -n "$GPU_ADDR" ]; then
  for i in "${!G_ADDR[@]}"; do [ "${G_ADDR[$i]}" = "$GPU_ADDR" ] && G_INDEX=$i; done
fi
log "detected vendor: $VENDOR (driver=${CHOSEN_DRV:-?}, pci=${GPU_ADDR:-?}, index=${G_INDEX:-?}, name=${GPU_NAME:-?})"

if [ "$VENDOR" = "unknown" ] || [ "$VENDOR" = "none" ]; then
  STATUS="skipped"
  SKIP_REASON="no usable GPU found (no nvidia/amdgpu/i915 device, or only vfio-passthrough GPUs present)"
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
    # Generic sysfs sampler for amdgpu / i915 / xe.
    # Use the selected PCI device itself (not simply the first DRM card).
    local drm=""
    if [ -n "$GPU_ADDR" ] && [ -d "/sys/bus/pci/devices/$GPU_ADDR/drm" ]; then
      drm="/sys/bus/pci/devices/$GPU_ADDR/drm/$(ls "/sys/bus/pci/devices/$GPU_ADDR/drm" 2>/dev/null | grep -m1 '^card')"
    fi
    if [ -z "$drm" ] || [ ! -e "$drm/device/vendor" ]; then
      drm=""
      for c in /sys/class/drm/card*; do
        [ -e "$c/device/vendor" ] || continue
        drm="$c"; break
      done
    fi
    {
      echo "timestamp,temp_c,power_w,sclk_mhz,busy_pct,vram_used_mib,fan_rpm,pcie_link"
      while :; do
        local ts temp pwr sclk busy vram fan link
        ts="$(date '+%F %T')"
        temp="n/a"; pwr="n/a"; sclk="n/a"; busy="n/a"; vram="n/a"; fan="n/a"; link="n/a"
        if [ -n "$drm" ]; then
          local dev="$drm/device"
          # temperature (hwmon tempN_input is in millidegrees)
          for h in "$dev"/hwmon/hwmon*/temp1_input; do
            [ -r "$h" ] && { temp="$(( $(cat "$h" 2>/dev/null || echo 0) / 1000 ))"; break; }
          done
          # power (microwatts)
          for h in "$dev"/hwmon/hwmon*/power1_average "$dev"/hwmon/hwmon*/power1_input; do
            [ -r "$h" ] && { pwr="$(awk '{printf "%.1f",$1/1000000}' "$h" 2>/dev/null)"; break; }
          done
          # shader clock (hwmon freq1_input is in Hz)
          for h in "$dev"/hwmon/hwmon*/freq1_input; do
            [ -r "$h" ] && { sclk="$(awk '{printf "%.0f",$1/1000000}' "$h" 2>/dev/null)"; break; }
          done
          # busy %
          [ -r "$dev/gpu_busy_percent" ] && busy="$(cat "$dev/gpu_busy_percent" 2>/dev/null)"
          # vram used (bytes)
          [ -r "$dev/mem_info_vram_used" ] && vram="$(( $(cat "$dev/mem_info_vram_used" 2>/dev/null || echo 0) / 1048576 ))"
          # fan rpm
          for h in "$dev"/hwmon/hwmon*/fan1_input; do
            [ -r "$h" ] && { fan="$(cat "$h" 2>/dev/null)"; break; }
          done
          # pcie link
          [ -r "$dev/current_link_speed" ] && link="$(cat "$dev/current_link_speed" 2>/dev/null)"
        fi
        echo "$ts,$temp,$pwr,$sclk,$busy,$vram,$fan,$link"
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

# Make sure background telemetry never outlives the script.
cleanup() { stop_telemetry; }
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
pick_hashcat_device

# Xid (GPU driver error) lines are counted before and after; only NEW ones count.
xid_count() { dmesg 2>/dev/null | grep -c 'NVRM: Xid'; }
XID_BEFORE="$(xid_count)"

# ---------------------------------------------------------------------------
# Pre-test health snapshot (NVIDIA only; AMD/Intel noted in detect.txt)
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

if have hashcat; then
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
      STRESS_STATUS="skipped"
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

# ---------------------------------------------------------------------------
# 3a. hashcat benchmark scores
# ---------------------------------------------------------------------------
run_bench() {
  # $1 = mode, $2 = label
  local mode="$1" label="$2" out="$OUT/bench-${1}-${2}.txt"
  log "benchmark: hashcat -m $mode ($label)"
  if have timeout; then
    timeout "${BENCH_TIMEOUT}s" hashcat -b --backend-ignore-cuda -D 2 ${HC_DEV[@]+"${HC_DEV[@]}"} -m "$mode" \
      > "$out" 2>&1
  else
    hashcat -b --backend-ignore-cuda -D 2 ${HC_DEV[@]+"${HC_DEV[@]}"} -m "$mode" > "$out" 2>&1
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

if have hashcat; then
  HASHCAT_STATUS="ok"
  run_bench 0     md5
  run_bench 1000  ntlm
  run_bench 1400  sha256
  run_bench 22000 wpa
else
  HASHCAT_STATUS="skipped"
fi

# ---------------------------------------------------------------------------
# 3b. clpeak
# ---------------------------------------------------------------------------
if [ "$RUN_CLPEAK" -eq 1 ] && have clpeak; then
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
  if have clinfo; then
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
  # best value over all vector widths of one section, inside the GPU platform block only
  clp_best() {
    awk -v re="$PLAT_RE" -v sec="$1" '
      /^Platform:/ { inp = ($0 ~ re && $0 !~ /Portable Computing|pocl/); dev=0; next }
      inp && /^  Device:/ { dev++; next }
      inp && dev==1 && index($0, sec) { f=1; next }
      f && /^[[:space:]]*$/ { if (got) exit; next }
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

log "=== GPU part complete ==="
finish
