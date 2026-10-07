#!/bin/bash
# =============================================================================
# disk.sh - SSD / NVMe / HDD stress + benchmark for a Proxmox VE host
# Part of the "proxmox-hardware-stress-test" skill. Run as root ON the host.
#
# USAGE
#   File mode (default; read + write tests on a test file, never the device):
#   disk.sh [--mode file] --path /mount/point --duration SECONDS --out DIR
#           [--profile nvme|ssd|hdd|auto] [--device /dev/X] [--size-gb N]
#           [--smart-type TYPE] [--no-install]
#
#   Read-only raw-device mode (whole physical disk, reads only):
#   disk.sh --mode readonly --device /dev/X --duration SECONDS --out DIR
#           [--profile nvme|ssd|hdd|auto] [--smart-type TYPE] [--no-install]
#
#   --mode      file (default) | readonly.
#               readonly: for disks that have no mounted writable filesystem
#               (LVM-thin / ZFS members, mdraid members, disks given to VMs,
#               unpartitioned spares, disks behind an HBA). fio opens the raw
#               device with --readonly, so fio itself refuses any write, and the
#               script also aborts (exit 3) before starting any job that is not
#               a pure read. Jobs: sequential read 1M, random read 4K high QD,
#               random read 4K QD1 over the WHOLE device. Only physical disks
#               are accepted: a partition is mapped to its whole disk; an LVM
#               LV / dm / dm-crypt / multipath / mdraid device is refused and
#               its member disks are listed (run once per member). Reading a
#               disk that is in use (pool member, VM disk) is safe; guest I/O
#               at the same time lowers the numbers.
#   --smart-type  passed to smartctl as "-d TYPE" for disks behind a RAID
#               controller or a USB bridge (e.g. megaraid,0  cciss,0  sat
#               aacraid,0,0,0). Default: smartctl's auto-detection.
#   --path      (file mode) a directory on a MOUNTED, writable local filesystem (ext4, xfs,
#               zfs, btrfs, f2fs) that lives on the disk you want to test, e.g.
#               /var/lib/vz (root disk) or /mnt/<your-hdd-mount>. A test file
#               ".pve-stresstest-fio-<pid>.tmp" is created there and ALWAYS
#               deleted on exit (also on Ctrl-C / error).
#   --device    the disk the path lives on, used ONLY for read-only queries
#               (SMART, temperature, link speed). A partition (/dev/sda1,
#               /dev/nvme0n1p3) or an NVMe controller (/dev/nvme0) is mapped to
#               its whole disk. Optional: detected from --path when omitted
#               (LVM and ZFS are followed down to the physical disk).
#   --device    (readonly mode) REQUIRED: /dev/sdX, /dev/nvmeXnY, an NVMe
#               controller /dev/nvmeX (-> its first namespace), or a
#               /dev/disk/by-id/... link.
#   --profile   nvme | ssd (SATA/SAS SSD) | hdd | auto (default). Picks queue
#               depths, jobs and test-file cap. auto = nvme for NVMe, hdd for a
#               rotational disk, else ssd.
#   --duration  sustained stress length in seconds (30, 60, 300, 600; 10-3600
#               accepted). It is split across the fio jobs (see below).
#   --out       output directory (created).
#   --size-gb   requested test-file size (default 8 for nvme/ssd, 4 for hdd).
#               Capped to min(requested, 10% of free space, 8 GB ssd/nvme,
#               4 GB hdd). Refused if free space < 2x the file size or the
#               capped size is below 512 MiB.
#   --no-install  never apt-install missing tools (fio/smartmontools/nvme-cli);
#               refuse instead.
#
# WHAT IT MEASURES
#   Before/after: smartctl -a (text + JSON), nvme smart-log, SATA error log,
#   kernel messages for the disk, free space. Link: PCIe speed/width for NVMe
#   (sysfs + lspci LnkCap/LnkSta), SATA link speed (smartctl). ZFS: dataset
#   properties (read-only) and ARC hit/miss counts per job.
#   fio on the TEST FILE only (direct=1, io_uring -> libaio -> psync fallback):
#     nvme/ssd: fill (unscored prep), seq read 1M QD32, seq write 1M QD32,
#               rand read 4K QD32 x4 jobs, rand write 4K QD32 x4 jobs,
#               rand read 4K QD1 (latency)
#               split of DURATION: 25% / 25% / 20% / 20% / 10%
#     hdd:      fill write 1M QD8 (scored: sequential write over the whole
#               file, shows SMR/cache drop-off), seq read 1M QD8, seq write
#               1M QD8, rand read 4K QD1, rand read 4K QD32, rand write 4K QD32
#               split of DURATION: 20% / 20% / 20% / 15% / 25% (fill extra)
#               HDD score = sequential tests only (fill, seq read, seq write);
#               random tests are reported, not scored (small file flatters
#               them; random write measures the drive/SMR cache).
#   fio on the RAW DEVICE, readonly mode (--readonly, direct=1, whole device):
#     nvme/ssd: seq read 1M QD32, rand read 4K QD32 x4 jobs, rand read 4K QD1
#               split of DURATION: 35% / 35% / 30%
#     hdd:      seq read 1M QD8 (starts at LBA 0 = outer tracks), rand read 4K
#               QD32, rand read 4K QD1 (full stroke)
#               split of DURATION: 40% / 30% / 30%; only seq read is scored.
#   Each job has min 4 s. Per job: MB/s, IOPS, avg / p50 / p99 / p99.9
#   completion latency, plus fio's own 1-second bandwidth log, used for a
#   "sustain ratio" (last quarter vs first quarter) that exposes SLC-cache or
#   SMR-cache exhaustion on longer runs.
#   Telemetry every second during the run (telemetry-1s.csv): disk temperature
#   (NVMe hwmon / drivetemp / smartctl), hottest NVMe sensor, and
#   /proc/diskstats MB/s (informational only: scores always use fio's figures,
#   per-second diskstats IOPS on an HDD can be ~20% off).
#
# TIME IT TAKES
#   DURATION + the fill/prep write (bounded, max 180 s; typically 2-10 s for
#   NVMe 8 GB, 15-60 s for SATA SSD 8 GB, 25-60 s for HDD 4 GB) + ~20 s for
#   SMART snapshots, engine probe, idle lead-in and 5 s cooldown.
#   Readonly mode: DURATION + ~20 s (no fill step).
#
# OUTPUT (in --out)
#   summary.json, summary.txt, run.log, telemetry-1s.csv, fio-*.json/.err,
#   fio-*_bw.*.log, pre-/post-smartctl.txt(+.json), pre-/post-nvme-smartlog.txt,
#   pre-/post-smart-errlog.txt, pre-/post-dmesg.txt, journal-warnings.txt,
#   link.txt, lspci-nvme.txt, queue.txt, zfs.txt, df-pre/post.txt,
#   testfile-deleted.txt (file mode), smart-scan.txt (smartctl --scan-open, only for
#   a hardware RAID logical volume: shows the -d types of the member disks). Raw smartctl text contains the drive serial number;
#   summary.json does not.
#
# SAFETY
#   Never writes to a block device: file mode writes only its own test file
#   (the name must not exist; deleted on exit); readonly mode opens the device
#   with fio --readonly and a hard guard refuses any job that is not a read.
#   Does not change any disk/fs/ZFS setting, does not start/stop guests.
#   Write volume: a long NVMe run writes a lot (a 600 s run on a fast NVMe
#   drive can write several hundred GB or more); bytes written are reported in summary.json.
#
# EXIT CODES
#   0 = ran (individual jobs that failed are recorded as errors/skipped)
#   2 = bad usage   3 = refused (safety/precondition; reason in summary.json)
# =============================================================================
set -u -o pipefail
export LC_ALL=C

SCRIPT_NAME=disk.sh
DEVICE="" ; TPATH="" ; PROFILE="" ; DURATION="" ; OUT="" ; SIZE_GB="" ; NO_INSTALL=0
MODE="file" ; SMART_TYPE=""

usage() { sed -n '/^# USAGE/,/^# WHAT IT MEASURES/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; }

# A value-taking flag at the end of the line (no value) is a usage error, not a hang.
need_val() { [ $# -ge 2 ] && [ -n "$2" ] && [ "${2#--}" = "$2" ] || { echo "$SCRIPT_NAME: $1 needs a value (see --help)" >&2; exit 2; }; }
while [ $# -gt 0 ]; do
  case "$1" in
    --mode)     need_val "$@"; MODE="$2"; shift 2 ;;
    --smart-type) need_val "$@"; SMART_TYPE="$2"; shift 2 ;;
    --device)   need_val "$@"; DEVICE="$2"; shift 2 ;;
    --path)     need_val "$@"; TPATH="$2"; shift 2 ;;
    --profile)  need_val "$@"; PROFILE="$2"; shift 2 ;;
    --duration) need_val "$@"; DURATION="$2"; shift 2 ;;
    --out)      need_val "$@"; OUT="$2"; shift 2 ;;
    --size-gb)  need_val "$@"; SIZE_GB="$2"; shift 2 ;;
    --no-install) NO_INSTALL=1; shift ;;
    -h|--help)  usage; exit 0 ;;
    *) echo "$SCRIPT_NAME: unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

