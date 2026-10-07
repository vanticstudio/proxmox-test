# Proxmox Hardware Stress Test (Claude skill)

**A Claude skill that stress-tests every part of your Proxmox VE host over SSH, one part at a time, and tells you in plain English whether each part runs as well as it should.**

You ask Claude something like *"stress test my Proxmox server and tell me if everything is running properly"*. The skill finds all your hardware, shows you a test plan, loads each part in turn while logging sensors every second, compares the results with spec sheets, and hands you a scored report as Markdown, HTML and PDF.

> A **skill** is a folder of instructions and scripts that Claude loads when a task needs it. This repository is that folder, plus ready-made packages and documentation.

---

## Contents

- [What it does](#what-it-does)
- [Example result](#example-result)
- [Quick start](#quick-start)
- [What's in the box: `skill/` vs `dist/`](#whats-in-the-box-skill-vs-dist)
- [Safety model](#safety-model)
- [Requirements](#requirements)
- [Repository layout](#repository-layout)
- [Contributing](#contributing)
- [Licence](#licence)
- [Disclaimer](#disclaimer)

---

## What it does

| Step | What happens |
|---|---|
| **1. Two questions** | How long to load each part: **30 seconds** (quick look), **1**, **5** or **10 minutes**. And the **SSH address** of your Proxmox host. |
| **2. Auto-discovery** | Inventories the whole box: board and BIOS, every CPU socket, every RAM slot (DIMM), every GPU, every NVMe / SATA / SAS drive (including drives behind HBAs and RAID controllers), NICs and sensors. A mini PC and a dual-socket server get the same report structure. |
| **3. Plan first, nothing installed** | A *plan-only* pass shows you every part, how it will be tested (or why it is skipped), which packages would be installed, running guests, and the estimated total time. Nothing is installed or loaded until you say yes. |
| **4. One part at a time** | **CPU -> RAM -> each GPU -> each SSD -> each HDD**, strictly in sequence, so every temperature and power reading belongs to one part only. |
| **5. Telemetry every second** | CPU package power (RAPL), temperatures, clocks and throttle counters; GPU power, clock and temperature; drive temperatures and throughput. Health checks before and after each part (machine-check / EDAC errors, RAM data verification, GPU driver errors, SMART counters). |
| **6. Scored, not just measured** | Each result is shown as **"% of expected"** against the manufacturer's spec sheet, a well-known published benchmark or a theoretical maximum, with a verdict per part. If there is no trustworthy reference, the report says so instead of making one up. |
| **7. Three reports** | A Markdown report, a designed HTML report (light and dark mode, works offline) that **opens in your browser automatically**, and a PDF of the same page. |
| **8. Cleans up** | Copies the logs to your computer, verifies them by checksum, then removes exactly the packages it installed and its working folder from the host. |

Tools used on the host (installed from your own apt repos, removed afterwards): `stress-ng`, `sysbench` and 7-Zip for the CPU; a bundled STREAM bandwidth test, a pointer-chase latency test, `stress-ng --verify` and `memtester` for RAM; `hashcat` and `clpeak` over OpenCL for NVIDIA GPUs; `fio`, `smartctl` and `nvme-cli` for disks.

More detail: [docs/how-it-works.md](docs/how-it-works.md) and [docs/report-format.md](docs/report-format.md).

## Example result

> **Illustrative example only.** Made-up round numbers for a generic box, to show the format. They are not measurements from any real machine; your numbers will differ.

| Part | Key score(s) | % of expected | Peak temp | Peak power | Verdict |
|---|---|---|---|---|---|
| **CPU** | 7-Zip 100,000 MIPS | ~98% | 80 °C | 150 W | Running optimally |
| **RAM** | 50 GB/s bandwidth; 16 GB verified, 0 errors | ~95% | 75 °C (CPU) | 120 W (CPU) | Running optimally |
| **GPU 1** | FP32 10.0 TFLOPS | ~97% | 70 °C | 200 W | Running optimally |
| **SSD 1** | 3,000 MB/s read; 2,500 MB/s write | ~99% | 50 °C | not measurable | Running optimally |
| **HDD 1** | 200 MB/s read; 200 MB/s write | ~98% | 40 °C | not measurable | Running optimally |

More GPUs or disks simply add rows ("SSD 2", "HDD 3" ...); a part your box doesn't have shows as one "Not present" row.

## Quick start

Pick whichever install suits you. Full step-by-step instructions are in **[docs/installation.md](docs/installation.md)**.

| Option | For | In short |
|---|---|---|
| **A. One-click `.skill` file** | Claude apps with skill upload | Download `dist/proxmox-hardware-stress-test.skill` and upload it in your Claude app's skill settings. |
| **B. Claude Code from the zip** | Claude Code users | Unzip `dist/proxmox-hardware-stress-test.zip` into `~/.claude/skills/`. |
| **C. Clone the repo** | People who want to read or change the code | Clone, then copy `skill/proxmox-hardware-stress-test/` into `~/.claude/skills/`. |

Then make sure you can log in to the host with an SSH key (the skill never asks for a password):

```bash
ssh-keygen -t ed25519              # only if you don't have a key yet
ssh-copy-id root@192.0.2.10        # use your Proxmox host's address
```

And ask Claude, for example:

> Run a 5-minute burn-in on my Proxmox box at 192.0.2.10 and check the CPU temps and NVMe speed.

Repository: `https://github.com/<your-github-user>/proxmox-hardware-stress-test`

## What's in the box: `skill/` vs `dist/`

**The `.skill` file, the `.zip` file and the `skill/proxmox-hardware-stress-test/` folder all contain exactly the same files.** They are three ways of getting the same skill:

| You have | What it is | Use it to |
|---|---|---|
| `dist/proxmox-hardware-stress-test.skill` | A zip archive with a different file extension | Install in one click in a Claude app |
| `dist/proxmox-hardware-stress-test.zip` | The same archive with a `.zip` extension | Open, inspect or audit it with any unzip tool, or install it in Claude Code |
| `skill/proxmox-hardware-stress-test/` | The unpacked source folder | Read, review, change or extend the skill |

- **Want to look inside a `.skill`?** Rename it to `.zip`, or run `unzip -l proxmox-hardware-stress-test.skill`.
- **Want to check a download?** `dist/SHA256SUMS` lists the checksums: `cd dist && shasum -a 256 -c SHA256SUMS` (macOS) or `sha256sum -c SHA256SUMS` (Linux).
- **Changed something in `skill/`?** Run `tools/build.sh` to rebuild both archives and the checksum file.

Full explanation: **[docs/packages-explained.md](docs/packages-explained.md)**.

## Safety model

The skill runs on a box that holds your VMs and data, so it is deliberately cautious:

- **Never writes to a raw disk.** No formatting, partitioning, mounting or resizing. Write tests use only one temporary file (`.pve-stresstest-fio-<pid>.tmp`) on a mounted filesystem, capped in size, and always deleted.
- **Read-only for pool members.** Disks without their own filesystem (ZFS / Ceph / mdraid members, LVM-only disks, hardware RAID volumes) are only read, with `fio --readonly`; a guard refuses any job that is not a pure read.
- **No tuning.** Never changes BIOS, power limits, CPU governors, fan curves, GPU clocks, RAID controller settings or kernel parameters.
- **Hands off your guests.** Never starts, stops, migrates or reconfigures VMs or containers, and never touches a GPU passed through to a VM.
- **Removes what it installed.** Packages come only from the host's own apt repos; the new ones are recorded and exactly those are removed at the end.
- **Asks first.** Nothing is installed or loaded before you approve the plan; risky disks (failing SMART, USB, a stopped VM's raw disk) are asked about one by one; the sweep stops if hardware errors appear.

Details and how to report a safety problem: **[SECURITY.md](SECURITY.md)**.

## Requirements

**On your computer**

| Need | Notes |
|---|---|
| [Claude Code](https://claude.com/claude-code), or a Claude app with skills | It must be able to run shell commands on your computer (to reach the host over SSH). |
| `ssh` | With key-based login to the host (or Tailscale SSH). |
| `python3` | For the final HTML/PDF step (standard library only). |
| Chrome, Chromium, Edge or Brave (optional) | Used headless to make the PDF. Without one you can print the HTML to PDF from your browser. |

Works from macOS, Linux or WSL.

**On the Proxmox host**

| Need | Notes |
|---|---|
| Proxmox VE 8 or 9 | Debian 12 / 13, Intel or AMD CPU. GPU optional (NVIDIA fully tested; AMD / Intel get telemetry and best-effort benchmarks). |
| Root SSH | Or a user with passwordless `sudo`. |
| apt access | To install the test tools. Without internet, tests that need missing tools are skipped and the report says so. |
| Some free space (for full disk scores) | About 2x the test file (16 GB on an SSD, 8 GB on an HDD) on a mounted filesystem. Otherwise the disk is tested read-only. |

## Repository layout

```
proxmox-hardware-stress-test/
├── README.md                  you are here
├── LICENSE                    MIT
├── CHANGELOG.md               release history
├── CONTRIBUTING.md            how to help (hardware reports, code, docs)
├── SECURITY.md                what the skill can and cannot touch
├── skill/
│   └── proxmox-hardware-stress-test/   the skill itself (source of truth)
│       ├── SKILL.md           the workflow Claude follows
│       ├── README.md          the skill's own short readme
│       ├── assets/            HTML report template
│       ├── references/        report structure, reference values, safety notes
│       └── scripts/           scripts run on the host (+ one run locally)
├── dist/                      built by tools/build.sh
│   ├── proxmox-hardware-stress-test.skill
│   ├── proxmox-hardware-stress-test.zip
│   └── SHA256SUMS
├── docs/
│   ├── installation.md
│   ├── packages-explained.md
│   ├── how-it-works.md
│   ├── report-format.md
│   └── developing.md
├── tools/
│   └── build.sh               rebuilds dist/ from skill/
└── .github/                   issue templates, PR template, CI workflow
```

## Contributing

Hardware results, bug reports and improvements are welcome, especially from hardware the skill hasn't seen yet. Start with **[CONTRIBUTING.md](CONTRIBUTING.md)** and, for code changes, **[docs/developing.md](docs/developing.md)**. Please never include personal or host data (hostnames, IPs, serial numbers) in issues or pull requests.

## Licence

[MIT](LICENSE).

## Disclaimer

Stress testing deliberately runs hardware at full load. On healthy, well-cooled hardware that is safe and is exactly what burn-in tests are for, but it can expose an existing fault (a failing disk, unstable RAM overclock, poor cooling) at that moment. Keep your backups current and don't run it on a production host during working hours. **You use it at your own risk**; the authors accept no liability for data loss, downtime or hardware damage. The "expected" values are approximate references, not guarantees.

This is an independent community project. It is **not affiliated with, endorsed by or sponsored by Proxmox Server Solutions GmbH or Anthropic**. Proxmox and Claude are trademarks of their respective owners.
