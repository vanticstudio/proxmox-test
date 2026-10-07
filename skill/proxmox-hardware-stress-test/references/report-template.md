# Report template

The report is the product. A reader should be able to read the first screen (at-a-glance table + bottom line) and know whether their server is healthy, then dig into any part for the evidence.

## Contents
1. Scoring rules (part score, verdicts)
2. Style rules
3. Scaling to any amount of hardware (units, naming, absent parts)
4. Report skeleton, section by section
5. Where each number comes from (inventory.json / plan.json / summary.json / CSV fields)

---

## 1. Scoring rules

**Per result:** `% of expected = measured / expected x 100`. For lower-is-better metrics (latency in ns or ms) use `expected / measured x 100`. Round to whole numbers except near 100 (99.5%, 100.5% are fine).

**Main results** (the ones that count towards the part score). Drop any that are missing, invalid or have no trustworthy reference:

| Part | Main results |
|---|---|
| CPU | 7-Zip multi-thread MIPS vs a published result for the model; single-core boost clock vs advertised max turbo; thread scaling (sysbench MT / 1T, or 7-Zip MT / 1T) vs the expected scaling for the core layout |
| RAM | STREAM Triad runs and stress-ng stream vs **typical** real-world for the platform; sysbench 1-thread sequential read vs typical single-core; DRAM latency vs typical for the platform. State the best result as % of the **theoretical** maximum on its own line too |
| GPU | hashcat MD5 / NTLM / SHA-256 / WPA vs published results for the model; clpeak FP32 vs spec TFLOPS; clpeak VRAM bandwidth vs spec GB/s. AMD/Intel: score hashcat only against a reference from the same kind of OpenCL runtime (`.opencl.platform`: rusticl / Clover / compute-runtime / ROCm), otherwise show it unscored and rely on clpeak. Integrated GPUs (iGPU / APU): bandwidth vs the RAM's measured STREAM result, not a VRAM spec |
| SSD / NVMe | seq read, seq write, 4K random read IOPS, 4K random write IOPS, 4K QD1 read IOPS vs the drive's datasheet (class reference only if no datasheet). Read-only (`read_only_raw`) method: the read results only |
| HDD | sequential only (fill write, seq read, seq write) vs the datasheet sustained transfer rate. Random results are shown but not scored: a small test file flatters them, and random writes measure the drive's cache. Read-only method: seq read only; a test marked `valid: false` is excluded |
| Pool (ZFS/mdraid) | the same results as its member type, against the pool's expected speed (e.g. mirror reads up to n x one drive, writes ~1 x); say how you derived it |

Each GPU and each disk is its own unit with its own part score and verdict. Identical units (four of the same SSD) are scored separately; say so when one is clearly slower than its twins, because that is a useful finding in itself.

**Part score** = plain average of that part's main "% of expected" values. Always show the calculation, e.g. "**CPU part score: ~97%** (7-Zip MT 96%, boost clock 99%, thread scaling ~95%)." (illustrative) Prefix with "~" because references are approximate.

**Pass/fail checks** (not averaged, but they override the verdict): data integrity (stress-ng `--verify`, STREAM validation, memtester), hardware error counters (MCE, EDAC, PCIe AER, NVMe media errors, SATA CRC/reallocated/pending, GPU Xid on NVIDIA, new GPU hang / reset / ring-timeout lines on AMD/Intel), thermal throttling.

**Verdict per part:**

| Condition | Verdict wording |
|---|---|
| Any data-integrity failure or new hardware error | **FAILED: <what>** - investigate before trusting this part |
| Part score >= 90% and no thermal throttling | **Running optimally** |
| 75-90%, or thermal throttling seen even with a score >= 90% | **Slightly below expected** - explain the likely cause (power limit set low, guests running, cooling, PCIe link below max, single-channel RAM, SMR or SLC cache, ...) |
| < 75% | **Underperforming** - list concrete checks |
| No trustworthy reference for any main result | **Healthy (no reference)** if results are consistent and error-free, and say so |

