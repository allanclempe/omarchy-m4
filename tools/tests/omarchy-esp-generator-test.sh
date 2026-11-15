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

fail() { echo "FAIL $1" >&2; failures=$((failures + 1)); }

# run NAME BYTES: run the generator with BYTES as the device-tree property
# (no property when BYTES is "-"); its early directory is $work/NAME/early.
run() {
  local name=$1 bytes=$2 dir=$work/$1
  mkdir -p "$dir/normal" "$dir/early" "$dir/late"
  if [[ $bytes == - ]]; then
    OMARCHY_ESP_PARTUUID_FILE=$dir/missing sh "$generator" "$dir/normal" "$dir/early" "$dir/late"
  else
    printf '%b' "$bytes" >"$dir/node"
    OMARCHY_ESP_PARTUUID_FILE=$dir/node sh "$generator" "$dir/normal" "$dir/early" "$dir/late"
  fi
}

# aura writes the PARTUUID upper-case with a trailing NUL.
run upper '272043E7-EC24-4890-93D6-545CFBB8329B\0'
unit=$work/upper/early/boot-efi.mount
if [[ -f $unit ]]; then
  grep -qx 'What=/dev/disk/by-partuuid/272043e7-ec24-4890-93d6-545cfbb8329b' "$unit" || fail "upper: What= is not the lower-case PARTUUID"
  grep -qx 'Where=/boot/efi' "$unit" || fail "upper: Where="
  grep -qx 'Type=vfat' "$unit" || fail "upper: Type="
  grep -qx 'Options=umask=0077' "$unit" || fail "upper: Options= differs from fstab's"
  escaped=$(systemd-escape --path /dev/disk/by-partuuid/272043e7-ec24-4890-93d6-545cfbb8329b)
  grep -qxF "Requires=systemd-fsck@$escaped.service" "$unit" || fail "upper: no fsck of the ESP"
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

# No property (not booted through aura): nothing is written, fstab applies.
run missing -
[[ -z $(ls -A "$work/missing/early") ]] || fail "missing: wrote a unit without the property"

# Anything but one canonical UUID is ignored the same way.
for bad in 'not-a-uuid\0' '272043e7-ec24-4890-93d6\0' '272043e7-ec24-4890-93d6-545cfbb8329b-x\0' \
  '../../etc/passwd\0' '272043e7-ec24-4890-93d6-545cfbb8329\n\0' '\0'; do
  name=bad$((++n))
  run "$name" "$bad"
  [[ -z $(ls -A "$work/$name/early") ]] || fail "$name: accepted ${bad}"
done

if ((failures)); then
  echo "$failures failure(s)" >&2
  exit 1
fi
echo "PASS omarchy-esp-generator: device-tree ESP mounted at /boot/efi with fstab's options and fsck; nothing written without a canonical PARTUUID"
