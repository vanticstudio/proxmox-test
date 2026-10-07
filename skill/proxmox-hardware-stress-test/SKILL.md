---
name: proxmox-hardware-stress-test
description: Stress-test, burn-in and benchmark every hardware component of a Proxmox VE host (PVE 8/9) over SSH. It auto-discovers whatever the box has (one or several CPU sockets, every DIMM, zero to many NVIDIA, AMD or Intel GPUs including integrated ones, every NVMe/SATA SSD and HDD, including disks behind HBAs/RAID controllers), tests each part one at a time with 1-second power/temperature/clock telemetry, then writes a scored plain-English report ("% of expected" against spec sheets and published results, a verdict per part) as Markdown, a designed HTML page (opened in the browser) and a PDF. Use this whenever someone wants to stress test, burn in, benchmark, health-check or "see if it's running properly" a Proxmox server, homelab box or PVE node, check its temperatures, power draw, throttling, RAM errors, NVMe/HDD speed or GPU performance, or validate new/used hardware before putting VMs on it, even if they don't say "stress test". On load it asks how long to test each part (30-second quick test, 1, 5 or 10 minutes) and the SSH address of the Proxmox host.
---

# Proxmox hardware stress test

Runs a sequential, file-safe hardware sweep on a Proxmox VE host and turns the raw logs into a report a non-expert can act on. The skill scales to the host: it discovers every component, builds a test plan with one **unit** per testable part, and runs the units strictly one at a time in the order **CPU -> RAM -> GPU 1..n -> SSD 1..n -> HDD 1..n**, so each unit's temperature and power numbers belong to that part alone and a failure can be pinned on one component. A box with no GPU and one disk and a dual-socket server with four GPUs and twenty drives get the same report structure.

Everything runs on the host as root through SSH. The scripts in `scripts/` do the measuring; your job is to drive them, keep the user informed, look up reference values and write the reports.

Files you will need:
- `scripts/`: copied to the host (except `finish_report.py`, which runs locally). Each script's header comment documents its flags, outputs and timing; `inventory.py` (run by `prep.sh`) documents `inventory.json` and `plan.json`, and step 3 below lists the fields you need.
- `references/report-template.md`: the Markdown report structure and scoring rules. Read it before step 7.
- `assets/report-template.html`: the designed HTML report; its header comment has the fill rules. Read it before step 7.
- `references/reference-values.md`: how to find "expected" values, plus a starter table. Read it before step 6.
- `references/safety-and-troubleshooting.md`: read it when anything unusual happens (SSH problems, sudo instead of root, no internet, ZFS, RAID/HBA, AMD, passthrough GPUs, missing sensors, guests running, longer burn-ins).

## 1. Ask two questions first

Ask these before touching anything. Use the AskUserQuestion tool when it is available; otherwise ask in plain text and wait for the answer.

1. **How long should each part be stressed?** Options: "30-second quick test", "1 minute per part", "5 minutes per part", "10 minutes per part". This becomes `D` = 30 / 60 / 300 / 600 seconds: the sustained full-load phase per unit; benchmarks add a fixed extra on top. Suggest 30 s for a first look and 5-10 min for checking cooling or used hardware. On a host with many disks or GPUs, mention that the total scales with the number of units (the plan in step 3 gives the real total).
2. **What is the SSH address of the Proxmox host?** Free text: an IP or hostname (a VPN/Tailscale address is fine), plus the user (default `root`) and port (default `22`) if they differ.

If the request already answers a question (e.g. "5-minute test on 192.0.2.10"), don't ask it again; repeat the value back in one line. Never ask for, store or pass a password. The run needs key-based SSH (or Tailscale SSH) because it sends dozens of commands, and a typed password would end up in files, logs and shell history.

## 2. Set up one shared SSH connection

Many back-to-back SSH logins look like a brute-force attack to router IPS / threat-management features (e.g. Suricata/Snort-based gateway IPS, fail2ban) and can get the user's own IP blocked for a while. So every command goes through one multiplexed connection.