Above 100% is normal (boost behaviour, good cooling, small test areas) and not suspicious unless it exceeds a physical limit; then the measurement is invalid and is excluded. Hitting a power limit ("SW Power Cap", RAPL pinned at PL1/PL2) is healthy behaviour, not throttling. Thermal throttling is.

**Overall verdict:** if every tested unit is "Running optimally": "The whole server is healthy and performing at or above expectations." Otherwise name the units that need attention ("SSD 3", not "the SSDs"). Report the average of the unit scores, but never let a good average hide one failed unit, and don't let many disks drown out the CPU: also give the per-category average (CPU, RAM, GPUs, SSDs, HDDs).

## 2. Style rules

- Plain English for a homelab owner. Define each technical term once, in a short **Terms:** list in the section where it first appears (P/E-cores, PL1/PL2, TjMax, IOPS, QD, TFLOPS, SMR, ECC...).
- Give the number, then what it means: "Peak 80 °C, about 20 °C below the point where the chip slows itself down."
- Bold the key figures and the verdicts. Tables for numbers, short paragraphs for meaning.
- Every recommendation is an action ("Keep the current power limit", "Update the BIOS"), or "Nothing to change."
- Be honest. If a sensor doesn't exist, write "not measurable (no sensor)" and, where useful, give the datasheet figure. If a test was skipped, say why. If a reference is approximate or missing, say so.
- Explain anything surprising, e.g. "a sudden drop in HDD write speed partway through is the SMR cache filling, not a fault".
- Use the host's local time zone; write dates in words (e.g. 14 March 2025).
- No serial numbers, IP addresses, MAC addresses, UUIDs/WWNs or passwords in the report: people share these reports publicly. Hostnames, guest names and storage names are fine in the user's own copy, but offer to replace them before sharing.

## 3. Scaling to any amount of hardware

The report has the **same sections in the same order on every host**; only the number of rows and per-unit sections changes.

- **Units** come from `plan.json` `.units[]` in `seq` order: CPU, RAM, GPU 1..n, SSD 1..n, HDD 1..n, then any optional pool units that were run (report them with their member type, as "SSD pool 1" / "HDD pool 1"). NVMe and SATA SSDs are both "SSD" (`part: ssd`); the interface is in the label. Physical disks hidden behind a hardware RAID controller appear as skipped rows ("tested through the RAID volume").
- **Naming** (use it everywhere: table rows, section headings, recommendations): `CPU: <model>` (with "2 x" for two identical sockets), `RAM: <n> x <size> <type>-<speed>`, `GPU 1: <model> (<PCI slot>)` (add "integrated" for an iGPU / APU, e.g. `GPU 1: Intel UHD Graphics 770 (integrated, 00:02.0)`), `SSD 1: <model> (<dev>)`, `HDD 2: <model> (<dev>)`, `SSD pool 1: <pool name> (<layout>, <n> x <model>)`. Numbering follows the plan, not the device name.
- **At a glance:** one row per unit; a skipped unit keeps its row with "Skipped: <reason>" in the score column and "-" elsewhere. A part the host doesn't have at all is a single row with "Not present" (e.g. `| **GPU** | Not present | - | - | - | - |`).
- **Per-unit sections:** every tested unit gets the full sub-section set (what and why, stress phase, scores, part score, health before/after, "Is it running optimally?", recommendations). A skipped unit gets a two-line section with the reason and what would be needed to test it. With more than ~6 identical disks, you may merge their sections into one comparison table plus full sections only for the outliers; say that you did.
- **Your hardware** lists *every* component, tested or not: every socket, every DIMM slot (empty ones too), every GPU, every controller and the disks behind it, every NIC.

## 4. Skeleton