# ---- argument validation (before anything is created on disk) ------------------
usage_err() { echo "$SCRIPT_NAME: $*" >&2; exit 2; }
[ -n "$OUT" ] || usage_err "--out DIR is required"
case "$MODE" in file|readonly) ;; *) usage_err "--mode must be file or readonly" ;; esac
[ -n "$PROFILE" ] || PROFILE=auto
case "$PROFILE" in nvme|ssd|hdd|auto) ;; *) usage_err "--profile must be nvme, ssd, hdd or auto" ;; esac
[[ "$DURATION" =~ ^[0-9]+$ ]] && [ "$DURATION" -ge 10 ] && [ "$DURATION" -le 3600 ] \
  || usage_err "--duration must be an integer 10..3600 (seconds)"
[ -z "$SMART_TYPE" ] || [[ "$SMART_TYPE" =~ ^[A-Za-z0-9_,+./-]+$ ]] || usage_err "--smart-type contains unexpected characters"
if [ "$MODE" = file ]; then
  [ -n "$TPATH" ] || usage_err "--path is required in file mode (use --mode readonly --device /dev/X for a raw disk)"
  if [ -n "$SIZE_GB" ]; then
    [[ "$SIZE_GB" =~ ^[0-9]+$ ]] && [ "$SIZE_GB" -ge 1 ] || usage_err "--size-gb must be a positive integer"
  fi
else
  [ -n "$DEVICE" ] || usage_err "--mode readonly needs --device /dev/X"
  [ -z "$TPATH" ] || usage_err "--path is not used in readonly mode (it tests the raw --device)"
  [ -z "$SIZE_GB" ] || usage_err "--size-gb is not used in readonly mode (the whole device is read)"
fi

mkdir -p "$OUT" || { echo "$SCRIPT_NAME: cannot create $OUT" >&2; exit 2; }
OUT=$(cd "$OUT" && pwd)
: > "$OUT/run.log"; : > "$OUT/.notes"; : > "$OUT/.warnings"; : > "$OUT/.errors"; : > "$OUT/.skipped"; : > "$OUT/.meta"; : > "$OUT/.tests"

log()  { echo "[$(date '+%F %T')] $*" | tee -a "$OUT/run.log" >&2; }
warn() { log "WARNING: $*"; printf '%s\n' "$*" >> "$OUT/.warnings"; }
errr() { log "ERROR: $*";   printf '%s\n' "$*" >> "$OUT/.errors"; }
note() { log "NOTE: $*"; printf '%s\n' "$*" >> "$OUT/.notes"; }
skip() { log "SKIPPED $1: $2"; printf '%s\t%s\n' "$1" "$2" >> "$OUT/.skipped"; }
meta() { printf '%s\t%s\n' "$1" "${2//$'\n'/ }" >> "$OUT/.meta"; }

