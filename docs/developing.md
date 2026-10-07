# Developing the skill

This page is for people who want to change, extend or audit the skill. If you only want to use it, see [installation.md](installation.md).

## Repository layout

| Path | What it is | Edit it? |
|---|---|---|
| `skill/proxmox-hardware-stress-test/` | The skill itself, the source of truth | **Yes**, this is where all changes go |
| `dist/` | `proxmox-hardware-stress-test.skill`, `proxmox-hardware-stress-test.zip`, `SHA256SUMS` | **No**, regenerate with `tools/build.sh` |
| `tools/build.sh` | Packs the skill folder into `dist/` and writes the checksums | Only to change packaging |
| `docs/` | These guides | Yes, keep them in step with the skill |
| `.github/` | Issue and PR templates, CI workflow | As needed |

How the three forms of the skill relate is explained in [packages-explained.md](packages-explained.md).

Inside the skill:

| Path | Role |
|---|---|
| `SKILL.md` | The workflow Claude follows. Keep it about *what to do and why*; details live in the script headers and `references/` |
| `references/*.md` | Loaded by Claude only when needed: report template and scoring, reference values, safety and troubleshooting |
| `assets/report-template.html` | The HTML report design; its header comment holds the fill rules |
| `scripts/` | Everything that runs. All but `finish_report.py` run **on the Proxmox host as root** |

## Working on the skill locally

Point Claude Code at your working copy with a symlink instead of a copy, so every edit is live in the next session:

```bash
mkdir -p ~/.claude/skills
rm -rf ~/.claude/skills/proxmox-hardware-stress-test        # remove an old copy first
ln -s "$PWD/skill/proxmox-hardware-stress-test" ~/.claude/skills/proxmox-hardware-stress-test
```

Run this from the repository root. Use a **test host** you can afford to load, never a production box during working hours.

## Script conventions

Follow these when you add or change a script. They are what keep the skill safe and the reports consistent.

### Headers and flags
- Every script starts with a **header comment** that documents usage and flags, what it measures (in order), how long it takes, its outputs, safety rules and exit codes. `--help` prints that header. Claude reads the header instead of guessing, so keep it accurate.
- Bash scripts use `set -u` and `set -o pipefail`, and run under `LC_ALL=C` where parsing depends on it.
- Part scripts take `--duration SECONDS` (the sustained stress phase; benchmarks add a bounded extra) and `--out DIR`.
- `--no-install` means "never call apt; skip the sub-test instead". All installs happen once, in `prep.sh` (`gpu.sh` never installs anything).
- Exit codes: `0` = ran (individual sub-tests may still be skipped, see `summary.json`); `2` = bad usage for the part scripts (`prep.sh`/`cleanup.sh` use `1`); `3` = refused for safety (`disk.sh`) or skipped something for safety (`cleanup.sh`).

### `telemetry.sh`, the shared API
Source it, don't execute it:

```bash
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$SCRIPT_DIR/telemetry.sh"
tel_init                                        # once, in the main shell
trap 'tel_sampler_stop; tel_cleanup' EXIT       # your own trap; telemetry.sh sets none
```

The **stable public interface** is listed in the file's header. The parts you'll use most:

| Group | Functions |
|---|---|
| CPU | `cpu_power`, `cpu_temp`, `cpu_mhz`, `cpu_mhz_hybrid`, `cpu_busy`, `cpu_throttle`, per-socket `cpu_power_sockets` / `cpu_temp_sockets` |
| Memory / GPU | `mem_usage`; `gpu_count`, `gpu_list`, `gpu_query [IDX]` (10 fields in `TEL_GPU_FIELDS` order, any vendor); `gpu_query_ext IDX` (17 AMD/Intel fields in `TEL_GPU_EXT_FIELDS` order); `gpu_index_for_pci`, `gpu_is_integrated_pci`, `gpu_util_helper_start` / `gpu_util_helper_stop` (optional `intel_gpu_top` / `radeontop`) |
| Disks | `disk_temp`, `disk_io`, `disk_kind`, `path_disks`, `fs_type`, `fs_avail_bytes`, `disk_smart_snapshot`, `smart_brief` |
| Hardware errors | `hw_error_snapshot`, `hw_error_diff A B` |
| 1 Hz sampler | `tel_sampler_start FILE [cpu mem gpu[:IDX] disk:DEV sockets]`, `tel_phase NAME`, `tel_sampler_stop` |
| CSV | `csv_init`, `csv_row`, `csv_safe`, `csv_stats`, `csv_stats_json` |
| JSON / summary | `json_str`, `json_num`, `json_bool`, `json_arr_str`; `tel_warn`, `tel_error`, `tel_skip TEST REASON`; `summary_write` |