```markdown
# Proxmox hardware stress test report (<30 s | 1 min | 5 min | 10 min> per part)

**Date:** <date>, <start> to <end> (<time zone>)
**Server:** `<hostname>`, <n x CPU> / <RAM size + type + speed> / <n x GPU or "no GPU"> / <n SSDs> / <n HDDs> (full list under "Your hardware")
**Proxmox:** PVE <version>, kernel <version>

## How the test was done
- Claude detected <n> components and built a plan of <n> test units; <n> were tested and <n> skipped (reasons below). They were tested one after another, in this order: CPU, RAM, <GPU 1..n>, <SSD 1..n>, <HDD 1..n>. Each unit got a <D>-second full-load stress phase, followed by benchmark runs that give it performance scores.
- Disks were tested through a temporary file on their filesystem where possible (read and write); disks without a usable filesystem were read directly in read-only mode (read speed only, nothing written). The method per disk is listed under "Your hardware".
- Guests: <"No VMs or containers were running" | "N VMs / M containers were running (list); they were not stopped, so scores may read slightly low">. None were started or stopped by the test.
- Telemetry (power, temperature, clock speed, load) was recorded once a second. Health checks (error logs, throttle counters, SMART) were taken before and after each part.
- Tools: <those actually used; say which were unavailable and what was skipped>.

### What "% of expected" means
Each score is compared with a published reference: the manufacturer's spec sheet, well-known review results, or the hardware's theoretical maximum. 100% means the part performs exactly as it should; anything from about 90% up is healthy. Where no reference exists, the report says so instead of inventing one. The part score is the average of that part's main results; the calculation is shown in each section.

## At a glance
| Part | Key score(s) | Part score (% of expected) | Peak temp | Peak power | Verdict |
|---|---|---|---|---|---|
| **CPU** (<n> socket(s)) | 7-Zip <n> MIPS; sysbench 1T <n> / <T>T <n> events/s | **~<n>%** | <n> °C | <n> W | <verdict> |
| **RAM** (<n> DIMMs) | STREAM <n> GB/s; latency <n> ns; <n> GB verified with <n> errors | **~<n>%** of typical (<n>% of theoretical max) | <CPU package °C> | <CPU package W> | ... |
| **GPU 1** (one row per GPU) | MD5 <n> GH/s; FP32 <n> TFLOPS; <n> GB/s | ... | ... | ... | ... |
| **SSD 1** (one row per SSD or SSD pool) | <n> MB/s read; <n> MB/s write; <n> / <n> IOPS | ... | <n> °C (controller <n> °C) | not measurable (no sensor) | ... |
| **HDD 1** (one row per HDD or HDD pool) | <n> MB/s read; <n> MB/s write | ... | ... | not measurable (no sensor) | ... |
| **SSD 3** (example skipped unit) | Skipped: <reason> | - | - | - | - |
| **GPU** (example absent part) | Not present | - | - | - | - |

**Bottom line:** <one or two sentences: what passed, what needs attention, whether changes are needed>.

---

## Your hardware
Everything Claude found on the host, tested or not. Serial numbers, MAC addresses and UUIDs are left out on purpose.

### System
| Item | Detail |
|---|---|
| Board / system | <vendor + model> (BIOS <version>, <date in words>) |
| Firmware | UEFI or legacy BIOS; Secure Boot on/off |
| Proxmox / kernel | PVE <version>, kernel <version>, Debian <version> |
| Virtualisation | VT-x/AMD-V on/off; IOMMU on/off (<n> groups) |

### CPU (one row per socket)
| Socket | Model | Cores / threads | Base-max clock | Cache | Notes |
|---|---|---|---|---|---|
| 0 | <model> | <c> (<p> P + <e> E) / <t> | <min>-<max> GHz | L3 <n> MB | microcode <x>; governor <x>; PL1/PL2 <n>/<n> W |

### Memory (<total> GB, <populated> of <slots> slots, <max capacity> max, ECC <yes/no>)
| Slot | Size | Type / speed (configured / rated) | Maker / part number | Rank |
|---|---|---|---|---|
| <slot name> | 32 GB | DDR5-<configured> / <rated> | <maker> <part number> | <n> |
| <slot name> | empty | - | - | - |

### GPUs (<n> found)
| # | Model | Type | PCI slot | Driver / OpenCL runtime | VRAM | PCIe link max | Power limit | Tested? |
|---|---|---|---|---|---|---|---|---|
| GPU 1 | <model> | discrete / integrated | <slot> | <driver + version> / <runtime, e.g. Mesa rusticl> | <n> GB, or "shared RAM" | Gen<n> x<n> | <n> W | Yes / Limited: <reason> / No: <reason> |
<or the single line "No GPU found.">

### Storage controllers and disks (<n> controllers, <n> disks)
| Controller | Type / driver | Disks behind it |
|---|---|---|
| <model> | NVMe / AHCI / SAS HBA / hardware RAID (<driver>) | <list of units or devices> |

| Unit | Model | Kind / interface | Size | Health / wear / hours | Used for | Test method |
|---|---|---|---|---|---|---|
| SSD 1 | <model> | NVMe, PCIe Gen<n> x<n> | <n> TB | PASSED / <n>% used / <n> h | Proxmox boot, `local-lvm` | write+read (test file in `/var/lib/vz`) |
| HDD 1 | <model> | SATA 6 Gb/s, <rpm>, CMR/SMR | <n> TB | PASSED / - / <n> h | ZFS pool `<name>` member | read-only (whole disk) |
| - | <model> | USB | <n> GB | - | - | skipped: USB, not requested |

### Network
| Interface | Model | Driver | Link speed | Role |
|---|---|---|---|---|
| <nic> | <model> | <driver> | <speed or "no link"> | bridge `<vmbrN>` / unused |

---

## Starting point (baseline, before any load)
| Item | Idle reading |
|---|---|
| CPU | idle W, °C, MHz; throttle counters |
| CPU settings | governor, turbo, PL1/PL2, microcode |
| RAM | DIMMs, speed, channels, ECC, free |
| GPU | W, °C, fan, clocks, PCIe link at idle (low gen at idle is power saving) |
| Each SSD / HDD | temp, wear, errors, TB written, hours, SMART |
| Error logs | MCE / EDAC / AER / NVMe / SATA this boot |
| Free space | each filesystem used for testing |
| Guests | running list, or none |

---

## 1. CPU: <model>        (multi-socket: "2 x <model>", stress table with one column group per socket where the summary gives it)
### What was tested and why
<2-3 sentences, then a Terms list>
### Stress phase (<tool>, <workers>, <D> s, <start>-<end>)
| Measure | Idle before | Under load | Right after |
|---|---|---|---|
<rows: package power, core power, package temperature, P-core / E-core / all-core clock, utilisation, throttle counters>
<Result line: ops/s, workers passed/failed. Say whether the chip was held back by power or by heat.>
### Scores
| Test | Result | Expected / reference | % of expected | Verdict |
|---|---|---|---|---|
<rows: 7-Zip MT, 7-Zip 1T, sysbench 1T (+ boost clock), sysbench MT (+ scaling), stress-ng, performance per watt>
**CPU part score: ~<n>%** (<calculation>).
### Health before and after
### Is it running optimally?
### Recommendations (CPU)

## 2. RAM: <n> x <size> <type>-<speed>
<Same sub-sections. Stress table: memory in use, swap, CPU package W/°C, clock, throttle. The result line must state the size actually tested and the error count. Scores: each STREAM run, stress-ng stream, latency (+ L1/L2/L3 ladder), sysbench 1T, memtester; list invalid results as "Invalid - excluded from scoring" with the reason. Explain ECC vs non-ECC and what that means for catching errors.>

## 3.1 GPU 1: <model> (<PCI slot>)        (repeat as 3.2 GPU 2, 3.3 GPU 3 ...; "## 3. GPU: not present" when there is none; "## 3.n GPU n: <model>, skipped" + reason)
<Vendor, discrete or integrated, and how it was driven: "NVIDIA driver <version>, OpenCL" or "in-kernel amdgpu/i915/xe driver, OpenCL through <runtime> (`.opencl.platform`)"; say if the stress used the clpeak fallback (`stress_method: clpeak-loop`) and why. Stress table: power vs limit, temp (AMD: edge and junction/hotspot, memory), graphics/memory clock (AMD/Intel: average vs max, `clock_vs_max_pct`), utilisation, fan, VRAM (iGPU/APU: "shared system RAM"), PCIe link idle vs load (n/a for an iGPU), throttle reason (NVIDIA bitmask; Intel throttle reasons; AMD: judged from clock vs max + temperature). For an iGPU / APU, label power "shared with the CPU" (`power_note`) and don't compare it with a discrete card. Scores: hashcat modes (or "not available on this OpenCL runtime"), clpeak FP32 / FP64 / INT32 / memory bandwidth / PCIe transfer / kernel latency. Limited GPUs (telemetry only): a short section with the idle/loaded sensor readings and the reason no OpenCL runtime was usable.>

## 4.1 SSD 1: <model> (<dev>), <capacity>, <NVMe|SATA|SAS>, <role>        (repeat as 4.2 SSD 2 ...; pools as "SSD pool 1"; "## 4. SSD: not present")
<Method (write+read with the test-file size and path, or read-only: whole disk, no write scores). Controller it sits behind. Stress table: throughput per phase, temp (+ controller), power state, host CPU power, throttling, sustain ratio on long runs. Scores vs datasheet. Health table before/after: SMART, temp, wear/spare, media errors, unsafe shutdowns, data written. PCIe or SATA link under load. Firmware notes.>

## 5.1 HDD 1: <model> (<dev>), <capacity>, <role>        (repeat as 5.2 HDD 2 ...; pools as "HDD pool 1"; "## 5. HDD: not present")
<Method as for SSDs. Say CMR or SMR and what that means. Scores from fio's own figures; random results shown but not scored. SMART identical before and after?>

---

## Overall health verdict
| | Result |
|---|---|
| Units tested / passed / skipped | <n> / <n> / <n> (of <n> components found) |
| Average unit score | ~<n>% (CPU ~, RAM ~, GPUs ~ avg of <n>, SSDs ~ avg of <n>, HDDs ~ avg of <n>) |
| Thermal throttling | |
| Hardware errors (MCE, EDAC, AER, NVMe, ATA, GPU Xid) | |
| Data errors (RAM check, disk I/O) | |
| Settings changed | None |

| Unit | Peak temperature | Limit | Headroom |
|---|---|---|---|
<one row per tested unit>

## Recommendations, in priority order
<numbered; urgent first; say "None of these are urgent" when true>

## Limits of these tests
- <D> seconds per part proves the parts work at full speed and stay stable when loaded; it does not prove stability over hours (heat soak, rare RAM errors, SLC/SMR cache exhaustion only show in longer runs).
- Disk tests used a test file on the filesystem where possible (only part of each disk was tested); disks read in read-only mode have no write scores. Disks behind a hardware RAID controller were tested as the controller's virtual disk, and their SMART data may be hidden.
- RAM coverage was partial (<n> GB of <n> GB; memtester <n> of ~17 subtests); not a replacement for memtest86+.
- No wall-power meter; CPU/GPU power come from on-chip sensors; disks have no power sensors.
- Running guests (if any) and their effect.
- ZFS ARC caveat (if a ZFS path was used).
- Approximate or missing references; measurement quirks that were excluded.

### How to do a longer burn-in
<the table from safety-and-troubleshooting.md, with this host's thread count and paths filled in>

## Where the raw logs are
<local folder; table of sub-folders and the key files in each>

## Cleanup
<what cleanup.sh removed (packages, test files, working folder), what it kept and why; logs verified by checksum before the host copy was deleted>
```