# ---- summary writer (also used for refusals) --------------------------------
STATUS="running"; REFUSE_REASON=""
write_summary() {
  if ! command -v python3 >/dev/null 2>&1; then
    printf '{"part":"disk","status":"%s","error":"python3 missing, see summary.txt"}\n' "$STATUS" > "$OUT/summary.json"
    return
  fi
  STATUS="$STATUS" REFUSE_REASON="$REFUSE_REASON" OUTDIR="$OUT" python3 - <<'PY'
import json, os, glob, re, statistics
out = os.environ["OUTDIR"]
def lines(p):
    try:
        with open(os.path.join(out, p)) as f: return [l.rstrip("\n") for l in f if l.strip()]
    except OSError: return []
meta = {}
for l in lines(".meta"):
    k, _, v = l.partition("\t"); meta[k] = v
def num(v, cast=float):
    try: return cast(v)
    except (TypeError, ValueError): return None
notes = lines(".notes"); warnings = lines(".warnings"); errors = lines(".errors")
skipped = [dict(zip(("test", "reason"), l.split("\t", 1))) for l in lines(".skipped")]
profile = meta.get("profile", "")

# ---------- class reference values (rough; replace with the model's datasheet) --
gen = num(meta.get("pcie_gen"), int); width = num(meta.get("pcie_width"), int)
ref = {}; ref_basis = ""
if profile == "nvme":
    table = {3: (3500, 3000, 500000, 450000, 13000),
             4: (7000, 6000, 1000000, 1000000, 20000),
             5: (12000, 11000, 1400000, 1400000, 20000)}
    g = gen if gen in table else (3 if (gen or 0) < 3 else 5)
    sr, sw, rr, rw, q1 = table[g]
    scale = min(1.0, (width or 4) / 4.0)
    ref = {"seqread": sr*scale, "seqwrite": sw*scale, "randread": rr, "randwrite": rw, "randread_qd1": q1}
    ref_basis = f"typical high-end PCIe Gen{g} x{width or '?'} NVMe; budget/DRAM-less models are lower - use the model's datasheet"
elif profile == "ssd":
    slow = "3.0 Gb/s" in meta.get("sata_link", "")
    ref = {"seqread": 280 if slow else 550, "seqwrite": 270 if slow else 520,
           "randread": 95000, "randwrite": 85000, "randread_qd1": 10000}
    ref_basis = "typical SATA III SSD" + (" (link at 3 Gb/s halves sequential)" if slow else "")
elif profile == "hdd":
    rpm = num(meta.get("rotation_rpm"), int) or 0
    if rpm >= 7200: ref = {"fill": 220, "seqread": 220, "seqwrite": 220, "randread_qd1": 120}
    else:           ref = {"fill": 180, "seqread": 180, "seqwrite": 180, "randread_qd1": 80}  # typical 5400-5900 rpm 3.5" class, outer-track sequential
    ref_basis = f"typical {rpm or 'unknown'}-rpm 3.5\" HDD outer tracks; only sequential tests are scored (random results are flattered by the small test file, random write measures the cache)"

def verdict(p):
    if p is None: return "not scored"
    if p >= 90: return "running optimally"
    if p >= 75: return "slightly below expected"
    if p >= 50: return "below expected - investigate"
    return "well below expected - investigate"

def bwlog_series(prefix):
    buckets = {}
    for fn in glob.glob(os.path.join(out, prefix + "_bw.*.log")):
        try:
            for l in open(fn):
                parts = [x.strip() for x in l.split(",")]
                if len(parts) < 2: continue
                t = round(int(parts[0]) / 1000); buckets[t] = buckets.get(t, 0) + int(parts[1])
        except (OSError, ValueError): pass
    return [buckets[k] / 1024.0 * 1.048576 for k in sorted(buckets)]  # KiB/s -> MB/s

tests = []; bytes_written = 0; bytes_read = 0
for l in lines(".tests"):
    idx, name, label, scored, refkey = (l.split("\t") + [""] * 5)[:5]
    t = {"id": name, "label": label, "scored": scored == "1"}
    fj = os.path.join(out, f"fio-{idx}-{name}.json")
    try:
        raw = open(fj).read(); raw = raw[raw.index("{"):]
        job = json.loads(raw)["jobs"][0]
    except Exception as e:
        t["status"] = "error"; t["error"] = f"no valid fio JSON ({e.__class__.__name__})"
        tests.append(t); continue
    t["fio_error"] = job.get("error", 0)
    for d in ("read", "write"):
        x = job.get(d, {})
        if not x or x.get("io_bytes", 0) == 0: continue
        if d == "write": bytes_written += x["io_bytes"]
        else: bytes_read += x["io_bytes"]
        pc = x.get("clat_ns", {}).get("percentile", {})
        t.update({"direction": d, "MBps": round(x["bw_bytes"] / 1e6, 1), "IOPS": round(x["iops"], 1),
                  "lat_avg_us": round(x.get("lat_ns", {}).get("mean", 0) / 1000, 1),
                  "lat_p50_us": round(pc.get("50.000000", 0) / 1000, 1),
                  "lat_p99_us": round(pc.get("99.000000", 0) / 1000, 1),
                  "lat_p99_9_us": round(pc.get("99.900000", 0) / 1000, 1),
                  "lat_max_us": round(x.get("clat_ns", {}).get("max", 0) / 1000, 1),
                  "runtime_s": round(x.get("runtime", 0) / 1000, 1)})
    s = bwlog_series(f"fio-{idx}-{name}")
    if len(s) >= 8:
        q = max(2, len(s) // 4)
        first, last = statistics.mean(s[:q]), statistics.mean(s[-q:])
        if first > 0:
            t["sustain_ratio"] = round(last / first, 2)
            t["sustain_first_quarter_MBps"] = round(first, 1); t["sustain_last_quarter_MBps"] = round(last, 1)
    arc = meta.get(f"arc_{name}")
    if arc:
        h, m = (int(v) for v in arc.split(":"))
        if h + m > 0: t["zfs_arc_hit_pct"] = round(100.0 * h / (h + m), 1)
    if "MBps" in t:
        t["status"] = "ok" if not t["fio_error"] else "error"
        r = ref.get(refkey)
        if r:
            val = t["IOPS"] if refkey in ("randread", "randwrite", "randread_qd1") else t["MBps"]
            t["expected"] = r; t["expected_unit"] = "IOPS" if refkey in ("randread", "randwrite", "randread_qd1") else "MB/s"
            t["pct_of_expected"] = round(100.0 * val / r, 1)
        t["verdict"] = verdict(t.get("pct_of_expected")) if t["scored"] else "reported, not scored"
        # A real HDD seek takes several ms. A raw random read whose median latency is
        # below ~4 ms hit unwritten/unmapped LBAs (answered from the drive's translation
        # table, common on SMR drives) or the drive cache - not the platters.
        if (profile == "hdd" and meta.get("mode") == "readonly" and name.startswith("randread")
                and 0 < t.get("lat_p50_us", 0) < 4000):
            t["valid"] = False
            t["invalid_reason"] = ("median latency %.2f ms is below a physical seek (~4 ms+): reads hit unwritten/unmapped "
                                   "or cached regions (typical on SMR drives), not seek-bound" % (t["lat_p50_us"] / 1000))
            t.pop("pct_of_expected", None); t.pop("expected", None)
            t["verdict"] = "invalid - not seek-bound (excluded)"
    else:
        t["status"] = "error"; t.setdefault("error", "fio produced no I/O")
    tests.append(t)

pcts = [t["pct_of_expected"] for t in tests if "pct_of_expected" in t and t["scored"]]
score = round(statistics.mean(pcts), 1) if pcts else None

# ---------- telemetry ----------
temps = {}; tmax_all = []
try:
    import csv
    for row in csv.DictReader(open(os.path.join(out, "telemetry-1s.csv"))):
        v = num(row.get("temp_c")); m = num(row.get("temp_max_sensor_c"))
        if v is not None: temps.setdefault(row.get("phase", ""), []).append(v)
        if m is not None: tmax_all.append(m)
except OSError: pass
all_t = [v for vs in temps.values() for v in vs]
telemetry = {"temp_c_min": min(all_t) if all_t else None, "temp_c_avg": round(statistics.mean(all_t), 1) if all_t else None,
             "temp_c_max": max(all_t) if all_t else None, "hottest_sensor_c_max": max(tmax_all) if tmax_all else None,
             "temp_c_max_by_phase": {k: max(v) for k, v in temps.items()}, "samples": len(all_t)}

# ---------- SMART pre/post ----------
def smart(p):
    try: return json.load(open(os.path.join(out, p)))
    except Exception: return None
pre, post = smart("pre-smartctl.json"), smart("post-smartctl.json")
health = {}
def counters(j):
    c = {}
    if not j: return c
    n = j.get("nvme_smart_health_information_log")
    if n:
        for k in ("critical_warning", "media_errors", "num_err_log_entries", "percentage_used", "unsafe_shutdowns",
                  "power_on_hours", "data_units_written", "available_spare", "temperature"):
            if k in n: c[k] = n[k]
    for a in j.get("ata_smart_attributes", {}).get("table", []):
        if a.get("id") in (5, 9, 187, 188, 190, 194, 196, 197, 198, 199, 241):
            c[f"{a['id']}_{a.get('name','')}"] = a.get("raw", {}).get("value")
    return c
cpre, cpost = counters(pre), counters(post)
if pre or post:
    j = post or pre
    health = {"model": j.get("model_name"), "firmware": j.get("firmware_version"),
              "capacity_bytes": j.get("user_capacity", {}).get("bytes") or j.get("nvme_total_capacity"),
              "smart_passed": j.get("smart_status", {}).get("passed"),
              "rotation_rate": j.get("rotation_rate"), "counters_pre": cpre, "counters_post": cpost}
    bad = []
    for k in cpost:
        if any(s in k for s in ("media_errors", "num_err_log", "critical_warning", "Reallocated", "Pending", "Uncorrectable",
                                 "CRC", "Reported_Uncorrect", "Command_Timeout", "Offline_Uncorrectable")):
            a, b = cpre.get(k), cpost.get(k)
            if isinstance(a, int) and isinstance(b, int) and b > a: bad.append(f"{k}: {a} -> {b}")
    health["counters_increased_during_test"] = bad
    if bad: warnings.append("SMART error counters increased during the test: " + "; ".join(bad))
    if health["smart_passed"] is False: warnings.append("SMART overall health is FAILED")

summary = {
  "part": "disk", "status": os.environ.get("STATUS", "unknown"),
  "refuse_reason": os.environ.get("REFUSE_REASON") or None,
  "mode": meta.get("mode", "file"), "readonly": meta.get("mode") == "readonly",
  "profile": profile, "device": meta.get("device"), "path": meta.get("path"),
  "device_bytes": num(meta.get("device_bytes"), int),
  "member_disks": (meta.get("member_disks") or "").split() or None,
  "duration_s": num(meta.get("duration"), int),
  "filesystem": meta.get("fstype"), "source": meta.get("fs_source"),
  "test_file_bytes": num(meta.get("size_bytes"), int),
  "fio": {"engine": meta.get("engine"), "direct": num(meta.get("direct"), int), "version": meta.get("fio_version")},
  "link": {"pcie_current": meta.get("pcie_current"), "pcie_max": meta.get("pcie_max"),
           "pcie_gen": gen, "pcie_width": width, "sata_link": meta.get("sata_link") or None},
  "disk_info": {"rotational": meta.get("rotational"), "zoned": meta.get("zoned"), "write_cache": meta.get("write_cache"),
                "rotation_rpm": num(meta.get("rotation_rpm"), int), "backs_path": meta.get("device_backs_path"),
                "transport": meta.get("transport") or None, "vendor": meta.get("dev_vendor") or None,
                "model": meta.get("dev_model") or None, "controller_driver": meta.get("hba_driver") or None,
                "nvme_controller": meta.get("nvme_ctrl") or None, "smart_type": meta.get("smart_type") or None,
                "raid_logical_volume": meta.get("raid_lv") == "yes"},
  "tests": tests,
  "score_pct_of_expected": score,
  "score_basis": ("average of scored tests vs class reference: " + ref_basis) if ref_basis else None,
  "verdict": verdict(score),
  "bytes_written": bytes_written, "bytes_read": bytes_read,
  "telemetry": telemetry, "smart": health,
  "zfs": {"dataset": meta.get("zfs_dataset"), "direct_property": meta.get("zfs_direct"),
          "recordsize": meta.get("zfs_recordsize"), "compression": meta.get("zfs_compression"),
          "arc_c_max_bytes": num(meta.get("zfs_arc_c_max"), int)} if meta.get("fstype") == "zfs" else None,
  "test_file_deleted": meta.get("testfile_deleted"),
  "notes": notes, "warnings": warnings, "errors": errors, "skipped": skipped,
}
json.dump(summary, open(os.path.join(out, "summary.json"), "w"), indent=2)

# human-readable
if summary["mode"] == "readonly":
    L = [f"DISK TEST (READ-ONLY raw device)  profile={profile}  device={meta.get('device')}  size={round((summary['device_bytes'] or 0)/1e9,1)} GB",
         f"status={summary['status']}  duration={meta.get('duration')} s  engine={meta.get('engine')} direct={meta.get('direct')}  (fio --readonly; nothing written)"]
    if summary["member_disks"]: L.append("member disks: " + " ".join(summary["member_disks"]))
else:
    L = [f"DISK TEST  profile={profile}  device={meta.get('device')}  path={meta.get('path')}  fs={meta.get('fstype')}",
         f"status={summary['status']}  duration={meta.get('duration')} s  file={round((summary['test_file_bytes'] or 0)/2**30,2)} GiB  engine={meta.get('engine')} direct={meta.get('direct')}"]
if summary["refuse_reason"]: L.append("REFUSED: " + summary["refuse_reason"])
if health: L.append(f"model={health.get('model')}  fw={health.get('firmware')}  SMART passed={health.get('smart_passed')}")
if meta.get("pcie_current") or meta.get("pcie_max"):
    L.append(f"link: PCIe {meta.get('pcie_current') or '-'} (max {meta.get('pcie_max') or '-'})")
elif meta.get("sata_link"):
    sl = meta.get("sata_link")
    L.append("link: " + (sl if sl.upper().startswith("SATA") else "SATA " + sl))
else:
    L.append("link: not reported" + (f" (transport {meta.get('transport')})" if meta.get("transport") else ""))
L.append("")
for t in tests:
    if "MBps" not in t: L.append(f"{t['label']:34s} ERROR {t.get('error','')}"); continue
    s = f"{t['label']:34s} {t['MBps']:9.1f} MB/s {t['IOPS']:11.0f} IOPS  avg {t['lat_avg_us']:9.1f} us  p99 {t['lat_p99_us']:9.1f} us"
    if "pct_of_expected" in t: s += f"  {t['pct_of_expected']:5.1f}% of {t['expected']:.0f} {t['expected_unit']}" + ("" if t["scored"] else " (not scored)")
    if t.get("valid") is False: s += "  INVALID (not seek-bound)"
    if "sustain_ratio" in t: s += f"  sustain {t['sustain_ratio']}"
    if "zfs_arc_hit_pct" in t: s += f"  ARC hits {t['zfs_arc_hit_pct']}%"
    L.append(s)
def na(v): return "n/a" if v is None else v
L += ["", f"score: {score}% of class reference -> {verdict(score)}" if score is not None else "score: n/a",
      f"temp: min {na(telemetry['temp_c_min'])} / avg {na(telemetry['temp_c_avg'])} / max {na(telemetry['temp_c_max'])} C"
      + (f" (hottest sensor {telemetry['hottest_sensor_c_max']} C)" if telemetry['hottest_sensor_c_max'] is not None else ""),
      f"written {bytes_written/1e9:.1f} GB, read {bytes_read/1e9:.1f} GB; " + (
          "read-only mode, no test file" if summary["mode"] == "readonly" else f"test file deleted: {meta.get('testfile_deleted')}")]
for n in notes: L.append("NOTE: " + n)
for w in warnings: L.append("WARNING: " + w)
for e in errors: L.append("ERROR: " + e)
for s in skipped: L.append(f"SKIPPED: {s.get('test')}: {s.get('reason')}")
open(os.path.join(out, "summary.txt"), "w").write("\n".join(L) + "\n")
PY
}

refuse() {
  REFUSE_REASON="$*"; STATUS="refused"
  log "REFUSED: $*"
  exit 3   # the EXIT trap deletes the test file (if any) and writes summary.json
}

# ---- cleanup trap (installed before anything is created) ----------------------
TF=""; TF_CREATED=0; SAMPLER_PID=""
cleanup() {
  local rc=$?
  trap - EXIT INT TERM HUP
  if [ -n "$SAMPLER_PID" ]; then kill "$SAMPLER_PID" 2>/dev/null; wait "$SAMPLER_PID" 2>/dev/null; fi
  if [ "$TF_CREATED" -eq 1 ] && [ -n "$TF" ]; then
    rm -f -- "$TF"; sync
    if [ -e "$TF" ]; then echo "test file STILL PRESENT: $TF" > "$OUT/testfile-deleted.txt"; meta testfile_deleted "no"
    else echo "deleted: $TF (verified absent)" > "$OUT/testfile-deleted.txt"; meta testfile_deleted "yes"; fi
  fi
  rm -f "$OUT/.phase"
  [ "$STATUS" = running ] && STATUS="interrupted"
  [ "$STATUS" != ok ] && write_summary
  exit "$rc"
}
trap cleanup EXIT
trap 'log "interrupted"; exit 130' INT TERM HUP

# ---- privileges -----------------------------------------------------------------
[ "$(id -u)" -eq 0 ] || refuse "must run as root on the Proxmox host"
SMART_OPTS=(); [ -n "$SMART_TYPE" ] && SMART_OPTS=(-d "$SMART_TYPE")
meta mode "$MODE"; meta duration "$DURATION"; meta smart_type "$SMART_TYPE"

# ---- packages (distro repos only; record what we add) -------------------------
PKG_RECORD="$(dirname "$OUT")/installed-packages.txt"
ensure_pkg() { # ensure_pkg <package> <command>
  command -v "$2" >/dev/null 2>&1 && return 0
  if [ "$NO_INSTALL" -eq 1 ]; then return 1; fi
  command -v apt-get >/dev/null 2>&1 || return 1
  log "installing $1 from the distro repositories (apt)"
  local before after
  before=$(dpkg-query -W -f='${Package}\n' 2>/dev/null | sort)
  if ! DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "$1" >> "$OUT/apt.log" 2>&1; then
    DEBIAN_FRONTEND=noninteractive apt-get update >> "$OUT/apt.log" 2>&1
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "$1" >> "$OUT/apt.log" 2>&1 || return 1
  fi
  after=$(dpkg-query -W -f='${Package}\n' 2>/dev/null | sort)
  comm -13 <(echo "$before") <(echo "$after") >> "$PKG_RECORD"
  sort -u -o "$PKG_RECORD" "$PKG_RECORD" 2>/dev/null
  command -v "$2" >/dev/null 2>&1
}
ensure_pkg python3 python3 || refuse "python3 is required (apt install python3)"
ensure_pkg fio fio || refuse "fio is not installed and could not be installed (apt install fio)"
ensure_pkg smartmontools smartctl || warn "smartctl unavailable: no SMART data or SATA temperature"
meta fio_version "$(fio --version 2>/dev/null)"

# ---- device helpers (read-only) ------------------------------------------------
# NVMe controller (char dev /dev/nvmeX) -> its first namespace block device name.
# Handles native NVMe multipath, where the block device is the subsystem head
# nvme<subsys>n<ns> and the controller only lists hidden nvmeXcYnZ paths.
nvme_ctrl_to_ns() {
  local c="$1" ns sub
  ns=$(ls "/sys/class/nvme/$c/" 2>/dev/null | grep -E '^nvme[0-9]+n[0-9]+$' | sort -V | head -1)
  if [ -z "$ns" ]; then
    for sub in /sys/class/nvme-subsystem/nvme-subsys*; do
      [ -e "$sub/$c" ] || continue
      ns=$(ls "$sub/" 2>/dev/null | grep -E '^nvme[0-9]+n[0-9]+$' | sort -V | head -1); break
    done
  fi
  [ -n "$ns" ] && echo "$ns"
}
to_disk() { # map any block device to its whole-disk kernel name
  local d k
  d=$(readlink -f "$1" 2>/dev/null); [ -n "$d" ] || d="$1"
  if [ -c "$d" ] && [[ "$(basename "$d")" =~ ^nvme[0-9]+$ ]]; then
    k=$(nvme_ctrl_to_ns "$(basename "$d")")
    d="/dev/${k:-$(basename "$d")n1}"
  fi
  [ -b "$d" ] || return 1
  k=$(lsblk -n -d -o KNAME "$d" 2>/dev/null | head -1); [ -n "$k" ] || return 1
  if [ "$(lsblk -n -d -o TYPE "$d" 2>/dev/null | head -1)" = disk ]; then echo "$k"; return 0; fi
  lsblk -n -l -s -o KNAME,TYPE "$d" 2>/dev/null | awk '$2=="disk"{print $1; exit}'
}
member_disks() { # all physical disks under a (stacked) block device, as /dev/X
  lsblk -n -l -s -o KNAME,TYPE "$1" 2>/dev/null | awk '$2=="disk"{print "/dev/"$1}' | sort -u | tr '\n' ' ' | sed 's/ $//'
}

FSTYPE=""; FSSRC=""; MNT=""; BACKING=""
if [ "$MODE" = file ]; then
  # ---- path checks --------------------------------------------------------------
  { [ -b "$TPATH" ] || [ -c "$TPATH" ]; } && refuse "--path $TPATH is a device node; file mode never writes raw devices. Give a mounted directory, or use --mode readonly --device $TPATH for read-only tests"
  [ -d "$TPATH" ] || refuse "--path $TPATH is not a directory"
  TPATH=$(cd "$TPATH" && pwd -P)
  case "$TPATH" in
    /etc/pve|/etc/pve/*|/proc|/proc/*|/sys|/sys/*|/dev|/dev/*|/run|/run/*) refuse "--path $TPATH is a system/virtual filesystem" ;;
  esac
  FSTYPE=$(findmnt -n -o FSTYPE -T "$TPATH" 2>/dev/null | head -1)
  FSSRC=$(findmnt -n -o SOURCE -T "$TPATH" 2>/dev/null | head -1)
  FSOPTS=$(findmnt -n -o OPTIONS -T "$TPATH" 2>/dev/null | head -1)
  MNT=$(findmnt -n -o TARGET -T "$TPATH" 2>/dev/null | head -1)
  meta path "$TPATH"; meta fstype "$FSTYPE"; meta fs_source "$FSSRC"; meta mountpoint "$MNT"
  case "$FSTYPE" in
    ext4|ext3|xfs|zfs|btrfs|f2fs) ;;
    "") refuse "cannot determine the filesystem of $TPATH (findmnt)" ;;
    *) refuse "filesystem '$FSTYPE' at $TPATH is not a supported local disk filesystem (ext4/xfs/zfs/btrfs/f2fs)" ;;
  esac
  case ",$FSOPTS," in *,ro,*) refuse "$MNT is mounted read-only" ;; esac
  [ -w "$TPATH" ] || refuse "$TPATH is not writable"

  backing_disks() { # physical disks under the filesystem of --path (LVM, md, LUKS, ZFS, btrfs)
    if [ "$FSTYPE" = zfs ]; then
      command -v zpool >/dev/null 2>&1 || return 0
      zpool list -v -H -P "${FSSRC%%/*}" 2>/dev/null | grep -oE '/dev/[^[:space:]]+' | while read -r p; do to_disk "$p"; done | sort -u
    elif [ -b "$FSSRC" ]; then
      lsblk -n -l -s -o KNAME,TYPE "$FSSRC" 2>/dev/null | awk '$2=="disk"{print $1}' | sort -u
    elif [ "$FSTYPE" = btrfs ]; then
      to_disk "$(findmnt -n -o SOURCE -T "$TPATH" | sed 's/\[.*//')" 2>/dev/null
    fi
  }
  BACKING=$(backing_disks | tr '\n' ' ')
  if [ -n "$DEVICE" ]; then
    DISK=$(to_disk "$DEVICE") || refuse "--device $DEVICE is not a block device (or NVMe controller) on this host"
    [ -n "$DISK" ] || refuse "cannot map --device $DEVICE to a whole disk"
  else
    DISK=$(echo "$BACKING" | awk '{print $1}')
    [ -n "$DISK" ] || refuse "could not detect the disk behind $TPATH; pass --device /dev/X"
    [ "$(echo "$BACKING" | wc -w)" -gt 1 ] && warn "$TPATH spans several disks ($BACKING); SMART/temps use $DISK only (fio measures the whole filesystem). Test each member with --mode readonly for per-disk figures"
  fi
  DEV="/dev/$DISK"
  if [ -n "$BACKING" ] && ! echo " $BACKING " | grep -q " $DISK "; then
    warn "--device $DEV does not appear to back $TPATH (backing: $BACKING). fio measures $TPATH; SMART/temps are for $DEV"
    meta device_backs_path "no"
  else
    meta device_backs_path "${BACKING:+yes}"
  fi
