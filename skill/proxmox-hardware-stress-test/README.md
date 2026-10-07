# proxmox-hardware-stress-test (Claude skill)

A Claude Code skill that stress-tests and benchmarks the hardware of your Proxmox VE host over SSH, one part at a time, and writes a plain-English report that tells you whether each part performs as it should.

- **Finds everything on its own:** it inventories the whole box (board and BIOS, every CPU socket, every DIMM slot, every GPU, every NVMe/SATA/SAS drive including those behind HBAs and RAID controllers, NICs) and builds a test plan that scales to it. A mini PC with one SSD and no GPU and a dual-socket server with several GPUs and a shelf of drives get the same report structure, covering every single part.
- **Order:** CPU -> RAM -> GPU 1..n -> SSD 1..n -> HDD 1..n, strictly one after another.
- **You choose the length:** a 30-second quick test, or 1, 5 or 10 minutes of full load per part (benchmarks add a few minutes on top).
- **Telemetry every second:** CPU package power (RAPL), temperatures, clocks, throttle counters, GPU power/clock/temperature, drive temperatures and throughput.
- **Health checks before and after each part:** machine-check / EDAC / PCIe AER errors, RAM data verification, GPU driver (Xid) errors, SMART and NVMe error counters.
- **Disk-safe for any layout:** disks with a filesystem of their own get a full read/write test on a temporary file; disks without one (LVM-thin, ZFS/Ceph/mdraid members, hardware RAID volumes without a filesystem) are read in read-only mode, so nothing on them is ever written. Disks and GPUs passed through to a running VM are skipped.
- **Scored report:** every result is compared with the manufacturer's spec sheet, well-known published results or the theoretical maximum, as "% of expected", with a verdict per part and concrete recommendations. Where no reference exists, it says so instead of making one up.
- **Three report formats:** a Markdown report, a designed HTML report (light and dark mode, works offline) that opens in your browser automatically, and a PDF of the same page.
- **Cleans up after itself:** removes exactly the packages it installed and its working folder, after the logs are copied to your machine and checksum-verified.

## What it uses

`stress-ng`, `sysbench` and `7-Zip` (CPU); a bundled STREAM and pointer-chase latency test, `stress-ng --vm --verify` and `memtester` (RAM); `hashcat` and `clpeak` over OpenCL (NVIDIA GPU); `fio`, `smartctl` and `nvme-cli` (disks). All installed from your host's own apt repos.

## Requirements

