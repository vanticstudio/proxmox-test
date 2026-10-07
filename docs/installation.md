# Installation

There are three ways to install the skill. All three give Claude **the same files**: the `.skill` file, the `.zip` file and the `skill/proxmox-hardware-stress-test/` folder have identical contents (see [packages-explained.md](packages-explained.md)).

| Option | Best for | What you need |
|---|---|---|
| [1. One-click `.skill` file](#option-1-one-click-skill-file-claude-apps) | Claude apps that accept skill uploads | The `.skill` file from `dist/` |
| [2. Copy or clone the folder](#option-2-claude-code-copy-or-clone-the-skill-folder) | Claude Code users, people who want to read or edit the skill | `git` (optional) |
| [3. Unzip the `.zip`](#option-3-unzip-the-zip) | Claude Code users who don't use git | `unzip` |

> **Where the skill can actually run:** the skill drives your Proxmox host over SSH. It only works in a Claude client that can run shell commands (`ssh`, `tar`, `python3`) **on a computer that can reach your Proxmox host**. Claude Code on your laptop or desktop is the main target. A cloud-hosted chat can install the skill, but it usually can't reach a server on your home network.

---

## Before you start (prerequisites)

| On your own computer | On the Proxmox host |
|---|---|
| Claude Code (or another Claude client with skills + shell access) | Proxmox VE 8 or 9 (Debian 12/13), Intel or AMD CPU |
| `ssh`, `tar` and `python3` (macOS, Linux or WSL; bash or zsh) | Root SSH access with a **key** (or Tailscale SSH) |
| Optional: Chrome, Chromium, Edge or Brave for the PDF (otherwise print the HTML to PDF yourself) | Internet access for `apt` (to install the test tools; they are removed again afterwards) |
| | For full read+write disk scores: some free space on each disk (about 2x the test file, so ~16 GB on an SSD, ~8 GB on an HDD) on a mounted filesystem. Disks without one are tested read-only |

### Set up SSH key login to the host

The skill sends dozens of commands to the host, so it **never asks for, stores or passes a password**. It needs key-based login. Do this once, in your own terminal (the IP below is an example, use your host's address):

```bash
# 1. Create a key if you don't have one yet (press Enter to accept the defaults)
ssh-keygen -t ed25519

# 2. Copy your public key to the Proxmox host (you type the root password once, here)
ssh-copy-id root@192.0.2.10

# 3. Check that login now works without a password
ssh -o BatchMode=yes root@192.0.2.10 'pveversion'
```

Step 3 should print a `pve-manager/...` line. If your SSH port is not 22, add `-p PORT` to both commands. Using Tailscale SSH instead? That works too: access comes from your tailnet policy, not from `authorized_keys`.

> Tip: in Claude Code you can run step 2 yourself by starting the line with `!`, so the password goes into your own terminal and never into the conversation.

---

## Option 1: One-click `.skill` file (Claude apps)

1. Download `dist/proxmox-hardware-stress-test.skill` from the repository (or from the Releases page, if there is one):
   `https://github.com/<your-github-user>/proxmox-hardware-stress-test`
2. In your Claude app, open the skills settings and upload the file. In the claude.ai apps this is under **Settings -> Capabilities -> Skills**. (Menu names can change between app versions.)
3. Make sure the skill is switched on.

A `.skill` file is just a zip archive with a different extension. If you want to look inside before you upload it, see [How to inspect a .skill file](packages-explained.md#how-to-inspect-a-skill-file).

## Option 2: Claude Code, copy or clone the skill folder

Claude Code loads personal skills from `~/.claude/skills/<skill-name>/`. The folder must be called `proxmox-hardware-stress-test` and contain `SKILL.md` directly.

**a) You already have the repository on disk** (downloaded or cloned):

```bash
mkdir -p ~/.claude/skills
cp -R skill/proxmox-hardware-stress-test ~/.claude/skills/
```

Run this from the repository root.

**b) Clone only the skill folder** (sparse checkout, skips `dist/` and the docs):

```bash
git clone --depth 1 --filter=blob:none --sparse \
  https://github.com/<your-github-user>/proxmox-hardware-stress-test.git
cd proxmox-hardware-stress-test
git sparse-checkout set skill
mkdir -p ~/.claude/skills
cp -R skill/proxmox-hardware-stress-test ~/.claude/skills/
```

**c) Full clone:**

```bash
git clone https://github.com/<your-github-user>/proxmox-hardware-stress-test.git
mkdir -p ~/.claude/skills
cp -R proxmox-hardware-stress-test/skill/proxmox-hardware-stress-test ~/.claude/skills/
```

To update later: `git pull` in your clone, then copy the folder again (delete the old copy first so removed files don't linger). If you plan to edit the skill, a symlink is handier than a copy; see [developing.md](developing.md#working-on-the-skill-locally).

> Skills for a single project can also live in that project's `.claude/skills/` folder instead of your home folder.

## Option 3: Unzip the `.zip`

1. Download `dist/proxmox-hardware-stress-test.zip`.
2. (Recommended) check it against `dist/SHA256SUMS`, see [Verify a download](packages-explained.md#verify-a-download-with-sha256sums).
3. Unzip it into your skills folder:

```bash
mkdir -p ~/.claude/skills
unzip -l proxmox-hardware-stress-test.zip          # look first: every path should start with proxmox-hardware-stress-test/
unzip proxmox-hardware-stress-test.zip -d ~/.claude/skills/
```

The same works with the `.skill` file: `unzip proxmox-hardware-stress-test.skill -d ~/.claude/skills/`.

---

## Check that it is installed

```bash
ls ~/.claude/skills/proxmox-hardware-stress-test/SKILL.md
```

If that prints the path, the files are in place. Then **start a new Claude Code session** (skills are picked up when a session starts) and ask:

> What skills do you have available?

`proxmox-hardware-stress-test` should be in the list. In the Claude apps, the skill appears in the skills settings page after upload.

**Not showing up?** The most common cause is one folder level too many, e.g. `~/.claude/skills/proxmox-hardware-stress-test/proxmox-hardware-stress-test/SKILL.md`. Move the inner folder up one level.

## Use it

You don't need to name the skill. Describe what you want, for example:

> Stress test my Proxmox server and tell me if everything is running properly.

> Run a 5-minute burn-in on my homelab box at 192.0.2.10, I want to check the CPU temps and the NVMe speed.

Claude then asks how long to test each part (30 seconds, 1, 5 or 10 minutes) and the host's SSH address (unless you already said), shows you a full inventory and test plan, and **waits for your yes** before it installs or loads anything. The whole flow is described in [how-it-works.md](how-it-works.md).

## Uninstall

**Claude Code (options 2 and 3):**

```bash
rm -rf ~/.claude/skills/proxmox-hardware-stress-test
```

**Claude apps (option 1):** remove or switch off the skill in the skills settings.

**The Proxmox host:** a normal run already cleans up after itself (it removes exactly the packages it installed, its test files and its working folder `/root/pve-stresstest`). If a run was interrupted, you can check for leftovers and remove them on the host:

```bash
bash /root/pve-stresstest/cleanup.sh --dry-run    # shows what it would do
bash /root/pve-stresstest/cleanup.sh              # does it (keeps logs unless --confirm-logs-copied)
```

The local report folder on your computer is yours to keep or delete.