else
  # ---- readonly: resolve --device to ONE physical disk -----------------------------
  RDEV=$(readlink -f "$DEVICE" 2>/dev/null); [ -n "$RDEV" ] || RDEV="$DEVICE"
  if [ -c "$RDEV" ] && [[ "$(basename "$RDEV")" =~ ^nvme[0-9]+$ ]]; then
    NS=$(nvme_ctrl_to_ns "$(basename "$RDEV")")
    [ -n "$NS" ] || refuse "NVMe controller $DEVICE has no namespace block device"
    note "NVMe controller $DEVICE mapped to its first namespace /dev/$NS"
    RDEV="/dev/$NS"
  fi
  [ -b "$RDEV" ] || refuse "--device $DEVICE is not a block device on this host"
  RTYPE=$(lsblk -n -d -o TYPE "$RDEV" 2>/dev/null | head -1)
  case "$RTYPE" in
    disk) DISK=$(lsblk -n -d -o KNAME "$RDEV" 2>/dev/null | head -1) ;;
    part)
      DISK=$(to_disk "$RDEV") || DISK=""
      [ -n "$DISK" ] || refuse "cannot map partition $DEVICE to its whole disk"
      note "$DEVICE is a partition; the whole disk /dev/$DISK is read" ;;
    lvm|crypt|dm|mpath|raid*|md|linear|stripe|multipath)
      MEMBERS=$(member_disks "$RDEV"); meta member_disks "$MEMBERS"
      refuse "$DEVICE is a $RTYPE device, not a physical disk. Readonly mode tests physical disks only; run it once per member disk: ${MEMBERS:-none found}" ;;
    *) refuse "$DEVICE has type '${RTYPE:-unknown}' (not a physical disk)" ;;
  esac
  [ -n "$DISK" ] || refuse "cannot resolve $DEVICE to a disk"
  case "$DISK" in
    zram*|rbd*|nbd*|loop*|ram*|sr*|fd*|md*|dm-*|drbd*) refuse "/dev/$DISK is a virtual/network/optical device, not a physical disk" ;;
  esac
  DEV="/dev/$DISK"
  DEV_BYTES=$(blockdev --getsize64 "$DEV" 2>/dev/null || cat "/sys/block/$DISK/size" 2>/dev/null | awk '{print $1*512}')
  [[ "$DEV_BYTES" =~ ^[0-9]+$ ]] && [ "$DEV_BYTES" -ge 1073741824 ] || refuse "$DEV reports a size below 1 GiB (or unreadable); nothing sensible to test"
  meta device_bytes "$DEV_BYTES"
  USERS=$(lsblk -n -r -o NAME,TYPE,FSTYPE,MOUNTPOINT "$DEV" 2>/dev/null | awk -F'[ ]' '($3!="" || $4!="") {print $1"("$2(($3!="")?","$3:"")(($4!="")?" on "$4:"")")"}' | tr '\n' ' ')
  [ -n "$USERS" ] && note "$DEV is in use ($USERS). Reads only, so this is safe; host/guest I/O at the same time lowers the results"
