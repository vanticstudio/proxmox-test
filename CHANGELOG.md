# Changelog

All notable changes to this project are recorded here.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project uses [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

Nothing yet.

## [1.0.0] - 2026-10-07

Initial public release.

### Added

- **Two-question start:** asks how long to load each part (30 s, 1, 5 or 10 minutes) and the SSH address of the Proxmox VE host.
- **Shared SSH connection:** every command goes through one multiplexed connection, so router IPS / fail2ban don't mistake the run for a brute-force attack. Key-based or Tailscale SSH only; no passwords.
- **Auto-discovery and plan (`prep.sh`, `inventory.py`):** full inventory of board, BIOS, every CPU socket, every DIMM slot, every GPU, every storage controller and disk (including disks behind HBAs and hardware RAID), NICs and sensors. A plan-only pass (no installs, no load) shows the test plan, skipped parts with reasons, packages to install, running guests and the estimated total time.
- **Sequential test units:** CPU -> RAM -> each GPU -> each SSD -> each HDD, plus optional pool units for multi-disk filesystems (ZFS mirror / RAIDZ, mdraid).
- **CPU (`cpu.sh`):** `stress-ng` load on all threads, `sysbench` single- and multi-thread, 7-Zip benchmark, throttle counters, per-socket results.
- **RAM (`ram.sh`, `stream.c`, `latency.c`):** `stress-ng --vm --verify`, STREAM-style bandwidth, pointer-chase latency and `memtester`, sized so the host and its guests keep enough free memory.
- **GPU (`gpu.sh`):** one unit per GPU; `hashcat` and `clpeak` over OpenCL on NVIDIA; telemetry and best-effort benchmarks on AMD / Intel; passthrough (vfio-pci) GPUs are never touched.
- **Disks (`disk.sh`):** `fio` read/write tests on a temporary file (`write_read`), or read-only tests on the raw device (`read_only_raw`) for disks without a usable filesystem; NVMe, SATA SSD and HDD profiles; ZFS ARC hit-rate check.
- **Per-second telemetry (`telemetry.sh`):** CPU package power, temperatures, clocks, GPU power / clock / temperature, drive temperatures; missing sensors are recorded as `n/a`.
- **Health checks before and after each part:** machine-check / EDAC / PCIe AER errors, RAM verification, NVIDIA Xid errors, SMART and NVMe error counters. The sweep stops and asks if errors appear.
- **Scored report:** "% of expected" against spec sheets, published benchmarks or theoretical maxima, with the source for every reference and a verdict per part.
- **Three report formats:** Markdown, a designed HTML report (light / dark mode, works offline) and a PDF; `finish_report.py` embeds fonts, renders the PDF with a local headless browser and opens the HTML automatically.
- **Log copy and verification:** logs are copied back as one tar stream and checked with SHA-256 before anything is deleted on the host.
- **Cleanup (`cleanup.sh`):** removes exactly the packages recorded in the install ledger, any leftover test files and the working folder.
- **Developer mock hook:** `PVE_STRESS_MOCK_DIR` lets `inventory.py` run against simulated hosts on any machine.
- **Packaging:** `dist/` with identical `.skill` and `.zip` archives plus `SHA256SUMS`, rebuilt by `tools/build.sh`.

[Unreleased]: https://github.com/<your-github-user>/proxmox-hardware-stress-test/compare/v1.0.0...HEAD
[1.0.0]: https://github.com/<your-github-user>/proxmox-hardware-stress-test/releases/tag/v1.0.0
