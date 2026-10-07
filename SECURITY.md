# Security and safety

This skill runs as **root** on a Proxmox VE host that holds your VMs, containers and data. This page explains exactly what it can and cannot touch, and how to report a problem.

## Contents

- [What the skill touches](#what-the-skill-touches)
- [What it never does](#what-it-never-does)
- [Disk test files: naming and cleanup](#disk-test-files-naming-and-cleanup)
- [The package ledger](#the-package-ledger)
- [Credentials and privacy](#credentials-and-privacy)
- [Reporting a safety issue](#reporting-a-safety-issue)
- [Supported versions](#supported-versions)

---

## What the skill touches

| On the host | What and why |
|---|---|
| `/root/pve-stresstest/` | Its working folder: the scripts, the run logs and caches. Deleted at the end, after the logs are copied to your computer and checked by checksum. |
| CPU, RAM, GPU | Loaded to 100% one part at a time. The RAM test uses at most about 40% of available memory and always leaves at least 4 GiB plus your guests' headroom free; a watchdog stops it if memory runs low. |
| Disks with their own filesystem | One temporary test file per disk (see below), then deleted. |
| Disks without one (ZFS / Ceph / mdraid members, LVM-only, RAID volumes) | **Read only**, with `fio --readonly` on the device. |
| apt packages | Test tools installed from the host's own configured repos, recorded, and removed at the end. |

On **your computer** it writes only the copied logs and the three reports (Markdown, HTML, PDF) into a local folder, and a small temporary SSH wrapper script that is deleted at the end.

## What it never does

- **Never writes to a raw block device** (`/dev/sdX`, `/dev/nvmeXn1`, LVs, zvols). Raw-device access happens only in read-only mode, where `fio` opens the device with `--readonly` and the script refuses (exit 3) any job that is not a pure read.
- **Never formats, partitions, mounts or resizes** anything, never changes filesystem or ZFS properties, and never touches backup or VM image files.
- **Never changes RAID controller or HBA settings**, rebuilds arrays or runs controller self-tests. Only read-only queries are used.
- **Never changes BIOS, power limits, CPU governors, fan curves, GPU clocks / power limits or kernel parameters.** The point is to measure the box as it really runs; suggested changes go in the report as recommendations.
- **Never starts, stops, migrates, snapshots or reconfigures guests**, and never touches a GPU bound to `vfio-pci` (passed through to a VM).
- **Never runs two parts at once**, and stops to ask you if hardware errors appear (machine-check / EDAC, RAM miscompares, GPU Xid, rising SMART counters, kernel I/O errors).
- **Never installs from anywhere but your host's configured apt repos.**

Disks that need extra care (failing SMART, USB-attached, the raw disk of a stopped VM) are asked about one by one, and are not tested without a clear yes.

## Disk test files: naming and cleanup

- Write tests use a single file named **`.pve-stresstest-fio-<pid>.tmp`** inside a mounted, writable filesystem that lives on that disk.
- Size is capped at the smallest of: 8 GB (SSD / NVMe) or 4 GB (HDD), and 10% of free space. The test refuses to run if free space is less than twice the file size.
- A guard refuses any `fio` job whose target isn't the skill's own test file.
- The file is deleted when the test ends, also on Ctrl-C, errors and hang-ups (an exit trap), and every test file is registered in `/root/pve-stresstest/.testfiles`.
- `cleanup.sh` sweeps again: it deletes registered files and searches mounted local filesystems (up to 4 levels deep) for that name. It deletes **only regular files** (not symlinks) named `.pve-stresstest-fio-*` / `pve-stresstest-fio*`; nothing else on those filesystems is touched.
- It stops only leftover processes whose command line or working folder belongs to the skill; other `stress-ng` / `fio` processes are reported, never killed.
- If a run was abandoned, `bash /root/pve-stresstest/cleanup.sh --dry-run` shows what would be removed.

## The package ledger

1. `prep.sh` checks which tools are missing, installs them from your apt repos and records **only the packages that were not installed before** (including dependencies) in `<run folder>/installed-packages.txt`, the **ledger**.
2. `cleanup.sh` removes **exactly** the packages in that ledger. It simulates the removal with apt first and **refuses** if apt would remove anything not on the list, or any protected package (Proxmox / PVE, kernel, ZFS, NVIDIA, systemd, apt ...). `apt autoremove` runs only if its simulation touches ledger packages only.
3. If something was skipped for safety, cleanup exits with code 3 and prints what it kept and why. You can keep the tools on purpose with `--keep-packages`.

One caveat: if another process installs packages at exactly the same moment as prep (e.g. unattended upgrades), they could appear in the ledger. Cleanup prints the list before removing, so glance at it.

## Credentials and privacy

- **No passwords.** The skill never asks for, stores or passes a password. It needs key-based SSH (or Tailscale SSH) and uses one shared SSH connection for the whole run.
- **Reports leave out identifiers:** no serial numbers, IP addresses, MAC addresses, UUIDs/WWNs or passwords. The inventory files they are built from (`inventory.json` / `inventory.md`) have no hostname or IP addresses, mask serials and MACs to the last 4 characters and list guests by ID only. Your own copy of a report may still show the hostname (and guest or storage names); ask Claude to replace them before you share it.
- **Raw logs are not masked:** `hardware.json`, `*smartctl*`, `smart-*.txt`, `dmidecode-*`, `guests.txt` and kernel log excerpts can contain serials, the hostname and IP / MAC addresses. Redact them before sharing.

## Reporting a safety issue

If the skill wrote, deleted or changed anything it shouldn't have, touched a guest or a passthrough device, or could be made to do so, please report it **privately**:

1. Go to the repository's **Security** tab: `https://github.com/vanticstudio/proxmox-test/security/advisories/new`
2. Choose **Report a vulnerability** and describe what happened, the step (plan, which test unit, cleanup), the storage / GPU layout in general terms, and the relevant log lines (redacted).

Please don't open a public issue for safety problems until a fix is out. You'll get an acknowledgement as soon as the maintainer can, and credit in the changelog if you'd like it.

## Supported versions

| Version | Supported |
|---|---|
| 1.0.x | Yes |
| Older | No |