fi
meta device "$DEV"

# ---- device identity / transport / controller (read-only) ---------------------------
IS_NVME=0; CTRL=""
if [[ "$DISK" =~ ^nvme ]]; then
  IS_NVME=1
  CTRL=$(basename "$(readlink -f "/sys/block/$DISK/device" 2>/dev/null)")
  if [[ "$CTRL" =~ ^nvme-subsys[0-9]+$ ]]; then   # native multipath: pick the first live controller
    CTRL=$(ls "/sys/class/nvme-subsystem/$CTRL/" 2>/dev/null | grep -E '^nvme[0-9]+$' | sort -V | head -1)
  fi
  [[ "$CTRL" =~ ^nvme[0-9]+$ ]] || CTRL=$(echo "$DISK" | sed -E 's/(c[0-9]+)?n[0-9]+$//')
  meta nvme_ctrl "$CTRL"
  ensure_pkg nvme-cli nvme || warn "nvme-cli unavailable: no nvme smart-log"
fi
TRAN=$(lsblk -n -d -o TRAN "$DEV" 2>/dev/null | head -1 | tr -d ' ')
[ "$IS_NVME" -eq 1 ] && [ -z "$TRAN" ] && TRAN=nvme
DVEND=$(cat "/sys/block/$DISK/device/vendor" 2>/dev/null | sed 's/[[:space:]]*$//')
DMODEL=$(cat "/sys/block/$DISK/device/model" 2>/dev/null | sed 's/[[:space:]]*$//')
HOSTN=$(readlink -f "/sys/block/$DISK/device" 2>/dev/null | grep -oE 'host[0-9]+' | tail -1)
HBA_DRV=""; [ -n "$HOSTN" ] && HBA_DRV=$(cat "/sys/class/scsi_host/$HOSTN/proc_name" 2>/dev/null)
meta transport "$TRAN"; meta dev_vendor "$DVEND"; meta dev_model "$DMODEL"; meta hba_driver "$HBA_DRV"
RAID_LV=no
case "$HBA_DRV" in
  megaraid_sas|smartpqi|hpsa|aacraid|mpi3mr|cciss|arcmsr|3w-*|ips)
    if echo "$DVEND $DMODEL" | grep -qiE 'PERC|MegaRAID|MR[0-9]|LOGICAL|Virtual|RAID|LSI|AVAGO|Adaptec|HP +LOGICAL|Smart Array|ServeRAID|Areca'; then
      RAID_LV=yes
      warn "$DEV ($DVEND $DMODEL) is a hardware RAID logical volume on a $HBA_DRV controller: results are for the volume, not one disk. SMART of the member disks needs --smart-type (e.g. megaraid,N / cciss,N); see smart-scan.txt"
    fi ;;
esac
meta raid_lv "$RAID_LV"
# --scan-open probes every disk (can wake sleeping HDDs), so only use it when needed
if [ "$RAID_LV" = yes ] && command -v smartctl >/dev/null 2>&1; then smartctl --scan-open > "$OUT/smart-scan.txt" 2>&1; fi
ROT=$(cat "/sys/block/$DISK/queue/rotational" 2>/dev/null || echo "?")
meta rotational "$ROT"; meta zoned "$(cat "/sys/block/$DISK/queue/zoned" 2>/dev/null || echo n/a)"
if [ "$PROFILE" = auto ]; then
  if [ "$IS_NVME" -eq 1 ]; then PROFILE=nvme; elif [ "$ROT" = 1 ]; then PROFILE=hdd; else PROFILE=ssd; fi
  log "profile auto -> $PROFILE (transport ${TRAN:-?}, rotational $ROT)"
  [ "$RAID_LV" = yes ] && [ "$ROT" = 1 ] && note "RAID logical volume reports rotational; HDD class reference applies per member disk, so a multi-disk volume can score above 100%"
fi
meta profile "$PROFILE"
[ "$PROFILE" = nvme ] && [ "$IS_NVME" -ne 1 ] && warn "profile nvme but $DEV is not an NVMe device"
[ "$PROFILE" = hdd ] && [ "$ROT" = 0 ] && warn "profile hdd but $DEV reports non-rotational"
[ "$PROFILE" != hdd ] && [ "$ROT" = 1 ] && warn "profile $PROFILE but $DEV reports rotational (HDD)"
if [ "$MODE" = file ]; then
  log "testing $TPATH ($FSTYPE on $FSSRC), device $DEV, profile $PROFILE, duration ${DURATION}s"
else
  log "READ-ONLY test of raw device $DEV ($((DEV_BYTES/1000000000)) GB, ${TRAN:-?}${HBA_DRV:+ via $HBA_DRV}), profile $PROFILE, duration ${DURATION}s"
fi

