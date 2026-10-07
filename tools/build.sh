#!/usr/bin/env bash
# =============================================================================
# tools/build.sh - package the skill folder into dist/
#
# Usage (from anywhere; the script works from the repo root):
#   tools/build.sh           validate the skill, rebuild dist/, then verify it
#   tools/build.sh --check   only verify that dist/ matches the skill folder
#                            (no rebuild; used by CI)
#   tools/build.sh --help
#
# What it produces:
#   dist/proxmox-hardware-stress-test.zip    zip of the skill folder
#   dist/proxmox-hardware-stress-test.skill  the SAME archive, .skill extension
#                                            (what Claude apps install)
#   dist/SHA256SUMS                          checksums of both files
#
# Both archives contain one top-level folder, proxmox-hardware-stress-test/,
# with every file from skill/proxmox-hardware-stress-test/ (executable bits
# kept, files in a fixed sorted order, timestamps normalised, junk excluded).
#
# Needs: bash, zip, unzip, diff, and sha256sum or shasum.
# =============================================================================
set -euo pipefail

NAME="proxmox-hardware-stress-test"
FIXED_TIME="202601010000"   # touch -t format; makes rebuilds byte-identical

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

SRC="skill/$NAME"
DIST="dist"
ZIP="$DIST/$NAME.zip"
SKILL="$DIST/$NAME.skill"
SUMS="$DIST/SHA256SUMS"

MODE="build"
case "${1:-}" in
  "") ;;
  --check) MODE="check" ;;
  -h|--help) sed -n '2,22p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
  *) echo "Unknown option: $1 (try --help)" >&2; exit 2 ;;
esac

fail() { echo "ERROR: $*" >&2; exit 1; }
info() { echo "==> $*"; }

for tool in zip unzip diff; do
  command -v "$tool" >/dev/null 2>&1 || fail "'$tool' is not installed"
done
if command -v sha256sum >/dev/null 2>&1; then
  SHA=(sha256sum)
elif command -v shasum >/dev/null 2>&1; then
  SHA=(shasum -a 256)
else
  fail "need sha256sum or shasum"
fi

TMP="$(mktemp -d "${TMPDIR:-/tmp}/skill-build.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

# Files that must never ship in the archive.
is_junk() {
  case "$(basename "$1")" in
    .DS_Store|Thumbs.db|desktop.ini|._*|*.pyc|*.pyo|*.swp|*~) return 0 ;;
  esac
  case "$1" in
    */__pycache__/*|*/__pycache__) return 0 ;;
  esac
  return 1
}

# --------------------------------------------------------------------------
# 1. Validate the skill folder
# --------------------------------------------------------------------------
validate() {
  info "Validating $SRC"
  [ -d "$SRC" ] || fail "$SRC not found (copy the skill folder there first)"
  [ -f "$SRC/SKILL.md" ] || fail "$SRC/SKILL.md is missing"

  # Frontmatter: first line '---', a closing '---', name + description inside.
  [ "$(head -n 1 "$SRC/SKILL.md")" = "---" ] \
    || fail "SKILL.md must start with a '---' frontmatter line"
  local fm
  fm="$(awk 'NR==1{next} /^---[[:space:]]*$/{exit} {print}' "$SRC/SKILL.md")"
  [ -n "$fm" ] || fail "SKILL.md frontmatter is empty or not closed with '---'"
  local fm_name fm_desc
  fm_name="$(printf '%s\n' "$fm" | sed -n 's/^name:[[:space:]]*//p' | head -n 1)"
  fm_desc="$(printf '%s\n' "$fm" | sed -n 's/^description:[[:space:]]*//p' | head -n 1)"
  [ -n "$fm_name" ] || fail "SKILL.md frontmatter has no 'name:'"
  [ -n "$fm_desc" ] || fail "SKILL.md frontmatter has no 'description:'"
  [ "$fm_name" = "$NAME" ] \
    || fail "SKILL.md name is '$fm_name' but the folder is '$NAME'"
  if [ "${#fm_desc}" -gt 1024 ]; then
    echo "WARNING: description is ${#fm_desc} characters (Claude's limit is 1024)" >&2
  fi

  # Scripts that are run directly must be executable.
  local f bad=0
  while IFS= read -r f; do
    if [ ! -x "$f" ]; then
      echo "  not executable: $f (fix: chmod +x '$f')" >&2
      bad=1
    fi
  done < <(find "$SRC/scripts" -type f \( -name '*.sh' -o -name '*.py' \) | LC_ALL=C sort)
  [ "$bad" -eq 0 ] || fail "some scripts are not executable"

  # No junk (macOS/Windows metadata, Python caches, editor backups).
  local junk=()
  while IFS= read -r f; do
    if is_junk "$f"; then junk+=("$f"); fi
  done < <(find "$SRC" -mindepth 1 | LC_ALL=C sort)
  if [ "${#junk[@]}" -gt 0 ]; then
    printf '  junk: %s\n' "${junk[@]}" >&2
    fail "remove the files above, e.g.: find '$SRC' \\( -name .DS_Store -o -name __pycache__ -o -name '*.pyc' \\) -prune -exec rm -rf {} +"
  fi

  # No symlinks (zip would store them differently on each platform).
  if [ -n "$(find "$SRC" -type l | head -n 1)" ]; then
    fail "symlinks are not allowed in $SRC: $(find "$SRC" -type l | tr '\n' ' ')"
  fi

  echo "    name: $fm_name"
  echo "    description: ${#fm_desc} characters"
  echo "    files: $(find "$SRC" -type f | wc -l | tr -d ' ')"
}