- Proxmox VE 8 or 9 (Debian 12/13), Intel or AMD CPU. GPU optional (NVIDIA tested; AMD/Intel get telemetry and best-effort benchmarks).
- [Claude Code](https://claude.com/claude-code) (or another Claude client that supports skills and can run shell commands) on a machine that can SSH to the host.
- **Key-based SSH as root** (or Tailscale SSH). The skill never asks for or stores a password. If you don't have a key yet: `ssh-keygen -t ed25519` then `ssh-copy-id root@<your-pve-ip>`.
- For full read/write disk scores, some free space on each disk: about 2x the test file (16 GB for an SSD, 8 GB for an HDD), on a mounted filesystem (e.g. `/var/lib/vz` or a directory storage). Disks without one are still tested, read-only.
- On your own machine: `python3` (for the HTML/PDF finishing step). The PDF is made with a locally installed Chrome/Chromium or Edge in headless mode if one is found; otherwise you can print the HTML to PDF from the browser.
- Internet access from the host for `apt` (to install the test tools). Without it, the tests that need missing tools are skipped and the report says so.
- Works from macOS, Linux or WSL (bash or zsh). On Windows OpenSSH, the shared-connection options are not available.

## Install

Copy the folder into your Claude skills directory:

```bash
mkdir -p ~/.claude/skills
cp -r proxmox-hardware-stress-test ~/.claude/skills/
```

Or, if you got the packaged `proxmox-hardware-stress-test.skill` file, install it through your Claude client's skill settings (claude.ai: Settings -> Capabilities -> Skills -> upload; Claude Code: unzip it into `~/.claude/skills/`).

## Use

Start Claude Code and ask, for example:

> Stress test my Proxmox server and tell me if everything is running properly.

> Run a 5-minute burn-in on my homelab box, I want to check the CPU temps and the NVMe speed.

The skill then:
1. Asks how long to test each part (30 s / 1 min / 5 min / 10 min) and the host's SSH address.
2. Checks the SSH connection (and explains key setup if needed).
3. Copies its scripts to `/root/pve-stresstest/` on the host and runs a **plan-only** pass (nothing installed, no load): it inventories your hardware and shows you the inventory and a test plan: every component, how each one will be tested (write+read on a test file, read-only, or skipped, always with the reason), running VMs/containers, packages to install, and the estimated total time. Anything risky (a USB disk, a disk with failing SMART, a raw disk that belongs to a stopped VM) is asked about separately. Nothing is installed or loaded until you say yes.
4. Installs the test tools, records an idle baseline, then runs each unit one after another (CPU, RAM, each GPU, each SSD, each HDD), telling you the headline result and progress as it goes.
5. Copies all logs back to a local folder and verifies them by checksum.
6. Looks up reference values for your exact models and writes the Markdown report, the HTML report and a PDF, then opens the HTML in your browser and tells you where all three files are.
7. Cleans up the host: removes exactly the packages it installed, any test files and its working folder.

Rough total time (estimate): roughly 15 minutes for the 30-second option on a typical single-GPU, two-disk box, up to over an hour for 10 minutes per part. Every extra disk or GPU adds about the chosen duration plus a minute; the plan shows the real total for your hardware before anything starts.

## Sample output

Illustrative example of the at-a-glance table (made-up round numbers for a generic box, shown for format only; your numbers will differ):

| Part | Key score(s) | Part score (% of expected) | Peak temp | Peak power | Verdict |
|---|---|---|---|---|---|
| **CPU** | 7-Zip 120,000 MIPS; sysbench 1T 1,500 / 16T 20,000 events/s | **~98%** | 78 °C | 150 W | Running optimally |
| **RAM** | STREAM 60 GB/s; latency 90 ns; 16 GB verified with 0 errors | **~97%** of typical (80% of theoretical max) | 80 °C (CPU package) | 140 W (CPU package) | Running optimally |
| **GPU** | MD5 30.0 GH/s; FP32 15.0 TFLOPS; 400 GB/s | **~97%** | 65 °C | 200 W | Running optimally |
| **SSD** | 3,500 MB/s read; 3,000 MB/s write; 500K / 450K IOPS | **~99%** | 45 °C (controller 55 °C) | not measurable (no sensor) | Running optimally |
| **HDD** | 200 MB/s read; 195 MB/s write | **~98%** | 35 °C | not measurable (no sensor) | Running optimally |

> **Is it running optimally?** Yes. The CPU scored close to published results for its model, held a steady clock under full load, and stayed well below its temperature limit with no errors. *(Made-up example wording.)*

With more hardware the table simply gets more rows ("SSD 1", "SSD 2", "GPU 2" ...); a part your box doesn't have is one "Not present" row. Right after the table comes **Your hardware**: the full inventory with specs for every component. Each tested unit also gets a stress-phase table (idle vs load vs after), a scores table with the reference and its source, health before/after, and recommendations; the report ends with an overall verdict, the limits of the test, and commands for a longer burn-in.

## Safety

- Disk write tests only use a temporary file inside a mounted filesystem (capped at 8 GB for SSDs, 4 GB for HDDs, at most 10% of free space) and always delete it. Disks without a usable filesystem are only read, through a read-only mode. **Never a raw-disk write**, no formatting, no partitioning, no RAID controller changes.
- No changes to BIOS, power limits, governors, clocks, fan curves or kernel parameters.
- VMs and containers are never started or stopped. If some are running, the test still works but scores may read lower (the skill tells you). GPUs passed through to a VM (vfio-pci) are never touched.
- The RAM test leaves at least 4 GiB plus your guests' headroom free and stops itself if memory runs low.
- Packages come only from your host's configured apt repos and are removed again at the end (only the ones the test installed).
- Privacy: the raw logs (`hardware.json`, `smart-*.txt`, `*smartctl*.txt`, `dmidecode-*.txt`, `guests.txt`) contain your hostname, serial numbers and guest names. The report leaves them out, but redact the raw logs before sharing them.

## Disclaimer

Stress testing deliberately runs hardware at full load. On healthy, properly cooled hardware that is safe and is exactly what burn-in tests are for, but it can expose an existing fault (a failing disk, unstable RAM overclock, poor cooling) at that moment. Make sure your backups are current, and don't run it on a production host during working hours. You run it at your own risk; the authors accept no liability for data loss, downtime or hardware damage. The "expected" values are approximate references, not guarantees, and results on a busy host are not comparable with lab reviews.

## Files

```
proxmox-hardware-stress-test/
├── SKILL.md                         workflow Claude follows
├── README.md                        this file
├── assets/
│   └── report-template.html         designed HTML report (filled in by Claude)
├── references/
│   ├── report-template.md           Markdown report structure, scoring, verdicts
│   ├── reference-values.md          where expected values come from + starter tables
│   └── safety-and-troubleshooting.md
└── scripts/                         run on the host as root
    ├── telemetry.sh                 shared sensor/CSV/JSON helpers (sourced)
    ├── prep.sh                      hardware detection, tool install, idle baseline (--plan-only: plan only)
    ├── inventory.py                 full inventory + per-component test plan (called by prep.sh)
    ├── cpu.sh                       CPU stress + sysbench + 7-Zip
    ├── ram.sh, stream.c, latency.c  RAM stress + bandwidth + latency + memtester
    ├── gpu.sh                       GPU stress + hashcat + clpeak
    ├── disk.sh                      fio tests for NVMe/SSD/HDD (file-based, or read-only raw)
    ├── cleanup.sh                   removes test files, installed packages, working dir
    └── finish_report.py             runs locally: embeds fonts, makes the PDF, opens the HTML
```

**Developer testing (not used in a real run):** `inventory.py` has a test hook: with `PVE_STRESS_MOCK_DIR=<fixture dir>` set, it reads `/sys`, `/proc`, `/dev` and `/etc/pve` from `<fixture dir>/root/` and takes every command's output from `<fixture dir>/commands.json`. That lets the inventory and test plan be checked against simulated hosts (multi-socket servers, HBAs, hardware RAID, ZFS/Ceph/mdraid, passthrough, mini PCs) on any machine. Details are in the script's header.
