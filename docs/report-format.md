# The report

Every run produces **three files with the same content**: a Markdown report, a designed HTML page (opened in your browser automatically) and a PDF of that page. The structure is the same on every host; only the number of rows and per-part sections changes. A mini PC with one SSD and a dual-socket server with many drives get the same layout.

The full template the skill follows is [`references/report-template.md`](../skill/proxmox-hardware-stress-test/references/report-template.md).

## Where the files land

By default Claude creates a folder in your current directory and tells you the exact paths at the end:

```
pve-stress-test-<hostname>-<YYYY-MM-DD>/
├── run-<YYYYMMDD-HHMM>/                raw logs from the host, one sub-folder per unit
│                                       (00-baseline, 01-cpu, 02-ram, 03-gpu-1, 04-ssd-…, 05-hdd-…)
├── host-sha256.txt                     checksums used to verify the copy
├── pve-stress-report-<duration>.md     e.g. pve-stress-report-5min.md
├── pve-stress-report-<duration>.html
└── pve-stress-report-<duration>.pdf
```

The folder name contains your host's name. The reports themselves contain **no serial numbers, IP addresses, MAC addresses, UUIDs/WWNs or passwords**, because people share these reports. Hostnames, guest names and storage names may appear in your own copy; ask Claude to replace them before you share it. The raw logs **do** contain serials and the hostname, so redact them before sharing.

## Markdown report: sections

| # | Section | What it tells you |
|---|---|---|
| 1 | Header | Date and time, a one-line hardware summary, Proxmox and kernel version |
| 2 | How the test was done | How many components and units, the order, the stress length, disk methods, running guests, tools used or missing |
| 3 | What "% of expected" means | A short explanation for non-experts |
| 4 | **At a glance** | One row per unit: key scores, part score, peak temperature, peak power, verdict. Skipped units keep their row with the reason; absent parts show "Not present". Followed by a one-or-two-sentence **Bottom line** |
| 5 | Your hardware | The full inventory, tested or not: system, every CPU socket, every DIMM slot (empty ones too), every GPU, every controller and its disks (with the test method), every NIC |
| 6 | Starting point | Idle readings before any load: power, temperatures, settings, disk health, error logs, free space, guests |
| 7 | One section per unit | What was tested and why (with a short **Terms** list), stress-phase table (idle / under load / right after), scores table with reference and source, part score with the calculation, health before and after, "Is it running optimally?", recommendations |
| 8 | Overall health verdict | Units tested / passed / skipped, average scores (overall and per category), throttling, errors, a cooling headroom table |
| 9 | Recommendations | Numbered, most urgent first, each a concrete action |
| 10 | Limits of these tests | What a short test can and can't prove, partial disk/RAM coverage, missing sensors, guests, ZFS caveats |
| 11 | How to do a longer burn-in | Ready-made commands for longer CPU, RAM (memtest86+), GPU, SSD and HDD tests |
| 12 | Where the raw logs are | The local folder and the key files in it |
| 13 | Cleanup | What was removed from the host, what was kept and why |

Writing style: plain English for a homelab owner. Each technical term is explained once, every number is followed by what it means ("Peak 80 °C, about 20 °C below the point where the chip slows itself down"), and anything not tested is stated honestly.

### Example "At a glance" table

Made-up round numbers for a generic box, shown for format only:

| Part | Key score(s) | Part score (% of expected) | Peak temp | Peak power | Verdict |
|---|---|---|---|---|---|
| **CPU** | 7-Zip 100,000 MIPS | **~98%** | 80 °C | 150 W | Running optimally |
| **RAM** | STREAM 60 GB/s; latency 90 ns; 0 errors | **~95%** of typical | 75 °C (CPU package) | 120 W (CPU package) | Running optimally |
| **SSD 1** | 3,500 MB/s read; 3,000 MB/s write | **~97%** | 50 °C | not measurable (no sensor) | Running optimally |
| **HDD 1** | 200 MB/s read; 190 MB/s write | **~85%** | 40 °C | not measurable (no sensor) | Slightly below expected |
| **GPU** | Not present | - | - | - | - |

## Scoring rules

**Per result:** `% of expected = measured / expected x 100`. For latency, where lower is better: `expected / measured x 100`.