# --------------------------------------------------------------------------
# 2. Build the archives
# --------------------------------------------------------------------------
build() {
  info "Building $ZIP"
  mkdir -p "$DIST"
  rm -f "$ZIP" "$SKILL" "$SUMS"

  # Stage a clean copy so permissions and timestamps can be normalised
  # without touching the real files.
  local stage="$TMP/stage"
  mkdir -p "$stage"
  cp -R "$SRC" "$stage/$NAME"
  find "$stage/$NAME" -type d -exec chmod 755 {} +
  find "$stage/$NAME" -type f -exec sh -c '
    for f do
      if [ -x "$f" ]; then chmod 755 "$f"; else chmod 644 "$f"; fi
    done' sh {} +
  find "$stage/$NAME" -exec env TZ=UTC touch -t "$FIXED_TIME" {} +

  # Sorted file list -> deterministic order. -X drops uid/gid and extra
  # timestamp fields; -D leaves out directory entries. Unix permission bits
  # (the +x on scripts) are still stored.
  local list="$TMP/files.txt"
  (cd "$stage" && find "$NAME" -type f | LC_ALL=C sort) > "$list"
  local abs_zip="$ROOT/$ZIP"
  (cd "$stage" && TZ=UTC zip -q -X -D -9 "$abs_zip" -@ < "$list")

  info "Writing $SKILL (identical copy of the .zip)"
  cp "$ZIP" "$SKILL"

  info "Writing $SUMS"
  (cd "$DIST" && "${SHA[@]}" "$NAME.skill" "$NAME.zip" > SHA256SUMS)
}

# --------------------------------------------------------------------------
# 3. Verify dist/ against the source folder
# --------------------------------------------------------------------------
verify_archive() {
  local archive="$1" label="$2"
  local out="$TMP/verify-$label"
  rm -rf "$out"; mkdir -p "$out"
  unzip -q "$archive" -d "$out" || fail "$archive is not a valid zip archive"

  # Exactly one top-level entry, the skill folder.
  local top
  top="$(cd "$out" && ls -A)"
  [ "$top" = "$NAME" ] \
    || fail "$archive must contain only the folder $NAME/ at the top level (found: $(echo "$top" | tr '\n' ' '))"

  # Same files, same contents.
  diff -r "$out/$NAME" "$SRC" >/dev/null \
    || { diff -r "$out/$NAME" "$SRC" >&2 || true; fail "$archive does not match $SRC (run tools/build.sh to rebuild)"; }

  # Same executable bits.
  local f rel
  while IFS= read -r f; do
    rel="${f#"$SRC"/}"
    if [ -x "$f" ] && [ ! -x "$out/$NAME/$rel" ]; then
      fail "$archive lost the executable bit on $rel"
    fi
    if [ ! -x "$f" ] && [ -x "$out/$NAME/$rel" ]; then
      fail "$archive has an unexpected executable bit on $rel"
    fi
  done < <(find "$SRC" -type f | LC_ALL=C sort)
  echo "    $label: matches $SRC"
}

verify() {
  info "Verifying $DIST against $SRC"
  local f
  for f in "$ZIP" "$SKILL" "$SUMS"; do
    [ -f "$f" ] || fail "$f is missing (run tools/build.sh)"
  done
  (cd "$DIST" && "${SHA[@]}" -c SHA256SUMS >/dev/null) \
    || fail "SHA256SUMS does not match the files in $DIST (run tools/build.sh)"
  echo "    SHA256SUMS: OK"
  cmp -s "$ZIP" "$SKILL" || fail "$SKILL and $ZIP should be byte-identical"
  echo "    .skill and .zip: byte-identical"
  verify_archive "$ZIP" zip
  verify_archive "$SKILL" skill
}

summary() {
  local files bytes
  files="$(unzip -Z1 "$ZIP" | wc -l | tr -d ' ')"
  bytes="$(wc -c < "$ZIP" | tr -d ' ')"
  echo
  echo "Summary"
  echo "  Source : $SRC"
  echo "  Files  : $files"
  echo "  Size   : $bytes bytes per archive"
  echo "  Output :"
  sed 's/^/    /' "$SUMS"
}

validate
if [ "$MODE" = "build" ]; then
  build
fi
verify
summary
echo
if [ "$MODE" = "build" ]; then
  echo "Done. dist/ is rebuilt and verified."
else
  echo "Done. dist/ matches the skill folder."
fi