Shell variables don't survive between your shell calls, and in zsh (the macOS default) an unquoted `$SSHO` is not split into separate options. Use a small wrapper script instead: write it once to your scratchpad or a temp directory, fill in USER, HOST and PORT, and call it with `sh` from any shell:

```sh
#!/bin/sh
# pvessh: every command for this run goes through one shared SSH connection
mkdir -p "$HOME/.ssh"
exec ssh -o BatchMode=yes -o ConnectTimeout=15 -o ServerAliveInterval=30 \
  -o ControlMaster=auto -o "ControlPath=$HOME/.ssh/cm-pvestress-%r@%h:%p" -o ControlPersist=4h \
  -p PORT USER@HOST "$@"
```

Below, `PVESSH` means `sh /abs/path/to/pvessh`. Test it with `PVESSH 'id -u; hostname; pveversion; uname -r'`.

- Success = `0` from `id -u` and a `pve-manager/...` line. If `pveversion` is missing, this is not a Proxmox host: stop and tell the user (the scripts expect PVE on Debian 12/13).
- `Permission denied (publickey...)`: explain key setup and let the user do it themselves: `ssh-keygen -t ed25519` (if they have no key), then `ssh-copy-id -p PORT USER@HOST`, typing the password into their own terminal (in Claude Code they can prefix the command with `!`). Then retry.
- `Host key verification failed`: ask the user to connect once by hand and check the fingerprint. If they confirm the address is right, add `-o StrictHostKeyChecking=accept-new` to the wrapper and retry once.
- Non-root user: every remote command needs `sudo -n`. Follow "Non-root user" in `references/safety-and-troubleshooting.md`, or ask the user to connect as root.
- Tailscale SSH "additional check" / auth URL: show the URL to the user, wait for them to approve it, then retry.
- Windows OpenSSH has no ControlMaster: drop the three `Control*` options and keep the number of separate commands low.

## 3. Discover the hardware and confirm the plan

Pick the run folder once, e.g. `RUN=/root/pve-stresstest/run-YYYYMMDD-HHMM` (date and time), and write the literal path into every later command.

```bash
tar -C <skill-dir>/scripts --exclude finish_report.py -cf - . | PVESSH 'mkdir -p /root/pve-stresstest && tar -C /root/pve-stresstest -xf -'
PVESSH 'bash /root/pve-stresstest/prep.sh --out RUN --duration D --plan-only'
PVESSH 'cat RUN/inventory.md; cat RUN/plan.json'
```

