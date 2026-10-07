# Safety and troubleshooting

## Contents
1. What the skill never does, and why
2. Guests running during the test
3. GPU passthrough and unsupported GPUs
4. ZFS and the ARC
5. Disks without a usable filesystem
6. Missing sensors and "n/a"
7. SSH problems (keys, host keys, Tailscale SSH, IPS lockouts)
8. When a part reports errors
9. Interrupted runs and leftovers
10. Longer burn-ins
11. Portability: other hosts and setups

---

## 1. What the skill never does, and why

| Never | Why |
|---|---|
| Write to a raw block device (`/dev/sdX`, `/dev/nvmeXn1`, LVs, zvols) | It destroys whatever is on it: VM disks, the OS, backups. Write tests only use one temporary file (`.pve-stresstest-fio-<pid>.tmp`) inside a mounted filesystem. It is deleted on exit, on Ctrl-C and on error, registered in `/root/pve-stresstest/.testfiles`, and swept again by cleanup.sh (which also searches mounted filesystems for that name). Disks without a usable filesystem are only ever *read*, through `disk.sh --mode readonly --device /dev/X` (fio opens the device with `--readonly`, and a guard refuses any job that is not a pure read). In file mode a second guard refuses any fio job whose target is not the skill's own test file |
| Change RAID controller / HBA settings, rebuild arrays or run controller self-tests | The array holds the user's data; only read-only queries (`smartctl -d megaraid,N` / `-d cciss,N`, `storcli`/`perccli` show commands if already installed) are used |
| Format, partition, mount, resize or change filesystem/ZFS properties | Same reason; and changing settings would also change what is being measured |
| Change BIOS, power limits (RAPL/PPT, `nvidia-smi -pl`), governors, EPP, fan curves, clocks or kernel parameters | The point is to measure the box as it actually runs. Report suggested changes as recommendations instead |
| Start, stop, migrate, snapshot or reconfigure guests | They belong to the user and may be production. Stopping them is the user's choice |
| Touch a GPU bound to `vfio-pci` | It belongs to a VM; probing it can crash that VM |
| Install from anywhere but the host's configured apt repos, or keep what it installed | Keeps the host supportable; cleanup.sh removes exactly the recorded packages and refuses if apt would remove anything else |
| Store or pass passwords | Key-based SSH only; passwords would end up in files, logs and shell history |
| Run two parts at once | Overlapping load makes the numbers meaningless and can overheat the box |

Test-file size is capped at min(requested, 10% of free space, 8 GB for SSD/NVMe, 4 GB for HDD), and the test refuses if free space is less than twice the file. The RAM stress leaves at least 4 GiB plus the running guests' possible growth free, and a watchdog stops it if available memory drops below 1.5 GiB, so guests are not pushed into swap or the OOM killer.

## 2. Guests running during the test

The skill leaves running guests alone. Effects to explain to the user and in the report:
- CPU and RAM bandwidth scores read low in proportion to guest load; disk scores read low if guests do I/O on the same disk.
- Guests may slow down noticeably during the stress phases (RAM stress takes up to ~40% of available memory).
- `prep.sh` warns when the host is more than 15% busy at idle. If it is, suggest stopping guests or testing at a quiet time; let the user decide.
- Ballooning VMs can reclaim memory during the RAM test; the RAM script reserves their headroom, which may make the tested size smaller.

## 3. GPU passthrough and unsupported GPUs