Rules: a missing sensor returns the literal string `n/a` and **never** makes a function fail. Nothing in `telemetry.sh` writes to block devices or changes a setting. Call `tel_warn` / `tel_error` / `tel_skip` in the main shell, not inside `$(...)`, or the record is lost.

### `summary.json`
Every part writes `summary.json` in its `--out` folder. `summary_write FILE PART DURATION_S METRICS_JSON [STATUS] [EXTRA]` produces:

```json
{"part": "...", "status": "ok|partial|error|skipped", "duration_s": 60, "generated": "...",
 "metrics": { }, "warnings": [], "errors": [], "skipped": []}
```

Status defaults to `error` if there are errors, `partial` if something was skipped, else `ok`. Claude reads these files to give progress updates and write the report, and [`references/report-template.md`](../skill/proxmox-hardware-stress-test/references/report-template.md) section 5 maps report items to fields. A result that must not be scored (cache-resident bandwidth, ARC-served reads, impossible HDD seeks) gets `"valid": false` plus a reason; don't drop it silently. **Never put serial numbers in `summary.json`.**

### Disk test files
- Every test file name **must start with** `pve-stresstest-fio` (`TEL_TESTFILE_PREFIX`); `disk.sh` uses `.pve-stresstest-fio-<pid>.tmp`. `cleanup.sh` finds leftovers by that name and deletes nothing else.
- Register each file with `testfile_register PATH` (it goes into `/root/pve-stresstest/.testfiles`) and delete it in an `EXIT` trap that also covers INT/TERM/HUP.
- Write tests only ever target the skill's own test file inside a mounted filesystem. Raw devices are read only, through `disk.sh --mode readonly` (fio `--readonly` plus a guard that refuses any non-read job).

### Package ledger
- `prep.sh` installs from the host's configured apt repos only and appends every package that **was not installed before** (dependencies included) to `RUN/installed-packages.txt`. Part scripts that install anything append to the same file (`DIR/../installed-packages.txt`).
- `cleanup.sh` removes exactly that list: it simulates `apt` first, refuses if anything unlisted would go, and never removes protected packages (Proxmox, PVE, kernel, ZFS, NVIDIA, systemd, apt and similar).
- `prep.sh` writes a `.pve-stresstest-root` marker into the working folder; `cleanup.sh` only deletes a working folder that has it (or a `hardware.json`).
- Tool caches go into the working folder (for example `/root/pve-stresstest/.gpu-cache`), never into `/root/.cache` or similar.

### Other conventions
- `cpu.sh` doubles as a library: `CR_LIB_ONLY=1 . cpu.sh` defines its `cr_*` helpers without running anything (`ram.sh` uses this).
- `inventory.json` / `inventory.md` must stay **report-safe**: no hostname, no IP addresses, serials and MACs masked to the last 4 characters, guests by ID only.
- Hardware-specific workarounds go in a `LESSONS` block in the script header, so the next person knows why the code looks the way it does.

## The developer-only mock hook (`PVE_STRESS_MOCK_DIR`)

`inventory.py` (the inventory and test planner) has a test hook so you can check the planning logic against simulated hosts on any machine, no Proxmox server needed. It is **never used in a real run**.

When the environment variable `PVE_STRESS_MOCK_DIR` points at a fixture folder:
- every file path the script reads (`/sys`, `/proc`, `/dev`, `/etc/pve`, mount points) is read from `<fixture>/root/...` instead;
- every command's output comes from `<fixture>/commands.json`, a map of `{"<exact command line>": "output text"}` or `{"<command line>": "@relative/file"}`. A command that isn't listed is treated as not installed;
- the hostname comes from the `"hostname"` entry (default `mock-node`); a directory containing a `.mock-readonly` file counts as not writable.

`inventory.py` also needs `hardware.json` (normally written by `prep.sh`) in its `--out` folder, and it **adds keys to that file**, so always work on a copy:

