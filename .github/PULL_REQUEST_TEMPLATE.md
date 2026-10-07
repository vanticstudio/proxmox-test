## What does this change?

A short summary, and the issue it fixes if there is one (`Fixes #123`).

## How did you test it?

- [ ] Ran the changed script(s) on a real Proxmox VE host
  - PVE version:
  - Hardware it was tested on (CPU / GPU / disks, no serials):
  - Test length (30 s / 1 / 5 / 10 min per part):
- [ ] Ran the full skill end to end and checked the report (Markdown / HTML / PDF)
- [ ] Documentation-only change, no test needed
- [ ] Other:

## Checklist

- [ ] I ran `tools/build.sh` and committed the updated `dist/` files (`.skill`, `.zip`, `SHA256SUMS`)
- [ ] `tools/build.sh --check` passes
- [ ] No personal data anywhere: no real IP addresses (only `192.0.2.x`, `198.51.100.x`, `203.0.113.x`), hostnames, serial numbers, email addresses, usernames or home-folder paths
- [ ] Shell scripts pass `bash -n` and `shellcheck --severity=error`
- [ ] Docs updated if behaviour, flags or output changed (`README.md`, `docs/`, the skill's own `README.md` / `SKILL.md`)
- [ ] `CHANGELOG.md` has an entry for this change
- [ ] Scripts are still safe: disk tests never write to a raw block device (only to their own test file), and `cleanup.sh` still removes everything the change adds
