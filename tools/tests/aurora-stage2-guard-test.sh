#!/bin/bash
# Tests for tools/image/aurora-stage2-guard-from-unlock.conf (OMS-17): with the
# drop-in, Aurora's guard timer counts 12 minutes from its own activation, not
# from kernel start. Runs as a normal user on a Linux with a systemd user
# manager: bash tools/tests/aurora-stage2-guard-test.sh
#
# It loads a copy of Aurora's timer under a throwaway name into the user
# manager, from $XDG_RUNTIME_DIR (gone at logout), with and without the
# drop-in, reads the timer settings systemd parsed, and removes it again.
# Nothing is started, so nothing fires.
set -euo pipefail
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
dropin=$here/../image/aurora-stage2-guard-from-unlock.conf
failures=0
fail() { echo "FAIL $1" >&2; failures=$((failures + 1)); }

if ! systemctl --user show-environment >/dev/null 2>&1 || [[ -z ${XDG_RUNTIME_DIR:-} ]]; then
  echo "SKIP aurora-stage2-guard: no systemd user manager" >&2
  exit 0
fi

name=omarchy-oms17-guard-test-$$
units=$XDG_RUNTIME_DIR/systemd/user
# A second unit directory, as the image keeps the drop-in under /usr/local/lib
# while Aurora's timer is in /usr/lib.
control=$XDG_RUNTIME_DIR/systemd/user.control
mkdir -p "$units" "$control"
cleanup() {
  rm -rf -- "$units/$name.timer" "$units/$name.service" "$control/$name.timer.d"
  systemctl --user daemon-reload || :
}
trap cleanup EXIT

# Aurora's aurora-stage2-guard.timer from asahi-scripts 20261023-9, as read on
# the J616c, without its device-tree condition so it loads anywhere.
cat >"$units/$name.timer" <<EOF
[Unit]
Description=Limit an uncommitted Aurora Stage 2 trial to twelve minutes (test copy)

[Timer]
OnBootSec=12min
AccuracySec=10s
EOF
printf '[Service]\nType=oneshot\nExecStart=/bin/true\n' >"$units/$name.service"

timers() { systemctl --user show -p TimersMonotonic --value "$name.timer"; }

systemctl --user daemon-reload
before=$(timers)
[[ $before == *OnBootUSec=12min* ]] || fail "without the drop-in: expected Aurora's OnBootSec=12min, got: $before"

mkdir -p "$control/$name.timer.d"
cp -- "$dropin" "$control/$name.timer.d/aurora-stage2-guard-from-unlock.conf"
systemctl --user daemon-reload
after=$(timers)
[[ $after == *OnActiveUSec=12min* ]] || fail "with the drop-in: no OnActiveSec=12min, got: $after"
[[ $after != *OnBootUSec* ]] || fail "with the drop-in: Aurora's OnBootSec is still there: $after"
[[ $(grep -c '^On' "$dropin") == 2 ]] || fail "the drop-in sets more than OnBootSec= and OnActiveSec="
accuracy=$(systemctl --user show -p AccuracyUSec --value "$name.timer")
[[ $accuracy == 10s ]] || fail "the drop-in changed Aurora's AccuracySec (now $accuracy)"

if ((failures)); then
  echo "$failures failure(s)" >&2
  exit 1
fi
echo "PASS aurora-stage2-guard: the drop-in replaces OnBootSec=12min with OnActiveSec=12min and keeps the rest"
