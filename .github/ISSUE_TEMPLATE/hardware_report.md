---
name: Hardware report
about: Share results from your hardware so others can compare (and to help tune reference values)
title: "[Hardware] <CPU> / <GPU or no GPU> / <disks>"
labels: hardware-report
assignees: ""
---

> **Redact before posting.** Leave out hostnames, IP addresses, serial numbers,
> MAC addresses, disk WWNs/IDs and anything else that identifies your network
> or your machine. Model names and numbers are fine.

## Hardware

| Part | Model |
|---|---|
| CPU (and number of sockets) | |
| RAM (size, type, speed, number of DIMMs) | |
| GPU(s) | |
| SSD(s) | |
| HDD(s) | |
| Disk controller / HBA (if any) | |
| Cooling (air, AIO, case) | |
| Proxmox VE version | |

## Test settings

- Duration per part: 30 s / 1 min / 5 min / 10 min
- Guests (VMs/containers) running during the test? yes / no
- Anything unusual (power limits changed in BIOS, undervolt, ZFS, passthrough GPU, ...)?

## At a glance

Copy the "At a glance" table from your report (Markdown version). The rows
below are only an example of the format.

| Part | Key score(s) | Part score (% of expected) | Peak temp | Peak power | Verdict |
|---|---|---|---|---|---|
| **CPU** (1 socket) | example: 7-Zip 100000 MIPS | **~100%** | 80 °C | 200 W | Running optimally |
| **RAM** (2 DIMMs) | example: STREAM 50 GB/s | **~90%** | - | - | Running optimally |

**Bottom line:** (copy it from the report)

## Anomalies

Anything the report flagged or that surprised you: thermal throttling, a part
well under 75%, hardware error counters, a slow disk next to identical ones,
a measurement that looked impossible.

## Notes

Optional: what you changed afterwards and whether it helped.
