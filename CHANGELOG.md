# Changelog

All notable changes to this project are recorded here.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project uses [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

Nothing yet.

## [1.1.0] - 2026-10-08

AMD and Intel GPUs, discrete and integrated, are now stress-tested and benchmarked like NVIDIA cards.

### Added

- **AMD and Intel GPU testing (`gpu.sh`):** AMD (`amdgpu`) and Intel (`i915` / `xe`) GPUs, discrete cards as well as integrated GPUs and APUs, get the same hashcat OpenCL stress phase, hashcat benchmarks (MD5, NTLM, SHA-256, WPA) and clpeak as NVIDIA. The GPU's OpenCL device is found by probing each installed runtime on its own with `clinfo` and matching the PCI address (or vendor and position); hashcat and clpeak then see only that runtime and device (`OCL_ICD_VENDORS`), so a second GPU, an NVIDIA card or the pocl CPU runtime is never loaded by mistake. `RUSTICL_ENABLE=radeonsi,iris` is exported for Mesa rusticl (and `RUSTICL_FEATURES=fp64` on AMD).
- **Vendor-neutral fallback:** if hashcat refuses a Mesa device it is retried once with `--force` (recorded as a warning); if it still can't run, the stress phase uses clpeak's compute and bandwidth kernels in a loop (`stress_method: clpeak-loop`). With no usable OpenCL runtime the stress phase is skipped with the exact reason and idle telemetry is still recorded.
- **AMD/Intel telemetry (`telemetry.sh`):** new `gpu_query_ext` with edge / junction / memory temperature, power and its source, core clock and its maximum, memory clock, busy %, VRAM and GTT use, fan rpm and %, power limit, PCIe link and Intel throttle reasons, from sysfs and hwmon (amdgpu `gpu_busy_percent`, `pp_dpm_*`, `mem_info_*`; i915 `gt_act_freq_mhz`, `throttle_reason_*`; xe `tile*/gt*/freq*`; hwmon power or energy counters). Integrated Intel GPUs report power from the RAPL "uncore" domain and AMD APUs the APU package, both marked "shared with CPU". Optional busy-% helpers: `intel_gpu_top` (Intel) and `radeontop` (AMD, only when sysfs has no busy counter). New helpers `gpu_index_for_pci`, `gpu_is_integrated_pci`, `gpu_util_helper_start` / `gpu_util_helper_stop`.
- **GPU summary fields:** `gpu_type` (discrete / integrated), `render_node`, `opencl` (platform, device, ICD, match method), `stress_method`, `power_note`, `gpu_error_lines_before/after` (new amdgpu / i915 / xe hang, reset, ring-timeout and page-fault lines for that PCI address), and AMD/Intel stress statistics `core_max_mhz`, `clock_vs_max_pct`, `junction_c_max`, `mem_temp_c_max`, `throttle_samples`, `power_source`.
- **Containers sharing an AMD/Intel GPU** (`/dev/dri` passed into an LXC container, e.g. an iGPU used for transcoding) are named in a warning; the GPU is still tested.
- **Reference values:** AMD (RX 500 to RX 7900 XTX, Radeon Pro W6600 / W7600), AMD APU (Radeon 680M / 780M, Vega 8 / 11), Intel Arc (A310 to B580) and Intel iGPU (UHD 630 / 730 / 770, Iris Xe, N100) spec FP32 and memory bandwidth, approximate hashcat MD5, and how to judge integrated GPUs (shared memory bandwidth and power) and Mesa runtimes.
- **Developer fake-root hook:** `PVE_STRESS_SYSFS_ROOT` makes the GPU reads of `telemetry.sh`, `gpu.sh` and `prep.sh` come from a fake sysfs tree, so the AMD/Intel code can be tested on any machine with fake GPU tools on `PATH` (see `docs/developing.md`). Reads only; never set on a real host.
- **Troubleshooting:** an "AMD and Intel GPUs" section covering the OpenCL runtimes per Debian release, `RUSTICL_ENABLE`, render nodes, package simulation, Intel generations, Arc on older kernels and integrated GPUs.

### Changed

- **`prep.sh --gpu-tools auto`** now also installs, for every AMD/Intel GPU the host drives, the userland OpenCL runtime that fits the Debian release and GPU generation: `mesa-opencl-icd` (Mesa rusticl; AMD needs Mesa 23.1+, from `bookworm-backports` on PVE 8 when that suite is configured), `intel-opencl-icd` where packaged (Debian 12), plus `intel-gpu-tools` for Intel busy %, `clinfo`, `clpeak` and `hashcat`. Every runtime package is simulated with apt first and left out if it would pull a kernel, firmware, DKMS or microcode package or upgrade a package already on the host; the GPU is then "limited" with that reason. All new packages go into the install ledger and are removed by `cleanup.sh` as before. `--amd-intel-opencl` is kept as a no-op alias.
- **`hardware.json` / `inventory.json`:** each GPU records `integrated`, `render_node` and `opencl` (runtime, state, packages, note); `inventory.md` shows the GPU type and OpenCL runtime.
- **Test plan (`inventory.py`):** AMD and Intel GPUs with an available runtime are `testable: yes` and planned as `gpu_compute` with the same time estimate as NVIDIA (D + 240 s), naming the runtime; GPUs without one stay `gpu_limited` with the reason. Integrated GPUs get a "shares RAM bandwidth and power with the CPU" note.
- **`telemetry.sh` `gpu_query`** for AMD/Intel is now derived from `gpu_query_ext` (Intel now has power, actual clock and throttle reasons); the AMD/Intel `stress-tel.csv` keeps its first eight columns and adds the extended ones.
- **Reports:** the Markdown and HTML report templates cover AMD/Intel GPU sections (runtime used, clpeak-loop fallback, junction temperature, clock vs max, "shared with CPU" power and shared memory for integrated GPUs).
- **`clpeak` parsing (all vendors):** a GPU without FP64 ("No double precision support! Skipped", usual on Intel) no longer reports the next section's integer figure as `clpeak_fp64_gflops`; the score is simply left out.
- **After a 90 °C abort** on AMD/Intel, clpeak is skipped as well as the hashcat benchmarks, so the card gets no more load.
- **`gpu.sh --help`** prints the whole header.
- **Legacy `radeon` driver** (pre-GCN AMD cards): `gpu.sh` now skips such a GPU with the reason (no OpenCL runtime exists for it) instead of treating it as an amdgpu card, matching the plan in `prep.sh`.
- **Docs:** README, SKILL.md, installation, how-it-works, report-format and security pages describe NVIDIA, AMD and Intel GPU support (discrete and integrated) instead of "NVIDIA only / best-effort".

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

[Unreleased]: https://github.com/vanticstudio/proxmox-test/compare/v1.1.0...HEAD
[1.1.0]: https://github.com/vanticstudio/proxmox-test/compare/v1.0.0...v1.1.0
[1.0.0]: https://github.com/vanticstudio/proxmox-test/releases/tag/v1.0.0
