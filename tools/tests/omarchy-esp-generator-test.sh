#!/bin/bash
# Tests for tools/image/omarchy-esp-generator. Runs as a normal user on any
# Linux with systemd's tools: bash tools/tests/omarchy-esp-generator-test.sh
set -euo pipefail
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
generator=$here/../image/omarchy-esp-generator
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
failures=0
n=0
# As root the generator reads the live device tree and ignores the fixtures.
if [[ $(id -u) == 0 ]]; then
  echo "SKIP omarchy-esp-generator: run this test as a normal user" >&2
  exit 0
fi

fail() { echo "FAIL $1" >&2; failures=$((failures + 1)); }

# run NAME BYTES: run the generator with BYTES as the device-tree property
# (no property when BYTES is "-"); its early directory is $work/NAME/early.
run() {
  local name=$1 bytes=$2 dir=$work/$1
  mkdir -p "$dir/normal" "$dir/early" "$dir/late"
  # A normal user can't write /dev/kmsg, so the log line lands in stderr.
  if [[ $bytes == - ]]; then
    OMARCHY_ESP_PARTUUID_FILE=$dir/missing sh "$generator" "$dir/normal" "$dir/early" "$dir/late" 2>"$dir/log"
  else
    printf '%b' "$bytes" >"$dir/node"
    OMARCHY_ESP_PARTUUID_FILE=$dir/node sh "$generator" "$dir/normal" "$dir/early" "$dir/late" 2>"$dir/log"
  fi
}

# As read on the J616c: lower case, NUL-terminated. Upper case is accepted too.
run lower '272043e7-ec24-4890-93d6-545cfbb8329b\0'
grep -qx 'What=/dev/disk/by-partuuid/272043e7-ec24-4890-93d6-545cfbb8329b' "$work/lower/early/boot-efi.mount" 2>/dev/null ||
  fail "lower: no unit for the PARTUUID as the J616c reports it"
run upper '272043E7-EC24-4890-93D6-545CFBB8329B\0'
unit=$work/upper/early/boot-efi.mount
if [[ -f $unit ]]; then
  grep -qx 'What=/dev/disk/by-partuuid/272043e7-ec24-4890-93d6-545cfbb8329b' "$unit" || fail "upper: What= is not the lower-case PARTUUID"
  grep -qx 'Where=/boot/efi' "$unit" || fail "upper: Where="
  grep -qx 'Type=vfat' "$unit" || fail "upper: Type="
  grep -qx 'Options=umask=0077' "$unit" || fail "upper: Options= differs from fstab's"
  escaped=$(systemd-escape --path /dev/disk/by-partuuid/272043e7-ec24-4890-93d6-545cfbb8329b)
  grep -qxF "Requires=systemd-fsck@$escaped.service" "$unit" || fail "upper: no fsck of the ESP"
  grep -qxF "After=systemd-fsck@$escaped.service blockdev@$escaped.target" "$unit" ||
    fail "upper: not ordered after the ESP's fsck and block device"
  grep -qxF "SourcePath=$work/upper/node" "$unit" || fail "upper: SourcePath= doesn't name the device-tree property"
  grep -q 'mounting /boot/efi from PARTUUID 272043e7-ec24-4890-93d6-545cfbb8329b' "$work/upper/log" ||
    fail "upper: didn't log the PARTUUID it mounts"
  grep -qx 'Before=local-fs.target' "$unit" || fail "upper: not ordered before local-fs.target"
  [[ $(readlink "$work/upper/early/local-fs.target.requires/boot-efi.mount") == ../boot-efi.mount ]] ||
    fail "upper: local-fs.target doesn't require it"
  [[ -z $(ls -A "$work/upper/normal") && -z $(ls -A "$work/upper/late") ]] || fail "upper: wrote outside the early directory"
  # systemd itself must accept the unit, under the name it has to have.
  if command -v systemd-analyze >/dev/null; then
    out=$(systemd-analyze verify --man=no "$unit" 2>&1 | grep -v -e 'is not a device' -e 'Failed to put bus name' -e 'SO_PASSCRED' || true)
    grep -qiE 'error|invalid|unknown' <<<"$out" && fail "upper: systemd-analyze verify: $out"
  fi
else
  fail "upper: no boot-efi.mount written"
fi

# The override only works if it replaces the unit systemd-fstab-generator makes
# from the image's fstab line: same unit name, mount point, type and options.
fstab_generator=/usr/lib/systemd/system-generators/systemd-fstab-generator
if [[ -x $fstab_generator && -f $unit ]]; then
  mkdir -p "$work/fstab"/{normal,early,late}
  printf 'UUID=4F4D-5801  /boot/efi  vfat  umask=0077  0 2\n' >"$work/fstab/fstab"
  SYSTEMD_FSTAB=$work/fstab/fstab SYSTEMD_PROC_CMDLINE= "$fstab_generator" \
    "$work/fstab/normal" "$work/fstab/early" "$work/fstab/late" 2>/dev/null || true
  theirs=$work/fstab/normal/boot-efi.mount
  if [[ -f $theirs ]]; then
    for key in Where Type Options; do
      [[ $(grep "^$key=" "$theirs") == "$(grep "^$key=" "$unit")" ]] || fail "fstab: $key= differs from systemd-fstab-generator's"
    done
    grep -q '^Requires=systemd-fsck@' "$theirs" && ! grep -q '^Requires=systemd-fsck@' "$unit" &&
      fail "fstab: systemd-fstab-generator checks the ESP and this doesn't"
  else
    fail "fstab: systemd-fstab-generator made no boot-efi.mount, so nothing is being replaced"
  fi
elif [[ ! -x $fstab_generator ]]; then
  echo "note: systemd-fstab-generator not found; skipped the comparison with it" >&2
fi

# No property (not booted through aura): nothing is written, fstab applies.
run missing -
[[ -z $(ls -A "$work/missing/early") ]] || fail "missing: wrote a unit without the property"
grep -q 'no ESP named in the device tree' "$work/missing/log" || fail "missing: didn't log why fstab applies"

# Anything but one canonical UUID is ignored the same way.
for bad in 'not-a-uuid\0' '272043e7-ec24-4890-93d6\0' '272043e7-ec24-4890-93d6-545cfbb8329b-x\0' \
  '../../etc/passwd\0' '272043e7-ec24-4890-93d6-545cfbb8329\n\0' '\0'; do
  name=bad$((++n))
  run "$name" "$bad"
  [[ -z $(ls -A "$work/$name/early") ]] || fail "$name: accepted ${bad}"
  grep -q 'is not one PARTUUID' "$work/$name/log" || fail "$name: didn't log the refusal"
done

if ((failures)); then
  echo "$failures failure(s)" >&2
  exit 1
fi
echo "PASS omarchy-esp-generator: device-tree ESP mounted at /boot/efi with fstab's options and fsck; nothing written without a canonical PARTUUID"
