---
name: Bug report
about: Something in the skill, a script or the report did not work as expected
title: "[Bug] "
labels: bug
assignees: ""
---

> **Before you attach anything: redact personal details.** Replace IP addresses,
> hostnames, serial numbers, MAC addresses, usernames and disk WWNs/IDs with
> placeholders (for example `192.0.2.10`, `pve-host`, `SERIAL-REDACTED`).
> Raw logs such as `hardware.json`, `dmidecode-*` and `smartctl` output contain
> full serial numbers (`inventory.json` masks them, but check it anyway).

## What happened?

A clear, short description of the problem.

## What did you expect to happen?

## Which step or script?

- [ ] Step 1-2: questions / SSH connection
- [ ] `prep.sh` / `inventory.py` (discovery and test plan)
- [ ] `cpu.sh`
- [ ] `ram.sh`
- [ ] `gpu.sh`
- [ ] `disk.sh` (SSD or HDD)
- [ ] `telemetry.sh`
- [ ] `cleanup.sh`
- [ ] `finish_report.py` / the Markdown, HTML or PDF report
- [ ] Not sure

## How to reproduce

1. Test length chosen (30 s / 1 / 5 / 10 min per part):
2. What you asked Claude:
3. What happened next:

## Your setup

| | |
|---|---|
| Proxmox VE version (`pveversion`) | e.g. 9.x |
| Kernel (`uname -r`) | |
| CPU vendor (Intel / AMD), sockets | |
| GPU(s), if any | |
| Disk layout (ZFS, LVM, HBA/RAID, ...) | |
| Connected as root or with sudo? | |
| Claude app used (Claude Code, desktop, web) | |
| Skill version (see `CHANGELOG.md`) | |

## Logs or error output (redacted)

```text
Paste the relevant lines here. Shorter is better.
```

## Anything else?
