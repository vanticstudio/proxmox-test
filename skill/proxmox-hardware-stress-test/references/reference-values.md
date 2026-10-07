# Finding "expected" values

A score only means something next to a trustworthy reference. This file explains where to get one for each metric, gives formulas for theoretical limits, a starter table of common homelab hardware, and what to do when there is no reference.

## Contents
1. Rules
2. Where to look, per metric
3. Theoretical maxima (formulas)
4. Starter tables (CPU, RAM, GPU, SSD, HDD)
5. Judging a result with no reference

---

## 1. Rules

- **Match the exact model and variant.** i5-13600K vs 13600KF are the same silicon (F = no iGPU); a 13600T is not. "990 PRO 1 TB" and "990 PRO 2 TB" have different specs. The RTX 3060 8 GB and 12 GB differ.
- **Prefer, in order:** (1) manufacturer datasheet / spec page, (2) a large public benchmark database or a well-known review that used the same test (7-Zip, hashcat, clpeak), (3) a theoretical maximum you can calculate, (4) a typical range for the hardware class.
- **Cite the source** next to every figure in the report ("Samsung spec", "hashcat forum / published benchmark for that card", "theoretical: 5600 MT/s x 8 B x 2 ch").
- **Check the conditions behind the reference.** Datasheet SSD IOPS are often measured at QD32 x 4-8 threads on an empty drive; sequential writes are SLC-cache speeds; HDD MB/s is the outer-track maximum; CPU reviews may use different power limits than the user's BIOS. Say so in the report when it matters.
- **Never invent a number.** If you cannot find one, use section 5 and say "no published reference".
- When web search is available, use it: search e.g. `"<model>" 7-zip benchmark MIPS`, `"<GPU>" hashcat benchmark md5`, `"<SSD model>" datasheet IOPS`, `"<HDD model>" datasheet sustained transfer rate`. Prefer the manufacturer domain for specs.
- The starter tables below are a convenience. They are well-known spec-sheet or published figures; re-check them against the manufacturer when you can.

## 2. Where to look, per metric

| Metric (script) | Reference source |
|---|---|
| CPU max boost clock (`cpu.sh` sysbench 1T max MHz) | Intel ARK / AMD product page: "Max Turbo Frequency" / "Max Boost Clock". Already scored by the script as % of the CPU's advertised max from sysfs |
| 7-Zip MT / 1T MIPS (`7z b`) | 7-cpu.com benchmark table, Phoronix/OpenBenchmarking "7-Zip compression", well-known reviews. Match thread count and power limits |
| sysbench cpu events/s | No reliable cross-machine database (version and compiler matter). Use thread scaling (section 5) |
| stress-ng bogo-ops | Not comparable between machines. Judge by: all workers passed, steady clock, power vs PL1/PPT |
| CPU package power under load | Intel PL1/PL2 (BIOS / `rapl-limits.txt`); AMD PPT (88 W for 65 W TDP parts, 142 W for 105 W AM4/AM5, 162 W for 120 W AM5, 230 W for 170 W AM5) |
| RAM bandwidth (STREAM, stress-ng stream, sysbench 1T) | Theoretical max (section 3) and the typical ranges in 4.2 |
| RAM latency (`latency.c`, 4 GB buffer, random pointer chase) | Typical ranges in 4.2. Review sites (AIDA64 latency) are 5-15 ns lower than this method because AIDA uses large pages / a different pattern |
| GPU hashcat speeds | hashcat forum / GitHub benchmark gists for the same card and a recent hashcat version. OpenCL vs CUDA backends differ by a few %; this skill uses OpenCL |
| GPU FP32 TFLOPS, VRAM GB/s | Spec sheet / TechPowerUp GPU database (boost-clock FP32). clpeak typically lands around 90-110% of spec FP32 (cards often boost above the rated clock) and around 80-95% of spec bandwidth |
| SSD seq MB/s, 4K IOPS | Manufacturer datasheet for that capacity. QD1 4K read is rarely published: use the class values in 4.4 |
| HDD MB/s | Datasheet "max sustained transfer rate" (outer tracks). Inner tracks are ~50-60% of it |
| Temperatures | CPU TjMax (Intel ARK, typically 100 °C; AMD Tjmax 90-95 °C), GPU slowdown temp (`nvidia-smi -q`), NVMe warning temp (`smartctl` "Warning Comp. Temp. Threshold"), HDD max operating temp (datasheet, usually 60-65 °C) |