```bash
FIX=path/to/fixtures/dual-socket-hba          # your fixture folder: root/, commands.json, hardware.json
OUT=$(mktemp -d)
cp "$FIX/hardware.json" "$OUT/"
PVE_STRESS_MOCK_DIR="$FIX" python3 skill/proxmox-hardware-stress-test/scripts/inventory.py \
  --out "$OUT" --duration 60 --mode plan-only
cat "$OUT/plan.md"
```

Good fixtures to keep around: a mini PC with one SSD, a dual-socket server, an HBA with many SATA disks, a hardware RAID controller, ZFS/Ceph/mdraid members, a GPU passed through to a VM, a GPU shared with containers. The repository doesn't ship fixtures yet; if you add some, scrub them of real serials, hostnames and IP addresses first.

## The developer-only fake-root hook for the shell scripts (`PVE_STRESS_SYSFS_ROOT`)

`telemetry.sh`, `gpu.sh` and `prep.sh` have a matching hook for the GPU code, so the AMD and Intel paths can be exercised without the hardware. It is **never set in a real run**; unset (or `/`) means the real files.

When `PVE_STRESS_SYSFS_ROOT=DIR` is set, these **reads** come from `DIR/...` instead of `/...` (nothing is ever written there):

| Script | Paths redirected |
|---|---|
| `telemetry.sh` | GPU detection (`/sys/class/drm/card*`), `gpu_query_ext`, `gpu_is_integrated_pci` (`/sys/bus/pci/devices`), RAPL including the iGPU's `uncore` domain (`/sys/class/powercap`, `amd_energy` hwmon) |
| `gpu.sh` | `/sys/bus/pci/devices` (enumeration and render nodes), `/dev/dri`, `/etc/OpenCL/vendors`, `/etc/pve/lxc` (also passed on to `telemetry.sh`) |
| `prep.sh` | GPU detection, `/etc/OpenCL/vendors` and `/etc/os-release` (the Debian codename that picks the OpenCL runtime packages) |

Commands are **not** redirected: put fake executables first on `PATH` instead (`lspci`, `nvidia-smi`, `clinfo`, `hashcat`, `clpeak`, `dmesg`, `intel_gpu_top`, and for the package planning `apt-cache`, `apt-get` (simulation only), `dpkg-query`, `dpkg --compare-versions`). On macOS also put a bash 5 build, GNU-style `timeout` and Debian's default `mawk` (as `awk`) on `PATH`, so the scripts run with the same shell and awk as on the host.

A fake sysfs tree needs, per GPU: `sys/bus/pci/devices/<addr>/{class,vendor,device}`, a `driver` symlink whose target is named after the driver (`amdgpu`, `i915`, `xe`, `nvidia`, `vfio-pci`), `drm/cardN` and `drm/renderDN` folders (each with a `device -> ../..` symlink), `sys/class/drm/cardN` linking to that folder, and the sensor files the vendor uses (amdgpu: `hwmon/hwmon*/temp*_{input,label}`, `power1_average` or `power1_input`, `gpu_busy_percent`, `pp_dpm_sclk`, `mem_info_vram_*`; i915: `gt_act_freq_mhz`, `gt_max_freq_mhz`, `gt/gt0/throttle_reason_*`; xe: `tile0/gt0/freq0/{act_freq,max_freq,throttle/*}` and an `energy1_input` hwmon). `etc/OpenCL/vendors/*.icd` decides which runtimes `gpu.sh` probes; `prep.sh` also needs `etc/os-release`. Run `prep.sh` from a copy of the scripts with only the root check removed, together with `PVE_STRESS_MOCK_DIR` for `inventory.py`, and with `--plan-only`.

Scenarios worth keeping: an AMD card on Mesa rusticl (with and without PCI info in `clinfo`), an AMD card with ROCm installed, an AMD APU, an Intel Arc card on `xe` and on `i915`, an Intel iGPU (RAPL `uncore` power, throttle reasons, no FP64), an old Gen7 iGPU, NVIDIA plus AMD in one box, two cards of the same vendor without PCI info, and a card bound to `vfio-pci`. For the package planning, vary the Debian release, `bookworm-backports`, and a simulated install that would upgrade an installed package or pull a firmware package. Keep the fixtures outside the repository, or scrub them of real serials, hostnames and addresses first.

## Adding a new test