## 5. Where the numbers come from

| Report item | Source |
|---|---|
| Hardware, settings, guests, idle readings | `hardware.json`, `00-baseline/summary.json`, `00-baseline/*.txt`, `00-baseline/idle-telemetry.csv` |
| Your hardware section | `inventory.json` (or the ready-made tables in `inventory.md`), which is already report-safe: no hostname, no IPs, serials/MACs masked. Keys: `.system`, `.board`, `.bios`, `.platform` (IOMMU, NUMA), `.cpu.sockets[]` (+ `.cpu.sockets_empty[]`), `.memory.slots[]` (empty slots have `populated: false`), `.gpus[]` (`testable`, `reason`, `integrated`, `opencl` runtime/state, `passthrough_vms`, `shared_with_containers`), `.storage.controllers[]` (with `.disks`), `.storage.disks[]` (`usage[]`, `smart`, `interface`, `rotation`), `.storage.raid_hidden_disks[]`, `.nics[]`, `.sensors`. Don't use `hardware.json` for this section: it holds full serials and the hostname |
| Unit list, labels, methods, skips | `plan.json` `.units[]` (`seq`, `label`, `part`, `method_id`/`method`, `path`/`device`, `status` test/skip, `reason`, `needs_confirmation`, `optional`); `.inventory_only[]` for NICs/controllers; `.estimate` for timing |
| CPU stress table | `01-cpu/summary.json` `.idle`, `.stress`, `.peaks`, `.throttle`; per-second detail in `telemetry-1s.csv` (phase `stress`) |
| CPU scores | `.benchmarks` (sysbench, 7-Zip), `.efficiency`, `.scores[]` (boost % is already computed) |
| RAM | `02-ram/summary.json`: `.stress.tested_mib` (use this, not the planned size), `.stream[]` (skip `valid: false`), `.stress_ng_stream`, `.sysbench`, `.latency.dram_ns` + ladder, `.memtester.state`, `.edac`, `.data_integrity`, `.host.theoretical_gbs_one_dimm_per_channel` (check the real channel count: 4 DIMMs on a 2-channel desktop is still 2 channels) |
| GPU | each GPU unit's `03-gpu*/summary.json`: `.vendor`, `.gpu_type` (discrete/integrated), `.power_note`, `.opencl` (platform, device, ICD, how it was matched; or `skip_reason`), `.stress.method` / `.stress_method` (hashcat / clpeak-loop / none), `.scores` (hashcat `value`+`unit`, clpeak best-of-vector-width), `.stress.stats` (loaded temp/power/core clock avg-min; AMD/Intel also `core_max_mhz`, `clock_vs_max_pct`, `junction_c_max`, `mem_temp_c_max`, `throttle_samples`, `power_source`, `util_filter`), `.xid_lines_before/after` (NVIDIA) or `.gpu_error_lines_before/after` (AMD/Intel); `stress-tel.csv` for per-second detail (AMD/Intel columns: `telemetry.sh` `TEL_GPU_EXT_FIELDS`); `clpeak.txt` for FP64/INT32/transfer/latency; `pre-/post-health.txt`; `opencl-probe.txt` for which runtimes were tried |
| SSD / HDD | each unit's `out` folder (`04-ssd-*`, `05-hdd-*`) `summary.json`: `.tests[]` (MBps, IOPS, latency, sustain_ratio, zfs_arc_hit_pct), `.telemetry`, `.smart.counters_pre/post`, `.link`, `.zfs`, `.bytes_written`. The script's own `pct_of_expected` uses class references; replace them with datasheet values when you have them |
| Errors and warnings | every `summary.json` `.errors`, `.warnings`, `.skipped`; `dmesg-new-hw-errors.txt` |

Compute min/avg/max from the CSVs yourself if a summary lacks them (python3 or awk locally). Ignore power samples below 0 W or above 2000 W (RAPL counter-wrap glitches).
