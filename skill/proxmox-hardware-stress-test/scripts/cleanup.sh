#!/usr/bin/env bash
# =============================================================================
# cleanup.sh - last step of the proxmox-hardware-stress-test sweep.
#
# Usage (as root ON the Proxmox host):
#   bash /root/pve-stresstest/cleanup.sh [--out DIR]... [--home DIR]
#        [--confirm-logs-copied] [--keep-packages] [--dry-run]
#
#   --out DIR               A run root made by prep.sh (has installed-packages.txt).
#                           May be repeated. Run roots under --home are found
#                           automatically.
#   --home DIR              Skill working dir (default /root/pve-stresstest).
#   --confirm-logs-copied   The user confirmed the logs/report were copied off
#                           the host: delete --home (and the --out dirs) too.
#                           Without it everything except the logs is cleaned
#                           and the script tells you how to copy them.
#   --keep-packages         Do not remove the packages prep.sh installed.
#   --dry-run               Only print what would be done.
#
# What it does, in order
#   1. Stops leftover test processes that belong to this skill (command line
#      or working dir under --home, or a pve-stresstest-fio* file); other
#      stress-ng / fio / ... processes are only reported, never killed.
#   2. Deletes disk test files named .pve-stresstest-fio-* / pve-stresstest-fio*
#      (registered ones in HOME/.testfiles, plus a search up to 4 levels deep
#      on mounted local filesystems). Only regular files (no symlinks) with
#      that name are deleted; nothing else is ever touched on those filesystems.
#   3. Removes EXACTLY the packages recorded in installed-packages.txt
#      (prep.sh records only packages that were not installed before, incl.
#      dependencies). apt is simulated first; if apt would remove anything
#      that is not on the list (e.g. something installed later depends on
#      it) or a protected package (proxmox/pve/kernel/zfs/nvidia), the
#      removal is refused and the list is printed instead.
#   4. apt autoremove only if its simulation touches recorded packages only.
#   5. With --confirm-logs-copied: deletes the working dir (must contain the
#      .pve-stresstest-root marker written by prep.sh) and the --out dirs.
#   Prints what was removed. Never touches guests, GPU drivers, kernels,
#   BIOS or power settings.
#
# Time: ~10-60 s. Exit 0 = all done; 3 = something was skipped for safety
# (reasons printed); 1 = bad usage / not root.
# =============================================================================
set -u
set -o pipefail

