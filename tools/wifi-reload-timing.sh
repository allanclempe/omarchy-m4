#!/bin/bash
# wifi-reload-timing.sh: time how long Wi-Fi takes to rejoin after the
# brcmfmac driver is reloaded, two ways (omarchy-m4 OMS-5, JOURNEY 9.26).
#
#   sudo bash wifi-reload-timing.sh [OUTPUT] [PLAIN_RUNS]
#     OUTPUT      default /tmp/oms5-result.txt
#     PLAIN_RUNS  how many plain reloads to time, default 1
#
# 1. plain: modprobe -r brcmfmac_wcc brcmfmac, then modprobe brcmfmac, as
#    omarchy-m-test's network.wifi-first-join does while connected (and
#    omarchy-wifi-resume-fix does when Wi-Fi didn't come back after resume).
#    Each run reports whether iwd tried to connect before the driver was
#    loaded again, the race seen on 2026-11-14.
# 2. clean: once, the same with the Wi-Fi radio turned off first (nmcli radio
#    wifi off) and on again after the reload, so iwd makes no connect attempts
#    on the radio while it goes away.
#
# Each run is timed from the modprobe that loads the driver to the Wi-Fi
# device being connected with a routable IPv4 address, giving up after 120 s.
# The first run needs Wi-Fi joined when the script starts. Before every later
# run it requires Wi-Fi joined and then waits 70 s, past iwd's 60 s block on
# access points that failed to connect, so a run doesn't inherit the last
# one's; a run that never joins stops the script with status 1. It needs no network
# while it runs: run it at the Mac, since Wi-Fi (and an SSH session over it)
# drops. Whatever happens, it loads the driver and turns the radio back on at
# exit.
set -uo pipefail
out=${1:-/tmp/oms5-result.txt}
plain_runs=${2:-1}
[[ $plain_runs =~ ^[1-9][0-9]*$ ]] || { echo "PLAIN_RUNS must be a positive number" >&2; exit 2; }
[[ $(id -u) == 0 ]] || { echo "run it with sudo" >&2; exit 1; }
for tool in modprobe nmcli iw ip journalctl logger awk pacman; do
  command -v "$tool" >/dev/null || { echo "missing $tool" >&2; exit 1; }
done

dev=$(iw dev | awk '$1 == "Interface" { print $2; exit }')
[[ -n $dev ]] || { echo "no Wi-Fi interface" >&2; exit 1; }

work=
restore() {
  modprobe brcmfmac 2>/dev/null || :
  nmcli radio wifi on 2>/dev/null || :
  [[ -z $work ]] || rm -rf -- "$work"
}
trap restore EXIT

now() { date +%s.%N; }
say() { echo "$*" | tee -a "$out"; logger -t oms5 "$*"; }
elapsed() { awk -v a="$1" -v b="$2" 'BEGIN { printf "%.1f", b - a }'; }

# joined: the Wi-Fi device is associated and has a routable IPv4 address.
joined() {
  iw dev "$dev" link 2>/dev/null | grep -q '^Connected to' &&
    ip -4 -br addr show "$dev" 2>/dev/null | awk '{ for (i = 3; i <= NF; i++) if ($i !~ /^169\.254\./) found = 1 } END { exit !found }'
}

# wait_join LABEL START: wait up to 120 s for joined, report seconds since START.
wait_join() {
  local label=$1 start=$2 t
  while :; do
    t=$(now)
    if joined; then
      say "$label: joined after $(elapsed "$start" "$t") s ($(iw dev "$dev" link | sed -n 's/^\tSSID: //p'), $(iw dev "$dev" link | sed -n 's/^\tfreq: //p') MHz)"
      return 0
    fi
    if awk -v a="$start" -v b="$t" 'BEGIN { exit !(b - a > 120) }'; then
      say "$label: not joined after 120 s"
      return 1
    fi
    sleep 0.5
  done
}

# settle: joined now, then 70 s for iwd's blocks to expire.
settle() {
  joined || { say "not joined before the next run; stopping"; exit 1; }
  say "waiting 70 s for iwd's blocks to expire"
  sleep 70
}

# unload LABEL: remove the driver, and stop if it's still loaded.
unload() {
  modprobe -r brcmfmac_wcc brcmfmac || { say "$1: modprobe -r failed; stopping"; exit 1; }
  [[ ! -d /sys/module/brcmfmac ]] || { say "$1: brcmfmac is still loaded; stopping"; exit 1; }
}

# race LABEL: report whether iwd tried to connect (connect-failed) or its scans
# failed before this run's driver load, counted up to the run's own marker,
# so no clock comparison is involved.
race() {
  local marker="$1: modprobe brcmfmac" failed scans
  failed=$(awk -v m="$marker" 'index($0, "oms5[") && index($0, m) { exit } /connect-failed/ { n++ } END { print n + 0 }' "$work/$1.journal")
  scans=$(awk -v m="$marker" 'index($0, "oms5[") && index($0, m) { exit } /CMD_TRIGGER_SCAN/ { n++ } END { print n + 0 }' "$work/$1.journal")
  if ((failed > 0)); then
    say "$1: race hit ($failed failed connects, $scans failed scans before the load)"
  else
    say "$1: race missed ($scans failed scans before the load)"
  fi
}

# journal LABEL SINCE: this script's markers, iwd, NetworkManager's Wi-Fi lines
# and brcmfmac since SINCE.
journal() {
  journalctl --no-pager -o short-precise --since "@${2%.*}" |
    grep -E "oms5\[|iwd\[|brcmf|NetworkManager.*($dev|iwd)" |
    grep -vE 'iwd\[[0-9]+\]: {2,}|Wiphy:|Bitrates|Capabilit|Band:|Mbps|Ciphers|iftypes|Short GI|MCS|0-15|Mhz operation' |
    cut -c1-220 >"$work/$1.journal"
  { echo "---- $1: journal"; cat "$work/$1.journal"; } >>"$out"
}

work=$(mktemp -d)
: >"$out"
say "oms5: start $(date -Is), $(uname -r), $(pacman -Q iwd networkmanager | tr '\n' ' '), device $dev, $plain_runs plain run(s)"
joined || { say "oms5: $dev isn't joined; join a network first"; exit 1; }

# 1. plain reloads while connected.
for ((n = 1; n <= plain_runs; n++)); do
  ((n == 1)) || settle
  label=plain$n
  since=$(now)
  say "$label: modprobe -r brcmfmac_wcc brcmfmac"
  unload "$label"
  sleep 1
  start=$(now)
  say "$label: modprobe brcmfmac"
  modprobe brcmfmac || { say "$label: modprobe failed; stopping"; exit 1; }
  wait_join "$label" "$start"
  joined_ok=$?
  journal "$label" "$since"
  race "$label"
  ((joined_ok == 0)) || { say "$label: stopping: Wi-Fi didn't rejoin"; exit 1; }
done

# 2. clean reload: radio off first, on after.
settle
since=$(now)
say "clean: nmcli radio wifi off"
nmcli radio wifi off || { say "clean: nmcli radio wifi off failed; stopping"; exit 1; }
sleep 2
unload clean
sleep 1
start=$(now)
say "clean: modprobe brcmfmac"
modprobe brcmfmac || { say "clean: modprobe failed; stopping"; exit 1; }
nmcli radio wifi on
wait_join clean "$start"
joined_ok=$?
journal clean "$since"
race clean
((joined_ok == 0)) || { say "clean: Wi-Fi didn't rejoin"; exit 1; }

say "oms5: done $(date -Is); result in $out"