`prep.sh` marks each GPU `testable` yes / limited / no with a reason:
- **vfio-pci** (passed through to a VM): not tested. To test it, the user must stop that VM and rebind the card to the host driver themselves; that is outside this skill.
- **nouveau** or no driver: not tested; the open driver has no usable compute path. The NVIDIA proprietary driver (and its OpenCL ICD) must be installed on the host by the user.
- **NVIDIA with driver but no OpenCL ICD** (`/etc/OpenCL/vendors/nvidia.icd` missing): hashcat/clpeak see no device. The `.run` installer and the `nvidia-opencl-icd` package provide it.
- **AMD (amdgpu) and Intel (i915/xe)**: "limited": telemetry from sysfs; benchmarks only if an OpenCL runtime works (`prep.sh --amd-intel-opencl` installs Mesa rusticl, often slow or unsupported). Scores from Mesa OpenCL are not comparable with ROCm/Windows reviews; say so.
- **BMC/server graphics** (ASPEED, Matrox): not a compute GPU; skipped.
- CUDA is deliberately not used (needs NVRTC, absent on a bare host). OpenCL results are within a few % of CUDA for hashcat.
- hashcat's 90 °C abort watchdog stays on.
- Debian's `hashcat` package has a hard dependency on an OpenCL ICD *package*. The NVIDIA `.run` installer provides the ICD file but no package, so apt installs `pocl-opencl-icd` (a CPU OpenCL runtime) plus LLVM/SPIR-V libraries. They are recorded and removed at cleanup. `gpu.sh` uses `-D 2` (GPU devices only) and runs clpeak only on the GPU's own platform, so pocl is never benchmarked.
- Only `NVRM: Xid` kernel lines are GPU errors, and only new ones (counted before and after) count. A bare "xid" search also matches unrelated kernel lines (other drivers can print "XID" too).
- **Several GPUs:** the plan has one unit per card (`gpu.sh --gpu <PCI address>`, out dirs `03-gpu-1`, `03-gpu-2`, ...). `gpu.sh --list` shows every display device with its index and whether it is testable; `gpu.sh --all` tests them all one after another (per-card folders `gpu<N>/` plus an aggregate `summary.json`). It restricts nvidia-smi to that card and maps it to hashcat's device number via `hashcat -I`. If the mapping fails, it warns that hashcat loaded all GPUs at once. A PCI address that is not a display device is a usage error (exit 2).
- **GPU shared with LXC containers** (`/dev/nvidia*` or `/dev/dri/*` passed in, e.g. Plex, Jellyfin or an AI inference container): the stress competes with their work and can fill VRAM. The plan matches `/dev/nvidiaN` to the card with nvidia-smi index N (only `nvidiactl`/`nvidia-uvm` = all NVIDIA cards) and puts a warning on that GPU's unit. Mention this in the plan; stopping those containers is the user's choice.
- hashcat, pocl and NVIDIA kernel caches go to `/root/pve-stresstest/.gpu-cache` (removed by cleanup), not `/root/.cache`, `/root/.local/share/hashcat` or `/root/.nv`.

## 4. ZFS and the ARC