# ---- size rules -----------------------------------------------------------------
if [ "$MODE" = file ]; then
  if [ -z "$SIZE_GB" ]; then [ "$PROFILE" = hdd ] && SIZE_GB=4 || SIZE_GB=8; fi
  FREE=$(df -P -B1 "$TPATH" | awk 'NR==2{print $4}')
  [[ "$FREE" =~ ^[0-9]+$ ]] || refuse "cannot read free space of $TPATH"
  [ "$PROFILE" = hdd ] && CAP=4 || CAP=8
  SIZE=$(( SIZE_GB * 1073741824 ))
  [ "$SIZE" -gt $(( CAP * 1073741824 )) ] && SIZE=$(( CAP * 1073741824 ))
  TENPCT=$(( FREE / 10 ))
  [ "$SIZE" -gt "$TENPCT" ] && SIZE=$TENPCT
  SIZE=$(( SIZE / 1048576 * 1048576 ))
  [ "$SIZE" -ge 536870912 ] || refuse "not enough free space on $TPATH: $((FREE/1048576)) MiB free; 10% of it is below the 512 MiB minimum test file"
  [ "$FREE" -ge $(( 2 * SIZE )) ] || refuse "free space $((FREE/1048576)) MiB is less than 2x the test file ($((SIZE/1048576)) MiB)"
  [ "$SIZE" -lt $(( SIZE_GB * 1073741824 )) ] && log "test file capped to $((SIZE/1048576)) MiB (requested ${SIZE_GB} GiB; caps: ${CAP} GiB profile, 10% of free)"
  meta size_bytes "$SIZE"
  df -hT "$TPATH" > "$OUT/df-pre.txt" 2>&1

  TF="$TPATH/.pve-stresstest-fio-$$.tmp"
  { [ -e "$TF" ] || [ -L "$TF" ]; } && refuse "test file $TF already exists; refusing to touch an existing file"
fi

# ---- telemetry helpers ------------------------------------------------------------
NVME_HWMON=""
if [ "$IS_NVME" -eq 1 ]; then
  for h in /sys/class/nvme/"$CTRL"/hwmon* /sys/class/nvme/"$CTRL"/device/hwmon/hwmon*; do
    [ -r "$h/temp1_input" ] && { NVME_HWMON="$h"; break; }
  done
fi
SATA_HWMON=""
for h in /sys/block/"$DISK"/device/hwmon/hwmon*; do [ -r "$h/temp1_input" ] && { SATA_HWMON="$h"; break; }; done
disk_temp() { # prints "<temp_c>,<hottest_other_sensor_c>" (n/a when missing)
  local t="n/a" m="n/a" f v
  if [ -n "$NVME_HWMON" ]; then
    v=$(cat "$NVME_HWMON/temp1_input" 2>/dev/null) && t=$(( v / 1000 ))
    for f in "$NVME_HWMON"/temp[2-9]_input; do
      [ -r "$f" ] || continue; v=$(cat "$f" 2>/dev/null) || continue
      [ "$v" -gt 0 ] 2>/dev/null || continue; v=$(( v / 1000 ))
      { [ "$m" = n/a ] || [ "$v" -gt "$m" ]; } && m=$v
    done
  elif [ -n "$SATA_HWMON" ]; then
    v=$(cat "$SATA_HWMON/temp1_input" 2>/dev/null) && t=$(( v / 1000 ))
  elif command -v smartctl >/dev/null 2>&1; then
    v=$(smartctl -A -n standby "${SMART_OPTS[@]}" "$DEV" 2>/dev/null | awk '
      $1==194 || $1==190 {print $10; exit}
      /^Current Drive Temperature:/ {print $4; exit}
      /^Temperature:/ {print $2; exit}')
    [[ "$v" =~ ^[0-9]+$ ]] && t=$v
  fi
  echo "$t,$m"
}
diskstat() { awk -v d="$DISK" '$3==d{print $6, $10; f=1} END{if(!f) print "0 0"}' /proc/diskstats; }
sampler() {
  local t0 prev cur now
  echo "ts,elapsed_s,phase,temp_c,temp_max_sensor_c,diskstats_read_MBps_info,diskstats_write_MBps_info"
  t0=$(date +%s); prev=$(diskstat)
  while :; do
    sleep 1
    cur=$(diskstat); now=$(date +%s)
    echo "$(date +%T),$((now - t0)),$(cat "$OUT/.phase" 2>/dev/null || echo -),$(disk_temp),$(echo "$prev $cur" | awk '{printf "%.1f,%.1f", ($3-$1)*512/1e6, ($4-$2)*512/1e6}')"
    prev=$cur
  done
}

# ---- snapshots ----------------------------------------------------------------
snapshot() { # pre|post
  local p=$1
  if command -v smartctl >/dev/null 2>&1; then
    smartctl -a "${SMART_OPTS[@]}" "$DEV" > "$OUT/$p-smartctl.txt" 2>&1
    smartctl -a -j "${SMART_OPTS[@]}" "$DEV" > "$OUT/$p-smartctl.json" 2>/dev/null
    [ "$IS_NVME" -eq 0 ] && smartctl -l error "${SMART_OPTS[@]}" "$DEV" > "$OUT/$p-smart-errlog.txt" 2>&1
  fi
  if [ "$IS_NVME" -eq 1 ] && command -v nvme >/dev/null 2>&1; then
    nvme smart-log "/dev/$CTRL" > "$OUT/$p-nvme-smartlog.txt" 2>&1 || nvme smart-log "$DEV" > "$OUT/$p-nvme-smartlog.txt" 2>&1
  fi
  local pat="$DISK|ata[0-9]+|I/O error|blk_update|AER"
  [ -n "$CTRL" ] && pat="$pat|$CTRL"
  dmesg -T 2>/dev/null | grep -E "$pat" | tail -60 > "$OUT/$p-dmesg.txt"
}
log "pre-test snapshot (SMART, kernel log)"
snapshot pre
# Full model name: sysfs/SCSI inquiry truncates ATA models to 16 characters.
FULLMODEL=$(sed -nE 's/^(Device Model|Model Number|Product):[[:space:]]*//p' "$OUT/pre-smartctl.txt" 2>/dev/null | head -1 | sed 's/[[:space:]]*$//')
[ -n "$FULLMODEL" ] || FULLMODEL=$(lsblk -dno MODEL "$DEV" 2>/dev/null | head -1 | sed 's/[[:space:]]*$//')
[ -n "$FULLMODEL" ] && meta dev_model "$FULLMODEL"
START_TS=$(date '+%F %T')

# link speed / queue / cache info
{
  if [ "$IS_NVME" -eq 1 ]; then
    for k in current_link_speed current_link_width max_link_speed max_link_width; do
      echo "$k: $(cat "/sys/class/nvme/$CTRL/device/$k" 2>/dev/null || echo n/a)"; done
  fi
} > "$OUT/link.txt"
if [ "$IS_NVME" -eq 1 ]; then
  CS=$(cat "/sys/class/nvme/$CTRL/device/current_link_speed" 2>/dev/null); CW=$(cat "/sys/class/nvme/$CTRL/device/current_link_width" 2>/dev/null)
  MS=$(cat "/sys/class/nvme/$CTRL/device/max_link_speed" 2>/dev/null); MW=$(cat "/sys/class/nvme/$CTRL/device/max_link_width" 2>/dev/null)
  if [ -n "$CS" ]; then
    meta pcie_current "$CS x$CW"; meta pcie_max "$MS x$MW"; meta pcie_width "$CW"
    case "${CS%% *}" in 2.5) G=1;; 5.0|5) G=2;; 8.0|8) G=3;; 16.0|16) G=4;; 32.0|32) G=5;; 64.0|64) G=6;; *) G="";; esac
    meta pcie_gen "$G"
  else
    skip link "NVMe PCIe link not readable from sysfs (e.g. behind a VMD / RAID controller)"
  fi
  BDF=$(basename "$(readlink -f "/sys/class/nvme/$CTRL/device" 2>/dev/null)")
  if command -v lspci >/dev/null 2>&1 && [ -n "$BDF" ]; then lspci -vv -s "$BDF" > "$OUT/lspci-nvme.txt" 2>&1; grep -E 'LnkCap:|LnkSta:' "$OUT/lspci-nvme.txt" >> "$OUT/link.txt"; fi
elif command -v smartctl >/dev/null 2>&1; then
  SL=$(grep -m1 '^SATA Version is:' "$OUT/pre-smartctl.txt" 2>/dev/null | sed 's/^SATA Version is:[[:space:]]*//')
  meta sata_link "$SL"; echo "SATA: ${SL:-n/a}" >> "$OUT/link.txt"
  if [[ "$SL" =~ ([0-9.]+)\ Gb/s\ \(current:\ ([0-9.]+)\ Gb/s\) ]] && [ "${BASH_REMATCH[1]}" != "${BASH_REMATCH[2]}" ]; then
    warn "SATA link negotiated at ${BASH_REMATCH[2]} Gb/s, below the drive's ${BASH_REMATCH[1]} Gb/s (cable/port?)"
  fi
  RPM=$(grep -m1 '^Rotation Rate:' "$OUT/pre-smartctl.txt" 2>/dev/null | grep -oE '[0-9]+'); meta rotation_rpm "${RPM:-}"
  WC=$(smartctl -g wcache "${SMART_OPTS[@]}" "$DEV" 2>/dev/null | grep -i 'Write cache' | sed 's/.*:[[:space:]]*//'); meta write_cache "$WC"