main() {
    local HOME_DIR=/root/pve-stresstest CONFIRM=0 KEEP_PKGS=0 DRY=0 PREFIX=pve-stresstest-fio
    local -a OUTS=()
    while (($#)); do
        case $1 in
            --out) [[ -n ${2:-} ]] || { echo "Missing value for --out" >&2; exit 1; }; OUTS+=("$2"); shift 2 ;;
            --home) [[ -n ${2:-} ]] || { echo "Missing value for --home" >&2; exit 1; }; HOME_DIR=$2; shift 2 ;;
            --confirm-logs-copied) CONFIRM=1; shift ;;
            --keep-packages) KEEP_PKGS=1; shift ;;
            --dry-run) DRY=1; shift ;;
            -h|--help) sed -n '4,20p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
            *) echo "Unknown argument: $1" >&2; exit 1 ;;
        esac
    done
    [[ $EUID -eq 0 ]] || { echo "FATAL: run as root on the Proxmox host" >&2; exit 1; }
    export LC_ALL=C DEBIAN_FRONTEND=noninteractive
    HOME_DIR=${HOME_DIR%/}
    local SKIPPED=0
    local -a REMOVED_PKGS=() REMOVED_FILES=() KILLED=() NOTES=()
    say() { printf '[cleanup] %s\n' "$*"; }
    run() { if ((DRY)); then say "DRY-RUN: $*"; else "$@"; fi; }

    # -------------------------------------------------------------- 1. leftover processes
    local p pid cmd cwd
    # test-file name test: disk.sh uses ".pve-stresstest-fio-<pid>.tmp"
    is_testfile_name() { local b; b=$(basename -- "$1"); [[ $b == "$PREFIX"* || $b == ".$PREFIX"* ]]; }
    for p in stress-ng sysbench fio hashcat clpeak memtester 7z 7zz 7za stream latency turbostat; do
        for pid in $(pgrep -x "$p" 2>/dev/null); do
            cmd=$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null)
            cwd=$(readlink "/proc/$pid/cwd" 2>/dev/null)
            if [[ $cmd == *"$HOME_DIR"* || $cmd == *"$PREFIX"* || $cwd == "$HOME_DIR"* ]]; then
                say "stopping leftover test process $pid: $cmd"
                if ((!DRY)); then
                    kill "$pid" 2>/dev/null
                    for _ in 1 2 3 4 5; do kill -0 "$pid" 2>/dev/null || break; sleep 1; done
                    kill -9 "$pid" 2>/dev/null
                fi
                KILLED+=("$pid $p")
            else
                NOTES+=("process $pid ($p) is running but was not started by this skill - left alone")
            fi
        done
    done

    # -------------------------------------------------------------- 2. disk test files
    local -a CAND=()
    local f t s ft o
    if [[ -r $HOME_DIR/.testfiles ]]; then
        while IFS= read -r f; do [[ -n $f ]] && CAND+=("$f"); done < "$HOME_DIR/.testfiles"
    fi
    while read -r t s ft o; do
        t=$(printf '%b' "$t")
        case $ft in ext4|ext3|xfs|btrfs|zfs|f2fs) ;; *) continue ;; esac
        case $t in /proc*|/sys*|/run*|/dev*|/etc/pve*) continue ;; esac
        [[ ",$o," == *",ro,"* ]] && continue
        while IFS= read -r f; do CAND+=("$f"); done < <(find "$t" -xdev -maxdepth 4 -type f \( -name "${PREFIX}*" -o -name ".${PREFIX}-*" \) 2>/dev/null)
    done < <(findmnt -rn -o TARGET,SOURCE,FSTYPE,OPTIONS 2>/dev/null)
    local -A DONE_F=()
    for f in "${CAND[@]}"; do
        [[ -n ${DONE_F[$f]:-} ]] && continue
        DONE_F[$f]=1
        is_testfile_name "$f" || { NOTES+=("refused to delete $f (name does not start with $PREFIX or .$PREFIX)"); SKIPPED=1; continue; }
        [[ -f $f && ! -L $f ]] || continue
        say "deleting test file $f ($(du -h -- "$f" 2>/dev/null | cut -f1))"
        run rm -f -- "$f" && REMOVED_FILES+=("$f")
    done
    ((DRY)) || { [[ -e $HOME_DIR/.testfiles ]] && : > "$HOME_DIR/.testfiles"; }
    ((DRY)) || rm -rf /tmp/pve-stresstest-tel.* 2>/dev/null
    # fixed-name apt log left by older versions of this script
    ((DRY)) || rm -f /tmp/pve-stresstest-cleanup-apt.log 2>/dev/null

    # -------------------------------------------------------------- 3. packages
    local -a LEDGERS=() RCLEDGERS=()
    local d
    for d in "${OUTS[@]}"; do
        [[ -r $d/installed-packages.txt ]] && LEDGERS+=("$d/installed-packages.txt") ||
            NOTES+=("no installed-packages.txt in $d")
        [[ -r $d/installed-packages.rc.txt ]] && RCLEDGERS+=("$d/installed-packages.rc.txt")
    done
    if [[ -d $HOME_DIR ]]; then
        while IFS= read -r f; do LEDGERS+=("$f"); done < <(find "$HOME_DIR" -maxdepth 3 -name installed-packages.txt -type f 2>/dev/null)
        while IFS= read -r f; do RCLEDGERS+=("$f"); done < <(find "$HOME_DIR" -maxdepth 3 -name installed-packages.rc.txt -type f 2>/dev/null)
    fi
    local -a RECORDED=() RCSET=() PURGE=() REMOVE=() PROTECTED=()
    if ((${#LEDGERS[@]})); then mapfile -t RECORDED < <(cat "${LEDGERS[@]}" 2>/dev/null | awk 'NF{print $1}' | sort -u); fi
    if ((${#RCLEDGERS[@]})); then mapfile -t RCSET < <(cat "${RCLEDGERS[@]}" 2>/dev/null | awk 'NF{print $1}' | sort -u); fi
    local PROTECT_RE='^(proxmox-|pve-|libpve|qemu-server|lxc-pve|corosync|ceph|linux-image|linux-headers|proxmox-kernel|pve-kernel|zfs|libzfs|libnvpair|libuutil|nvidia|libnvidia|openssh|systemd|apt|dpkg|libc6$|bash$|grub|shim|efibootmgr|ifupdown)'
    local pkg st
    for pkg in "${RECORDED[@]}"; do
        st=$(dpkg-query -W -f='${db:Status-Abbrev}' "$pkg" 2>/dev/null)
        [[ $st == ii* ]] || continue
        if [[ $pkg =~ $PROTECT_RE ]]; then PROTECTED+=("$pkg"); continue; fi
        if printf '%s\n' "${RCSET[@]}" | grep -qxF -- "$pkg"; then REMOVE+=("$pkg"); else PURGE+=("$pkg"); fi
    done
    ((${#PROTECTED[@]})) && { NOTES+=("protected packages on the list were kept: ${PROTECTED[*]}"); SKIPPED=1; }

    # simulate an apt action, print the packages it would remove
    APT_LOG=$(mktemp /tmp/pve-stresstest-cleanup-apt.XXXXXX 2>/dev/null || echo /tmp/pve-stresstest-cleanup-apt.log)
    local APT_FAILED=0
    sim_removed() { apt-get -s "$@" 2>/dev/null | awk '$1=="Remv"||$1=="Purg"{print $2}' | sort -u; }
    pkg_step() { # ACTION LIST...
        local action=$1; shift
        (($#)) || return 0
        local -a would extra=()
        mapfile -t would < <(sim_removed "$action" "$@")
        local w
        for w in "${would[@]}"; do
            printf '%s\n' "${RECORDED[@]}" | grep -qxF -- "$w" || extra+=("$w")
        done
        if ((${#extra[@]})); then
            say "REFUSED: 'apt-get $action' would also remove packages this test did not install: ${extra[*]}"
            say "         (something installed since depends on them). Nothing was removed in this step."
            say "         To remove manually after checking: apt-get $action $*"
            SKIPPED=1; return 0
        fi
        say "apt-get $action (${#would[@]} packages): ${would[*]}"
        if ((DRY)); then return 0; fi
        if apt-get "$action" -y -q -o DPkg::Lock::Timeout=300 "$@" >> "$APT_LOG" 2>&1; then
            REMOVED_PKGS+=("${would[@]}")
        else
            say "apt-get $action failed - see $APT_LOG"; SKIPPED=1; APT_FAILED=1
        fi
    }
    if ((KEEP_PKGS)); then
        say "--keep-packages: leaving installed packages in place (${#PURGE[@]} + ${#REMOVE[@]} recorded)"
    elif ((${#RECORDED[@]} == 0)); then
        say "no recorded packages (ledger missing or empty) - nothing to remove"
    elif ((${#PURGE[@]} + ${#REMOVE[@]} == 0)); then
        say "recorded packages are already removed"
    else
        pkg_step purge "${PURGE[@]}"
        pkg_step remove "${REMOVE[@]}"
        # 4. autoremove only if it would touch recorded packages only
        local -a ar=() arx=()
        mapfile -t ar < <(sim_removed autoremove --purge)
        local a
        for a in "${ar[@]}"; do printf '%s\n' "${RECORDED[@]}" | grep -qxF -- "$a" || arx+=("$a"); done
        if ((${#ar[@]} == 0)); then
            say "apt autoremove: nothing to do"
        elif ((${#arx[@]})); then
            say "apt autoremove skipped: it would also remove packages not installed by this test: ${arx[*]}"
        else
            say "apt autoremove --purge: ${ar[*]}"
            if ((!DRY)); then
                if apt-get autoremove --purge -y -q -o DPkg::Lock::Timeout=300 >> "$APT_LOG" 2>&1; then
                    REMOVED_PKGS+=("${ar[@]}")
                else
                    say "apt-get autoremove failed - see $APT_LOG"; SKIPPED=1; APT_FAILED=1
                fi
            fi
        fi
    fi

    # -------------------------------------------------------------- 5. working dir
    safe_rmdir() {
        local dir real
        dir=$1
        real=$(readlink -f -- "$dir" 2>/dev/null) || return 0
        [[ -d $real ]] || return 0
        local slashes=${real//[!\/]/}
        case $real in
            /|/root|/home|/etc|/usr|/var|/var/lib|/var/lib/vz|/mnt|/boot|/tmp|/opt|/srv|/etc/*|/usr/*|/boot/*)
                say "REFUSED to delete $real (unsafe path)"; SKIPPED=1; return 0 ;;
        esac
        if ((${#slashes} < 2)); then say "REFUSED to delete $real (top-level path)"; SKIPPED=1; return 0; fi
        if [[ ! -e $real/.pve-stresstest-root && ! -e $real/hardware.json ]]; then
            say "REFUSED to delete $real (no .pve-stresstest-root marker / hardware.json - not a skill directory)"; SKIPPED=1; return 0
        fi
        say "deleting $real"
        run rm -rf -- "$real"
        if ((!DRY)) && [[ -e $real ]]; then say "could not fully delete $real"; SKIPPED=1; else DELETED_DIRS+=("$real"); fi
    }
    local -a DELETED_DIRS=()
    if ((CONFIRM)); then
        for d in "${OUTS[@]}"; do
            [[ $(readlink -f -- "$d" 2>/dev/null) == "$(readlink -f -- "$HOME_DIR" 2>/dev/null)"/* ]] && continue
            safe_rmdir "$d"
        done
        safe_rmdir "$HOME_DIR"
    else
        say "logs kept in $HOME_DIR ${OUTS[*]}"
        say "copy them first, e.g. from your computer:  scp -r root@<host>:$HOME_DIR ./pve-stresstest-logs"
        say "then re-run: bash $HOME_DIR/cleanup.sh --confirm-logs-copied"
    fi

    # -------------------------------------------------------------- report
    echo
    echo "=================== CLEANUP SUMMARY ==================="
    ((DRY)) && echo "(dry run - nothing was changed)"
    echo "Processes stopped: ${#KILLED[@]}"; for p in "${KILLED[@]}"; do echo "  - $p"; done
    echo "Test files deleted: ${#REMOVED_FILES[@]}"; for f in "${REMOVED_FILES[@]}"; do echo "  - $f"; done
    echo "Packages removed: ${#REMOVED_PKGS[@]}"; ((${#REMOVED_PKGS[@]})) && printf '  %s\n' "$(printf '%s ' "${REMOVED_PKGS[@]}" | fold -s -w 76)"
    if ((CONFIRM)); then
        if ((DRY)); then echo "Working dir: would be deleted ($HOME_DIR) if it passes the safety checks above"
        elif [[ -e $HOME_DIR ]]; then echo "Working dir: NOT deleted ($HOME_DIR still exists - see REFUSED lines above)"
        else echo "Working dir: deleted ($HOME_DIR)"; fi
        for d in "${DELETED_DIRS[@]}"; do [[ $d == "$(readlink -f -- "$HOME_DIR" 2>/dev/null)" ]] || echo "  also deleted: $d"; done
    else echo "Working dir: kept ($HOME_DIR)"; fi
    if [[ -n ${APT_LOG:-} && -e $APT_LOG ]]; then
        if ((APT_FAILED)); then echo "apt log kept for inspection: $APT_LOG"; else rm -f -- "$APT_LOG"; fi
    fi
    ((${#NOTES[@]})) && { echo "Notes:"; for n in "${NOTES[@]}"; do echo "  - $n"; done; }
    echo "========================================================"
    ((SKIPPED)) && exit 3
    exit 0
}

main "$@"
exit $?
