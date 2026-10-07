# How it works

This page follows a run from start to finish, as laid out in the skill's [`SKILL.md`](../skill/proxmox-hardware-stress-test/SKILL.md). In short: Claude asks two questions, checks SSH, makes an inventory and test plan **without touching anything**, waits for your yes, then tests each part one at a time, copies the logs back, writes the reports and cleans up.

```
 You ──ask──> Claude (your computer) ──one shared SSH connection──> Proxmox host (root)
                 │                                                  scripts in /root/pve-stresstest
                 │ <──────────── logs (tar stream, checksum verified) ──┘
                 └─> Markdown + HTML + PDF report in a local folder
```

## Step 1: Two questions

| Question | Choices | Becomes |
|---|---|---|
| How long should each part be stressed? | 30-second quick test, 1, 5 or 10 minutes per part | `D` = 30 / 60 / 300 / 600 seconds of sustained full load per unit. Benchmarks add a fixed extra on top |
| What is the SSH address of the host? | IP or hostname (a VPN/Tailscale address is fine), plus user (default `root`) and port (default `22`) | The SSH target |

If your request already answers one ("5-minute test on 192.0.2.10"), Claude just repeats it back. Claude **never asks for a password**: the run needs key-based SSH or Tailscale SSH (see [installation.md](installation.md#set-up-ssh-key-login-to-the-host)).

## Step 2: One shared SSH connection

Lots of quick SSH logins in a row can look like a brute-force attack to a router's intrusion prevention (IPS) or to fail2ban, and get your own IP blocked for a while. So Claude writes a tiny wrapper script that sends **every command through one multiplexed SSH connection** (OpenSSH `ControlMaster`), then checks it with `id -u; hostname; pveversion; uname -r`.

- Not root (`id -u` isn't `0`)? Every command needs passwordless `sudo -n`, or you connect as root.
- No `pveversion`? It isn't a Proxmox host, and the run stops.
- Key not accepted, unknown host key or a Tailscale SSH approval link: Claude explains the fix and lets you do it yourself.

## Step 3: Discovery and the test plan (plan-only, nothing changes)

Claude copies `scripts/` (except `finish_report.py`) to `/root/pve-stresstest/` and runs:

```bash
bash /root/pve-stresstest/prep.sh --out RUN --duration D --plan-only
```

`--plan-only` **installs nothing, runs no `apt update` and puts no load on the host**. It only reads. It writes:

| File | What's in it |
|---|---|
| `inventory.json` / `inventory.md` | Every component with specs: system, board, BIOS, every CPU socket (empty ones too), every DIMM slot (empty ones too), every GPU, every storage controller and the disks behind it (also disks hidden behind hardware RAID), each disk's SMART data and what it is used for, NICs, fans/PSU/sensors. **Report-safe:** no hostname, no IP addresses, serials and MACs masked to the last 4 characters, guests by ID only |
| `plan.json` / `plan.md` | The test plan: one **unit** per testable part, in run order, with its method, ready-to-run command and time estimate. Also lists skipped parts with reasons, inventory-only items (NICs, controllers, board, sensors), packages to install, running guests and warnings |
| `hardware.json` | Raw detection data. Holds full serials and the hostname, so it is never quoted in a report |

### The test plan

Units always run in this order, **strictly one at a time**: **CPU -> RAM -> GPU 1..n -> SSD 1..n (NVMe first) -> HDD 1..n**, then any optional pool units. One at a time means each part's temperature and power figures belong to that part alone, and a failure can be pinned on one component.

| Method (`method_id`) | Used for | What happens |
|---|---|---|
| `cpu_stress` | The CPU (one unit, even with several sockets) | All threads of all sockets at 100% (stress-ng), then sysbench and 7-Zip benchmarks; per-socket figures |
| `ram_stress` | The RAM (one unit, all DIMMs together) | stress-ng with every write read back and checked, STREAM bandwidth, latency, sysbench, memtester. Every NUMA node is loaded |
| `gpu_compute` | Each GPU the host drives itself: NVIDIA on the `nvidia` driver; AMD (`amdgpu`) and Intel (`i915` / `xe`), discrete or integrated, when an OpenCL runtime for it is available from the host's apt repos | hashcat as a steady compute load, then hashcat benchmarks (MD5, NTLM, SHA-256, WPA) and clpeak, all over OpenCL. On AMD/Intel only the GPU's own runtime and device are visible to the tools; if hashcat can't use that runtime, clpeak's kernels in a loop are the load instead |
| `gpu_limited` | AMD / Intel GPUs with no usable OpenCL runtime (e.g. AMD on PVE 8 without backports, Intel Gen7 or older, or a runtime install that would upgrade host packages) | Telemetry from sysfs/hwmon; the plan says why. OpenCL tests still run if a runtime turns out to work |
| `write_read` | A disk with a writable, mounted filesystem of its own and at least 2x the test file free | fio on **one temporary test file** (max 8 GiB on SSD/NVMe, 4 GiB on HDD, never more than 10% of free space), deleted afterwards. Full read + write scores. On the boot disk this is usually `/var/lib/vz` |
| `read_only_raw` | ZFS / Ceph / mdraid members, LVM-only disks, unmounted or nearly full disks, hardware RAID volumes without a filesystem, raw disks of stopped VMs | fio opens the whole device with `--readonly`, and a guard refuses any job that isn't a pure read. Read scores only |
| Pool unit (optional) | Each multi-disk filesystem (ZFS mirror/RAIDZ, mdraid) | `write_read` on the pool's path, to measure the pool's write path. Only run if you ask for it |
| `skip` | See below | Not tested; the reason is always recorded |

**Why a part is skipped:** a virtual disk, zero-size media, USB/removable devices under 8 GB, a disk passed through to a running VM or a container, physical disks hidden behind a hardware RAID controller (tested through the controller's volume, SMART only), and GPUs that can't be tested from the host (bound to `vfio-pci` for passthrough, `nouveau`, a BMC/server display chip, or no driver). The plan re-checks the live driver binding, so a passthrough GPU is never planned.

**Asked about separately** (`needs_confirmation`): a disk whose SMART status is FAILED, a USB-attached disk, or a raw disk configured for a stopped VM. Without a clear yes, these are not run.

### What you see before anything happens

Claude shows a short summary: the inventory, the plan in run order with times, every skipped part with its reason, running guests (they are **never** started or stopped, but they compete for the hardware and can lower scores), the packages it would install, what gets loaded, warnings, and the total estimated time. **Nothing is installed or loaded until you say yes.**

## Step 3b: Full prep (after your yes)

```bash
bash /root/pve-stresstest/prep.sh --out RUN --duration D
```

This installs the test tools **from the host's own apt repositories only**, records every package that wasn't there before (the "package ledger", `installed-packages.txt`), takes a 30-second idle baseline with SMART snapshots and error counters, and rebuilds the plan with complete data. If the new plan differs from the one you approved, Claude tells you before running anything.

Tools installed when missing: `stress-ng`, `sysbench`, 7-Zip, `fio`, `nvme-cli`, `smartmontools`, `lm-sensors`, `linux-cpupower`, `dmidecode`, `pciutils`, `memtester`, `gcc`, `libc6-dev`, `python3`, plus `hashcat`, `ocl-icd-libopencl1`, `clinfo` and `clpeak` when the host drives a GPU (Debian's `hashcat` also pulls in `pocl-opencl-icd` and some LLVM libraries; they are recorded and removed too).

For **AMD and Intel GPUs** prep also installs the userland OpenCL runtime that fits the Debian release and the GPU:

| GPU | PVE 9 (Debian 13) | PVE 8 (Debian 12) |
|---|---|---|
| AMD (`amdgpu`), discrete or APU | `mesa-opencl-icd` (Mesa rusticl, radeonsi) | Mesa rusticl needs 23.1+: `mesa-opencl-icd` from `bookworm-backports` if that suite is in the host's apt sources; otherwise "limited" (Clover only) |
| Intel (`i915`), Gen8+ iGPU or Arc | `mesa-opencl-icd` (Mesa rusticl, iris) | `intel-opencl-icd` (Intel compute-runtime) plus `mesa-opencl-icd` as a fallback |
| Intel (`xe`), e.g. Arc B-series | `mesa-opencl-icd` (needs Mesa 24.1+) | "limited" (Mesa too old) |

`intel-gpu-tools` (for Intel busy %) is added when available. Each runtime package is simulated with apt first and is **not** installed if it would pull in a kernel, firmware, DKMS or microcode package or **upgrade** a package already on the host (cleanup can only remove new packages); the GPU is then "limited" with that reason. GPU drivers, kernel modules, kernels and firmware are never installed or changed. Without internet, the sub-tests that need a missing tool are skipped and the report says so.

## Step 4: Run the units

Each unit's command is started **detached** on the host (`nohup setsid`), so a dropped SSH connection can't kill a test halfway. Claude waits for the unit's exit-code file, reads its `summary.json` and gives you a one-line update ("SSD 2 of 4 done ..."). Then the next unit starts, never before.

If a unit reports **hardware errors** (machine-check/EDAC errors, RAM miscompares, new GPU Xid errors or AMD/Intel GPU hangs and resets, disk I/O errors, rising SMART counters), Claude **stops and asks you** before going on.

### How long it takes

Each unit takes `D` plus a fixed extra for its benchmarks. These are the planner's own (rough) estimates from `inventory.py`:

| Unit | Formula | 30 s | 1 min | 5 min | 10 min |
|---|---|---|---|---|---|
| CPU | D + 150 s | 3 min | 3.5 min | 7.5 min | 12.5 min |
| RAM | D + memtester (D, clamped to 30-300 s) + 195 s | ~4.3 min | ~5.3 min | ~13.3 min | ~18.3 min |
| GPU, any vendor (`gpu_compute`) | D + 240 s | 4.5 min | 5 min | 9 min | 14 min |
| GPU, telemetry only (`gpu_limited`) | D + 90 s | 2 min | 2.5 min | 6.5 min | 11.5 min |
| NVMe, `write_read` | D + 35 s | ~1.1 min | ~1.6 min | ~5.6 min | ~10.6 min |
| SATA/SAS SSD, `write_read` | D + 70 s | ~1.7 min | ~2.2 min | ~6.2 min | ~11.2 min |
| HDD, `write_read` | D + 90 s | 2 min | 2.5 min | 6.5 min | 11.5 min |
| Any disk, `read_only_raw` | D + 30 s | 1 min | 1.5 min | 5.5 min | 10.5 min |
| Fixed overhead | prep ~3 min + copy/verify/cleanup ~1.5 min + reports ~5 min | ~9.5 min | | | |

**Example** (illustrative, a generic box with 1 CPU, RAM, 1 NVIDIA GPU, 1 NVMe and 1 HDD): about 24 min at 30 s, 27 min at 1 min, 51 min at 5 min and 76 min at 10 min per part. The plan always shows the real total for **your** hardware before anything starts (`estimate.total_human`, plus the totals for the other durations).

## Telemetry: where the numbers come from

Telemetry is sampled **once per second** for the whole run into CSV files, with a `phase` column naming the sub-test. A missing sensor is written as `n/a` and never fails a test.

| Measurement | Source |
|---|---|
| CPU package / core power | RAPL through the kernel's `powercap` interface (Intel, and AMD Zen on recent kernels), else the `amd_energy` hwmon. Summed over sockets. *RAPL = the CPU's built-in energy counters* |
| CPU temperature | `coretemp` (Intel), `k10temp` / `zenpower` Tdie or Tctl (AMD), else the `x86_pkg_temp` or `acpitz` thermal zone. Hottest socket |
| CPU clocks, busy %, throttling | sysfs and `/proc/stat`; P-core and E-core clocks on hybrid Intel; Intel `thermal_throttle` counters; `turbostat` alongside the CPU stress when installed |
| Memory | used / available / swap |
| GPU | NVIDIA: `nvidia-smi` (temperature, power vs limit, clocks, utilisation, fan, VRAM, throttle reasons, PCIe link). AMD / Intel: `amdgpu` / `i915` / `xe` sysfs and hwmon (edge, junction and memory temperature, power, core clock vs its max, memory clock, busy %, VRAM/GTT, fan, power limit, PCIe link, Intel throttle reasons); `intel_gpu_top` for Intel busy % when installed. Integrated GPUs: power from the CPU's RAPL "uncore" domain (Intel) or the APU package (AMD), marked "shared with CPU" |
| Disks | Temperature from NVMe hwmon / `drivetemp`, else `smartctl -n standby` (doesn't wake a sleeping HDD); throughput from `/proc/diskstats` (informational; scores use fio's own figures) |
| Health before and after each part | `smartctl` and `nvme smart-log`, SATA error log, and kernel error counters: machine checks (MCE), EDAC memory errors, PCIe AER errors, NVIDIA Xid lines, AMD/Intel GPU hang / reset / ring-timeout lines |

## Step 5: Copy the logs back and verify

The whole run folder comes back to your computer as one `tar` stream over the shared connection, by default into `./pve-stress-test-<hostname>-<YYYY-MM-DD>/`. Claude then compares SHA-256 checksums of every file on both sides and treats the logs as safe only after it sees **VERIFIED**, because the cleanup step deletes the host copy.

> **Privacy:** the raw logs contain serial numbers, the hostname and sometimes MAC or IP addresses (e.g. `hardware.json`, `*smartctl*`, `dmidecode-*`, `guests.txt`). The reports leave them out. Redact the raw logs before sharing them.

## Step 6: Reference values and scoring

For each scored result Claude looks up an **expected value for the exact model**, in this order of preference: the manufacturer's spec sheet, a well-known published benchmark, a theoretical maximum it can calculate (for example DDR bandwidth from the real channel count), or a typical range for the hardware class. The source is recorded next to every figure. The skill's [`references/reference-values.md`](../skill/proxmox-hardware-stress-test/references/reference-values.md) has the rules, formulas and a starter table of common homelab parts.

```
% of expected = measured / expected x 100        (latency, lower is better: expected / measured x 100)
```

If there is no trustworthy reference, the report **says so** and judges the part by internal consistency (thread scaling, steadiness over time, agreement between identical units or two tools). It never invents a number. Results the scripts marked invalid (cache-resident bandwidth, reads served from the ZFS ARC, impossible HDD seeks) are left out, with the reason. Scoring and verdicts are explained in [report-format.md](report-format.md).

## Step 7: Reports

Markdown first, then the HTML page filled from it, then `finish_report.py` on your computer embeds the fonts, makes the PDF and opens the HTML. See [report-format.md](report-format.md).

## Step 8: Cleanup

Only after the logs printed VERIFIED (and you agreed in step 3):

```bash
bash /root/pve-stresstest/cleanup.sh --out RUN --confirm-logs-copied     # add --keep-packages to keep the tools
```

It stops leftover test processes that belong to the skill, deletes any leftover test files, removes **exactly** the packages in the ledger (it simulates `apt` first and refuses if anything else would be removed, and never removes protected packages such as Proxmox, kernel, ZFS or NVIDIA ones), removes the GPU tools' caches and deletes the working folder. It prints a definite "Working dir: deleted" or "NOT deleted". Exit code 3 means it skipped something for safety; Claude reports what and why instead of forcing it. Finally Claude closes the shared SSH connection, deletes the wrapper script and fills in the report's Cleanup section.

## Safety rules, in one place

- Never writes to a raw block device, never formats, partitions, mounts or resizes, never touches backup or VM image files.
- Never changes BIOS, power limits, governors, fan curves, GPU clocks or power limits, RAID controller settings or kernel parameters.
- Never starts, stops, migrates or reconfigures guests, and never touches a passthrough (`vfio-pci`) GPU.
- The RAM test leaves at least 4 GiB plus the guests' possible growth free, and a watchdog stops it if available memory gets low.
- Installs only from the host's configured apt repos, records what was new, and removes exactly that.
- Stops and asks when hardware errors appear, a disk already fails SMART, or a choice is unclear.

The full list, with the reasons, is in [`references/safety-and-troubleshooting.md`](../skill/proxmox-hardware-stress-test/references/safety-and-troubleshooting.md).