fi
for k in scheduler nr_requests max_sectors_kb rotational zoned; do echo "$k $(cat "/sys/block/$DISK/queue/$k" 2>/dev/null)"; done > "$OUT/queue.txt"

# ZFS caveats (read-only)
ZFS_DS=""
arc_counts() { awk '$1=="hits"{h=$3} $1=="misses"{m=$3} END{print (h+0)":"(m+0)}' /proc/spl/kstat/zfs/arcstats 2>/dev/null; }
if [ "$FSTYPE" = zfs ]; then
  ZFS_DS="$FSSRC"; meta zfs_dataset "$ZFS_DS"
  ZD=$(zfs get -H -o value direct "$ZFS_DS" 2>/dev/null)
  meta zfs_direct "${ZD:-unsupported}"
  meta zfs_recordsize "$(zfs get -H -o value recordsize "$ZFS_DS" 2>/dev/null)"
  meta zfs_compression "$(zfs get -H -o value compression "$ZFS_DS" 2>/dev/null)"
  meta zfs_arc_c_max "$(awk '$1=="c_max"{print $3}' /proc/spl/kstat/zfs/arcstats 2>/dev/null)"
  zfs get all "$ZFS_DS" > "$OUT/zfs.txt" 2>&1; zpool status -P "${ZFS_DS%%/*}" >> "$OUT/zfs.txt" 2>&1
  case "$ZD" in
    standard|always) note "ZFS: direct=$ZD, O_DIRECT is honoured (OpenZFS 2.3+) but ZFS checksumming/CoW still adds overhead; results reflect the pool, not just the raw disk" ;;
    disabled) warn "ZFS: direct=disabled on $ZFS_DS, so O_DIRECT is ignored and READ results are served largely from the ARC (RAM); read scores are not disk speed" ;;
    *) note "ZFS: this OpenZFS version ignores O_DIRECT; READ results may come from the ARC (RAM), see zfs_arc_hit_pct per test; treat read scores as upper bounds" ;;
  esac
fi

# ---- fio engine / direct probe ------------------------------------------------------
ENGINE=""; DIRECT=1
if [ "$MODE" = file ]; then
  TF_CREATED=1   # from here the file may exist and is ours (name verified unused above)
  # Record it so cleanup.sh can remove it even if this script is killed with SIGKILL.
  STRESS_HOME="${STRESS_HOME:-/root/pve-stresstest}"
  mkdir -p "$STRESS_HOME" 2>/dev/null && printf '%s\n' "$TF" >> "$STRESS_HOME/.testfiles" 2>/dev/null
  for d in 1 0; do
    for e in io_uring libaio psync; do
      if timeout 60 fio --name=probe --filename="$TF" --size=16M --rw=write --bs=1M --direct=$d --ioengine=$e \
           --iodepth=1 --output-format=terse >> "$OUT/probe.log" 2>&1; then ENGINE=$e; DIRECT=$d; break 2; fi
    done
  done
  [ -n "$ENGINE" ] || refuse "fio could not write a test file on $TPATH with io_uring, libaio or psync (see probe.log)"
  [ "$DIRECT" -eq 0 ] && warn "O_DIRECT not supported on $TPATH: results include the page cache and overstate reads"
else
  # read-only probe: fio --readonly makes fio itself refuse any write to the device
  FIOHELP=$(fio --help 2>&1)
  [[ "$FIOHELP" == *--readonly* ]] || refuse "this fio build has no --readonly option; refusing raw-device tests"
  for e in io_uring libaio psync; do
    if timeout 60 fio --name=probe --readonly --filename="$DEV" --size=16M --rw=read --bs=1M --direct=1 --ioengine=$e \
         --iodepth=1 --output-format=terse >> "$OUT/probe.log" 2>&1; then ENGINE=$e; break; fi
  done
  [ -n "$ENGINE" ] || refuse "fio could not read $DEV with O_DIRECT (io_uring, libaio or psync); see probe.log"
fi
[ "$ENGINE" != io_uring ] && warn "fio engine io_uring unavailable, using $ENGINE"
meta engine "$ENGINE"; meta direct "$DIRECT"
log "fio engine $ENGINE, direct=$DIRECT"

# ---- start telemetry --------------------------------------------------------------
echo idle > "$OUT/.phase"
sampler > "$OUT/telemetry-1s.csv" 2>/dev/null &
SAMPLER_PID=$!
sleep 3

# ---- job runner ---------------------------------------------------------------------
secs() { local s=$(( (DURATION * $1 + 50) / 100 )); [ "$s" -lt 4 ] && s=4; echo "$s"; }
if [ "$MODE" = file ]; then
  FIO_COMMON=(--filename="$TF" --direct="$DIRECT" --ioengine="$ENGINE" --group_reporting
              --percentile_list=50:99:99.9 --log_avg_msec=1000 --output-format=json)
else
  FIO_COMMON=(--readonly --filename="$DEV" --direct=1 --ioengine="$ENGINE" --group_reporting
              --percentile_list=50:99:99.9 --log_avg_msec=1000 --output-format=json)
