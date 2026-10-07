# The skill folder, the `.zip` and the `.skill` file

This repository ships the skill in three forms. **They contain exactly the same files.** Only the packaging differs, so you can pick whichever suits you.

| | `skill/proxmox-hardware-stress-test/` | `dist/proxmox-hardware-stress-test.zip` | `dist/proxmox-hardware-stress-test.skill` |
|---|---|---|---|
| **What it is** | The plain source folder | A zip archive of that folder | The *same* zip archive, with a `.skill` extension |
| **Contents** | The skill | Same files | Same files |
| **Best for** | Reading on GitHub, editing, `git clone` into Claude Code | Downloading, inspecting and auditing offline, manual install | One-click install in Claude apps |
| **How to install** | Copy into `~/.claude/skills/` | Unzip into `~/.claude/skills/` | Upload in the app's skills settings |
| **Open it with** | Any file browser or editor | Any unzip tool | Any unzip tool (rename to `.zip` first if your OS insists) |

## Why both exist

- **The `.skill` file is for convenience.** Claude apps recognise the extension and install it in one step. Nothing is hidden inside it: it is an ordinary zip archive.
- **The `.zip` and the folder are for transparency.** This skill runs commands **as root on your server**, so you should be able to see exactly what it does. Browse the folder on GitHub, or download the `.zip` and read every file before you install it. Operating systems and GitHub treat `.zip` as a normal archive, so you don't need to rename anything.
- **The folder is the source of truth.** `tools/build.sh` makes both archives from it, so they can't drift apart. If you want to expand or change the skill, edit the folder and rebuild (see below).

## How to inspect a `.skill` file

A `.skill` file is a zip archive. Any of these works:

```bash
# List what's inside, without extracting
unzip -l proxmox-hardware-stress-test.skill

# Extract it to a scratch folder and read it
unzip proxmox-hardware-stress-test.skill -d /tmp/skill-check

# Or rename a copy to .zip and double-click it in your file manager
cp proxmox-hardware-stress-test.skill proxmox-hardware-stress-test-copy.zip
```

Every path in the archive should start with `proxmox-hardware-stress-test/`, and the file list should match the folder tree below.

Check that the `.skill` and `.zip` hold the same file list:

```bash
diff <(unzip -Z1 proxmox-hardware-stress-test.skill | sort) \
     <(unzip -Z1 proxmox-hardware-stress-test.zip   | sort) && echo "same files"
```

## Verify a download with SHA256SUMS

`dist/SHA256SUMS` lists the SHA-256 checksum of each archive. A checksum is a fingerprint of the file: if even one byte changes, the fingerprint changes. Download `SHA256SUMS` next to the archives, then run this in that folder:

```bash
# macOS
shasum -a 256 -c SHA256SUMS

# Linux / WSL
sha256sum -c SHA256SUMS
```

Each line should end in `OK`. If you only downloaded one of the two archives, the other line reports a missing file. That is fine (GNU `sha256sum` can hide it with `--ignore-missing`).

## How to modify the skill and rebuild

1. Edit the files in `skill/proxmox-hardware-stress-test/` (never edit the archives directly).
2. Rebuild the archives and checksums from the repository root:

   ```bash
   bash tools/build.sh
   ```

   This repacks the folder into `dist/proxmox-hardware-stress-test.skill` and `dist/proxmox-hardware-stress-test.zip` and rewrites `dist/SHA256SUMS`.
3. Check the result with `unzip -l` and the checksum commands above.
4. Commit the folder change and the new `dist/` files together, so all three forms stay identical.

More about changing the scripts (conventions, local checks, the release checklist) is in [developing.md](developing.md).

## What's inside (one line per file)

```
proxmox-hardware-stress-test/
├── SKILL.md                          The workflow Claude follows: questions, SSH, plan, run, report, cleanup
├── README.md                         The skill's own overview (features, requirements, safety, disclaimer)
├── assets/
│   └── report-template.html          The designed HTML report; Claude fills it in (fill rules in its header comment)
├── references/
│   ├── report-template.md            Markdown report structure, scoring rules and verdict thresholds
│   ├── reference-values.md           Where "expected" values come from, formulas, starter tables of common parts
│   └── safety-and-troubleshooting.md What the skill never does, SSH problems, ZFS, RAID/HBA, GPUs, longer burn-ins
└── scripts/
    ├── telemetry.sh                  Shared helpers (sourced): sensors, 1 Hz sampler, CSV and summary.json writers
    ├── prep.sh                       Hardware detection, plan-only pass, tool install + package ledger, idle baseline
    ├── inventory.py                  Full inventory + per-component test plan (inventory.json/.md, plan.json/.md)
    ├── cpu.sh                        CPU stress (stress-ng), sysbench, 7-Zip, boost clock, throttle counters
    ├── ram.sh                        RAM stress with data verification, STREAM, latency, sysbench, memtester
    ├── stream.c                      STREAM-style bandwidth test (Copy/Scale/Add/Triad), compiled on the host
    ├── latency.c                     Random pointer-chase memory latency test, compiled on the host
    ├── gpu.sh                        GPU stress (hashcat) + hashcat benchmarks + clpeak, per GPU
    ├── disk.sh                       fio tests for NVMe/SSD/HDD: test-file read+write, or read-only raw device
    ├── cleanup.sh                    Removes test files, exactly the installed packages, and the working folder
    └── finish_report.py              Embeds fonts in the HTML report, makes the PDF, opens it in your browser
```

## Where each file runs

| File(s) | Runs where | Notes |
|---|---|---|
| `SKILL.md`, `references/*`, `assets/report-template.html` | Read by Claude on **your computer** | Never copied to the host |
| `scripts/*.sh`, `scripts/inventory.py` | On the **Proxmox host**, as root | Copied to `/root/pve-stresstest/` with one `tar` stream over SSH |
| `scripts/stream.c`, `scripts/latency.c` | Compiled and run **on the host** by `ram.sh` | Uses `gcc`, which prep installs if missing (and removes afterwards) |
| `scripts/finish_report.py` | On **your computer** (macOS, Linux or Windows) | Python 3 standard library only; never copied to the host |

Everything copied to the host is deleted again by `cleanup.sh` once the logs are safely on your computer.
