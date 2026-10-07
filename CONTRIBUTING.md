# Contributing

Thanks for helping. This skill gets better with every new kind of hardware it sees, so even a short report from your box is useful.

## Contents

- [The privacy rule (please read first)](#the-privacy-rule-please-read-first)
- [Reporting hardware results](#reporting-hardware-results)
- [Reporting a bug or asking for a feature](#reporting-a-bug-or-asking-for-a-feature)
- [Changing the code](#changing-the-code)
- [Testing without a real host: the mock hook](#testing-without-a-real-host-the-mock-hook)
- [Coding conventions](#coding-conventions)
- [Pull request checklist](#pull-request-checklist)

---

## The privacy rule (please read first)

Issues and pull requests are public. **Never post personal or host-identifying data**, in text, logs, screenshots or test fixtures:

| Don't include | Use instead |
|---|---|
| Hostnames, domain names | `pve-host`, `example.com` |
| IP addresses (LAN, public, Tailscale) | Documentation addresses such as `192.0.2.10` ([RFC 5737](https://www.rfc-editor.org/rfc/rfc5737)) |
| Disk, board or system serial numbers, MAC addresses | Masked values, e.g. `****ABCD` |
| Usernames, home-folder paths (`/Users/<you>`, `/home/<you>`) | `~`, `<user>` |
| Guest (VM / container) names | Guest IDs only, e.g. `VM 100` |

The skill's `inventory.json` / `inventory.md` are already masked, and the **reports** leave out serials, IP and MAC addresses (but the report header can name your host, so check it before pasting). The **raw logs** are not: `hardware.json`, `*smartctl*`, `smart-*.txt`, `dmidecode-*`, `guests.txt` and kernel log excerpts can contain serials, the hostname and IP or MAC addresses. Redact them before attaching.

## Reporting hardware results

Results from real hardware help us improve the reference values and spot parts the skill handles badly. Open a **Hardware report** issue (template: [.github/ISSUE_TEMPLATE/hardware_report.md](.github/ISSUE_TEMPLATE/hardware_report.md)) and include:

1. The **at-a-glance table** from your Markdown report (it is already privacy-safe).
2. The exact **models** (CPU, RAM kit, GPU, SSD, HDD), the test **duration** you chose, and the Proxmox VE version.
3. Anything odd: a part scored far from 100%, a reference that looked wrong, a part that was skipped when it shouldn't have been, or a sensor that showed `n/a`.
4. Whether guests were running during the test (they lower the scores).

If you know a better reference value (a manufacturer spec page or a well-known published benchmark), link the source. Please don't suggest numbers without a source.

## Reporting a bug or asking for a feature

- **Bug:** use the [bug report template](.github/ISSUE_TEMPLATE/bug_report.md). Say which step failed (SSH, plan, a test unit, report, cleanup), paste the error, and describe your setup (single disk, ZFS mirror, HBA, RAID controller, number of GPUs ...).
- **Feature:** use the [feature request template](.github/ISSUE_TEMPLATE/feature_request.md).
- **A safety problem** (the skill wrote, deleted or changed something it shouldn't): do **not** open a public issue. Follow [SECURITY.md](SECURITY.md).

## Changing the code

1. Fork the repository and make your change inside **`skill/proxmox-hardware-stress-test/`**. That folder is the source of truth; never edit the files in `dist/` by hand.
2. Test it (see below). For anything that touches the inventory or test plan, add or update a mock host.
3. Rebuild the packages:

   ```bash
   tools/build.sh
   ```

   This regenerates `dist/proxmox-hardware-stress-test.skill`, `dist/proxmox-hardware-stress-test.zip` and `dist/SHA256SUMS`, so the packages always match the folder. See [docs/packages-explained.md](docs/packages-explained.md).
4. Add a line under **[Unreleased]** in [CHANGELOG.md](CHANGELOG.md).
5. Open a pull request using the template.

More background on the code layout: [docs/developing.md](docs/developing.md) and [docs/how-it-works.md](docs/how-it-works.md).

## Testing without a real host: the mock hook

You don't need a spare Proxmox server for most changes to discovery and planning. `inventory.py` has a developer-only test hook:

- Set `PVE_STRESS_MOCK_DIR=<fixture folder>`.
- Every file the script would read from `/sys`, `/proc`, `/dev`, `/etc/pve` and mount points is read from `<fixture folder>/root/...` instead.
- Every command's output comes from `<fixture folder>/commands.json`, a map of `"<command line>": "output text"` (or `"@relative/file"` to load the output from a file). A command that isn't listed is treated as missing.

That lets you check the inventory and plan against simulated hosts (dual-socket servers, HBAs, hardware RAID, ZFS / Ceph / mdraid, GPU passthrough, mini PCs) on any machine with Python 3.7+. The script header in `skill/proxmox-hardware-stress-test/scripts/inventory.py` has the details.

Fixtures must follow the privacy rule too: invent serials, use RFC 5737 addresses, generic hostnames.

**Changes to the test scripts themselves** (`cpu.sh`, `ram.sh`, `gpu.sh`, `disk.sh`, `cleanup.sh`) need a real or nested Proxmox VE 8/9 host you don't mind loading. Say in the pull request what you tested on (in general terms, e.g. "PVE 9, single NVMe, ext4 root, no GPU").

## Coding conventions

Follow the style of the existing scripts:

- **Bash:** `#!/usr/bin/env bash`, `set -u` and `set -o pipefail`. Quote variables. Parse long options in a `while`/`case` loop with a clear error for unknown arguments.
- **Python:** standard library only, Python 3.7+ compatible.
- **Header comment in every script:** usage, every flag, what it measures, outputs, exit codes and timing. Keep it current: `SKILL.md` relies on these headers.
- **Exit codes:** `0` finished (even if some sub-tests were skipped), `3` refused or skipped something for safety (with the reason printed or in `summary.json`), non-zero otherwise for usage errors or fatal problems. Document them in the script header.
- **Outputs:** each test writes a `summary.json` with status, scores, errors, warnings and skipped sub-tests, plus CSV telemetry.
- **Missing sensors are not failures:** record the literal `n/a` and carry on.
- **Safety first:** read the "Rules that keep this safe" in `SKILL.md` and [SECURITY.md](SECURITY.md). A change must never write to a raw device, change a host setting, or start / stop a guest. New packages must come from Debian / Proxmox apt repos and go through the install ledger.
- **Plain English** in anything the user sees: explain a term once, then give the number and what it means.

## Pull request checklist

- [ ] No personal or host data anywhere (text, logs, screenshots, fixtures).
- [ ] Changes are inside `skill/proxmox-hardware-stress-test/` (plus docs if needed), not in `dist/`.
- [ ] `tools/build.sh` was run and `dist/` is up to date.
- [ ] Script header comments updated if flags or outputs changed.
- [ ] CHANGELOG.md updated under [Unreleased].
- [ ] Tested with the mock hook and / or on a real host (described in the PR).

**Sign-off is optional.** If you like, add a `Signed-off-by:` line (`git commit -s`) to certify you wrote the change ([Developer Certificate of Origin](https://developercertificate.org/)); it isn't required.

By contributing you agree that your contribution is licensed under the [MIT licence](LICENSE).