fi
# HARD GUARD (readonly mode): refuse to start any fio job that could write.
# fio --readonly already makes fio reject writes; this is a second, independent check.
ro_guard() { # fio args...
  local a rw=0 ro=0 fn=0
  if [ "$MODE" = file ]; then
    # file mode: every job must target exactly our own test file, never a device node
    for a in "${FIO_COMMON[@]}" "$@"; do
      case "$a" in
        --filename=*) [ "$a" = "--filename=$TF" ] && fn=$((fn + 1)) || fm_abort "$a" ;;
        --directory=*|--opendir=*|--filename_format=*) fm_abort "$a" ;;
      esac
    done
    [ "$fn" -eq 1 ] || fm_abort "job must target exactly --filename=$TF"
    { [ -b "$TF" ] || [ -c "$TF" ] || [ -L "$TF" ]; } && fm_abort "$TF is a device node or symlink"
    case "$TF" in /dev/*|/proc/*|/sys/*) fm_abort "$TF" ;; esac
    return 0
  fi
  for a in "${FIO_COMMON[@]}" "$@"; do
    case "$a" in
      --readonly|--readonly=1) ro=1 ;;
      --readonly=*) ro_abort "$a" ;;
      --rw=read|--rw=randread|--readwrite=read|--readwrite=randread) rw=$((rw + 1)) ;;
      --rw=*|--readwrite=*|-rw*) ro_abort "$a" ;;
      --directory=*|--opendir=*|--filename_format=*|--verify*|--do_verify*|--trim*|--fill_device*|--fill_fs*|--create_*|--allow_file_create*|--zonemode*|--zone_reset*|--overwrite*|--unlink*|--file_append*|--fallocate*) ro_abort "$a" ;;
      --filename=*) [ "$a" = "--filename=$DEV" ] && fn=$((fn + 1)) || ro_abort "$a" ;;
    esac
  done
  [ "$ro" -eq 1 ] || ro_abort "missing --readonly"
  [ "$rw" -eq 1 ] || ro_abort "job must have exactly one --rw=read|randread (found $rw)"
  [ "$fn" -eq 1 ] || ro_abort "job must target exactly --filename=$DEV"
}
fm_abort() {
  errr "SAFETY GUARD: file mode refused a fio job that does not target the skill's own test file ($1). Nothing was written."
  refuse "safety guard: file-mode fio job not on the test file ($1)"
}
ro_abort() {
  errr "SAFETY GUARD: readonly mode refused a fio job that is not a pure read ($1). Nothing was written."
  refuse "safety guard: non-read fio job in readonly mode ($1)"
}
run_job() { # idx name label scored refkey -- fio args...
  local idx=$1 name=$2 label=$3 scored=$4 refkey=$5; shift 5
  local base="$OUT/fio-$idx-$name" arc0="" arc1="" rc
  ro_guard "$@"
  echo "$name" > "$OUT/.phase"
  printf '%s\t%s\t%s\t%s\t%s\n' "$idx" "$name" "$label" "$scored" "$refkey" >> "$OUT/.tests"
  [ -n "$ZFS_DS" ] && arc0=$(arc_counts)
  log "fio $label"
  timeout $(( DURATION + 600 )) fio --name="$name" "${FIO_COMMON[@]}" --write_bw_log="$base" --output="$base.json" "$@" 2> "$base.err"
  rc=$?
  if [ -n "$ZFS_DS" ] && [ -n "$arc0" ]; then
    arc1=$(arc_counts); meta "arc_$name" "$(( ${arc1%%:*} - ${arc0%%:*} )):$(( ${arc1##*:} - ${arc0##*:} ))"
  fi
  [ "$rc" -eq 0 ] || errr "fio $label exited with code $rc (see $(basename "$base").err)"
  return 0
}
link_under_load() { # NVMe: sample the PCIe link 3 s into the first loaded job
  [ "$IS_NVME" -eq 1 ] || return 0
  ( sleep 3; { echo "current_link_speed: $(cat "/sys/class/nvme/$CTRL/device/current_link_speed" 2>/dev/null)"
               echo "current_link_width: $(cat "/sys/class/nvme/$CTRL/device/current_link_width" 2>/dev/null)"; } > "$OUT/link-under-load.txt" ) &
}

RAND=(--randrepeat=0 --norandommap)
if [ "$MODE" = readonly ]; then
  # ---- read-only raw-device jobs (whole device, time based) ------------------------
  RO=(--offset=0 --time_based)
  if [ "$PROFILE" = hdd ]; then
    run_job 01 seqread       "Seq read 1M QD8 (raw, outer tracks)" 1 seqread   "${RO[@]}" --rw=read --bs=1M --iodepth=8 --runtime="$(secs 40)"
    run_job 02 randread_qd32 "Rand read 4K QD32 (raw, full stroke)" 0 none     "${RO[@]}" "${RAND[@]}" --rw=randread --bs=4k --iodepth=32 --runtime="$(secs 30)"
    run_job 03 randread_qd1  "Rand read 4K QD1 (raw, full stroke)"  0 randread_qd1 "${RO[@]}" "${RAND[@]}" --rw=randread --bs=4k --iodepth=1 --runtime="$(secs 30)"
  else
    link_under_load
    run_job 01 seqread      "Seq read 1M QD32 (raw)"     1 seqread      "${RO[@]}" --rw=read --bs=1M --iodepth=32 --runtime="$(secs 35)"
    run_job 02 randread     "Rand read 4K QD32 x4 (raw)" 1 randread     "${RO[@]}" "${RAND[@]}" --rw=randread --bs=4k --iodepth=32 --numjobs=4 --runtime="$(secs 35)"
    run_job 03 randread_qd1 "Rand read 4K QD1 (raw)"     1 randread_qd1 "${RO[@]}" "${RAND[@]}" --rw=randread --bs=4k --iodepth=1 --runtime="$(secs 30)"
  fi
else
  # ---- fill / prep ------------------------------------------------------------------
  if [ "$PROFILE" = hdd ]; then FILL_QD=8; else FILL_QD=32; fi
  FILL_SCORED=0; [ "$PROFILE" = hdd ] && FILL_SCORED=1
  run_job 00 fill "Fill write 1M QD$FILL_QD ($(( SIZE / 1048576 )) MiB)" "$FILL_SCORED" fill \
    --rw=write --bs=1M --iodepth=$FILL_QD --size="$SIZE" --end_fsync=1 --runtime=180
  sync; sleep 2
  ACTUAL=$(stat -c %s "$TF" 2>/dev/null || echo 0)
  if [ "$ACTUAL" -lt "$SIZE" ]; then
    warn "fill stopped after 180 s at $((ACTUAL/1048576)) MiB of $((SIZE/1048576)) MiB (slow device); tests use the written part"
    SIZE=$(( ACTUAL / 1048576 * 1048576 )); meta size_bytes "$SIZE"
  fi
  [ "$SIZE" -ge 67108864 ] || refuse "the fill write produced only $((ACTUAL/1048576)) MiB; device too slow or failing (see fio-00-fill.err)"

  JOB=(--size="$SIZE" --allow_file_create=0 --time_based)
  if [ "$PROFILE" = hdd ]; then
    run_job 01 seqread  "Seq read 1M QD8"       1 seqread      "${JOB[@]}" --rw=read      --bs=1M --iodepth=8  --runtime="$(secs 20)"
    run_job 02 seqwrite "Seq write 1M QD8"      1 seqwrite     "${JOB[@]}" --rw=write     --bs=1M --iodepth=8  --runtime="$(secs 20)"
    run_job 03 randread_qd1  "Rand read 4K QD1"  0 randread_qd1 "${JOB[@]}" "${RAND[@]}" --rw=randread  --bs=4k --iodepth=1  --runtime="$(secs 20)"
    run_job 04 randread_qd32 "Rand read 4K QD32" 0 none        "${JOB[@]}" "${RAND[@]}" --rw=randread  --bs=4k --iodepth=32 --runtime="$(secs 15)"
    run_job 05 randwrite_qd32 "Rand write 4K QD32" 0 none      "${JOB[@]}" "${RAND[@]}" --rw=randwrite --bs=4k --iodepth=32 --runtime="$(secs 25)"
  else
    link_under_load
    run_job 01 seqread   "Seq read 1M QD32"        1 seqread   "${JOB[@]}" --rw=read  --bs=1M --iodepth=32 --runtime="$(secs 25)"
    run_job 02 seqwrite  "Seq write 1M QD32"       1 seqwrite  "${JOB[@]}" --rw=write --bs=1M --iodepth=32 --runtime="$(secs 25)"
    run_job 03 randread  "Rand read 4K QD32 x4"    1 randread  "${JOB[@]}" "${RAND[@]}" --rw=randread  --bs=4k --iodepth=32 --numjobs=4 --runtime="$(secs 20)"
    run_job 04 randwrite "Rand write 4K QD32 x4"   1 randwrite "${JOB[@]}" "${RAND[@]}" --rw=randwrite --bs=4k --iodepth=32 --numjobs=4 --runtime="$(secs 20)"
    run_job 05 randread_qd1 "Rand read 4K QD1"     1 randread_qd1 "${JOB[@]}" "${RAND[@]}" --rw=randread --bs=4k --iodepth=1 --runtime="$(secs 10)"
  fi
fi

# NVMe link under load (some platforms lower PCIe speed at idle, so judge it loaded)
if [ "$IS_NVME" -eq 1 ] && [ -n "${CS:-}" ]; then
  LCS=$(sed -n 's/^current_link_speed: *//p' "$OUT/link-under-load.txt" 2>/dev/null); LCW=$(sed -n 's/^current_link_width: *//p' "$OUT/link-under-load.txt" 2>/dev/null)
  [ -n "$LCS" ] && [ -n "$LCW" ] || { LCS=$CS; LCW=$CW; }
  echo "under load: $LCS x$LCW" >> "$OUT/link.txt"
  meta pcie_current "$LCS x$LCW"; meta pcie_width "$LCW"
  case "${LCS%% *}" in 2.5) G=1;; 5.0|5) G=2;; 8.0|8) G=3;; 16.0|16) G=4;; 32.0|32) G=5;; 64.0|64) G=6;; *) G="";; esac
  meta pcie_gen "$G"
  if [ "$LCS" != "$MS" ] || [ "$LCW" != "$MW" ]; then
    warn "NVMe link under load is $LCS x$LCW, below the device maximum $MS x$MW (slot wired for fewer lanes, chipset slot, riser, or BIOS setting). Normal if the slot/CPU supports less than the drive."
  fi
fi

echo cooldown > "$OUT/.phase"; sync; sleep 5
kill "$SAMPLER_PID" 2>/dev/null; wait "$SAMPLER_PID" 2>/dev/null; SAMPLER_PID=""

# ---- delete test file now (trap is the safety net) ------------------------------
if [ "$MODE" = file ]; then
  rm -f -- "$TF"; sync
  if [ -e "$TF" ]; then errr "could not delete test file $TF"; meta testfile_deleted "no"
  else echo "deleted: $TF (verified absent)" > "$OUT/testfile-deleted.txt"; meta testfile_deleted "yes"; TF_CREATED=0; fi
  df -hT "$TPATH" > "$OUT/df-post.txt" 2>&1
else
  meta testfile_deleted "n/a (readonly mode, no test file)"
fi

log "post-test snapshot"
snapshot post
journalctl -k --since "$START_TS" -p warning --no-pager > "$OUT/journal-warnings.txt" 2>&1
if grep -qiE "($DISK|${CTRL:-__none__}).*(error|timeout|reset)|I/O error|blk_update_request|ata[0-9]+.*(exception|failed|hard resetting)" "$OUT/journal-warnings.txt"; then
  warn "kernel logged disk/I/O warnings during the test (see journal-warnings.txt)"
fi
if [ "$PROFILE" = hdd ] && [ "$MODE" = readonly ]; then
  note "HDD read-only: random reads span the whole disk (full stroke), so QD1 IOPS is normally realistic seek-bound performance; random results are reported, not scored. A random-read result with a median latency under ~4 ms is marked valid=false (it read unwritten/unmapped or cached regions, e.g. on an SMR drive). Sequential read starts at LBA 0 (outer, fastest tracks)."
elif [ "$PROFILE" = hdd ]; then
  note "HDD: random results use a small file near one region of the disk, so they flatter the drive; random write QD32 mostly measures the drive's write cache (and the SMR media cache on SMR drives), not the platters. If 'sustain_ratio' on fill/random write drops well below 1, the cache filled up (typical of SMR). Not scored."
fi

STATUS="ok"
write_summary
log "done: $(grep -m1 '^score' "$OUT/summary.txt" 2>/dev/null)"
cat "$OUT/summary.txt"
exit 0