**Main results** (the ones that count towards a part's score):

| Part | Main results |
|---|---|
| CPU | 7-Zip multi-thread vs a published result; single-core boost clock vs advertised max turbo; thread scaling vs the expected scaling for the core layout |
| RAM | STREAM Triad and stress-ng stream vs **typical** real-world for the platform; sysbench single-thread read; DRAM latency. The best result is also shown as % of the **theoretical** maximum |
| GPU | hashcat MD5 / NTLM / SHA-256 / WPA vs published results; clpeak FP32 vs spec TFLOPS; clpeak memory bandwidth vs spec |
| SSD / NVMe | Sequential read and write, 4K random read and write IOPS, 4K QD1 read IOPS vs the datasheet. Read-only method: read results only |
| HDD | Sequential only (fill write, sequential read and write) vs the datasheet's sustained rate. Random results are shown but not scored (a small test file flatters them) |
| Pool (ZFS/mdraid) | Same as its member type, vs the pool's expected speed (e.g. a mirror reads up to n x one drive) |

*Terms: IOPS = input/output operations per second; QD1 = queue depth 1, one request at a time (what a single app waiting on the disk feels); TFLOPS = trillions of floating-point operations per second.*

**Part score** = the plain average of that part's main results, always shown with the calculation and a `~` because references are approximate. Example (made-up numbers): "CPU part score: ~97% (7-Zip 96%, boost clock 99%, thread scaling ~95%)".

**Pass/fail checks** are not averaged but override the verdict: data integrity (RAM verify, STREAM validation, memtester) and hardware error counters (machine checks, EDAC, PCIe AER, NVMe media errors, SATA CRC/reallocated/pending sectors, GPU Xid), plus thermal throttling.

### Verdicts

| Condition | Verdict |
|---|---|
| Any data-integrity failure or new hardware error | **FAILED: \<what\>**, investigate before trusting this part |
| Part score 90% or more, and no thermal throttling | **Running optimally** |
| 75-90%, or thermal throttling even with a score of 90%+ | **Slightly below expected**, with the likely cause |
| Below 75% | **Underperforming**, with concrete checks |
| No trustworthy reference for any main result | **Healthy (no reference)** if the results are consistent and error-free |

Good to know:
- **Above 100% is normal** (boost behaviour, good cooling, small test areas), unless it beats a physical limit. Then the measurement is invalid and excluded.
- **Hitting a power limit is not throttling.** A CPU sitting at its configured power limit is behaving as designed. Thermal throttling (slowing down because it's too hot) is what counts against it.
- **Overall verdict:** "The whole server is healthy and performing at or above expectations" only if every tested unit is running optimally. Otherwise the units that need attention are named ("SSD 3", not "the SSDs"). A good average never hides one failed unit, and per-category averages stop many disks from drowning out the CPU.

## HTML report: design and features

The HTML page is built from [`assets/report-template.html`](../skill/proxmox-hardware-stress-test/assets/report-template.html), filled only with numbers from the Markdown report. It looks like a bench-test lab sheet:

| Part of the page | What it shows |
|---|---|
| Header + verdict strip | Title, run details and the overall verdict in a green / amber / red banner |
| Part navigation | One link per tested unit; scrolls sideways on hosts with many parts |
| At a glance | One card per unit with its score and a mini bar. Skipped and absent parts get a grey card with the reason. Grouped by category on bigger hosts |
| Cooling headroom | One bar per tested unit: peak temperature against its limit |
| Your hardware | The full inventory tables, with a "Tested" pill per item (tested, warning, failed, skipped) |
| One sheet per tested unit | Verdict pill, a short plain-English summary, 4 stat tiles, a **% of expected gauge** (0-120% scale, with 100% marked), two takeaway boxes, and a collapsible table with every score |
| What to do next | Prioritised recommendations |
| Limits of these tests | The caveats from the Markdown report |

Features:
- **Light and dark mode**, following your system setting.
- **Works offline:** the web fonts (Familjen Grotesk, Atkinson Hyperlegible, JetBrains Mono) are embedded into the file, so it loads nothing from the internet. If the font download fails, the page falls back to system fonts.
- **Print-friendly:** a print stylesheet uses the light palette, drops the sticky navigation and keeps cards and tables together across pages.
- **Colour coding:** green = pass, amber = below ~90% or warnings, red = errors or thermal throttling.

## PDF generation and auto-open

After the HTML is filled, Claude runs this **on your computer** (not the host):

```bash
python3 <skill-dir>/scripts/finish_report.py --html pve-stress-report-<duration>.html
```

It needs only Python 3 (standard library) and does four things:

1. **Embeds the fonts** into the HTML so it is self-contained.
2. **Makes the PDF** next to the HTML, from a temporary print copy with every collapsible section opened. It tries these renderers in order and uses the first that works:
   1. Google Chrome (headless)
   2. Chromium
   3. Microsoft Edge
   4. Brave
   5. `wkhtmltopdf`
   6. WeasyPrint (Python module or command)
3. **Opens the HTML** in your default browser.
4. Prints the paths of the Markdown, HTML and PDF files, and warns if any `{{placeholder}}` was left unfilled.

If **no renderer is found**, the Markdown and HTML are still complete. Open the HTML in a browser, expand the "All ... scores" sections and use **Print -> Save as PDF**, or install Chrome and run the command again.

| Option | Effect |
|---|---|
| `--pdf OUT.pdf` | Write the PDF somewhere else |
| `--no-open` | Don't open the browser (used when the PDF is refreshed after the Cleanup section is filled in) |
| `--no-embed-fonts` | Leave the Google Fonts link as it is |
