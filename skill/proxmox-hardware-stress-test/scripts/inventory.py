#!/usr/bin/env python3
# =============================================================================
# inventory.py - full hardware inventory + per-component test plan for the
#                proxmox-hardware-stress-test skill. Called by prep.sh (step 4b);
#                can also be run on its own after prep.sh wrote hardware.json.
#
# Usage (root, on the Proxmox host):
#   python3 inventory.py --out DIR [--duration SECONDS] [--mode plan-only|full]
#                        [--warnings-file F] [--packages-file F]
#
#   --out DIR         run root; must contain hardware.json (written by prep.sh).
#   --duration S      per-part stress length the user chose; used for the time
#                     estimates (default 60 when not given; marked "assumed").
#   --mode            plan-only = prep ran with --plan-only (nothing installed,
#                     no baseline yet; prep time is added to the estimate).
#   --warnings-file   prep's warnings, one per line (copied into plan.json).
#   --packages-file   packages prep would install / installed, one per line.
#
# Writes (all report-safe: serial numbers and MACs masked to the last 4
# characters, no hostname, no IP addresses, guests only by numeric ID):
#   DIR/inventory.json  every component with full specs (schema below)
#   DIR/inventory.md    the same as readable tables
#   DIR/plan.json       one TEST UNIT per testable item, in run order
#                       CPU -> RAM -> each GPU -> each SSD (NVMe first) -> each
#                       HDD (-> optional multi-disk pool units), with method,
#                       ready-to-run command, estimated time; plus skipped units
#                       with reasons and "inventory only" items (NICs, ...)
#   DIR/plan.md         the plan as a table to show the user before anything
#                       is installed or loaded
#   and adds to DIR/hardware.json: "system", "board", "bios", "cpu.sockets_detail",
#   "storage_controllers", "nics", "raid_hidden_disks", per-disk "usage" /
#   "controller" / "plan", plus "inventory_file" and "plan_file".
#
# Read-only: runs only query commands (lsblk, lspci, smartctl -a/-i, dmidecode,
# pvs/lvs, zpool status, nvidia-smi, ethtool, ipmitool sdr, sensors) and reads
# sysfs, /proc and /etc/pve. Never installs, writes to devices or changes
# settings. Every missing tool or sensor becomes "not reported" / null.
# Needs python3 >= 3.7 (stock on PVE 7/8/9).
#
# DEVELOPER-ONLY test hook (never used in a real run): when the environment
# variable PVE_STRESS_MOCK_DIR points at a fixture folder, every file path
# (/sys, /proc, /dev, /etc/pve, mountpoints) is read from <dir>/root/... and
# every command's output comes from <dir>/commands.json ({"<cmd line>": "text"
# or "@relative/file"}; a command that is not listed is treated as missing).
# This lets the inventory and plan logic be checked against simulated hosts
# (dual-socket servers, HBAs, hardware RAID, mini PCs) on any machine.
# =============================================================================
import argparse
import glob
import json
import os
import re
import shutil
import subprocess
import sys
import time

NR = "not reported"
JUNK = {"", "to be filled by o.e.m.", "default string", "not specified", "none", "n/a", "na",
        "system serial number", "system product name", "system manufacturer", "system version",
        "base board serial number", "chassis serial number", "0", "00000000", "0123456789",
        "123456789", "unknown", "not available", "no asset tag", "[empty]", "o.e.m.", "oem",
        "not provided", "serial number", "default", "unknow"}

GIB = 1024 ** 3


# ----------------------------------------------------------------------------- filesystem / command layer
# All host access goes through these few functions so the developer-only mock
# (PVE_STRESS_MOCK_DIR, see header) can redirect it. Without the variable they
# are thin wrappers around os / glob / subprocess.
MOCK = os.environ.get("PVE_STRESS_MOCK_DIR") or None
MOCK_ROOT, MOCK_CMDS = None, {}
if MOCK:
    MOCK = os.path.realpath(MOCK)
    MOCK_ROOT = os.path.join(MOCK, "root")
    try:
        with open(os.path.join(MOCK, "commands.json")) as _f:
            MOCK_CMDS = json.load(_f)
    except Exception:
        MOCK_CMDS = {}


def P(path):
    """Host path -> path actually opened (mock root prefix in mock mode)."""
    if MOCK and isinstance(path, str) and path.startswith("/"):
        return MOCK_ROOT + path
    return path


def U(path):
    """Opened path -> host path (strip the mock root again)."""
    if MOCK and isinstance(path, str) and path.startswith(MOCK_ROOT):
        return path[len(MOCK_ROOT):] or "/"
    return path


def x_exists(p):
    return os.path.exists(P(p))


def x_isdir(p):
    return os.path.isdir(P(p))


def x_glob(pattern):
    return [U(g) for g in glob.glob(P(pattern))]


def x_realpath(p):
    return U(os.path.realpath(P(p)))


def x_listdir(p):
    return os.listdir(P(p))


def x_open(p, mode="r"):
    return open(P(p), mode) if "b" in mode else open(P(p), mode, errors="replace")


def x_writable(p):
    if MOCK:
        return os.path.isdir(P(p)) and not os.path.exists(P(p) + "/.mock-readonly")
    return os.access(p, os.W_OK)


def x_nodename():
    if MOCK:
        return (MOCK_CMDS.get("hostname") or "mock-node").strip()
    return os.uname()[1]


def which(name):
    if MOCK:
        return any(k.split()[0] == name for k in MOCK_CMDS)
    return shutil.which(name) is not None


def run(cmd, timeout=30):
    """Run a command, return stdout ('' on any failure). Non-zero exit is fine
    (smartctl returns a bitmask) as long as there is output."""
    if MOCK:
        v = MOCK_CMDS.get(" ".join(cmd))
        if v is None:
            return ""
        if isinstance(v, str) and v.startswith("@"):
            try:
                with open(os.path.join(MOCK, v[1:]), errors="replace") as f:
                    return f.read()
            except Exception:
                return ""
        return v
    if not shutil.which(cmd[0]):
        return ""
    try:
        p = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, timeout=timeout,
                           universal_newlines=True, env=dict(os.environ, LC_ALL="C"))
        return p.stdout or ""
    except Exception:
        return ""


# ----------------------------------------------------------------------------- helpers
def rd(path):
    try:
        with x_open(path) as f:
            v = f.read().strip()
        return v if v != "" else None
    except Exception:
        return None


def rdi(path):
    v = rd(path)
    try:
        return int(v)
    except Exception:
        return None


def clean(s):
    if s is None:
        return None
    s = str(s).strip().strip("\x00").strip()
    return None if s.lower() in JUNK else s


def mask(s):
    s = clean(s)
    if not s:
        return None
    s = re.sub(r"\s+", "", s)
    return "****" + s[-4:] if len(s) > 4 else "****"


def mask_mac(m):
    if not m or not re.match(r"^[0-9a-fA-F:]{17}$", m):
        return None
    return "xx:xx:xx:xx:" + m[-5:].lower()


def nkey(s):
    return [int(t) if t.isdigit() else t for t in re.split(r"(\d+)", str(s))]


def link_name(path):
    try:
        return os.path.basename(x_realpath(path))
    except Exception:
        return None


def human_bytes(b, unit=None):
    if b is None:
        return NR
    b = float(b)
    for u, d in (("TB", 1e12), ("GB", 1e9), ("MB", 1e6)):
        if b >= d or u == "MB":
            v = b / d
            return ("%.2f %s" % (v, u)) if v < 10 else ("%.1f %s" % (v, u)) if v < 100 else ("%.0f %s" % (v, u))
    return "%d B" % b


def gib(b):
    return None if b is None else round(b / GIB, 1)


