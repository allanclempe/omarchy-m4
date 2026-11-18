#!/bin/bash
# Tests for the identifier filter, redact(), in tools/touchid-probe.sh. Runs as a
# normal user on any Linux: bash tools/tests/touchid-probe-redact-test.sh
set -euo pipefail
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# Load redact() alone; the probe itself needs root and a Mac.
eval "$(sed -n '/^redact()/,/^}/p' "$here/../touchid-probe.sh")"
declare -F redact >/dev/null || { echo "FAIL redact() not found in touchid-probe.sh" >&2; exit 1; }
failures=0
n=0

# expect NAME INPUT OUTPUT: redact turns INPUT into exactly OUTPUT.
expect() {
  local got
  n=$((n + 1))
  got=$(printf '%s\n' "$2" | redact)
  if [[ $got != "$3" ]]; then
    printf 'FAIL %s\n  input:    %s\n  expected: %s\n  got:      %s\n' "$1" "$2" "$3" "$got" >&2
    failures=$((failures + 1))
  fi
}

id="identity 53 fb e1 45 55 31 4a 07 ad 87 f4 26 e7 1b 6c 10 (host index present)"
expect "a byte list with spaces" "verify: enclave matched $id" \
  "verify: enclave matched identity <bytes withheld> (host index present)"
expect "a byte list with colons" "id de:ad:be:ef:01:02:03:04:05" "id <bytes withheld>"
expect "a byte list with commas, as Rust prints a slice" "id [de, ad, be, ef, 01, 02, 03, 04, 05, 06]" \
  "id [<bytes withheld>]"
expect "a byte list with 0x and commas" "id [0xde, 0xad, 0xbe, 0xef, 0x01, 0x02, 0x03, 0x04]" \
  "id [<bytes withheld>]"
expect "a long hex run" "msg0 0x00ff00aa11bb22cc" "msg0 <hex withheld>"
expect "a UUID" "id 12345678-abcd-ef01-2345-6789abcdef01" "id <uuid withheld>"
expect "a line that names an identifier is withheld and counted" "sep: ECID 001a2b3c" \
  "(1 line(s) withheld: they named an identifier)"
expect "a line about the identity's source is kept" "xART: using /chosen/apfs-preboot-uuid" \
  "xART: using /chosen/apfs-preboot-uuid"
expect "the driver's policy is kept" "xart_writes=0 provision_keybag=0 xart_guard=1 identity_source=dt" \
  "xart_writes=0 provision_keybag=0 xart_guard=1 identity_source=dt"
expect "the profile and endpoint names are kept" "T6041/J614c, J616c: cntl sbio scrd sse hdcp xars sks xarm" \
  "T6041/J614c, J616c: cntl sbio scrd sse hdcp xars sks xarm"
expect "seven bytes are not a list" "status 80 20 00 10 00 00 00" "status 80 20 00 10 00 00 00"

if ((failures)); then
  echo "touchid-probe redact: $failures of $n failed" >&2
  exit 1
fi
echo "touchid-probe redact: $n passed"