1. **Pick the right place.** A new sub-test for an existing part goes into that part's script (`cpu.sh`, `ram.sh`, `gpu.sh`, `disk.sh`). A brand-new kind of unit also needs planning code in `inventory.py` (a `method_id`, ready-to-run `command`, `est_s` estimate, `reason` for skips).
2. **Tools:** if it needs a new package, add it to the install list in `prep.sh` (so it lands in the ledger and gets removed), and make the part script skip the sub-test with `tel_skip` when the tool is missing or `--no-install` is set.
3. **Measure safely:** bounded time (a hard timeout), `tel_phase <name>` so the CSV shows when it ran, `n/a` for missing sensors, no writes outside the skill's own files.
4. **Record results** in the `metrics` passed to `summary_write`; mark untrustworthy figures `"valid": false` with a reason.
5. **Document it:** the script header (what it measures, time, outputs), the time estimate in `inventory.py`, the scoring table and "where the numbers come from" in `references/report-template.md`, the HTML template if it needs a new element, `SKILL.md` only if the workflow changes, and these docs.

## Adding a reference value

Reference values live in [`references/reference-values.md`](../skill/proxmox-hardware-stress-test/references/reference-values.md) (starter tables for CPUs, RAM platforms, GPUs, SSDs and HDDs).

- Add only **manufacturer spec-sheet figures or well-known published results**, for the exact model and variant (capacity matters for SSDs). Write "look up" rather than guess.
- Note any conditions that matter (queue depth, SLC cache, power limits, CMR vs SMR for hard drives).
- Mention the source in your pull request so reviewers can check it.
- `disk.sh` has its own rough **class references** (used only when no datasheet value is available); change those only with a good reason, and keep the table in `reference-values.md` section 4.4 in step.

## Running checks locally

From the repository root:

```bash
S=skill/proxmox-hardware-stress-test/scripts

# Bash syntax
for f in "$S"/*.sh; do bash -n "$f" && echo "ok  $f"; done

# Lint (install: brew install shellcheck / apt install shellcheck)
shellcheck -x "$S"/*.sh

# Python syntax (compiles in memory, writes no __pycache__ into the skill folder)
python3 -c 'import sys; [compile(open(f).read(), f, "exec") for f in sys.argv[1:]]; print("ok", *sys.argv[1:])' "$S"/*.py

# C sources compile (on Linux; ram.sh builds them on the host with these flags)
gcc -O3 -fopenmp -o /dev/null "$S"/stream.c -lm
gcc -O2 -o /dev/null "$S"/latency.c

# The HTML template still has its placeholders (the filled report must have none)
grep -c '{{' skill/proxmox-hardware-stress-test/assets/report-template.html
```

`python3 -m py_compile file.py` also works but leaves a `__pycache__` folder inside the skill; delete it before building. The CI workflow in `.github/workflows/ci.yml` runs checks like these on every push and pull request.

## Rebuilding `dist/`

Whenever anything under `skill/proxmox-hardware-stress-test/` changes:

```bash
bash tools/build.sh
```

It repacks the folder into `dist/proxmox-hardware-stress-test.skill` and `dist/proxmox-hardware-stress-test.zip` and rewrites `dist/SHA256SUMS`. Commit the skill change and the rebuilt `dist/` together. To check: `unzip -l dist/proxmox-hardware-stress-test.zip` and `cd dist && shasum -a 256 -c SHA256SUMS` (or `sha256sum -c`).

## Release checklist

1. [ ] All checks above pass (`bash -n`, `shellcheck`, Python compile, C compile).
2. [ ] Tested on a real Proxmox host, at least a 30-second run end to end: plan-only, full run, logs VERIFIED, reports made, cleanup reports "Working dir: deleted" and removes only the ledger's packages.
3. [ ] If the planner changed: checked against mock fixtures (`PVE_STRESS_MOCK_DIR`) for the layouts it affects; if GPU code changed, against fake hosts (`PVE_STRESS_SYSFS_ROOT`, see above).
4. [ ] Script headers, `SKILL.md`, `references/`, the skill's `README.md` and `docs/` match the new behaviour.
5. [ ] No personal data anywhere: no real hostnames, IP addresses (use `192.0.2.x` examples), serials, usernames or local paths; sample numbers clearly marked as made-up examples.
6. [ ] No stray files in the skill folder (`__pycache__`, `.DS_Store`, editor backups, test output).
7. [ ] `bash tools/build.sh` run; `dist/` contents match the folder; checksums verify.
8. [ ] `CHANGELOG.md` updated with the version and date.
9. [ ] Commit, tag (for example `v1.1.0`) and push; optionally attach the `.skill`, `.zip` and `SHA256SUMS` to a GitHub release.