def fmt_s(s):
    s = int(round(s))
    if s < 90:
        return "%d s" % s
    m = s / 60.0
    if m < 90:
        return "~%d min" % round(m)
    return "~%dh %02dm" % (s // 3600, (s % 3600) // 60)


def pcie_gen(speed):
    """'16.0 GT/s PCIe' -> '4.0'."""
    if not speed:
        return None
    m = re.search(r"([\d.]+)\s*GT/s", speed)
    if not m:
        return None
    return {"2.5": "1.0", "5.0": "2.0", "5": "2.0", "8.0": "3.0", "8": "3.0", "16.0": "4.0", "16": "4.0",
            "32.0": "5.0", "32": "5.0", "64.0": "6.0", "64": "6.0"}.get(m.group(1))


def pci_link(slot):
    d = "/sys/bus/pci/devices/%s" % slot
    ms, mw = rd(d + "/max_link_speed"), rd(d + "/max_link_width")
    cs, cw = rd(d + "/current_link_speed"), rd(d + "/current_link_width")
    if not ms and not cs:
        return None

    def txt(s, w):
        if not s or s.lower().startswith("unknown"):
            return None
        g = pcie_gen(s)
        return ("PCIe %s x%s" % (g, w)) if g else ("%s x%s" % (s, w))
    return {"max": txt(ms, mw), "current": txt(cs, cw), "max_raw": ms, "current_raw": cs,
            "max_width": mw, "current_width": cw}


_lspci_all = None


def lspci_name(slot):
    """Device name from one 'lspci -D' call (cached); per-slot query as fallback."""
    global _lspci_all
    if _lspci_all is None:
        _lspci_all = {}
        for line in run(["lspci", "-D"]).splitlines():
            m = re.match(r"^([0-9a-fA-F]{4,5}:[0-9a-fA-F]{2}:[0-9a-fA-F]{2}\.[0-7])\s+[^:]*:\s*(.*)$", line)
            if m:
                _lspci_all[m.group(1).lower()] = m.group(2).strip()
    if slot in _lspci_all:
        return _lspci_all[slot]
    name = None
    if not MOCK:
        out = run(["lspci", "-s", slot]).strip().splitlines()
        if out:
            name = re.sub(r"^\S+\s+", "", out[0])
            name = re.sub(r"^[^:]*:\s*", "", name)
    _lspci_all[slot] = name
    return name


def pci_info(slot):
    d = "/sys/bus/pci/devices/%s" % slot
    drv = link_name(d + "/driver") if x_exists(d + "/driver") else None
    grp = link_name(d + "/iommu_group") if x_exists(d + "/iommu_group") else None
    return {"slot": slot, "name": lspci_name(slot), "vendor_id": rd(d + "/vendor"), "device_id": rd(d + "/device"),
            "subsystem_vendor_id": rd(d + "/subsystem_vendor"), "subsystem_device_id": rd(d + "/subsystem_device"),
            "class": rd(d + "/class"), "driver": drv, "iommu_group": grp, "numa_node": rdi(d + "/numa_node")}


def pci_of_path(syspath):
    """Last PCI address in a resolved sysfs path (the device's controller)."""
    try:
        p = x_realpath(syspath)
    except Exception:
        return None
    hits = re.findall(r"/([0-9a-f]{4,5}:[0-9a-f]{2}:[0-9a-f]{2}\.[0-7])(?=/)", p + "/")
    return hits[-1] if hits else None


LSBLK_COLS = "NAME,KNAME,PATH,TYPE,SIZE,FSTYPE,MOUNTPOINTS,ROTA,TRAN,MODEL,SERIAL,REV,RM,HOTPLUG,VENDOR,PHY-SEC,LOG-SEC"
LSBLK_COLS_OLD = "NAME,KNAME,PATH,TYPE,SIZE,FSTYPE,MOUNTPOINT,ROTA,TRAN,MODEL,SERIAL,REV,RM,HOTPLUG,VENDOR"
_lsblk = None


def lsblk_tree():
    """(tree, mountpoint key, {name|kname|path: [whole disks]}) from one lsblk -J call."""
    global _lsblk
    if _lsblk is not None:
        return _lsblk
    mpkey = "mountpoints"
    lj = run(["lsblk", "-J", "-b", "-o", LSBLK_COLS])
    if not lj:
        lj = run(["lsblk", "-J", "-b", "-o", LSBLK_COLS_OLD])
        mpkey = "mountpoint"
    try:
        tree = json.loads(lj).get("blockdevices", []) or []
    except Exception:
        tree = []
    anc = {}

    def walk(n, top):
        for k in (n.get("name"), n.get("kname"), n.get("path")):
            if k and top not in anc.setdefault(k, []):
                anc[k].append(top)
        for c in n.get("children") or []:
            walk(c, top)
    for n in tree:
        if n.get("type") == "disk" and n.get("name"):
            walk(n, n["name"])
    _lsblk = (tree, mpkey, anc)
    return _lsblk


_anc_cache = {}


def disks_of(dev):
    """Whole-disk names under a block device (follows partitions, LVM, md, crypt).
    A device stacked on several disks (LVM VG over 2 PVs, md mirror) returns all of them."""
    if not dev:
        return []
    try:
        real = x_realpath(dev)
    except Exception:
        real = dev
    if real in _anc_cache:
        return _anc_cache[real]
    anc = lsblk_tree()[2]
    res = []
    for k in (real, os.path.basename(real), dev, os.path.basename(dev)):
        if k in anc:
            res = list(anc[k])
            break
    if not res and not MOCK:
        out = run(["lsblk", "-nrs", "-o", "NAME,TYPE", real])
        for line in out.splitlines():
            f = line.split()
            if len(f) >= 2 and f[1] == "disk" and f[0] not in res:
                res.append(f[0])
    if not res:
        n = os.path.basename(real)
        if x_exists("/sys/class/block/%s/partition" % n):
            res = [os.path.basename(os.path.dirname(x_realpath("/sys/class/block/" + n)))]
        elif x_exists("/sys/block/" + n):
            res = [n]
    _anc_cache[real] = res
    return res


FS_MOUNTS = []    # mountpoints from hardware.json (used for mount_of in mock mode)


def mount_of(path):
    try:
        if MOCK:
            best = None
            for mp in FS_MOUNTS:
                if path == mp or path.startswith(mp.rstrip("/") + "/"):
                    if best is None or len(mp) > len(best):
                        best = mp
            return best or "/"
        p = os.path.realpath(path)
        while not os.path.ismount(p):
            p = os.path.dirname(p)
        return p
    except Exception:
        return None


def dmi_parse(text):
    recs, cur, lastkey = [], None, None
    for line in text.splitlines():
        m = re.match(r"^Handle (0x[0-9A-Fa-f]+), DMI type (\d+)", line)
        if m:
            cur = {"_handle": m.group(1), "_type": int(m.group(2)), "_name": None}
            recs.append(cur)
            lastkey = None
            continue
        if cur is None or not line.strip():
            continue
        if cur["_name"] is None and not line.startswith("\t"):
            cur["_name"] = line.strip()
            continue
        if line.startswith("\t\t"):
            if lastkey:
                cur.setdefault(lastkey + "_list", []).append(line.strip())
            continue
        if line.startswith("\t"):
            k, _, v = line.strip().partition(":")
            cur[k.strip()] = v.strip()
            lastkey = k.strip()
    return recs


def size_mb(s):
    if not s:
        return None
    m = re.match(r"^\s*(\d+(?:\.\d+)?)\s*(TB|GB|MB|KB|kB)", s)
    if not m:
        return None
    v = float(m.group(1))
    return int(v * {"TB": 1048576, "GB": 1024, "MB": 1, "KB": 1 / 1024.0, "kB": 1 / 1024.0}[m.group(2)])


def num_prefix(s):
    if not s:
        return None
    m = re.match(r"^\s*(\d+(?:\.\d+)?)", s)
    if not m:
        return None
    v = float(m.group(1))
    return int(v) if v.is_integer() else v


def cache_bytes(s):
    if not s:
        return 0
    m = re.match(r"^(\d+)([KMG]?)", s)
    if not m:
        return 0
    return int(m.group(1)) * {"": 1, "K": 1024, "M": 1048576, "G": GIB}[m.group(2)]


def expand_cpulist(s):
    out = []
    for part in (s or "").split(","):
        part = part.strip()
        if not part:
            continue
        if "-" in part:
            a, b = part.split("-", 1)
            out.extend(range(int(a), int(b) + 1))
        else:
            out.append(int(part))
    return out


def compress_cpulist(ids):
    ids = sorted(set(ids))
    out, i = [], 0
    while i < len(ids):
        j = i
        while j + 1 < len(ids) and ids[j + 1] == ids[j] + 1:
            j += 1
        out.append(str(ids[i]) if i == j else "%d-%d" % (ids[i], ids[j]))
        i = j + 1
    return ",".join(out)


# ----------------------------------------------------------------------------- Proxmox config
def conf_top(path):
    lines = []
    try:
        with x_open(path) as f:
            for line in f:
                if line.startswith("["):
                    break
                lines.append(line.rstrip("\n"))
    except Exception:
        pass
    return lines


def norm_pci(addr):
    addr = addr.strip().lower()
    if not addr:
        return None
    if re.match(r"^[0-9a-f]{2}:[0-9a-f]{2}(\.[0-7])?$", addr):
        addr = "0000:" + addr
    return addr


def pci_mappings():
    """Resource mappings (/etc/pve/mapping/pci.cfg): name -> [addresses on this node]."""
    res, cur = {}, None
    node = x_nodename()
    try:
        with x_open("/etc/pve/mapping/pci.cfg") as f:
            for line in f:
                if line.strip() and not line[0].isspace():
                    cur = line.strip()
                    res.setdefault(cur, [])
                elif cur and line.strip().startswith("map "):
                    props = dict(kv.split("=", 1) for kv in line.strip()[4:].split(",") if "=" in kv)
                    if props.get("node", node) == node and props.get("path"):
                        res[cur].extend(norm_pci(p) for p in props["path"].split(";") if p)
    except Exception:
        pass
    return res


def read_guest_configs(running_vms):
    """Which disks / PCI devices are given to which VM or container."""
    maps = pci_mappings()
    disk_vm, pci_vm, ct_gpu = {}, {}, {"nvidia": [], "dri": []}
    for conf in sorted(x_glob("/etc/pve/qemu-server/*.conf"), key=nkey):
        vmid = os.path.basename(conf)[:-5]
        for line in conf_top(conf):
            m = re.match(r"^(scsi|sata|ide|virtio)\d+:\s*(\S+)", line)
            if m:
                src = m.group(2).split(",")[0]
                if src.startswith("/dev/"):
                    for d in disks_of(src):
                        disk_vm.setdefault(d, []).append(vmid)
                continue
            m = re.match(r"^hostpci\d+:\s*(\S+)", line)
            if m:
                first = m.group(1).split(",")[0]
                addrs = []
                if first.startswith("mapping="):
                    addrs = maps.get(first[8:], [])
                else:
                    first = first.replace("host=", "")
                    addrs = [norm_pci(a) for a in first.split(";") if a]
                for a in addrs:
                    if a:
                        pci_vm.setdefault(a, []).append(vmid)
    for conf in sorted(x_glob("/etc/pve/lxc/*.conf"), key=nkey):
        ctid = os.path.basename(conf)[:-5]
        txt = "\n".join(conf_top(conf))
        # GPU device nodes handed to the container: remember WHICH ones (None = all/unknown)
        if "/dev/nvidia" in txt:
            idx = sorted({int(x) for x in re.findall(r"/dev/nvidia(\d+)\b", txt)})
            ct_gpu["nvidia"].append((ctid, idx or None))
        if "/dev/dri" in txt:
            idx = sorted({(k, int(x)) for k, x in re.findall(r"/dev/dri/(card|renderD)(\d+)", txt)})
            ct_gpu["dri"].append((ctid, idx or None))
        for m in re.finditer(r"^(?:dev|mp)\d+:\s*(/dev/[^,\s]+)", txt, re.M):
            for d in disks_of(m.group(1)):
                disk_vm.setdefault(d, []).append("ct" + ctid)

    def vm_state(v):
        if v.startswith("ct"):
            return "container %s" % v[2:]
        return "VM %s (%s)" % (v, "running" if v in running_vms else "stopped")
    return disk_vm, pci_vm, ct_gpu, vm_state


def pci_vms(slot, pci_vm):
    s = slot.lower()
    out = []
    for a, vms in pci_vm.items():
        if s == a or (re.match(r"^[0-9a-f]{4,5}:[0-9a-f]{2}:[0-9a-f]{2}$", a) and s.startswith(a + ".")):
            out.extend(vms)
    return sorted(set(out), key=nkey)


def storage_cfg():
    res, cur = [], None
    try:
        with x_open("/etc/pve/storage.cfg") as f:
            for line in f:
                m = re.match(r"^(\w+):\s*(\S+)", line)
                if m:
                    cur = {"type": m.group(1), "name": m.group(2)}
                    res.append(cur)
                elif cur and line.strip():
                    k, _, v = line.strip().partition(" ")
                    cur[k] = v.strip()
    except Exception:
        pass
    return res


# ----------------------------------------------------------------------------- collectors
def collect_system():
    D = "/sys/class/dmi/id/"
    chassis = {1: "Other", 2: "Unknown", 3: "Desktop", 4: "Low-profile desktop", 5: "Pizza box", 6: "Mini tower",
               7: "Tower", 8: "Portable", 9: "Laptop", 10: "Notebook", 11: "Handheld", 12: "Docking station",
               13: "All-in-one", 14: "Sub-notebook", 15: "Space-saving", 16: "Lunch box", 17: "Main server chassis",
               23: "Rack mount chassis", 24: "Sealed-case PC", 25: "Multi-system chassis", 28: "Blade",
               29: "Blade enclosure", 30: "Tablet", 31: "Convertible", 32: "Detachable", 33: "IoT gateway",
               34: "Embedded PC", 35: "Mini PC", 36: "Stick PC"}
    ct = rdi(D + "chassis_type")
    secure = None
    for f in x_glob("/sys/firmware/efi/efivars/SecureBoot-8be4df61-93ca-11d2-aa0d-00e098032b8c"):
        try:
            with x_open(f, "rb") as fh:
                b = fh.read()
            secure = "on" if len(b) >= 5 and b[4] == 1 else "off"
        except Exception:
            pass
    fw = "UEFI" if x_isdir("/sys/firmware/efi") else "Legacy BIOS"
    bios_extra = {}
    t = run(["dmidecode", "-t", "0"])
    for r in dmi_parse(t):
        if r["_type"] == 0:
            bios_extra = {"release": clean(r.get("BIOS Revision")), "firmware_revision": clean(r.get("Firmware Revision")),
                          "rom_size": clean(r.get("ROM Size"))}
    system = {"vendor": clean(rd(D + "sys_vendor")), "product": clean(rd(D + "product_name")),
              "version": clean(rd(D + "product_version")), "family": clean(rd(D + "product_family")),
              "sku": clean(rd(D + "product_sku")), "serial_masked": mask(rd(D + "product_serial")),
              "chassis_type": chassis.get(ct, NR if ct is None else "type %s" % ct),
              "chassis_vendor": clean(rd(D + "chassis_vendor")), "chassis_serial_masked": mask(rd(D + "chassis_serial"))}
    board = {"vendor": clean(rd(D + "board_vendor")), "model": clean(rd(D + "board_name")),
             "version": clean(rd(D + "board_version")), "serial_masked": mask(rd(D + "board_serial"))}
    bios = {"vendor": clean(rd(D + "bios_vendor")), "version": clean(rd(D + "bios_version")),
            "date": clean(rd(D + "bios_date")), "release": clean(rd(D + "bios_release")) or bios_extra.get("release"),
            "firmware_revision": bios_extra.get("firmware_revision"), "rom_size": bios_extra.get("rom_size"),
            "boot_mode": fw, "secure_boot": secure or (NR if fw == "UEFI" else "n/a (legacy BIOS)")}
    iommu_groups = len(x_glob("/sys/kernel/iommu_groups/*"))
    platform = {"iommu_active": iommu_groups > 0, "iommu_groups": iommu_groups,
                "numa_nodes": len(x_glob("/sys/devices/system/node/node[0-9]*")) or 1,
                "bmc_ipmi_device": any(x_exists(p) for p in ("/dev/ipmi0", "/dev/ipmi/0", "/dev/ipmidev/0"))}
    return system, board, bios, platform


def collect_cpu(hw):
    cpuinfo = {}
    blk = {}
    try:
        with x_open("/proc/cpuinfo") as f:
            for line in f.read().split("\n"):
                if not line.strip():
                    if "processor" in blk:
                        cpuinfo[int(blk["processor"])] = blk
                    blk = {}
                    continue
                k, _, v = line.partition(":")
                blk[k.strip()] = v.strip()
        if "processor" in blk:
            cpuinfo[int(blk["processor"])] = blk
    except Exception:
        pass
    pkgs = {}
    for c in x_glob("/sys/devices/system/cpu/cpu[0-9]*"):
        cid = int(re.sub(r"\D", "", os.path.basename(c)))
        pid = rdi(c + "/topology/physical_package_id")
        if pid is None:
            continue
        pkgs.setdefault(pid, []).append(cid)
    pcores = set(expand_cpulist(rd("/sys/devices/cpu_core/cpus") or ""))
    ecores = set(expand_cpulist(rd("/sys/devices/cpu_atom/cpus") or ""))
    # dmidecode type 4 (sockets incl. empty ones)
    dmi_sock = [r for r in dmi_parse(run(["dmidecode", "-t", "4"])) if r["_type"] == 4]
    pop_sock = [r for r in dmi_sock if "Populated" in (r.get("Status") or "") and "Unpopulated" not in (r.get("Status") or "")]
    # RAPL per package
    rapl = {}
    for z in sorted(x_glob("/sys/class/powercap/intel-rapl:[0-9]*")):
        if z.count(":") != 1:
            continue
        name = rd(z + "/name") or ""
        m = re.match(r"^package-(\d+)", name)
        if not m:
            continue
        pid = int(m.group(1))
        lim = {}
        for f in x_glob(z + "/constraint_*_name"):
            base = f[:-5]
            n = rd(f)
            pl = rdi(base + "_power_limit_uw")
            tw = rdi(base + "_time_window_us")
            mx = rdi(base + "_max_power_uw")
            lim[n] = {"limit_w": round(pl / 1e6, 1) if pl else None, "window_s": round(tw / 1e6, 3) if tw else None,
                      "max_w": round(mx / 1e6, 1) if mx else None}
        rapl.setdefault(pid, {"domain": os.path.basename(z), "enabled": rd(z + "/enabled"), "constraints": {}})
        rapl[pid]["constraints"].update(lim)
    # temperatures per package
    temps = {}
    k10 = []
    for h in x_glob("/sys/class/hwmon/hwmon*"):
        n = rd(h + "/name")
        if n == "coretemp":
            for l in x_glob(h + "/temp*_label"):
                m = re.match(r"^Package id (\d+)", rd(l) or "")
                if m:
                    v = rdi(l[:-6] + "_input")
                    if v is not None:
                        temps[int(m.group(1))] = round(v / 1000.0, 1)
        elif n in ("k10temp", "zenpower"):
            k10.append(h)
    if k10:
        k10.sort(key=lambda h: x_realpath(h + "/device"))
        ns = max(1, len(pkgs))
        for i, h in enumerate(k10):
            sock = i * ns // len(k10)
            best = None
            for l in x_glob(h + "/temp*_label"):
                lab = rd(l)
                if lab in ("Tdie", "Tctl"):
                    v = rdi(l[:-6] + "_input")
                    if v is not None and (best is None or lab == "Tdie"):
                        best = round(v / 1000.0, 1)
            if best is None:
                v = rdi(h + "/temp1_input")
                best = round(v / 1000.0, 1) if v is not None else None
            if best is not None:
                temps[sock] = max(temps.get(sock, -999), best)
    sockets = []
    for idx, pid in enumerate(sorted(pkgs)):
        cpus = sorted(pkgs[pid])
        first = cpus[0]
        ci = cpuinfo.get(first, {})
        cores = set()
        dies = set()
        for c in cpus:
            cl = rd("/sys/devices/system/cpu/cpu%d/topology/core_cpus_list" % c) or \
                rd("/sys/devices/system/cpu/cpu%d/topology/thread_siblings_list" % c) or str(c)
            cores.add(cl)
            d = rdi("/sys/devices/system/cpu/cpu%d/topology/die_id" % c)
            if d is not None:
                dies.add(d)
        # caches: unique instances by (level,type,shared list)
        inst = {}
        for c in cpus:
            for ix in x_glob("/sys/devices/system/cpu/cpu%d/cache/index[0-9]*" % c):
                lvl, typ = rd(ix + "/level"), rd(ix + "/type")
                shared = rd(ix + "/shared_cpu_list") or str(c)
                key = (lvl, typ, shared)
                if key not in inst:
                    inst[key] = cache_bytes(rd(ix + "/size"))
        caches = {}
        for (lvl, typ, _), b in inst.items():
            name = "L%s%s" % (lvl, {"Data": "d", "Instruction": "i"}.get(typ, ""))
            e = caches.setdefault(name, {"total_kib": 0, "instances": 0, "sizes_kib": []})
            e["total_kib"] += b // 1024
            e["instances"] += 1
            if b // 1024 not in e["sizes_kib"]:
                e["sizes_kib"].append(b // 1024)
        f0 = "/sys/devices/system/cpu/cpu%d/cpufreq/" % first
        base = rdi(f0 + "base_frequency")
        dm = pop_sock[idx] if idx < len(pop_sock) else {}
        base_mhz = round(base / 1000) if base else num_prefix(dm.get("Current Speed"))
        base_src = "cpufreq base_frequency" if base else ("dmidecode Current Speed" if base_mhz else None)

        def fmax(ids):
            vals = [rdi("/sys/devices/system/cpu/cpu%d/cpufreq/cpuinfo_max_freq" % c) for c in ids]
            vals = [v for v in vals if v]
            return round(max(vals) / 1000) if vals else None

        def fmin(ids):
            vals = [rdi("/sys/devices/system/cpu/cpu%d/cpufreq/cpuinfo_min_freq" % c) for c in ids]
            vals = [v for v in vals if v]
            return round(min(vals) / 1000) if vals else None
        sp = [c for c in cpus if c in pcores]
        se = [c for c in cpus if c in ecores]
        hybrid = None
        if sp and se:
            def ncores(ids):
                s = set()
                for c in ids:
                    s.add(rd("/sys/devices/system/cpu/cpu%d/topology/core_cpus_list" % c) or str(c))
                return len(s)
            hybrid = {"p_cores": ncores(sp), "p_threads": len(sp), "p_cpulist": compress_cpulist(sp),
                      "p_max_mhz": fmax(sp), "e_cores": ncores(se), "e_threads": len(se),
                      "e_cpulist": compress_cpulist(se), "e_max_mhz": fmax(se)}
        r = rapl.get(pid)
        cons = (r or {}).get("constraints", {})
        sockets.append({
            "socket": pid,
            "designation": clean(dm.get("Socket Designation")),
            "model": ci.get("model name") or clean(dm.get("Version")) or NR,
            "vendor_id": ci.get("vendor_id"),
            "family": ci.get("cpu family"), "model_id": ci.get("model"), "stepping": ci.get("stepping"),
            "microcode": ci.get("microcode"),
            "cores": len(cores), "threads": len(cpus), "dies": len(dies) or 1,
            "cpulist": compress_cpulist(cpus),
            "base_mhz": base_mhz, "base_mhz_source": base_src, "max_mhz": fmax(cpus), "min_mhz": fmin(cpus),
            "dmi_max_speed_mhz": num_prefix(dm.get("Max Speed")), "external_clock_mhz": num_prefix(dm.get("External Clock")),
            "voltage": clean(dm.get("Voltage")),
            "hybrid": hybrid,
            "cache": caches,
            "rapl": {"domain": r["domain"], "pl1_w": cons.get("long_term", {}).get("limit_w"),
                     "pl1_window_s": cons.get("long_term", {}).get("window_s"),
                     "pl2_w": cons.get("short_term", {}).get("limit_w"),
                     "pl2_window_s": cons.get("short_term", {}).get("window_s"),
                     "tdp_w": cons.get("long_term", {}).get("max_w"),
                     "pl4_w": cons.get("peak_power", {}).get("limit_w")} if r else None,
            "temp_now_c": temps.get(pid if pid in temps else idx),
            "numa_nodes": sorted({int(os.path.basename(n)[4:]) for c in cpus[:1]
                                  for n in x_glob("/sys/devices/system/cpu/cpu%d/node[0-9]*" % c)}),
        })
    empty = [{"designation": clean(r.get("Socket Designation")), "status": r.get("Status")}
             for r in dmi_sock if "Unpopulated" in (r.get("Status") or "")]
    flags = (cpuinfo.get(min(cpuinfo)) or {}).get("flags", "").split() if cpuinfo else []
    feat = {f: (f in flags) for f in ("vmx", "svm", "avx", "avx2", "avx512f", "aes", "sha_ni", "rdrand")}
    c = hw.get("cpu", {})
    return {
        "sockets_populated": len(sockets), "sockets_empty": empty,
        "sockets_total": len(sockets) + len(empty),
        "vendor": c.get("vendor"), "model": c.get("model"), "cores_total": c.get("cores"),
        "threads_total": c.get("threads"), "hybrid": bool(c.get("hybrid")),
        "virtualization": "VT-x" if feat["vmx"] else ("AMD-V" if feat["svm"] else "none"),
        "features": feat, "scaling_driver": c.get("scaling_driver"), "governor": c.get("governor"),
        "epp": c.get("epp"), "boost": c.get("boost"), "power_telemetry": c.get("rapl_source"),
        "temp_telemetry": c.get("temp_source"), "sockets": sockets,
    }


def collect_memory(hw):
    m = hw.get("memory", {})
    recs = dmi_parse(run(["dmidecode", "-t", "16", "-t", "17"]))
    arrays = {r["_handle"]: r for r in recs if r["_type"] == 16}
    sysarr = {h for h, r in arrays.items() if "System Memory" in (r.get("Use") or "System Memory")}
    slots = []
    for r in recs:
        if r["_type"] != 17:
            continue
        ah = r.get("Array Handle")
        if ah and sysarr and ah not in sysarr:
            continue
        size = r.get("Size") or ""
        pop = bool(size) and "No Module" not in size and "Not Installed" not in size and size_mb(size) not in (None, 0)
        tw, dw = num_prefix(r.get("Total Width")), num_prefix(r.get("Data Width"))
        loc = clean(r.get("Locator")) or r["_handle"]
        sm = re.search(r"(?:CPU|P|PROC|Processor)\s*_?(\d)", (r.get("Locator") or "") + " " + (r.get("Bank Locator") or ""), re.I)
        e = {"locator": loc, "bank": clean(r.get("Bank Locator")), "populated": pop,
             "socket_hint": int(sm.group(1)) if sm else None}
        if pop:
            e.update({
                "size_mb": size_mb(size), "type": clean(r.get("Type")), "type_detail": clean(r.get("Type Detail")),
                "form_factor": clean(r.get("Form Factor")), "technology": clean(r.get("Memory Technology")),
                "rated_mts": num_prefix(r.get("Speed")),
                "configured_mts": num_prefix(r.get("Configured Memory Speed") or r.get("Configured Clock Speed")),
                "voltage_configured": clean(r.get("Configured Voltage")), "voltage_min": clean(r.get("Minimum Voltage")),
                "voltage_max": clean(r.get("Maximum Voltage")), "manufacturer": clean(r.get("Manufacturer")),
                "part_number": clean(r.get("Part Number")), "serial_masked": mask(r.get("Serial Number")),
                "rank": clean(r.get("Rank")), "total_width_bits": tw, "data_width_bits": dw,
                "ecc": (tw > dw) if (tw and dw) else None})
        slots.append(e)
    source = "dmidecode"
    if not slots:
        # EDAC fallback (sizes/labels only)
        source = "edac"
        for d in sorted(x_glob("/sys/devices/system/edac/mc/mc*/dimm*"), key=nkey):
            sz = rdi(d + "/size")
            slots.append({"locator": rd(d + "/dimm_label") or os.path.basename(d), "bank": None,
                          "populated": bool(sz), "size_mb": sz, "type": rd(d + "/dimm_mem_type"),
                          "ecc": (rd(d + "/dimm_edac_mode") or "").upper() not in ("", "NONE", "UNKNOWN")})
        if not slots:
            source = NR
    ecc_arr = sorted({(a.get("Error Correction Type") or "").strip() for h, a in arrays.items() if h in sysarr} - {""})
    ecc_arr = ["none (non-ECC)" if e.lower() == "none" else e for e in ecc_arr]
    maxcap = [a.get("Maximum Capacity") for h, a in arrays.items() if h in sysarr]
    pop = [s for s in slots if s.get("populated")]
    return {"source": source, "total_mb": m.get("total_mb"), "installed_mb": sum((s.get("size_mb") or 0) for s in pop) or None,
            "slots_total": len(slots), "slots_populated": len(pop), "ecc": ", ".join(ecc_arr) or m.get("ecc") or NR,
            "max_capacity": ", ".join(x for x in maxcap if x) or m.get("max_capacity") or NR,
            "arrays": len(sysarr), "slots": slots}


GPU_VENDORS = {"0x10de": "nvidia", "0x1002": "amd", "0x8086": "intel"}
BASIC_DISPLAY = {"0x1a03", "0x102b", "0x1234", "0x1b36", "0x15ad"}
# AMD APU (integrated Radeon) code names as lspci prints them; same list as telemetry.sh.
APU_RE = re.compile(r"Renoir|Cezanne|Lucienne|Barcelo|Rembrandt|Phoenix|Hawk Point|Raphael|Granite Ridge|Strix|Krackan|"
                    r"Mendocino|Picasso|Raven|Van Gogh|Dali|Pollock|Stoney|Carrizo|Kaveri|Kabini|Mullins|Beema|Godavari|"
                    r"Cyan Skillfish|Vega Mobile|Radeon [678][0-9]0M|Radeon 8060S")


def gpu_integrated(slot, vendor, name):
    """True for an integrated GPU (shares RAM and power with the CPU): the Intel iGPU sits at
    0000:00:02.0; an AMD APU is recognised by its code name, else by a <= 1 GiB VRAM carve-out."""
    if vendor == "intel":
        return slot == "0000:00:02.0"
    if vendor == "amd":
        if APU_RE.search(name or ""):
            return True
        vt = rdi("/sys/bus/pci/devices/%s/mem_info_vram_total" % slot)
        return bool(vt and vt <= GIB)
    return False


def gpu_list(hw, pci_vm):
    """prep.sh's GPU list, completed from sysfs (display class 0x03) and re-checked
    against the LIVE driver binding: a card bound to vfio-pci or listed in a VM's
    hostpci line is never planned for testing, whatever hardware.json says."""
    gl = [dict(g) for g in hw.get("gpus", []) if g.get("slot")]
    known = {g["slot"] for g in gl}
    for d in sorted(x_glob("/sys/bus/pci/devices/*")):
        slot = os.path.basename(d)
        if not (rd(d + "/class") or "").startswith("0x03") or slot in known:
            continue
        v = rd(d + "/vendor") or ""
        drv = link_name(d + "/driver") if x_exists(d + "/driver") else "none"
        kind = GPU_VENDORS.get(v, "basic-display" if v in BASIC_DISPLAY else "other")
        gl.append({"slot": slot, "vendor": kind, "vendor_id": v, "device_id": rd(d + "/device"),
                   "name": lspci_name(slot) or "PCI %s:%s" % (v, rd(d + "/device")), "driver": drv,
                   "testable": "no", "reason": "found by the inventory only (not in prep's GPU list); not planned for testing"})
    for g in gl:
        d = "/sys/bus/pci/devices/%s" % g["slot"]
        live = link_name(d + "/driver") if x_exists(d + "/driver") else None
        if live:
            g["driver"] = live
        if live == "vfio-pci" and g.get("testable") != "no":
            g["testable"], g["reason"] = "no", "passed through to a VM (vfio-pci) - cannot be tested from the host"
    return gl


def collect_gpus(hw, pci_vm, ct_gpu, vm_state):
    out = []
    for g in gpu_list(hw, pci_vm):
        slot = g.get("slot")
        pi = pci_info(slot)
        d = "/sys/bus/pci/devices/%s" % slot
        nv = g.get("nvidia") or {}
        vram = nv.get("vram_mib") or g.get("vram_mib")
        pl = nv.get("power_limit_w")
        if pl is None and g.get("vendor") == "amd":
            for h in x_glob(d + "/hwmon/hwmon*"):
                v = rdi(h + "/power1_cap")
                if v:
                    pl = round(v / 1e6)
        drv = g.get("driver")
        drv_ver = (nv.get("driver") or rd("/sys/module/%s/version" % drv)) if (drv and drv != "none") else None
        if not drv_ver and drv in ("amdgpu", "i915", "xe", "nouveau"):
            drv_ver = "in-kernel (%s)" % (hw.get("host", {}).get("kernel") or "?")
        grp_members = []
        if pi["iommu_group"]:
            try:
                grp_members = sorted(x_listdir("/sys/kernel/iommu_groups/%s/devices" % pi["iommu_group"]))
            except Exception:
                grp_members = []
        vms = pci_vms(slot, pci_vm)
        shared = []
        if drv not in (None, "none", "vfio-pci"):
            if g.get("vendor") == "nvidia":
                for ct, idx in ct_gpu.get("nvidia", []):
                    if idx is None or nv.get("index") in idx:
                        shared.append(ct)
            elif g.get("vendor") in ("amd", "intel"):
                for ct, idx in ct_gpu.get("dri", []):
                    if idx is None or any(x_exists("%s/drm/%s%d" % (d, k, n)) for k, n in idx):
                        shared.append(ct)
        integ = g.get("integrated")
        if integ is None:
            integ = gpu_integrated(slot, g.get("vendor"), g.get("name"))
        oc = g.get("opencl") if isinstance(g.get("opencl"), dict) else None
        out.append({
            "slot": slot, "vendor": g.get("vendor"), "name": g.get("name"), "vendor_id": g.get("vendor_id"),
            "integrated": bool(integ), "render_node": g.get("render_node") or None, "opencl": oc,
            "device_id": g.get("device_id"), "subsystem": "%s:%s" % (pi["subsystem_vendor_id"], pi["subsystem_device_id"]),
            "driver": drv, "driver_version": drv_ver, "vbios": nv.get("vbios"),
            "vram_mib": vram if vram is not None else (NR if drv != "vfio-pci" else "not readable (vfio-pci)"),
            "memory_note": "shared system RAM (integrated GPU)" if integ else None,
            "pcie": pci_link(slot), "power_limit_w": pl, "power_default_w": nv.get("power_default_w"),
            "power_max_w": nv.get("power_max_w"),
            "iommu_group": pi["iommu_group"], "iommu_group_devices": grp_members,
            "vfio_bound": drv == "vfio-pci", "passthrough_vms": [vm_state(v) for v in vms],
            "shared_with_containers": ["container %s" % c for c in shared],
            "numa_node": pi["numa_node"], "testable": g.get("testable"), "reason": g.get("reason"),
            "opencl_icd": nv.get("opencl_icd"),
        })
    return out


SC_CLASSES = {"0x0100": "SCSI", "0x0101": "IDE", "0x0104": "RAID", "0x0105": "ATA", "0x0106": "SATA",
              "0x0107": "SAS", "0x0108": "NVMe", "0x0180": "other mass storage"}
RAID_DRIVERS = {"megaraid_sas", "hpsa", "smartpqi", "aacraid", "arcmsr", "cciss", "mpi3mr", "3w-9xxx", "3w-sas"}


def collect_controllers(pci_vm, vm_state):
    out = []
    for d in sorted(x_glob("/sys/bus/pci/devices/*")):
        cls = rd(d + "/class") or ""
        key = cls[:6]
        if key not in SC_CLASSES:
            continue
        slot = os.path.basename(d)
        pi = pci_info(slot)
        typ = SC_CLASSES[key]
        if key == "0x0106":
            typ = "SATA (AHCI)" if cls[6:8] == "01" else "SATA"
        if key == "0x0104" and pi["driver"] == "vmd":
            typ = "RAID (Intel VMD - NVMe remapping)"
        vms = pci_vms(slot, pci_vm)
        out.append({"slot": slot, "type": typ, "name": pi["name"] or "%s:%s" % (pi["vendor_id"], pi["device_id"]),
                    "vendor_id": pi["vendor_id"], "device_id": pi["device_id"], "driver": pi["driver"],
                    "hardware_raid": pi["driver"] in RAID_DRIVERS, "pcie": pci_link(slot),
                    "iommu_group": pi["iommu_group"], "vfio_bound": pi["driver"] == "vfio-pci",
                    "passthrough_vms": [vm_state(v) for v in vms], "disks": []})
    return out


def smart_json(dev, dtype=None):
    if not which("smartctl"):
        return None
    cmd = ["smartctl", "-j", "-a"]
    if dtype:
        cmd += ["-d", dtype]
    out = run(cmd + [dev], timeout=45)
    try:
        return json.loads(out)
    except Exception:
        return None


def smart_fields(sj):
    """Normalised SMART fields from smartctl -j output."""
    if not sj:
        return {}
    r = {}
    ss = sj.get("smart_status")
    if isinstance(ss, dict) and "passed" in ss:
        r["health"] = "PASSED" if ss["passed"] else "FAILED"
    r["power_on_hours"] = (sj.get("power_on_time") or {}).get("hours")
    r["temp_c"] = (sj.get("temperature") or {}).get("current")
    r["rotation_rpm"] = sj.get("rotation_rate")
    r["form_factor"] = (sj.get("form_factor") or {}).get("name")
    isp = sj.get("interface_speed") or {}
    r["link_current"] = (isp.get("current") or {}).get("string")
    r["link_max"] = (isp.get("max") or {}).get("string")
    r["sata_version"] = (sj.get("sata_version") or {}).get("string")
    r["protocol"] = (sj.get("device") or {}).get("protocol")
    r["trim"] = (sj.get("trim") or {}).get("supported")
    r["model"] = sj.get("model_name") or " ".join(x for x in (sj.get("scsi_vendor"), sj.get("scsi_product")) if x) or None
    r["family"] = sj.get("model_family")
    r["serial"] = sj.get("serial_number")
    r["firmware"] = sj.get("firmware_version") or sj.get("scsi_revision")
    r["capacity_bytes"] = (sj.get("user_capacity") or {}).get("bytes") or sj.get("nvme_total_capacity")
    nv = sj.get("nvme_smart_health_information_log")
    if nv:
        r["wear_pct_used"] = nv.get("percentage_used")
        r["available_spare_pct"] = nv.get("available_spare")
        r["media_errors"] = nv.get("media_errors")
        r["critical_warning"] = nv.get("critical_warning")
        r["unsafe_shutdowns"] = nv.get("unsafe_shutdowns")
        if nv.get("data_units_written") is not None:
            r["data_written_tb"] = round(nv["data_units_written"] * 512000 / 1e12, 2)
    attrs = {a.get("id"): a for a in ((sj.get("ata_smart_attributes") or {}).get("table") or [])}

    def raw(i):
        a = attrs.get(i)
        return (a.get("raw") or {}).get("value") if a else None
    for k, i in (("reallocated", 5), ("pending", 197), ("offline_uncorrectable", 198), ("crc_errors", 199)):
        v = raw(i)
        if v is not None:
            r[k] = v
    for i in (231, 233, 177, 202, 169):     # SSD life / wear indicators (normalised value = % left)
        a = attrs.get(i)
        if a and a.get("value") is not None and r.get("wear_pct_used") is None and r.get("rotation_rpm") in (0, None):
            v = a["value"]
            if 0 <= v <= 100:
                r["wear_pct_used"] = 100 - v
                r["wear_source"] = "ATA attribute %d %s (approx.)" % (i, a.get("name", ""))
    for i, f in ((241, "lbas_written"),):
        v = raw(i)
        if v is not None and r.get("data_written_tb") is None:
            r["data_written_tb"] = round(v * 512 / 1e12, 2)
    for p in ((sj.get("ata_device_statistics") or {}).get("pages") or []):
        for t in p.get("table") or []:
            if t.get("name") == "Percentage Used Endurance Indicator" and r.get("wear_pct_used") is None:
                r["wear_pct_used"] = t.get("value")
    if sj.get("scsi_grown_defect_list") is not None:
        r["grown_defects"] = sj.get("scsi_grown_defect_list")
    return {k: v for k, v in r.items() if v is not None}


def rotation_text(rpm, kind, sys_rot, raid_volume=False):
    """Human rotation string; sysfs 'rotational' wins over a SMART rpm of 0 (RAID volumes report none)."""
    if rpm:
        return "%d rpm" % rpm
    if kind == "hdd" or sys_rot == "1":
        return "rotational (RAID volume of HDDs)" if raid_volume else "rotational (rpm not reported)"
    if rpm == 0 or kind in ("nvme", "ssd") or sys_rot == "0":
        return "solid state"
    return NR


RAIDVOL_RE = re.compile(r"PERC|MegaRAID|\bMR\d|RAID|LOGICAL\s*VOLUME|Logical|Virtual\s*Disk|ServeRAID|Smart\s*Array|\bLD\b|ARC-\d", re.I)


def collect_disks(hw, controllers, disk_vm, vm_state, scfg, pci_vm=None):
    hd = {d["name"]: d for d in hw.get("disks", [])}
    # lsblk tree (one call, shared with disks_of)
    tree, mpkey, _ = lsblk_tree()
    bynode = {n.get("name"): n for n in tree}

    def b(v):
        return v in (True, 1, "1", "true")

    # LVM
    pv_vg = {}
    for line in run(["pvs", "--noheadings", "--separator", "|", "-o", "pv_name,vg_name"]).splitlines():
        f = [x.strip() for x in line.split("|")]
        if len(f) >= 2 and f[0]:
            for d in disks_of(f[0]):
                if f[1]:
                    pv_vg.setdefault(d, set()).add(f[1])
    vg_lvs, ceph_osd_vg = {}, {}
    for line in run(["lvs", "--noheadings", "--separator", "|", "-o", "vg_name,lv_name,lv_attr,lv_tags"]).splitlines():
        f = [x.strip() for x in line.split("|")]
        if len(f) < 3:
            continue
        vg_lvs.setdefault(f[0], []).append((f[1], f[2]))
        m = re.search(r"ceph\.osd_id=(\d+)", f[3] if len(f) > 3 else "")
        if m:
            ceph_osd_vg.setdefault(f[0], set()).add(m.group(1))
    # ZFS
    zfs_member = {}
    pool, section = None, "data"
    for line in run(["zpool", "status", "-LP"]).splitlines():
        m = re.match(r"^\s*pool:\s*(\S+)", line)
        if m:
            pool, section = m.group(1), "data"
            continue
        s = line.strip()
        if s in ("logs", "cache", "spares", "special", "dedup"):
            section = s
            continue
        m = re.match(r"^\s+(/dev/\S+)", line)
        if m and pool:
            for d in disks_of(m.group(1)):
                zfs_member.setdefault(d, []).append((pool, section))
    # mdraid
    md_member = {}
    try:
        with x_open("/proc/mdstat") as f:
            for line in f:
                m = re.match(r"^(md\S+)\s*:\s*\S+\s+(?:\(\S+\)\s+)?(\S+)\s+(.*)$", line)
                if m:
                    for mem in re.findall(r"(\S+?)\[\d+\]", m.group(3)):
                        for d in disks_of("/dev/" + mem):
                            md_member.setdefault(d, []).append("%s (%s)" % (m.group(1), m.group(2)))
    except Exception:
        pass
    swaps = set()
    try:
        with x_open("/proc/swaps") as f:
            for line in list(f)[1:]:
                for d in disks_of(line.split()[0]):
                    swaps.add(d)
    except Exception:
        pass
    vg_store, pool_store = {}, {}
    for s in scfg:
        if s["type"] in ("lvmthin", "lvm") and s.get("vgname"):
            vg_store.setdefault(s["vgname"], []).append("%s (%s)" % (s["name"], s["type"]))
        if s["type"] == "zfspool" and s.get("pool"):
            pool_store.setdefault(s["pool"].split("/")[0], []).append("%s (zfspool)" % s["name"])
    fss = hw.get("filesystems", [])

    def walk(n, acc):
        acc.append(n)
        for c in n.get("children") or []:
            walk(c, acc)
        return acc

    disks = []
    names = [n for n in hd] or [n.get("name") for n in tree if n.get("type") == "disk"]
    for name in sorted(names, key=nkey):
        h = hd.get(name, {})
        node = bynode.get(name, {})
        nodes = walk(node, []) if node else []
        sysb = "/sys/block/%s" % name
        ctrl = pci_of_path(sysb)
        via_usb = "/usb" in x_realpath(sysb)
        sj = smart_json("/dev/" + name)
        sm = smart_fields(sj)
        hs = h.get("smart") or {}
        size = h.get("size_bytes") or (int(node["size"]) if node.get("size") else None)
        kind = h.get("kind") or ("nvme" if name.startswith("nvme") else ("hdd" if b(node.get("rota")) else "ssd"))
        model = (h.get("model") or node.get("model") or sm.get("model") or "").strip() or NR
        vendor = (node.get("vendor") or "").strip()
        tran = h.get("transport") or node.get("tran") or ("usb" if via_usb else None)
        cinfo = next((c for c in controllers if c["slot"] == ctrl), None)
        raid_volume = bool(cinfo and cinfo["hardware_raid"] and RAIDVOL_RE.search(vendor + " " + model))
        rpm = sm.get("rotation_rpm")
        # interface / link
        link = None
        if kind == "nvme":
            pl = pci_link(ctrl) if ctrl else None
            if pl:
                link = "%s (max %s)" % (pl.get("current") or "?", pl.get("max") or "?")
        elif sm.get("link_current") or sm.get("sata_version"):
            link = "%s, %s (max %s)" % (sm.get("sata_version") or (tran or "").upper(), sm.get("link_current") or "?",
                                         sm.get("link_max") or "?")
        # usage
        usage = []
        mounts = []
        for n in nodes:
            mps = n.get(mpkey)
            if isinstance(mps, str):
                mps = [mps]
            for mp in mps or []:
                if mp:
                    mounts.append({"mountpoint": mp, "fstype": n.get("fstype"), "device": n.get("name")})
        if h.get("root_disk"):
            usage.append("root disk (Proxmox OS)")
        for vg in sorted(pv_vg.get(name, [])):
            lvs = vg_lvs.get(vg, [])
            thin = [l for l, a in lvs if a.startswith("t")]
            st = vg_store.get(vg, [])
            if vg in ceph_osd_vg:
                usage.append("Ceph OSD %s (LVM VG %s)" % (", ".join(sorted(ceph_osd_vg[vg], key=nkey)), vg))
            else:
                usage.append("LVM PV of VG %s (%d LVs%s%s)" % (vg, len(lvs), ", thin pool " + ", ".join(thin) if thin else "",
                                                               "; PVE storage " + ", ".join(st) if st else ""))
        if any(n.get("fstype") == "ceph_bluestore" for n in nodes) and not any(u.startswith("Ceph OSD") for u in usage):
            usage.append("Ceph OSD (bluestore)")
        for p, sec in zfs_member.get(name, []):
            st = pool_store.get(p, [])
            usage.append("ZFS pool %s member%s%s" % (p, "" if sec == "data" else " (%s)" % sec,
                                                    "; PVE storage " + ", ".join(st) if st else ""))
        for md in md_member.get(name, []):
            usage.append("mdraid %s member" % md)
        if name in swaps:
            usage.append("swap")
        disk_fs = []
        for fs in fss:
            if name in (fs.get("disks") or []):
                disk_fs.append(fs)
                usage.append("filesystem %s (%s) mounted at %s, %s free of %s%s%s" % (
                    fs.get("source"), fs.get("fstype"), fs.get("mountpoint"), human_bytes(fs.get("avail_bytes")),
                    human_bytes(fs.get("size_bytes")),
                    "" if len(fs.get("disks") or []) <= 1 else ", spans " + "+".join(fs["disks"]),
                    "; PVE storage " + ", ".join(fs.get("pve_storages") or []) if fs.get("pve_storages") else ""))
        other_mounts = [m for m in mounts if not any(m["mountpoint"] == fs.get("mountpoint") for fs in disk_fs)]
        for m in other_mounts:
            if m["mountpoint"] != "[SWAP]":
                usage.append("mounted %s (%s)" % (m["mountpoint"], m["fstype"] or "?"))
        vms = list(disk_vm.get(name, []))
        if ctrl and pci_vm:
            # the whole controller (NVMe drive, HBA, SATA controller) is a hostpci device of a guest
            vms += [x for x in pci_vms(ctrl, pci_vm) if x not in vms]
        for v in vms:
            usage.append("passed through to %s" % vm_state(v))
        if raid_volume:
            usage.insert(0, "hardware RAID volume on %s" % (cinfo["name"]))
        if not usage:
            idle = ["%s (%s)" % (n.get("name"), n.get("fstype")) for n in nodes[1:] if n.get("fstype")]
            if idle:
                usage.append("not mounted: " + ", ".join(idle))
            elif len(nodes) > 1:
                usage.append("partitioned, no filesystem or pool membership found (%s)" % ", ".join(n.get("name") for n in nodes[1:]))
            else:
                usage.append("unused (no partitions, filesystems or pool membership found)")
        e = {
            "name": name, "device": "/dev/" + name, "kind": kind, "raid_volume": raid_volume,
            "model": model, "vendor": vendor or None, "family": sm.get("family"),
            "size_bytes": size, "size_human": human_bytes(size),
            "serial_masked": mask(h.get("serial") or node.get("serial") or sm.get("serial")),
            "firmware": h.get("firmware") or node.get("rev") or sm.get("firmware"),
            "transport": tran, "interface": link, "form_factor": sm.get("form_factor"),
            "rotation": rotation_text(rpm, kind, rd(sysb + "/queue/rotational"), raid_volume),
            "removable": b(node.get("rm")) or b(node.get("hotplug")),
            "sector_bytes": {"logical": node.get("log-sec"), "physical": node.get("phy-sec")},
            "trim": sm.get("trim"),
            "controller": ctrl, "controller_name": (cinfo or {}).get("name") or (lspci_name(ctrl) if ctrl else None),
            "via_usb": via_usb,
            "smart": {
                "health": sm.get("health") or hs.get("health") or NR,
                "power_on_hours": sm.get("power_on_hours", hs.get("power_on_hours")),
                "temp_c": sm.get("temp_c", hs.get("temp_c")),
                "wear_pct_used": sm.get("wear_pct_used", hs.get("percent_used")),
                "wear_source": sm.get("wear_source"),
                "available_spare_pct": sm.get("available_spare_pct", hs.get("available_spare_pct")),
                "media_errors": sm.get("media_errors", hs.get("media_errors")),
                "critical_warning": sm.get("critical_warning", hs.get("critical_warning")),
                "reallocated": sm.get("reallocated", hs.get("reallocated")),
                "pending": sm.get("pending", hs.get("pending")),
                "offline_uncorrectable": sm.get("offline_uncorrectable", hs.get("offline_uncorrectable")),
                "crc_errors": sm.get("crc_errors", hs.get("crc_errors")),
                "data_written_tb": sm.get("data_written_tb", hs.get("data_written_tb")),
                "grown_defects": sm.get("grown_defects"),
                "source": "smartctl -j" if sj else ("smartctl text" if hs.get("health") not in (None, "n/a") else NR),
            },
            "usage": usage,
            "filesystems": [{"mountpoint": fs.get("mountpoint"), "fstype": fs.get("fstype"), "avail_bytes": fs.get("avail_bytes"),
                             "size_bytes": fs.get("size_bytes"), "disks": fs.get("disks"), "pve_storages": fs.get("pve_storages")}
                            for fs in disk_fs],
            "lvm_vgs": sorted(pv_vg.get(name, [])), "zfs_pools": sorted({p for p, _ in zfs_member.get(name, [])}),
            "ceph_osd": any("Ceph OSD" in u for u in usage), "md_arrays": md_member.get(name, []),
            "passthrough": [vm_state(v) for v in vms],
            "passthrough_running": any((not v.startswith("ct")) and "running" in vm_state(v) for v in vms) or
                                   any(v.startswith("ct") for v in vms),
        }
        if cinfo is not None:
            cinfo["disks"].append(name)
        disks.append(e)
    # disks hidden behind hardware RAID controllers (not block devices): SMART only
    hidden = []
    for line in run(["smartctl", "--scan-open"]).splitlines():
        m = re.match(r"^(\S+)\s+-d\s+(\S+)", line)
        if not m:
            continue
        dev, dt = m.group(1), m.group(2)
        if not re.search(r"(megaraid|cciss|aacraid|areca|3ware|hpt|sssraid),", dt):
            continue
        sj = smart_json(dev, dt)
        sm = smart_fields(sj)
        rpm = sm.get("rotation_rpm")
        ctrl_drv = {"megaraid": "megaraid_sas", "cciss": "hpsa", "aacraid": "aacraid", "areca": "arcmsr",
                    "3ware": "3w-9xxx"}.get(re.sub(r"^sat\+", "", dt).split(",")[0])
        ctrl = [c for c in controllers if c["driver"] in (ctrl_drv, "smartpqi" if ctrl_drv == "hpsa" else ctrl_drv)]
        vols = [d["name"] for d in disks if d["raid_volume"] and (not ctrl or d["controller"] in [c["slot"] for c in ctrl])]
        hidden.append({
            "smart_device": dev, "smart_type": dt, "model": sm.get("model") or NR, "family": sm.get("family"),
            "kind": "hdd" if rpm else ("ssd" if rpm == 0 else NR),
            "size_bytes": sm.get("capacity_bytes"), "size_human": human_bytes(sm.get("capacity_bytes")),
            "serial_masked": mask(sm.get("serial")), "firmware": sm.get("firmware"),
            "rotation": ("%d rpm" % rpm) if rpm else ("solid state" if rpm == 0 else NR),
            "interface": sm.get("link_current") or sm.get("protocol"),
            "controller": ctrl[0]["slot"] if ctrl else None, "controller_name": ctrl[0]["name"] if ctrl else None,
            "volumes_on_controller": vols,
            "smart": {"health": sm.get("health", NR), "power_on_hours": sm.get("power_on_hours"),
                      "temp_c": sm.get("temp_c"), "wear_pct_used": sm.get("wear_pct_used"),
                      "reallocated": sm.get("reallocated"), "pending": sm.get("pending"),
                      "grown_defects": sm.get("grown_defects")},
        })
    return disks, hidden


def collect_nics(pci_vm, vm_state):
    out, seen = [], set()
    netdev_by_pci = {}
    for n in sorted(x_glob("/sys/class/net/*"), key=nkey):
        if x_exists(n + "/device"):
            p = pci_of_path(n + "/device")
            netdev_by_pci.setdefault(p, []).append(os.path.basename(n))

    def nic_entry(ifn, slot):
        base = "/sys/class/net/%s/" % ifn
        oper = rd(base + "operstate")
        speed = rdi(base + "speed") if oper == "up" else None
        et = run(["ethtool", ifn], timeout=10)
        modes = [int(x) for x in re.findall(r"(\d+)base", " ".join(re.findall(r"Supported link modes:(.*?)(?:Supported pause|Supports auto|Advertised)", et, re.S)))]
        ei = run(["ethtool", "-i", ifn], timeout=10)
        fw = re.search(r"^firmware-version:\s*(.*)$", ei, re.M)
        return {"interface": ifn, "mac_masked": mask_mac(rd(base + "address")), "state": oper,
                "link_speed_mbps": speed if speed and speed > 0 else None,
                "max_speed_mbps": max(modes) if modes else None,
                "duplex": rd(base + "duplex") if oper == "up" else None, "mtu": rdi(base + "mtu"),
                "bridge": link_name(base + "master") if x_exists(base + "master") else None,
                "wireless": x_isdir(base + "wireless") or x_exists(base + "phy80211"),
                "firmware": (fw.group(1).strip() or None) if fw else None}

    for d in sorted(x_glob("/sys/bus/pci/devices/*")):
        cls = rd(d + "/class") or ""
        if not cls.startswith("0x02"):
            continue
        slot = os.path.basename(d)
        pi = pci_info(slot)
        ifs = netdev_by_pci.get(slot, [])
        vms = pci_vms(slot, pci_vm)
        base = {"slot": slot, "model": pi["name"] or "%s:%s" % (pi["vendor_id"], pi["device_id"]),
                "driver": pi["driver"], "pcie": pci_link(slot), "iommu_group": pi["iommu_group"],
                "vfio_bound": pi["driver"] == "vfio-pci", "passthrough_vms": [vm_state(v) for v in vms]}
        if not ifs:
            out.append(dict(base, interface=None, state="no host interface" if pi["driver"] else "no driver bound"))
        for ifn in ifs:
            seen.add(ifn)
            out.append(dict(base, **nic_entry(ifn, slot)))
    for n in sorted(x_glob("/sys/class/net/*"), key=nkey):
        ifn = os.path.basename(n)
        if ifn in seen or not x_exists(n + "/device"):
            continue
        if "/usb" not in x_realpath(n + "/device"):
            continue
        drv = link_name(n + "/device/driver") if x_exists(n + "/device/driver") else None
        out.append(dict({"slot": None, "model": "USB network adapter", "driver": drv, "pcie": None,
                         "iommu_group": None, "vfio_bound": False, "passthrough_vms": []}, **nic_entry(ifn, None)))
    return out


def collect_sensors():
    res = {"source": NR, "fans": [], "psus": [], "temperatures": [], "voltages": [], "power": []}
    has_ipmi_dev = any(x_exists(p) for p in ("/dev/ipmi0", "/dev/ipmi/0", "/dev/ipmidev/0"))
    if which("ipmitool") and has_ipmi_dev:
        out = run(["ipmitool", "sdr", "elist", "full"], timeout=60) or run(["ipmitool", "sdr"], timeout=60)
        for line in out.splitlines():
            f = [x.strip() for x in line.split("|")]
            if len(f) < 3:
                continue
            name, status = f[0], f[2]
            reading = f[4] if len(f) >= 5 else f[1]
            item = {"name": name, "reading": reading, "status": status}
            if "RPM" in reading:
                res["fans"].append(item)
            elif "degrees C" in reading:
                res["temperatures"].append(item)
            elif "Volts" in reading:
                res["voltages"].append(item)
            elif "Watts" in reading or "Amps" in reading:
                res["power"].append(item)
            if re.search(r"\bPS\d|PSU|Power Supply|PWR", name, re.I):
                res["psus"].append(item)
        if out:
            res["source"] = "ipmitool sdr"
            return res
    if which("sensors"):
        try:
            sj = json.loads(run(["sensors", "-j"], timeout=20) or "{}")
        except Exception:
            sj = {}
        skip = re.compile(r"^(coretemp|k10temp|zenpower|nvme|amdgpu|nouveau|drivetemp|iwlwifi|pch_|acpi_fan)", re.I)
        for chip, feats in sj.items():
            if not isinstance(feats, dict):
                continue
            for fname, vals in feats.items():
                if not isinstance(vals, dict):
                    continue
                for k, v in vals.items():
                    if re.match(r"^fan\d+_input$", k) and isinstance(v, (int, float)) and v > 0:
                        res["fans"].append({"name": "%s %s" % (chip.split("-")[0], fname), "reading": "%d RPM" % v,
                                            "status": "ok"})
                    elif re.match(r"^temp\d+_input$", k) and isinstance(v, (int, float)) and not skip.match(chip) \
                            and -30 < v < 150:
                        res["temperatures"].append({"name": "%s %s" % (chip.split("-")[0], fname),
                                                    "reading": "%.1f C" % v, "status": "ok"})
        res["source"] = "lm-sensors" if (res["fans"] or res["temperatures"]) else NR
    if res["source"] == NR:
        # No IPMI, no lm-sensors (or it found nothing): read the kernel's hwmon sysfs directly.
        for h in sorted(x_glob("/sys/class/hwmon/hwmon*"), key=nkey):
            chip = rd(h + "/name") or os.path.basename(h)
            for f in sorted(x_glob(h + "/*_input"), key=nkey):
                m = re.match(r"^(fan|temp|in|power|curr)(\d+)_input$", os.path.basename(f))
                if not m:
                    continue
                val = rdi(f)
                if val is None:
                    continue
                kind, idx = m.group(1), m.group(2)
                label = rd("%s/%s%s_label" % (h, kind, idx)) or "%s%s" % (kind, idx)
                name = "%s %s" % (chip, label)
                if kind == "fan":
                    if val > 0:
                        res["fans"].append({"name": name, "reading": "%d RPM" % val, "status": "ok"})
                elif kind == "temp":
                    c = val / 1000.0
                    if -30 < c < 150:
                        res["temperatures"].append({"name": name, "reading": "%.1f C" % c, "status": "ok"})
                elif kind == "in":
                    res["voltages"].append({"name": name, "reading": "%.3f V" % (val / 1000.0), "status": "ok"})
                elif kind == "power":
                    res["power"].append({"name": name, "reading": "%.1f W" % (val / 1e6), "status": "ok"})
        if res["fans"] or res["temperatures"] or res["voltages"] or res["power"]:
            res["source"] = "kernel hwmon (sysfs)"
    if not res["fans"]:
        res["note"] = ("no fan speeds exposed. On desktop/workstation boards fan readings usually need the board's "
                       "Super-I/O driver (e.g. nct6775 or it87 kernel module), which this skill does not load; "
                       "servers report fans through IPMI (ipmitool) when a BMC is present")
    return res


# ----------------------------------------------------------------------------- plan
def build_plan(inv, hw, D, assumed, mode, out_dir, warnings, packages):
    units, inv_only = [], []
    DIR = out_dir

    def add(u):
        u["seq"] = len([x for x in units if x["status"] == "test"]) + 1 if u["status"] == "test" else None
        units.append(u)

    gc = hw.get("cpu", {})
    sk = inv["cpu"]["sockets"]
    label = "%s%s" % ("%d x " % len(sk) if len(sk) > 1 else "", gc.get("model") or (sk[0]["model"] if sk else "CPU"))
    add({"id": "cpu", "part": "cpu", "status": "test", "method_id": "cpu_stress",
         "method": "all cores and sockets at 100% together (stress-ng), then sysbench + 7-Zip benchmarks",
         "label": "CPU: %s (%s cores / %s threads)" % (label, gc.get("cores") or "?", gc.get("threads") or "?"),
         "items": ["socket %s" % s["socket"] for s in sk],
         "telemetry": ["cpu (summed power, hottest socket)"] + (["sockets (per-socket power + temperature)"] if len(sk) > 1 else []),
         "script": "cpu.sh", "out_dir": "01-cpu",
         "command": "bash cpu.sh --no-install --duration %d --out %s/01-cpu" % (D, DIR),
         "est_s": D + 150, "needs_confirmation": False, "warnings": [], "reason": None})
    mem = inv["memory"]
    add({"id": "ram", "part": "ram", "status": "test", "method_id": "ram_stress",
         "method": "stress-ng verify + memtester on up to ~40% of free RAM, then STREAM/latency benchmarks",
         "label": "RAM: %s MB in %s/%s slots (%s)" % (hw.get("memory", {}).get("total_mb") or "?",
                                                   mem["slots_populated"], mem["slots_total"], mem["ecc"]),
         "items": [s["locator"] for s in mem["slots"] if s.get("populated")],
         "script": "ram.sh", "out_dir": "02-ram", "telemetry": ["cpu", "mem"],
         "command": "bash ram.sh --no-install --duration %d --out %s/02-ram" % (D, DIR),
         "est_s": D + min(max(D, 30), 300) + 195, "needs_confirmation": False, "warnings": [], "reason": None})
    tg = [g for g in inv["gpus"] if g["testable"] in ("yes", "limited")]
    gi = 0
    for g in inv["gpus"]:
        lab = "GPU %s: %s [%s]" % (g["slot"], g["name"], g["driver"])
        if g["testable"] in ("yes", "limited"):
            gi += 1
            od = "03-gpu" if len(tg) == 1 else "03-gpu-%d" % gi
            w = []
            if g["passthrough_vms"]:
                w.append("also configured for passthrough to %s - do not start that VM during the GPU test" % ", ".join(g["passthrough_vms"]))
            if g["shared_with_containers"]:
                w.append("shared with %s - their GPU work competes with the test" % ", ".join(g["shared_with_containers"]))
            full = g["testable"] == "yes"
            oc = g.get("opencl") or {}
            rt = oc.get("runtime") or None
            if g.get("integrated"):
                w.append("integrated GPU: shares RAM bandwidth and power with the CPU; its power reading is %s" % (
                    "the CPU package's RAPL 'uncore' share (if the CPU exposes it)" if g["vendor"] == "intel" else "the whole APU package (CPU + GPU)"))
            if oc.get("note"):
                w.append(oc["note"])
            if full:
                meth = "OpenCL compute stress (hashcat) + benchmarks (hashcat -b, clpeak)"
                if g["vendor"] in ("amd", "intel") and rt:
                    meth += " via %s" % rt
            else:
                meth = "telemetry; OpenCL stress/benchmarks only if a runtime works (limited)"
            add({"id": "gpu-%s" % g["slot"], "part": "gpu", "status": "test",
                 "method_id": "gpu_compute" if full else "gpu_limited",
                 "method": meth,
                 "label": lab, "pci": g["slot"], "vendor": g["vendor"], "script": "gpu.sh", "out_dir": od,
                 "integrated": bool(g.get("integrated")), "opencl_runtime": rt,
                 "opencl_state": oc.get("state"), "opencl_packages": oc.get("packages") or [],
                 "telemetry": ["gpu"],
                 "command": "bash gpu.sh --duration %d --gpu %s --out %s/%s" % (D, g["slot"], DIR, od),
                 "est_s": D + (240 if full else 90), "needs_confirmation": False, "warnings": w, "reason": g["reason"] if not full else None})
        else:
            add({"id": "gpu-%s" % g["slot"], "part": "gpu", "status": "skip", "method_id": "skip", "method": "skip",
                 "label": lab, "pci": g["slot"], "vendor": g["vendor"], "est_s": 0, "warnings": [],
                 "needs_confirmation": False,
                 "reason": (g["reason"] or "not testable") + ((" (VM: %s)" % ", ".join(g["passthrough_vms"])) if g["passthrough_vms"] else "")})
    # disks
    CAP = {"nvme": 8 * GIB, "ssd": 8 * GIB, "hdd": 4 * GIB}
    PEXTRA = {"nvme": 35, "ssd": 70, "hdd": 90}
    disk_units = []
    root_mount = "/"
    vz_ok = x_isdir("/var/lib/vz") and mount_of("/var/lib/vz") == "/"
    for d in inv["storage"]["disks"]:
        prof = d["kind"] if d["kind"] in CAP else ("hdd" if "rpm" in (d["rotation"] or "") else "ssd")
        if d["raid_volume"]:
            rot = rd("/sys/block/%s/queue/rotational" % d["name"])
            prof = "hdd" if rot == "1" else ("ssd" if rot == "0" else prof)
        cls = "nvme" if prof == "nvme" else prof
        lab = "%s %s: %s %s%s" % ({"nvme": "NVMe", "ssd": "SSD", "hdd": "HDD"}[prof], d["name"], d["model"],
                                   d["size_human"], " (hardware RAID volume)" if d["raid_volume"] else "")
        u = {"id": "disk-%s" % d["name"], "part": "ssd" if prof in ("nvme", "ssd") else "hdd", "class": cls,
             "label": lab, "device": d["device"], "dev": d["name"], "profile": prof, "warnings": [],
             "needs_confirmation": False, "reason": None, "path": None, "test_file_gib": None}
        cap = CAP[prof]
        sm = d["smart"]
        if str(sm.get("health", "")).startswith("FAILED"):
            u["needs_confirmation"] = True
            u["warnings"].append("SMART health FAILED - load can push a dying disk over the edge; back up and ask first")
        for k in ("media_errors", "reallocated", "pending", "offline_uncorrectable"):
            v = sm.get(k)
            if isinstance(v, int) and v > 0:
                u["warnings"].append("SMART %s = %d" % (k, v))
        skip = None
        if d["kind"] == "virtual":
            skip = "virtual disk (this host is itself a VM) - no physical drive to test"
        elif not d["size_bytes"]:
            skip = "no medium / zero size"
        elif (d["removable"] or d["via_usb"] or d["transport"] == "usb") and d["size_bytes"] < 8e9:
            skip = "removable/USB device under 8 GB (boot stick or card reader)"
        elif d["passthrough_running"]:
            skip = "passed through to %s - test it from inside the guest" % ", ".join(d["passthrough"])
        if skip:
            u.update(status="skip", method_id="skip", method="skip", reason=skip, est_s=0)
            disk_units.append(u)
            continue
        if d["via_usb"] or d["transport"] == "usb":
            u["needs_confirmation"] = True
            u["warnings"].append("USB-attached: results are limited by the USB bridge; ask the user before testing")
        if d["passthrough"]:
            u["needs_confirmation"] = True
            u["warnings"].append("configured as a raw disk for %s - read-only test only; ask the user, and do not start that guest meanwhile" % ", ".join(d["passthrough"]))
        # write+read candidates: writable fs living on THIS disk only
        cands = []
        if not d["passthrough"]:
            for fs in d["filesystems"]:
                if (fs.get("disks") or []) != [d["name"]]:
                    continue
                mp = fs.get("mountpoint")
                if not mp or not x_writable(mp):
                    continue
                av = fs.get("avail_bytes") or 0
                if av >= 2 * cap:
                    cands.append(fs)
        if cands:
            cands.sort(key=lambda f: (0 if f["mountpoint"] == root_mount and vz_ok else 1, -(f.get("avail_bytes") or 0),
                                      len(f["mountpoint"])))
            fs = cands[0]
            path = "/var/lib/vz" if (fs["mountpoint"] == root_mount and vz_ok) else fs["mountpoint"]
            tf = min(cap, int((fs.get("avail_bytes") or 0) * 0.10))
            u.update(status="test", method_id="write_read", method="write+read (test file)", path=path,
                     filesystem=fs["fstype"], fs_avail_gib=gib(fs.get("avail_bytes")), test_file_gib=round(tf / GIB, 1),
                     est_s=D + PEXTRA[prof],
                     command="bash disk.sh --no-install --mode file --path %s --device %s --profile %s --duration %d --out %s/%s" %
                             (path, d["device"], prof, D, DIR, "%s-%s-%s" % ("04" if u["part"] == "ssd" else "05", u["part"], d["name"])))
        else:
            why = []
            if d["passthrough"]:
                why.append("raw disk of a stopped guest")
            if d["zfs_pools"]:
                why.append("ZFS member (%s)" % ", ".join(d["zfs_pools"]))
            if d["ceph_osd"]:
                why.append("Ceph OSD")
            if d["md_arrays"]:
                why.append("mdraid member")
            if d["lvm_vgs"] and not d["filesystems"]:
                why.append("LVM only (VG %s, no mounted filesystem)" % ", ".join(d["lvm_vgs"]))
            multi = [f for f in d["filesystems"] if len(f.get("disks") or []) > 1]
            if multi:
                why.append("its filesystem spans several disks (%s)" % ", ".join(f["mountpoint"] for f in multi))
            single = [f for f in d["filesystems"] if (f.get("disks") or []) == [d["name"]]]
            if single:
                why.append("less than %d GiB free on %s" % (2 * cap // GIB, ", ".join(f["mountpoint"] for f in single)))
            if not why:
                why.append("no mounted writable filesystem on this disk")
            u.update(status="test", method_id="read_only_raw", method="read-only raw (fio --readonly, whole disk)",
                     reason="; ".join(why), est_s=D + 30,
                     command="bash disk.sh --no-install --mode readonly --device %s --profile %s --duration %d --out %s/%s" %
                             (d["device"], prof, D, DIR, "%s-%s-%s" % ("04" if u["part"] == "ssd" else "05", u["part"], d["name"])))
        u["out_dir"] = "%s-%s-%s" % ("04" if u["part"] == "ssd" else "05", u["part"], d["name"])
        u["script"] = "disk.sh"
        disk_units.append(u)
    for h in inv["storage"]["raid_hidden_disks"]:
        prof = h["kind"] if h["kind"] in ("ssd", "hdd") else "hdd"
        vols = h["volumes_on_controller"]
        disk_units.append({
            "id": "raidmember-%s" % h["smart_type"].replace(",", "-"), "part": "ssd" if prof == "ssd" else "hdd",
            "class": prof, "profile": prof, "status": "skip", "method_id": "skip", "method": "skip",
            "label": "%s behind RAID (%s): %s %s" % (prof.upper(), h["smart_type"], h["model"], h["size_human"]),
            "device": None, "smart_type": h["smart_type"], "est_s": 0, "warnings": [], "needs_confirmation": False,
            "reason": ("member of a hardware RAID array - tested through the controller's volume(s) (%s); SMART read with smartctl -d %s"
                       % (", ".join(vols), h["smart_type"])) if vols else
                      ("behind a hardware RAID controller and not visible as a block device; SMART only (smartctl -d %s)" % h["smart_type"])})
    order = {"nvme": 0, "ssd": 1, "hdd": 2}
    disk_units.sort(key=lambda u: (order.get(u.get("class"), 3), nkey(u.get("dev") or u.get("label"))))
    for u in disk_units:
        add(u)
    # optional pool units: writable filesystems that span several disks
    seen = set()
    pi = 0
    for fs in hw.get("filesystems", []):
        ds = fs.get("disks") or []
        if len(ds) < 2 or fs.get("mountpoint") in seen:
            continue
        kinds = {next((d["kind"] for d in inv["storage"]["disks"] if d["name"] == x), "hdd") for x in ds}
        prof = "hdd" if "hdd" in kinds else ("ssd" if "ssd" in kinds else "nvme")
        pool = fs.get("source", "").split("/")[0] if fs.get("fstype") == "zfs" else fs.get("source")
        if any(o.get("pool") == pool for o in units):
            continue
        seen.add(fs.get("mountpoint"))
        if (fs.get("avail_bytes") or 0) < 2 * CAP[prof] or not x_writable(fs["mountpoint"]):
            continue
        pi += 1
        path = "/var/lib/vz" if (fs["mountpoint"] == "/" and vz_ok) else fs["mountpoint"]
        od = "06-pool-%d" % pi
        u = {"id": "pool-%d" % pi, "part": "pool", "class": "pool", "status": "test", "optional": True,
             "method_id": "write_read", "method": "write+read (test file) on the multi-disk filesystem",
             "label": "Pool %s (%s across %s)" % (pool, fs.get("fstype"), " + ".join(ds)), "pool": pool,
             "path": path, "profile": prof, "member_disks": ds, "script": "disk.sh", "out_dir": od,
             "test_file_gib": round(min(CAP[prof], (fs.get("avail_bytes") or 0) * 0.1) / GIB, 1),
             "command": "bash disk.sh --no-install --mode file --path %s --profile %s --duration %d --out %s/%s" % (path, prof, D, DIR, od),
             "est_s": D + PEXTRA[prof], "warnings": [], "needs_confirmation": False,
             "reason": "optional: members are tested one by one read-only; this adds the write path of the pool as a whole"}
        add(u)
    # inventory only
    for n in inv["nics"]:
        inv_only.append({"kind": "nic", "label": "%s %s" % (n.get("interface") or n.get("slot"), n.get("model")),
                         "note": "inventory only (not stress-tested)" + (" - passed through to %s" % ", ".join(n["passthrough_vms"]) if n["passthrough_vms"] else "")})
    for c in inv["storage"]["controllers"]:
        inv_only.append({"kind": "storage-controller", "label": "%s %s (%s)" % (c["slot"], c["name"], c["driver"] or "no driver"),
                         "note": "inventory only (exercised through its disks)" if c["disks"] else "inventory only (not stress-tested)"})
    inv_only.append({"kind": "board", "label": "Motherboard / BIOS / chassis", "note": "inventory only (not stress-tested)"})
    if inv["sensors"]["source"] != NR:
        inv_only.append({"kind": "sensors", "label": "Fans / PSU / board sensors (%s)" % inv["sensors"]["source"],
                         "note": "inventory only (read before/after; not stress-tested)"})

    def est_for(u, dur):
        if u["part"] == "ram":
            return dur + min(max(dur, 30), 300) + 195
        return u["est_s"] - D + dur

    def totals(dur):
        return sum(est_for(u, dur) for u in units if u["status"] == "test" and not u.get("optional"))
    over = {"prep_install_and_baseline_s": 180 if mode == "plan-only" else 0, "copy_verify_cleanup_s": 90, "report_s": 300}
    test_s = totals(D)
    opt_s = sum(u["est_s"] for u in units if u["status"] == "test" and u.get("optional"))
    total = test_s + sum(over.values())
    by_d = {str(x): totals(x) + sum(over.values()) for x in (30, 60, 300, 600)}
    tested = [u for u in units if u["status"] == "test"]
    return {
        "schema": 1, "generated": time.strftime("%Y-%m-%dT%H:%M:%S%z"), "mode": mode,
        "duration_s": D, "duration_assumed": assumed, "run_dir": DIR,
        "order": "CPU -> RAM -> each GPU -> each SSD (NVMe first) -> each HDD -> optional pools",
        "units": units,
        "inventory_only": inv_only,
        "counts": {"test_units": len([u for u in tested if not u.get("optional")]), "optional_units": len([u for u in tested if u.get("optional")]),
                   "skipped_units": len([u for u in units if u["status"] == "skip"]),
                   "gpus_tested": len([u for u in tested if u["part"] == "gpu"]),
                   "disks_write_read": len([u for u in tested if u["part"] in ("ssd", "hdd") and u["method_id"] == "write_read"]),
                   "disks_read_only": len([u for u in tested if u["method_id"] == "read_only_raw"]),
                   "needs_confirmation": len([u for u in units if u.get("needs_confirmation")])},
        "estimate": {"tests_s": test_s, "optional_s": opt_s, "overhead": over, "total_s": total,
                     "total_human": fmt_s(total), "total_with_optional_s": total + opt_s,
                     "by_duration_total_s": by_d,
                     "note": "rough: varies with the hardware, disk fill speed and benchmark convergence"},
        "packages_to_install": packages,
        "guests_running": [("%s %s" % ("VM" if g.get("type") == "vm" else "CT", g.get("id"))) for g in hw.get("guests", {}).get("running", [])],
        "warnings": warnings,
    }


# ----------------------------------------------------------------------------- markdown
def md_esc(s):
    return str(s if s is not None else NR).replace("|", "/").replace("\n", " ")


def v(x, unit=""):
    if x is None or x == "":
        return NR
    return "%s%s" % (x, unit)


def inventory_md(inv):
    L = []
    s, b, bi, p = inv["system"], inv["board"], inv["bios"], inv["platform"]
    L += ["# Hardware inventory", "",
          "Generated %s. Serial numbers and MAC addresses are masked to their last 4 characters." % inv["generated"], "",
          "## System", "", "| Item | Value |", "|---|---|",
          "| System | %s |" % (" ".join(x for x in (s["vendor"], s["product"], s["version"]) if x) or NR),
          "| Chassis | %s |" % v(s["chassis_type"]),
          "| System serial | %s |" % v(s["serial_masked"]),
          "| Motherboard | %s%s |" % (" ".join(x for x in (b["vendor"], b["model"]) if x) or NR,
                                       (", " + (b["version"] if b["version"].lower().startswith("rev") else "rev " + b["version"])) if b["version"] else ""),
          "| Board serial | %s |" % v(b["serial_masked"]),
          "| BIOS | %s %s, %s |" % (v(bi["vendor"]), v(bi["version"]), v(bi["date"])),
          "| Firmware | %s, Secure Boot %s |" % (bi["boot_mode"], bi["secure_boot"]),
          "| IOMMU | %s (%d groups) |" % ("active" if p["iommu_active"] else "off", p["iommu_groups"]),
          "| NUMA nodes | %s |" % p["numa_nodes"], ""]
    c = inv["cpu"]
    L += ["## CPU (%d socket%s populated%s)" % (c["sockets_populated"], "" if c["sockets_populated"] == 1 else "s",
                                                ", %d empty" % len(c["sockets_empty"]) if c["sockets_empty"] else ""), "",
          "| Socket | Model | Cores / threads | Base / max MHz | L1d / L1i / L2 / L3 | Microcode | Power limits (RAPL) | Temp now |",
          "|---|---|---|---|---|---|---|---|"]
    for k in c["sockets"]:
        ca = k["cache"]

        def cs(n):
            e = ca.get(n)
            if not e:
                return "?"
            t = e["total_kib"]
            return ("%g MiB" % (t / 1024.0)) if t >= 1024 else ("%d KiB" % t)
        hy = ""
        if k["hybrid"]:
            hy = " (%dP + %dE)" % (k["hybrid"]["p_cores"], k["hybrid"]["e_cores"])
        r = k["rapl"]
        rl = ("PL1 %s / PL2 %s" % (v(r["pl1_w"], " W"), v(r["pl2_w"], " W"))) if r else NR
        L.append("| %s%s | %s | %s / %s%s | %s / %s | %s / %s / %s / %s | %s | %s | %s |" % (
            k["socket"], (" (%s)" % k["designation"]) if k["designation"] else "", md_esc(k["model"]), k["cores"], k["threads"], hy,
            v(k["base_mhz"]), v(k["max_mhz"]), cs("L1d"), cs("L1i"), cs("L2"), cs("L3"), v(k["microcode"]), rl, v(k["temp_now_c"], " C")))
    for e in c["sockets_empty"]:
        L.append("| %s | empty socket | | | | | | |" % md_esc(e["designation"]))
    L += ["", "Virtualisation: %s. Scaling driver %s, governor %s, boost %s. Power telemetry: %s; temperature: %s." % (
        c["virtualization"], v(c["scaling_driver"]), v(c["governor"]), v(c["boost"]), v(c["power_telemetry"]), v(c["temp_telemetry"])), ""]
    m = inv["memory"]
    L += ["## Memory: %s MB usable, %d of %d slots populated" % (v(m["total_mb"]), m["slots_populated"], m["slots_total"]), "",
          "ECC: %s. Maximum capacity: %s. Source: %s." % (m["ecc"], m["max_capacity"], m["source"]), "",
          "| Slot | Size | Type | Rated / configured MT/s | Voltage | Manufacturer | Part number | Rank | ECC | Serial |",
          "|---|---|---|---|---|---|---|---|---|---|"]
    for d in m["slots"]:
        if not d.get("populated"):
            L.append("| %s | empty | | | | | | | | |" % md_esc(d["locator"] + (" / " + d["bank"] if d.get("bank") else "")))
            continue
        L.append("| %s | %s | %s %s | %s / %s | %s | %s | %s | %s | %s | %s |" % (
            md_esc(d["locator"] + (" / " + d["bank"] if d.get("bank") else "")),
            ("%d GB" % (d["size_mb"] // 1024)) if d.get("size_mb") and d["size_mb"] >= 1024 else v(d.get("size_mb"), " MB"),
            v(d.get("type")), d.get("form_factor") or "", v(d.get("rated_mts")), v(d.get("configured_mts")),
            v(d.get("voltage_configured")), v(d.get("manufacturer")), md_esc(d.get("part_number")), v(d.get("rank")),
            {True: "yes", False: "no"}.get(d.get("ecc"), NR), v(d.get("serial_masked"))))
    L += ["", "## GPUs (%d)" % len(inv["gpus"]), ""]
    if not inv["gpus"]:
        L.append("No display/3D-class PCI device found.")
    else:
        L += ["| PCI | Model | Type | Driver | VRAM | PCIe (current / max) | Power limit | IOMMU group | Passthrough / sharing | OpenCL runtime | Testable |",
              "|---|---|---|---|---|---|---|---|---|---|---|"]
        for g in inv["gpus"]:
            pc = g["pcie"] or {}
            share = ", ".join(g["passthrough_vms"] + g["shared_with_containers"]) or ("vfio-pci" if g["vfio_bound"] else "host only")
            oc = g.get("opencl") or {}
            ocl = ("%s (%s)" % (oc.get("runtime") or "none", oc.get("state"))) if oc else ("vendor OpenCL ICD" if g["vendor"] == "nvidia" and g.get("opencl_icd") else "-")
            vram = ("%s MiB" % g["vram_mib"]) if isinstance(g["vram_mib"], (int, float)) else g["vram_mib"]
            if g.get("integrated"):
                vram = "shared RAM" + ((" (%s MiB carve-out)" % g["vram_mib"]) if isinstance(g["vram_mib"], (int, float)) else "")
            L.append("| %s | %s | %s | %s | %s | %s / %s | %s | %s | %s | %s | %s |" % (
                g["slot"], md_esc(g["name"]), "integrated" if g.get("integrated") else "discrete",
                " ".join(x for x in (v(g["driver"]), g["driver_version"]) if x), vram,
                v(pc.get("current")), v(pc.get("max")), v(g["power_limit_w"], " W"), v(g["iommu_group"]), md_esc(share),
                md_esc(ocl), g["testable"] + ((" - " + md_esc(g["reason"])) if g["reason"] and g["testable"] != "yes" else "")))
    if inv["gpus"]:
        L += ["", "A GPU or NVMe drive at idle often shows a lower *current* PCIe generation than its maximum: it drops the link to save power and returns to full speed under load."]
    st = inv["storage"]
    L += ["", "## Storage controllers (%d)" % len(st["controllers"]), "",
          "| PCI | Type | Model | Driver | PCIe | Disks |", "|---|---|---|---|---|---|"]
    for c2 in st["controllers"]:
        pc = c2["pcie"] or {}
        L.append("| %s | %s | %s | %s%s | %s | %s |" % (c2["slot"], c2["type"], md_esc(c2["name"]), v(c2["driver"]),
                                                        " (passthrough %s)" % ", ".join(c2["passthrough_vms"]) if c2["passthrough_vms"] else "",
                                                        v(pc.get("current")), ", ".join(c2["disks"]) or "-"))
    L += ["", "## Storage devices (%d)" % len(st["disks"]), "",
          "| Disk | Kind | Model | Size | Interface | Firmware | Serial | SMART | Hours | Wear | Temp | Controller |",
          "|---|---|---|---|---|---|---|---|---|---|---|---|"]
    for d in st["disks"]:
        sm = d["smart"]
        L.append("| %s | %s%s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s |" % (
            d["name"], d["kind"], " (RAID volume)" if d["raid_volume"] else "", md_esc(d["model"]), d["size_human"],
            md_esc(d["interface"] or d["transport"] or NR), v(d["firmware"]), v(d["serial_masked"]), v(sm["health"]),
            v(sm["power_on_hours"]), ("n/a (HDD)" if d["kind"] == "hdd" and sm["wear_pct_used"] is None else v(sm["wear_pct_used"], "%")),
            v(sm["temp_c"], " C"),
            md_esc(d["controller_name"] or d["controller"] or NR)))
    L += ["", "### What each disk is used for", ""]
    for d in st["disks"]:
        L.append("- **%s** (%s, %s): %s" % (d["name"], d["rotation"], d["size_human"], "; ".join(d["usage"])))
    if st["raid_hidden_disks"]:
        L += ["", "### Physical disks behind hardware RAID (%d)" % len(st["raid_hidden_disks"]), "",
              "| smartctl device | Kind | Model | Size | Serial | SMART | Hours | Temp | Volumes on controller |",
              "|---|---|---|---|---|---|---|---|---|"]
        for h in st["raid_hidden_disks"]:
            L.append("| %s -d %s | %s | %s | %s | %s | %s | %s | %s | %s |" % (
                h["smart_device"], h["smart_type"], h["kind"], md_esc(h["model"]), h["size_human"], v(h["serial_masked"]),
                v(h["smart"]["health"]), v(h["smart"]["power_on_hours"]), v(h["smart"]["temp_c"], " C"),
                ", ".join(h["volumes_on_controller"]) or "-"))
    L += ["", "## Network interfaces (%d)" % len(inv["nics"]), "",
          "| Interface | Model | Driver | Link | Max | State | MAC | Bridge / use |", "|---|---|---|---|---|---|---|---|"]
    for n in inv["nics"]:
        L.append("| %s | %s | %s | %s | %s | %s | %s | %s |" % (
            v(n.get("interface")), md_esc(n.get("model")), v(n.get("driver")),
            ("%s Mb/s" % n["link_speed_mbps"]) if n.get("link_speed_mbps") else "-",
            ("%s Mb/s" % n["max_speed_mbps"]) if n.get("max_speed_mbps") else NR, v(n.get("state")), v(n.get("mac_masked")),
            ", ".join(([("bridge " + n["bridge"])] if n.get("bridge") else []) + (["wireless"] if n.get("wireless") else []) +
                      (["passthrough " + ", ".join(n["passthrough_vms"])] if n.get("passthrough_vms") else [])) or "-"))
    se = inv["sensors"]
    L += ["", "## Fans, PSU and board sensors", ""]
    if se["source"] == NR:
        L.append("Not reported (no IPMI/BMC readable, nothing from lm-sensors or the kernel's hwmon sysfs).")
    else:
        L.append("Source: %s." % se["source"])
        for k in ("psus", "fans", "temperatures", "power", "voltages"):
            if se[k]:
                L.append("")
                L.append("- **%s:** %s" % ({"psus": "PSUs"}.get(k, k.capitalize()), "; ".join("%s %s (%s)" % (i["name"], i["reading"], i["status"]) for i in se[k][:40])))
        if not se["psus"]:
            L += ["", "- **PSUs:** not reported"]
    if se.get("note"):
        L += ["", "Fans: %s." % se["note"]]
    L.append("")
    return "\n".join(L)


def plan_md(plan):
    L = ["# Test plan", "",
         "Per-part stress duration: **%d s**%s. Order: %s." % (plan["duration_s"], " (assumed - not chosen yet)" if plan["duration_assumed"] else "", plan["order"]),
         "", "| # | Part | What | Method | Path / device | Est. time | Notes |", "|---|---|---|---|---|---|---|"]
    for u in plan["units"]:
        if u["status"] != "test":
            continue
        where = u.get("path") or u.get("device") or u.get("pci") or "-"
        if u.get("method_id") == "write_read" and u.get("test_file_gib"):
            where += " (%s GiB test file)" % u["test_file_gib"]
        notes = "; ".join(([u["reason"]] if u.get("reason") else []) +
                          (["OpenCL: %s" % u["opencl_runtime"]] if u.get("opencl_runtime") and u.get("method_id") == "gpu_compute" else []) + u.get("warnings", []) +
                          (["**ask the user first**"] if u.get("needs_confirmation") else []))
        L.append("| %s | %s | %s | %s | %s | %s | %s |" % (
            ("opt" if u.get("optional") else u["seq"]), u["part"].upper(), md_esc(u["label"]), u["method"], md_esc(where),
            fmt_s(u["est_s"]), md_esc(notes) or "-"))
    sk = [u for u in plan["units"] if u["status"] == "skip"]
    if sk:
        L += ["", "## Skipped (%d)" % len(sk), ""]
        for u in sk:
            L.append("- %s: %s" % (u["label"], u["reason"]))
    L += ["", "## Inventory only (not stress-tested)", ""]
    for i in plan["inventory_only"]:
        L.append("- %s: %s" % (i["label"], i["note"]))
    e = plan["estimate"]
    o = e["overhead"]
    L += ["", "## Estimated time", "",
          "- Tests: %s" % fmt_s(e["tests_s"]),
          "- Prep (install + baseline): %s" % fmt_s(o["prep_install_and_baseline_s"]) if o["prep_install_and_baseline_s"] else "- Prep: done",
          "- Copy logs, verify, clean up: %s; report: %s" % (fmt_s(o["copy_verify_cleanup_s"]), fmt_s(o["report_s"])),
          "- **Total: %s**%s" % (e["total_human"], (" (+%s for the optional pool units)" % fmt_s(e["optional_s"])) if e["optional_s"] else ""),
          "- Total for other durations: " + ", ".join("%s s per part = %s" % (k, fmt_s(x)) for k, x in e["by_duration_total_s"].items()),
          ""]
    if plan["packages_to_install"]:
        L += ["## Packages to install (removed again at the end)", "", ", ".join(plan["packages_to_install"]), ""]
    if plan["guests_running"]:
        L += ["## Running guests (keep running; they compete for the hardware)", "", ", ".join(plan["guests_running"]), ""]
    if plan["warnings"]:
        L += ["## Warnings", ""] + ["- " + w for w in plan["warnings"]] + [""]
    return "\n".join(L)


# ----------------------------------------------------------------------------- main
def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", required=True)
    ap.add_argument("--duration", type=int, default=None)
    ap.add_argument("--mode", default="full", choices=["full", "plan-only"])
    ap.add_argument("--warnings-file")
    ap.add_argument("--packages-file")
    a = ap.parse_args()
    out = os.path.abspath(a.out)
    hwf = os.path.join(out, "hardware.json")
    try:
        with open(hwf) as f:
            hw = json.load(f)
    except Exception as ex:
        print("inventory.py: cannot read %s: %s" % (hwf, ex), file=sys.stderr)
        return 1
    FS_MOUNTS[:] = [f.get("mountpoint") for f in hw.get("filesystems", []) if f.get("mountpoint")]
    D = a.duration or hw.get("requested_duration_s") or 60
    assumed = not (a.duration or hw.get("requested_duration_s"))

    def lines(fn):
        try:
            with open(fn) as f:
                return [x.strip() for x in f if x.strip()]
        except Exception:
            return []
    warnings = lines(a.warnings_file) if a.warnings_file else []
    packages = lines(a.packages_file) if a.packages_file else []
    running_vms = {str(g.get("id")) for g in hw.get("guests", {}).get("running", []) if g.get("type") == "vm"}
    disk_vm, pci_vm, ct_gpu, vm_state = read_guest_configs(running_vms)
    scfg = storage_cfg()
    system, board, bios, platform = collect_system()
    cpu = collect_cpu(hw)
    memory = collect_memory(hw)
    gpus = collect_gpus(hw, pci_vm, ct_gpu, vm_state)
    controllers = collect_controllers(pci_vm, vm_state)
    disks, hidden = collect_disks(hw, controllers, disk_vm, vm_state, scfg, pci_vm)
    nics = collect_nics(pci_vm, vm_state)
    sensors = collect_sensors()
    host = hw.get("host", {})
    inv = {
        "schema": 1, "generated": time.strftime("%Y-%m-%dT%H:%M:%S%z"),
        "privacy": "report-safe: no hostname, no IPs, serials/MACs masked to last 4 characters, guests by ID only",
        "software": {"pve_version": host.get("pve_version"), "kernel": host.get("kernel"),
                     "debian_version": host.get("debian_version"), "virtualization": host.get("virtualization"),
                     "root_fs": host.get("root_fs")},
        "system": system, "board": board, "bios": bios, "platform": platform,
        "cpu": cpu, "memory": memory, "gpus": gpus,
        "storage": {"controllers": controllers, "disks": disks, "raid_hidden_disks": hidden,
                    "zfs": hw.get("zfs"), "pve_storage": [{"name": s.get("name"), "type": s.get("type")} for s in hw.get("pve_storage", [])]},
        "nics": nics, "sensors": sensors,
        "counts": {"cpu_sockets": cpu["sockets_populated"], "dimms": memory["slots_populated"], "dimm_slots": memory["slots_total"],
                   "gpus": len(gpus), "storage_controllers": len(controllers), "disks": len(disks),
                   "raid_hidden_disks": len(hidden), "nics": len(nics)},
    }
    plan = build_plan(inv, hw, D, assumed, a.mode, out, warnings, packages)
    for name, data in (("inventory.json", inv), ("plan.json", plan)):
        with open(os.path.join(out, name), "w") as f:
            json.dump(data, f, indent=1)
            f.write("\n")
    with open(os.path.join(out, "inventory.md"), "w") as f:
        f.write(inventory_md(inv))
    with open(os.path.join(out, "plan.md"), "w") as f:
        f.write(plan_md(plan))
    # extend hardware.json (keeps every existing key)
    hw["system"], hw["board"], hw["bios"], hw["platform"] = system, board, bios, platform
    hw.setdefault("cpu", {})["sockets_detail"] = cpu["sockets"]
    hw["cpu"]["sockets_empty"] = cpu["sockets_empty"]
    hw.setdefault("memory", {})["slots_detail"] = memory["slots"]
    hw["gpus_detail"] = gpus
    hw["storage_controllers"] = controllers
    hw["raid_hidden_disks"] = hidden
    hw["nics"] = nics
    hw["sensors_inventory"] = sensors
    by = {d["name"]: d for d in disks}
    pu = {u.get("dev"): u for u in plan["units"] if u.get("dev")}
    for d in hw.get("disks", []):
        e = by.get(d.get("name"))
        if e:
            d["usage"] = e["usage"]
            d["controller"] = e["controller"]
            d["interface"] = e["interface"]
            d["rotation"] = e["rotation"]
        u = pu.get(d.get("name"))
        if u:
            d["plan"] = {"status": u["status"], "method_id": u["method_id"], "path": u.get("path"), "reason": u.get("reason"),
                         "out_dir": u.get("out_dir")}
    hw["inventory_file"], hw["plan_file"] = "inventory.json", "plan.json"
    tmp = hwf + ".tmp"
    with open(tmp, "w") as f:
        json.dump(hw, f, indent=1)
        f.write("\n")
    os.replace(tmp, hwf)
    c = plan["counts"]
    print("inventory: %d socket(s), %d/%d DIMMs, %d GPU(s), %d controller(s), %d disk(s)%s, %d NIC(s)" % (
        cpu["sockets_populated"], memory["slots_populated"], memory["slots_total"], len(gpus), len(controllers), len(disks),
        (" + %d behind RAID" % len(hidden)) if hidden else "", len(nics)))
    print("plan: %d test unit(s) (%d write+read disk, %d read-only disk, %d GPU), %d skipped, %d optional; est. total %s" % (
        c["test_units"], c["disks_write_read"], c["disks_read_only"], c["gpus_tested"], c["skipped_units"],
        c["optional_units"], plan["estimate"]["total_human"]))
    return 0


if __name__ == "__main__":
    sys.exit(main())