The ARC is ZFS's RAM cache. A file test on ZFS can be served from RAM instead of disk, which makes reads look impossibly fast.
- `disk.sh` uses `direct=1`. On **OpenZFS 2.3 or newer** with the dataset `direct` property at `standard` (default) or `always`, O_DIRECT bypasses the ARC for aligned I/O. On older ZFS (PVE 8 shipped 2.1/2.2 for a long time) `direct=1` is accepted but ignored, so reads can come from the ARC.
- For each fio job the script records `zfs_arc_hit_pct`. Treat reads with a high ARC hit rate as **not a disk result**; exclude them from scoring and say why.
- Compression: fio's default buffers are random (incompressible), so `compression=lz4` does not inflate results much, but mention the setting.
- Results on a pool reflect the pool layout (mirror reads can exceed one disk; RAIDZ writes include parity), not a single disk. Report "pool `rpool` (2 x NVMe mirror)" rather than one drive.
- `zfs_arc_max` is never changed. If the user wants a cleaner read test on old ZFS, they can use a test file larger than the ARC (outside this skill's caps) or test after upgrading.
- The RAM test does not count the ARC as free memory, so on ZFS hosts it tests a smaller amount.

## 5. Disks without a usable filesystem

The plan (`plan.json`, built by `inventory.py`) gives every disk a `method_id`: `write_read` when a writable filesystem that lives on that disk alone has at least 2x the test file free, otherwise `read_only_raw` (read-only, read scores only), or `skip`. A filesystem spanning several disks (ZFS mirror/RAIDZ, mdraid) also gets an optional pool unit (`part: pool`, `write_read` on the pool's path). Common cases on Proxmox:
- **LVM-thin** (`local-lvm`): no filesystem. If the root filesystem (`/var/lib/vz`) lives on the same disk, the plan uses `write_read` there (thin-LV overhead is not measured); a disk that is *only* LVM gets `read_only_raw`.
- **ZFS** (root on `rpool`, data pools): every member disk gets `read_only_raw`; the pool itself gets an optional pool unit on a mounted dataset (e.g. `/var/lib/vz` on `rpool/ROOT/pve-1`). A pool used only for zvols has no pool unit.
- **Ceph OSD, mdraid member, empty disk**: `read_only_raw`. Never create a filesystem to make room. Reads from an OSD add load to the Ceph cluster; mention it.
- **Disk passed through to a guest** (`/dev/disk/by-id/...` in a VM config, or the disk's whole controller in a `hostpci` line): `skip` while the VM is running (or for any container); `read_only_raw` with `needs_confirmation` when the VM is stopped (reading is safe, but ask, and the VM must not be started meanwhile).
- **Too little free space** (< 2x the test file): the plan picks `read_only_raw`. If `disk.sh` itself refuses file mode (exit 3, e.g. space ran out since the plan), offer the read-only command, another directory on the same disk, or skip.
- **USB disks**: under 8 GB (boot sticks, card readers) they are skipped; larger ones are planned read-only with `needs_confirmation`. Test only if the user wants; results reflect the USB bridge.
- **Disks behind an HBA** (LSI/Broadcom SAS in IT mode, `mpt3sas`): appear as normal `/dev/sdX` disks with SMART; tested like any SATA/SAS disk. SAS SSDs use the `ssd` profile.
- **Disks behind hardware RAID** (`megaraid_sas`, `hpsa`/`smartpqi`, PERC): the OS sees one virtual disk per array. That virtual disk is the test unit (`write_read` if it carries a usable filesystem, else `read_only_raw`; name it after the array, e.g. "HDD pool 1: RAID 6, 8 x <model>"). The physical member disks are found with `smartctl --scan-open` and listed in the inventory with their SMART data (`smartctl -d megaraid,N` / `-d cciss,N`) as `skip` units ("tested through the controller's volume"). Which member belongs to which array is not readable without the vendor tool; say so. The controller's settings are never changed.
- **HDD random reads that look too fast**: in read-only mode a 4K random read whose median latency is under ~4 ms cannot have come from the platters (a seek takes longer). It hit never-written / unmapped regions (answered from the drive's translation table, typical of SMR drives) or the drive's cache. `disk.sh` marks such a test `valid: false`; leave it out of the report's numbers and say why.

## 6. Missing sensors and "n/a"

A missing sensor is recorded as `n/a` and never fails a test. Typical gaps:
- **CPU power**: needs powercap `intel-rapl` (Intel, and AMD Zen via the same interface on recent kernels) or `amd_energy`. Some older AMD and many VMs have none: report "not measurable".
- **CPU temperature**: `coretemp` (Intel), `k10temp` (AMD). If missing, `modprobe coretemp`/`k10temp` may fix it, but the skill does not load modules on its own; suggest it as a recommendation.
- **Throttle counters**: Intel only (`/sys/devices/system/cpu/cpu*/thermal_throttle`). On AMD judge throttling by clock + temperature.
- **Disk power**: no drive reports it. Quote the datasheet's typical active power.
- **Drive temperature behind a RAID/HBA or USB bridge**: may be unreadable.
- **Turbostat**: used only if already installed (it is in `linux-cpupower` on Debian; prep may install it).
- **Running inside a VM** (nested PVE): power/temperature sensors are missing and scores reflect the hypervisor. prep warns; say so in the report.

## 7. SSH problems

- **Permission denied (publickey)**: the user sets up a key: `ssh-keygen -t ed25519` (if needed), then `ssh-copy-id -p PORT root@HOST` and types the password in their own terminal. Proxmox root login with a key is allowed by default.
- **Host key verification failed / changed**: a changed key after a reinstall is expected; the user removes the old line with `ssh-keygen -R HOST`. An unexpected change could mean the wrong host: ask before continuing.
- **Tailscale SSH**: if the tailnet policy uses `check` mode, the first connection prints a login URL ("Tailscale SSH requires an additional check"). With BatchMode this may fail or hang until approved: show the URL, wait, retry. The check usually lasts 12 h, enough for the run. Tailscale SSH ignores `authorized_keys`; access comes from the tailnet ACL.
- **Connection refused / timed out**: wrong IP or port, PVE firewall rules (Datacenter -> Firewall), or the router blocking SSH between VLANs/subnets.
- **Blocked after many connections**: router IPS/IDS, fail2ban or `sshd MaxStartups` can block an IP that opens many SSH sessions quickly. The skill avoids this with one shared ControlMaster connection and waits on results in a single session. If it happens, wait and retry later - don't retry in a loop.
- **Non-root user**: needs passwordless `sudo -n` (check with `PVESSH 'sudo -n true && echo ok'`); otherwise connect as root. With sudo, upload to the user's home and copy in as root: `tar -C <skill-dir>/scripts -cf - . | PVESSH 'mkdir -p ~/pve-stresstest-src && tar -C ~/pve-stresstest-src -xf - && sudo -n mkdir -p /root/pve-stresstest && sudo -n cp ~/pve-stresstest-src/* /root/pve-stresstest/ && rm -rf ~/pve-stresstest-src'`. Then prefix every remote command with `sudo -n`, including the `nohup setsid bash -c ...` launcher, the `.rc` wait loop (`sudo -n test -f ...`), the `tar` copy-back and the checksum command, because `/root` is not readable by the user.
- **SSH drops mid-test**: parts run under `nohup setsid`, so the test continues. Reconnect and wait for the `.rc` file.
- **zsh / "keyword batchmode extra arguments"**: an SSH options string kept in a shell variable is not word-split by zsh (the macOS default shell). Use the `pvessh` wrapper script from SKILL.md step 2, called with `sh`, rather than `ssh $OPTS`.
- **Checksums never VERIFIED although the hashes match**: `sort` orders file names differently under different locales (Linux host vs macOS). Both sides must use `LC_ALL=C sort -k2`, as in step 5.

## 8. When a part reports errors

Stop the sweep and tell the user before running the next part when any of these appear:
- MCE / EDAC lines or counter increases, RAM `--verify` miscompares, STREAM validation failure, memtester FAILURE: possible bad RAM, unstable XMP/EXPO, or an overclock. Suggest memtest86+ overnight and testing at JEDEC speed.
- GPU Xid / NVRM errors: driver, power or card fault.
- NVMe media errors / critical warning, SATA CRC (often a cable), reallocated or pending sectors rising, kernel I/O errors: back up first, then investigate.
- CPU at TjMax with falling clocks (thermal throttling): cooling problem (paste, fan curve, cooler mounting, dust).
A part that fails must be reported as FAILED even if its benchmark score was good.

## 9. Interrupted runs and leftovers

- Each disk test deletes its test file in an EXIT trap, also on INT/TERM/HUP, and writes `testfile-deleted.txt`.
- If a run is abandoned, run `bash /root/pve-stresstest/cleanup.sh --dry-run` to see leftovers, then without `--dry-run`. It only kills processes whose command line or working directory is in the skill's folder, and deletes only regular files named `.pve-stresstest-fio-*` / `pve-stresstest-fio*`.
- Without `--confirm-logs-copied`, cleanup keeps the logs and prints the scp command to fetch them.
- Cleanup exit 3 = something was skipped for safety (e.g. apt would remove a package something else now depends on). Report it; don't force it.

## 10. Longer burn-ins

The 10-minute option is the longest this skill runs per part. For a real burn-in (new or second-hand hardware), suggest running these one at a time with guests stopped, watching `sensors` / `nvidia-smi` / `smartctl`, then checking `dmesg`, `smartctl -a` and the throttle counters afterwards:

| Part | What to run | Length / pass criteria |
|---|---|---|
| CPU | `stress-ng --cpu <threads> --cpu-method matrixprod --timeout 60m --metrics-brief` | 30-60 min; stays below ~85-90 °C, clocks steady, 0 errors |
| RAM | Boot **memtest86+** from the Proxmox boot menu or a USB stick | Overnight, at least 4 full passes, 0 errors. The only full-coverage RAM test |
| GPU | the same `hashcat` stress command as `gpu.sh` with `--runtime=1800` | 30 min; below ~80-83 °C, no Xid errors |
| SSD | the same `fio` jobs with a longer `--runtime` and a test file larger than the SLC cache | 10-20 min; shows post-cache speed and sustained temperature. Mind the TBW used |
| HDD | the same `fio` random-write job for 10+ min on the same test path (to see real SMR behaviour), plus a SMART extended self-test: `smartctl -t long /dev/sdX` | The SMART long test is read-only and runs inside the drive (hours on large disks); check `smartctl -a` afterwards. Never run `badblocks -w` (destructive) on a disk that holds data |

## 11. Portability: other hosts and setups

| Setup | What happens / what to do |
|---|---|
| **No GPU** | prep lists no GPU and installs no GPU tools; skip the GPU part and say "not present" in the report. `gpu.sh` on its own writes `status: skipped` and exits 0. |
| **GPU bound to vfio-pci** (passed through to a VM) | Never touched; prep marks it `testable: no`, and `gpu.sh` skips it even when it is named with `--gpu`. Testing it means stopping the VM and rebinding the card, which is the user's job and outside this skill. |
| **AMD Ryzen / EPYC / Threadripper** | Power: recent kernels expose AMD RAPL under the same powercap name (`intel-rapl:0`, `package-0`, usually no `core` domain, so core W is n/a); older kernels use the `amd_energy` hwmon, which telemetry.sh reads. Temperature: `k10temp` Tdie (else Tctl). On Ryzen 1000/2000 "X" and early Threadripper, Tctl carries a +10 to +27 °C offset, so quote Tdie when present and mention the offset otherwise. No thermal-throttle counters exist on AMD: judge throttling by clock and temperature. EPYC/Threadripper have many memory channels, and the script's theoretical bandwidth assumes one DIMM per channel; check the real channel count before scoring. |
| **Multi-socket** | One CPU unit and one RAM unit load every socket / NUMA node together. Power is summed over sockets by telemetry.sh; the CPU temperature is the hottest package. The report lists every socket in "Your hardware" and names the CPU "2 x <model>". RAM theoretical bandwidth = channels per socket x sockets. |
| **Many disks / several GPUs** | Each disk and each GPU is its own unit, run one after another in plan order; total time grows by roughly D + 1 min per unit, so suggest the 30 s or 1 min option for a first pass on big boxes. Identical drives are looked up once and compared with each other in the report. |
| **ZFS root (`rpool`), no ext4** | Use `/var/lib/vz` (dataset `rpool/ROOT/pve-1`) or another mounted dataset. The ARC caveat in section 4 applies. RAM tests are smaller because the ARC is not counted as free memory. |
| **PVE 8 (Debian 12)** | Same package names (`linux-cpupower` provides `cpupower` and `turbostat` on both; `7zip` exists on Debian 12 and 13, with `p7zip-full` as fallback). OpenZFS 2.1/2.2 ignores O_DIRECT, so ZFS read results can come from RAM. |
| **SATA SSD only / several NVMe** | Profile `ssd` for SATA SSDs (the score uses a SATA III class reference and flags a 3 Gb/s link). With several NVMe drives, run `disk.sh` once per drive with a path whose filesystem lives on that drive and `--device` set. A pool spanning drives is tested once, as the pool. |
| **Guests running** | See section 2. The RAM test reserves their growth; CPU, RAM-bandwidth and disk scores read low in proportion to their load. |
| **Very low RAM** (e.g. 8-16 GB with guests) | The RAM stress needs at least 256 MiB above the 4 GiB + guest-growth reserve. Otherwise it is skipped with a reason and `data_integrity` = `not-tested`. STREAM, latency and memtester shrink or skip in the same way. Say so; suggest memtest86+ from the boot menu instead. |
| **Non-root user with sudo** | See section 7. |
| **No internet / no apt repo access** | prep uses 20 s apt timeouts, records which packages could not be installed, and carries on. The part scripts run with `--no-install`, so they skip the matching sub-tests instead of retrying apt. Tools already on the host are used. disk.sh refuses without `fio`; skip those disks and say why. |
| **Enterprise repo without subscription** | `apt-get update` reports errors for it; prep warns and continues with the repos that work. |
| **Nested PVE (inside a VM)** | Sensors are missing and results describe the VM. prep warns; say so in the report. |
| **Packages installed by someone else during prep** | prep records "new since the start of prep". If unattended-upgrades or the user installs something at the same moment, it would be on the list. cleanup.sh only removes listed packages, refuses if apt wants to remove anything unlisted, and never removes protected ones (pve/proxmox/kernel/zfs/nvidia/systemd/apt...). Glance at the list it prints. |