(From macOS the host's `tar` may print "Ignoring unknown extended header keyword" warnings for Apple file attributes; they are harmless.) `--plan-only` installs nothing, runs no apt update and puts no load on the host. It prints a **PLAN ONLY** banner followed by `plan.md`, and writes:
- `RUN/inventory.json` + `RUN/inventory.md`: every component with full specs (system, board, BIOS, every CPU socket incl. empty ones, every DIMM slot incl. empty ones, every GPU, every storage controller with the disks behind it, every disk with SMART and what it is used for, disks hidden behind hardware RAID, NICs, fans/PSUs/sensors). These two files are **report-safe**: no hostname, no IP addresses, serials and MACs masked to the last 4 characters, guests by ID only. The banner's `Host:` line shows the hostname; don't copy it into reports.
- `RUN/plan.json` + `RUN/plan.md`: the test plan. `plan.json` has `units[]` in run order, `inventory_only[]` (NICs, controllers, board, sensors), `counts`, `estimate` (`total_s`, `total_human`, `by_duration_total_s` for 30/60/300/600 s), `packages_to_install`, `guests_running` and `warnings`. Each unit has `id`, `part` (`cpu` / `ram` / `gpu` / `ssd` / `hdd` / `pool`), `label`, `status` (`test` or `skip`), `seq` (1..n in run order; `null` for skips), `method_id`, `method` (plain text), `command`, `out_dir`, `est_s`, `needs_confirmation`, `warnings[]`, `reason`, and per type `device`/`profile`/`path`/`test_file_gib` (disks) or `pci` (GPUs). Pool units also have `optional: true`.
- `RUN/hardware.json` (as before, plus the inventory keys; it still holds full serials and the hostname, so never quote it raw).

`--plan-only` is not "ready to test": `fio`, `stress-ng` and the other tools are usually not installed yet, so never start a unit before the full prep below.

How the plan tests each part (`method_id`; you may change a unit only towards the safer option):
- **`cpu_stress`, `ram_stress`**: one unit each, even on multi-socket / many-DIMM hosts; the scripts load every socket and NUMA node together and report per socket.
- **`gpu_compute`**: one unit per GPU, `gpu.sh --gpu <PCI address>`, the same OpenCL stress (hashcat) and benchmarks (hashcat -b, clpeak) for every vendor: NVIDIA on the host's `nvidia` driver, and AMD (`amdgpu`) and Intel (`i915`/`xe`) GPUs, discrete or integrated (iGPU / APU), through a userland OpenCL runtime from the host's apt repos (Mesa rusticl, Intel compute-runtime; the unit's `opencl_runtime` names it). **`gpu_limited`** (telemetry only, OpenCL if something usable turns up) when no runtime can be installed for that GPU; the `reason` says why (e.g. AMD on PVE 8 without backports, Intel Gen7 or older, an install that would upgrade host packages). GPUs bound to `vfio-pci`, `nouveau`, a BMC display or no driver are `skip` units with the reason (and the VM ID for passthrough). The plan re-checks the live driver binding, so a passthrough GPU is never planned.
- **`write_read`** (disks): fio on a temporary test file in a mounted, writable filesystem that lives on that disk only, with at least 2x the test file free (<= 8 GiB SSD/NVMe, <= 4 GiB HDD, 10% of free space at most; deleted afterwards). Full read + write scores. For the boot disk usually `/var/lib/vz`.
- **`read_only_raw`** (disks): `disk.sh --mode readonly --device /dev/X`, fio with `--readonly` on the whole block device; a guard refuses any job that is not a pure read. Used for ZFS / Ceph / mdraid members, LVM-only disks, unmounted or nearly full disks, hardware RAID volumes without a filesystem, and raw disks of stopped VMs. Read scores only; write scores are "not tested (read-only mode)".
- **Pool units** (`part: pool`, `optional: true`, `write_read` on the pool's path): one per multi-disk filesystem (ZFS mirror/RAIDZ, mdraid). Their member disks already have their own `read_only_raw` units; the pool unit adds the pool's write path. Offer them; run them only if the user wants.
- **`skip`**: virtual disks, zero-size media, USB/removable devices under 8 GB, disks passed through to a running VM or a container, physical disks hidden behind a hardware RAID controller (tested through the controller's volume; SMART only), non-testable GPUs. Always with a `reason`.
- **`needs_confirmation: true`** (SMART FAILED, USB-attached, a raw disk configured for a stopped VM): ask about each one separately; without a clear yes, don't run it.

Show the user the plan and get an explicit yes before going further. Keep it short but complete:

- **Inventory summary** (from `inventory.md`): system/board/BIOS; each CPU socket (model, cores/threads, P/E split); RAM (total, populated / total slots, type, speed, ECC); each GPU with whether it will be tested and why; each controller with its disks (model, kind, size, SMART health, what the disk is used for). "Not present" for any part the host doesn't have.
- **Test plan, in run order** (from `plan.md`): one line per `status: test` unit: label, method (and path for `write_read`), estimated time; the optional pool units; every skipped part with its reason; the **total estimated time** (`estimate.total_human`, which includes ~3 min prep, ~2 min copy/cleanup and ~5 min for the reports) and, if useful, the totals for the other durations.
- **Running guests** (`guests_running`): *VMs and containers keep running; the skill never starts or stops them. They will compete for the hardware, so scores may read low and their users may notice slowdowns. For the cleanest numbers, stop them yourself first.* Say so too when containers share a GPU (unit `warnings`; common for an iGPU used for Plex/Jellyfin transcoding), or when a `read_only_raw` disk holds running VM disks (reads add I/O load, nothing is written).
- **What gets installed** (`packages_to_install`): from the host's own apt repos only. GPU tools (`hashcat`, `clinfo`, `clpeak`) only when the host drives a GPU itself; for AMD/Intel also the userland OpenCL runtime (`mesa-opencl-icd`, `intel-opencl-icd` where packaged) and `intel-gpu-tools`. Never drivers, kernel modules, DKMS or firmware, and a runtime package that would upgrade something already installed is left out (the GPU becomes `gpu_limited`). Debian's `hashcat` pulls in `pocl-opencl-icd` and LLVM libraries. Everything new is recorded and removed at the end.
- **What gets loaded:** each CPU at 100% on all threads; RAM up to ~40% of available memory (the host always keeps >= 4 GiB plus guest headroom free); each GPU at full compute; each disk per its method. A 10-minute NVMe `write_read` run can write several hundred GB (a small fraction of a typical 300-700 TBW rating), if the user cares about wear.
- **Warnings** (`warnings` and each unit's `warnings`): host busy, SMART problems, hardware errors, RAID controller hiding SMART.
- **Afterwards:** logs are copied to a local folder, the tools and `/root/pve-stresstest` are removed from the host, and three reports (Markdown, HTML, PDF) are written locally, with the HTML opened in the browser. Ask whether they want to keep the tools (`--keep-packages`).

If you cannot ask (no interactive user), proceed only when the request itself clearly authorised the installs and the load (e.g. "run the full test and clean up afterwards"); even then never run units with `needs_confirmation: true` or `optional: true`. Otherwise stop after the plan and wait. Record any changes the user makes (skip a unit, a different path) and apply them in step 4.

Once confirmed, run prep for real. It installs the tools, records a 30 s idle baseline and rebuilds the inventory and plan with complete SMART data (same unit ids and order unless something changed):

```bash
PVESSH 'bash /root/pve-stresstest/prep.sh --out RUN --duration D'
PVESSH 'cat RUN/plan.json'
```

It ends with a `PREP SUMMARY` block. If packages were unavailable or failed (no internet, missing repo), tell the user which sub-tests will be skipped and carry on. Use this second `plan.json` from here on; if it differs from the one the user approved (a new skip, a changed method), tell them before running anything.

## 4. Run the units, strictly one at a time

Go through `plan.json` `.units[]` in `seq` order and run every unit with `status: "test"`, except those the user declined; `needs_confirmation` units only with the user's yes; `optional` pool units only if the user asked for them (run them after the HDDs). Never run two units together, and never start the next before the previous one has exited: overlapping load makes every number meaningless and can overheat a box.

Each unit's `command` is ready to run from `/root/pve-stresstest` and already contains `--out RUN/<out_dir>` with the run folder filled in. Long units outlive a normal tool call, and an SSH hiccup must not kill a test half-way. So launch each unit detached, then wait on its exit-code file in one long-lived SSH session (run that with `run_in_background` and a generous timeout, then read the result):

```bash
PVESSH "cd /root/pve-stresstest && nohup setsid bash -c '<command> > RUN/<out_dir>.console.log 2>&1; echo \$? > RUN/<out_dir>.rc' >/dev/null 2>&1 < /dev/null &"
PVESSH "while [ ! -f RUN/<out_dir>.rc ]; do sleep 20; done; cat RUN/<out_dir>.rc; tail -n 25 RUN/<out_dir>.console.log"
```

If you must build a command yourself (plan missing a field, user-chosen path), the patterns are:

| Unit | Command (in /root/pve-stresstest) |
|---|---|
| CPU (all sockets together) | `bash cpu.sh --no-install --duration D --out RUN/01-cpu` |
| RAM (all DIMMs together) | `bash ram.sh --no-install --duration D --out RUN/02-ram` |
| GPU n | `bash gpu.sh --duration D --gpu 0000:XX:00.0 --out RUN/03-gpu-N` (`gpu.sh --list` shows every GPU; `--all` tests them all one after another into `RUN/03-gpu/gpu<N>/`) |
| SSD, `write_read` | `bash disk.sh --no-install --mode file --path P --device /dev/X --profile nvme\|ssd --duration D --out RUN/04-ssd-X` |
| HDD, `write_read` | `bash disk.sh --no-install --mode file --path P --device /dev/X --profile hdd --duration D --out RUN/05-hdd-X` |
| any disk, `read_only_raw` | `bash disk.sh --no-install --mode readonly --device /dev/X --profile nvme\|ssd\|hdd --duration D --out RUN/04-ssd-X` (or `05-hdd-X`) |
| pool (optional) | `bash disk.sh --no-install --mode file --path <pool mountpoint> --profile ... --duration D --out RUN/06-pool-N` |

`--no-install` keeps every install in prep, so apt runs once and everything lands in one ledger (`gpu.sh` never installs anything and has no such flag). `disk.sh` exit 3 means it refused for safety (reason in its `summary.json` `refuse_reason`); for a `write_read` unit that refuses for lack of space, offer the `read_only_raw` command for the same disk instead.

After each unit, read its `summary.json` (status, scores, errors, warnings, skipped) and give the user a one-line update with progress, e.g. "SSD 2 of 4 done: 3,400 MB/s read, 52 °C, 0 errors; starting SSD 3" (illustrative). If a unit reports hardware errors (MCE/EDAC, RAM miscompares, new NVRM Xid lines or AMD/Intel GPU hang / reset / ring-timeout lines (`gpu_error_lines_after` > `_before`), disk I/O errors, SMART counters rising), stop the sweep and ask the user before continuing: something is genuinely wrong, and more load could make it worse. Check the actual log lines first: if a match is plainly unrelated (another device's boot message), say so and continue. A unit that exits non-zero or writes `status: skipped` is reported with its reason; carry on with the next unit.

Never pass a raw device to `disk.sh` except with `--mode readonly`, and never create, format, mount or resize anything to make room. ZFS: read the ZFS section of `references/safety-and-troubleshooting.md` so you can explain the ARC caveat in the report.

## 5. Copy the logs back and verify them

Choose a local folder (default `./pve-stress-test-<hostname>-<YYYY-MM-DD>/` in the current directory) and tell the user where it is. Copy it as one tar stream over the shared connection, then compare checksums, because step 8 deletes the host copy. `LC_ALL=C` makes `sort` order the files the same on Linux and macOS:

```bash
mkdir -p LOCAL && PVESSH 'tar -C /root/pve-stresstest -czf - run-XXXX' | tar -xzf - -C LOCAL
PVESSH 'cd RUN && find . -type f -exec sha256sum {} + | LC_ALL=C sort -k2' > LOCAL/host-sha256.txt
(cd LOCAL/run-XXXX && if command -v sha256sum >/dev/null; then find . -type f -exec sha256sum {} +; else find . -type f -exec shasum -a 256 {} +; fi | LC_ALL=C sort -k2 | diff - ../host-sha256.txt && echo VERIFIED)
```

Treat the logs as safe only once you see VERIFIED.

**Privacy:** the raw logs contain disk and board serial numbers (`hardware.json`, `*smartctl*`, `dmidecode-*`), the hostname, and sometimes MAC or IP addresses (kernel log excerpts, `lspci`, `guests.txt`). The reports must not repeat them. If the user wants to share the logs folder, tell them about these files and offer to redact them.

## 6. Look up reference values and compute "% of expected"

Read `references/reference-values.md`. For each scored result of each unit, find an expected value for **this exact model**: a manufacturer spec sheet, a well-known published benchmark, or a theoretical maximum you can calculate (e.g. DDR bandwidth from the real channel count). Look up each distinct model once and reuse it for identical drives or GPUs. Use web search when you have it; the starter table covers common homelab parts. Record the source next to every figure. If you cannot find a trustworthy reference, say so and judge the result by internal consistency instead (thread scaling, steadiness over time, agreement between identical units, agreement between two tools). Don't invent a number: a made-up reference is worse than none, because it turns a guess into a verdict.

`% of expected = measured / expected x 100` (for latency, where lower is better: `expected / measured x 100`). Leave out anything a script marked `valid: false` (cache-resident bandwidth, ARC-served reads, etc.) and say why. GPU hashcat scores carry `value` + `unit` (e.g. 12345.6 MH/s) and `hashes_per_s`; clpeak values are the best vector width for the GPU's own OpenCL platform. On AMD/Intel, check `summary.json` `.opencl.platform`: published hashcat figures mostly come from ROCm / Windows / Intel compute-runtime, so compare hashcat only with a reference from the same kind of runtime and lean on clpeak FP32 otherwise. Integrated GPUs (`gpu_type: integrated`) share RAM and power with the CPU: compare their bandwidth with the RAM's STREAM result and present their power as "shared with the CPU" (`power_note`). `read_only_raw` disks are scored on read results only.

## 7. Write the reports

**Markdown first.** Follow `references/report-template.md` exactly: header, how the test was done, the "% of expected" explanation, the at-a-glance table (one row per unit, "Not present" rows for absent parts, skipped rows with the reason), **Your hardware** (full inventory from `inventory.json` / `inventory.md`, which are already privacy-masked), baseline, then one section per unit in run order, overall verdict, prioritised recommendations, limits, longer burn-in commands, raw logs and cleanup. Save it as `LOCAL/pve-stress-report-<duration>.md` (e.g. `pve-stress-report-5min.md`).

**Then the HTML.** Copy `assets/report-template.html` to `LOCAL/pve-stress-report-<duration>.html` and fill it from the finished Markdown and the summaries, following the rules in its header comment: one nav link, one at-a-glance card, one headroom row and one sheet per **tested** unit; skipped and absent parts as `card skipped` with the reason; the "Your hardware" tables filled for every category. Use only numbers that are in the Markdown report. Remove every `{{...}}` placeholder and every example row you did not use; `grep -c '{{' file` must print 0.

**Then finish locally** (on this machine, not the host):

```bash
python3 <skill-dir>/scripts/finish_report.py --html LOCAL/pve-stress-report-<duration>.html
```

It embeds the web fonts so the HTML works offline, writes the PDF next to it (all details expanded) and opens the HTML in the default browser. If it reports that no PDF engine is available, tell the user the Markdown and HTML are complete and how to print the HTML to PDF from the browser. Finish by telling the user the three file paths.

Write for a homelab owner, not an engineer: explain each term once, give the number and then what it means, and make every recommendation a concrete action. Be honest about what was not tested.

## 8. Clean up the host

Only after step 5 printed VERIFIED (and the user agreed in step 3):

```bash
PVESSH 'bash /root/pve-stresstest/cleanup.sh --out RUN --confirm-logs-copied'   # add --keep-packages if they asked
```

It removes exactly the packages prep recorded (refusing if apt would remove anything else), deletes any leftover test files, the GPU tools' caches and the working folder, and prints a definite "Working dir: deleted" or "NOT deleted". Exit 3 means it skipped something for safety: report what it kept and why, and don't force it. Then close the shared connection with `ssh -O exit -o "ControlPath=$HOME/.ssh/cm-pvestress-%r@%h:%p" -p PORT USER@HOST`, delete the `pvessh` wrapper, and fill in the reports' Cleanup section with what was removed: update the Markdown and the HTML, then run `python3 <skill-dir>/scripts/finish_report.py --html <file.html> --no-open` again to refresh the PDF (the browser tab just needs a reload). Running cleanup before step 7 is also fine (the reports only need the local logs); then the Cleanup section can be written straight away.

## Rules that keep this safe

These rules exist because the user's VMs and data live on this box:
- Never write to raw block devices, never format, partition or mount, and never touch backup or VM image files. `write_read` disk tests only use the skill's own temporary file (`.pve-stresstest-fio-<pid>.tmp`), which is always deleted; a guard refuses any fio job aimed at anything else. Raw-device access happens only through `disk.sh --mode readonly`, which opens the device with `fio --readonly` and refuses any job that is not a pure read.
- Never change BIOS, power limits, governors, fan curves, GPU clocks/power limits, RAID controller settings or kernel parameters. The point is to measure the box as it really runs.
- Never start, stop, migrate or reconfigure guests, and never touch a passthrough (vfio) GPU.
- Install only from the host's configured apt repos, record what was new, and remove exactly that.
- Stop and ask whenever hardware errors appear, a disk is already failing SMART, or a method or path choice is unclear.