## 3. Theoretical maxima

| Quantity | Formula | Examples |
|---|---|---|
| DDR4/DDR5 bandwidth | MT/s x 8 bytes x **channels** (a DDR5 DIMM's two 32-bit sub-channels count as one 64-bit channel) | DDR4-3200 dual: 51.2 GB/s. DDR5-4800 dual: 76.8. DDR5-5600 dual: 89.6. DDR5-6400 dual: 102.4. DDR4-2400 quad (Xeon E5 v3/v4): 76.8. DDR4-3200 8-channel (EPYC 7002/7003): 204.8 |
| Channels | Desktop Intel/AMD = 2, whatever the DIMM count. HEDT/server: count populated channels from `dimm_locators` (one DIMM per channel needed for full bandwidth) | 4 DIMMs on a typical desktop board = still 2 channels |
| PCIe link (usable per direction, approx.) | Gen3 ~0.985 GB/s per lane, Gen4 ~1.97, Gen5 ~3.94, minus ~5-10% protocol overhead | Gen3 x4 ~3.5 GB/s; Gen4 x4 ~7.0 GB/s; Gen5 x4 ~14 GB/s; Gen4 x16 ~25 GB/s usable host-to-GPU |
| SATA III | 600 MB/s line rate | ~550-560 MB/s usable |
| GPU FP32 | shaders x 2 x boost clock | RTX 4070: 5888 x 2 x 2.475 GHz = 29.15 TFLOPS |
| GPU memory bandwidth | bus width / 8 x effective data rate | RTX 4070: 192-bit / 8 x 21 Gbps = 504 GB/s |
| HDD random IOPS (QD1, full stroke) | 1 / (avg seek + half a rotation) | 7200 rpm ~75-100 IOPS; 5400 rpm ~55-80 IOPS, i.e. a median latency of roughly 8-15 ms. Small test files give more (short seeks). A read-only full-disk result with a median latency under ~4 ms is not a seek: it hit never-written / unmapped LBAs (an SMR drive answers those from its translation table) or the drive cache; `disk.sh` marks it `valid: false` - exclude it |

Anything measured above a physical limit (e.g. RAM bandwidth > theoretical, NVMe > link limit) is a measurement artefact (cache, compression, ARC); exclude it.

## 4. Starter tables

### 4.1 CPUs (spec figures; 7-Zip only where a published figure exists)

| CPU | Cores / threads | Max boost | Default power limit | 7-Zip MT (MIPS) |
|---|---|---|---|---|
| Intel Core i9-14900K | 24 (8P+16E) / 32 | 6.0 GHz | PL1 125 W / PL2 253 W | look up |
| Intel Core i9-13900K | 24 (8P+16E) / 32 | 5.8 GHz | PL1 125 W / PL2 253 W (many boards default to 253/253) | look up |
| Intel Core i5-13600K | 14 (6P+8E) / 20 | 5.1 GHz | PL1 125 W / PL2 181 W | look up |
| Intel Core i7-12700K | 12 (8P+4E) / 20 | 5.0 GHz | PL2 190 W | look up |
| Intel Core i5-13500 | 14 (6P+8E) / 20 | 4.8 GHz | PL1 65 W / PL2 154 W | look up |
| Intel Core i5-12400 | 6 / 12 | 4.4 GHz | PL1 65 W / PL2 117 W | look up |
| Intel N100 | 4 / 4 | 3.4 GHz | 6 W TDP (boards often allow more) | look up |
| AMD Ryzen 9 7950X | 16 / 32 | 5.7 GHz | PPT 230 W | look up |
| AMD Ryzen 7 7700 | 8 / 16 | 5.3 GHz | PPT 88 W | look up |
| AMD Ryzen 9 5950X | 16 / 32 | 4.9 GHz | PPT 142 W | look up |
| AMD Ryzen 7 5700X | 8 / 16 | 4.6 GHz | PPT 76 W | look up |
| AMD Ryzen 5 5600X | 6 / 12 | 4.6 GHz | PPT 76 W | look up |
| Intel Xeon E5-2680 v4 | 14 / 28 per socket | 3.3 GHz | 120 W TDP | look up |

Hybrid Intel chips under all-core load sit at the power limit, so P-cores run well below the max boost (e.g. a 14900K or 13600K at its default power limit runs all-core well below its max boost, per reviews). That is normal. Intel's Vmin-shift fixes for 13th/14th-gen Raptor Lake started at microcode 0x129; recommend the newest BIOS microcode the board offers (0x12F or newer) and mention the loaded version in the report.

### 4.2 RAM

| Platform | Typical STREAM Triad, all cores (% of theoretical) | Typical 1-thread read | Typical latency (this method, 4 GB buffer) |
|---|---|---|---|
| Intel 12th-14th gen, DDR5 dual-channel | 75-90% of theoretical (e.g. ~65-75 GB/s at DDR5-5600) | 25-35 GB/s | ~75-95 ns |
| Intel 12th-14th gen, DDR4 dual-channel | 75-90% of theoretical | 20-30 GB/s | ~65-85 ns |
| AMD Ryzen 7000/9000 (AM5), DDR5 dual | 55-70% of theoretical on single-CCD parts (Infinity Fabric limits writes); 65-80% on dual-CCD | 25-40 GB/s | ~75-95 ns |
| AMD Ryzen 3000/5000 (AM4), DDR4 dual | 70-85% | 20-30 GB/s | ~70-90 ns |
| Xeon / EPYC, multi-channel | 65-85% with all cores | 10-20 GB/s | ~90-140 ns |
| Intel N100 and other single-channel mini PCs | 60-80% of a **single** channel | 10-20 GB/s | ~90-120 ns |

Typical pattern: a dual-channel DDR5 desktop usually reaches roughly 75-90% of theoretical in STREAM; on some CPUs fewer threads than the full thread count give the best result. Use the midpoint of the "typical" range as the expected value and say it is a range.

### 4.3 GPUs

| GPU | FP32 (spec, TFLOPS) | VRAM bandwidth (GB/s) | hashcat MD5 / NTLM / SHA-256 / WPA (published) |
|---|---|---|---|
| NVIDIA RTX 3060 12 GB | 12.74 | 360 | look up |
| NVIDIA RTX 3060 Ti | 16.20 | 448 | look up |
| NVIDIA RTX 3070 | 20.31 | 448 | look up |
| NVIDIA RTX 3080 10 GB | 29.77 | 760 | look up |
| NVIDIA RTX 3090 | 35.58 | 936 | look up |
| NVIDIA RTX 4060 | 15.11 | 272 | look up |
| NVIDIA RTX 4060 Ti | 22.06 | 288 | look up |
| NVIDIA RTX 4070 | 29.15 | 504 | look up |
| NVIDIA RTX 4090 | 82.58 | 1,008 | look up (MD5 widely reported around 160+ GH/s) |
| NVIDIA Tesla P40 | 11.76 | 347 | look up |
| NVIDIA Tesla P4 | 5.5 | 192 | look up |
| NVIDIA Quadro P2000 | 3.0 | 140 | look up |
| AMD RX 6600 | 8.93 | 224 | look up (OpenCL support on the host is often missing) |
| AMD RX 6700 XT | 13.21 | 384 | look up (as above) |

Typical: clpeak FP32 around 90-110% of spec (cards often boost past the rated clock), VRAM bandwidth ~80-95% of theoretical, FP64 ~1/64 of FP32 on GeForce, PCIe Gen4 x16 transfer ~16-19 GB/s.

### 4.4 SSDs

| Drive | Seq read / write (MB/s) | 4K random read / write (IOPS) | Notes |
|---|---|---|---|
| Samsung 990 PRO 1 TB (Gen4) | 7,450 / 6,900 | 1,200K / 1,550K | |
| Samsung 980 PRO 1 TB (Gen4) | 7,000 / 5,000 | 1,000K / 1,000K | |
| Samsung 990 EVO 1 TB (Gen4 x4 / Gen5 x2) | 5,000 / 4,200 | 680K / 800K | |
| Samsung 970 EVO Plus 1 TB (Gen3) | 3,500 / 3,300 | 600K / 550K | |
| Samsung 980 1 TB (Gen3, DRAM-less) | 3,500 / 3,000 | 500K / 480K | |
| WD Black SN850X 1 TB (Gen4) | 7,300 / 6,300 | 800K / 1,100K | |
| WD Red SN700 1 TB (Gen3) | 3,430 / 3,000 | 515K / 560K | |
| Kingston KC3000 1 TB (Gen4) | 7,000 / 6,000 | 900K / 1,000K | |
| Samsung 870 EVO 1 TB (SATA) | 560 / 530 | 98K / 88K | |
| Crucial MX500 1 TB (SATA) | 560 / 510 | 95K / 90K | |

QD1 4K random read (rarely on datasheets) - class values: PCIe Gen4 flagship 18-25K IOPS (40-55 µs); Gen3 NVMe 12-16K; SATA SSD 8-11K. Enterprise SATA/NVMe drives publish steady-state IOPS, which are lower but sustained; compare like with like.

When the model is unknown or no datasheet exists, `disk.sh` falls back to round class references: Gen4 7,000/6,000 MB/s (typical high-end Gen4; real Gen4 drives range ~5,000-7,400 / 4,000-7,000), 1M/1M IOPS, QD1 20K; Gen3 ~3,500/3,000; SATA 550/520 MB/s, 95K/85K IOPS, QD1 10K. Say "class reference" in the report.

### 4.5 HDDs

| Drive | Max sustained (MB/s) | Recording | Notes |
|---|---|---|---|
| WD Red Plus 4 TB (WD40EFPX/EFZX) | ~175-180 | CMR, 5400-class | |
| WD Red 2-6 TB EFAX | ~180 | **SMR** | avoid for ZFS resilvering |
| Seagate IronWolf 4 TB | ~180-210 (check model) | CMR, 5400-5900 | |
| Seagate Barracuda 2 TB ST2000DM008 | 220 | SMR, 7200 | |
| WD Blue 2 TB (WD20EZBX) | up to 180 | SMR, 5400-class | |
| Seagate Barracuda 2 TB ST2000DM005 | ~220 | SMR, 5400 | |
| Seagate Exos X16 16 TB | 261 | CMR, 7200 | |
| Seagate Exos X18 18 TB | 270 | CMR, 7200 | |
| WD Ultrastar DC HC550 16 TB | 262 | CMR, 7200 | |
| Toshiba MG08 16 TB | 262 | CMR, 7200 | |

If the model is unknown, `disk.sh` uses 180 MB/s for 5400-class and 220 MB/s for 7200+ rpm. Random results are not scored (see the report template).

## 5. Judging a result with no reference

Say "no published reference" and use these instead:

- **Thread scaling (CPU):** MT result / 1T result. Rough expectations: no SMT, all big cores: 0.85-0.95 x cores. SMT CPUs: about 1.2-1.3 x physical cores (e.g. 16C/32T -> ~19-21x). Hybrid Intel: P-cores x ~1.25 + E-cores x ~0.5 (i5-13500: 6 x 1.25 + 8 x 0.5 = ~11.5). Far below = cores parked, guests competing, power limit set very low, or thermal throttling.
- **Steadiness:** per-second power/clock/throughput during the stress phase should be flat. A falling clock with rising temperature = thermal throttling; a sudden drop in disk MB/s = SLC/SMR cache exhausted (`sustain_ratio` < 0.7 on long runs); a sawtooth = power-limit cycling (PL2 -> PL1 after tau, normal on Intel with PL1 < PL2).
- **Agreement between tools:** STREAM vs stress-ng stream within ~15%; fio MB/s vs the disk's per-second I/O within ~20%.
- **Physical sanity:** below the theoretical max and the link limit (section 3). A 4-lane Gen4 NVMe running at Gen3 or x2 will cap near the lower link's limit; report the link, not the drive, as the cause.
- **Sister models:** a figure for a closely related part (same silicon, different clocks) can be scaled by the clock ratio; say that you did this.
- **Power-limited results** are judged against the limit: "ran at 100% of its power limit with 0 errors" is a valid pass.
