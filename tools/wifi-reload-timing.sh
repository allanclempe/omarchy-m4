#!/bin/bash
# wifi-reload-timing.sh: time how long Wi-Fi takes to rejoin after the
# brcmfmac driver is reloaded, two ways (omarchy-m4 OMS-5, JOURNEY 9.26).
#
#   sudo bash wifi-reload-timing.sh [OUTPUT]      (default /tmp/oms5-result.txt)
#
# 1. plain: modprobe -r brcmfmac_wcc brcmfmac, then modprobe brcmfmac, as
#    omarchy-m-test's network.wifi-first-join does while connected.
# 2. clean: the same with the Wi-Fi radio turned off first (nmcli radio wifi
#    off) and on again after the reload, so iwd makes no connect attempts on
#    the radio while it goes away.
#
# Each run is timed from the modprobe that loads the driver to wlan0 being
# connected with an IPv4 address, giving up after 120 s. Between the runs it
# waits 70 s once connected, past iwd's 60 s block on failed access points, so
# the second run doesn't inherit the first's. It needs no network while it
# runs: run it at the Mac, since Wi-Fi (and an SSH session over it) drops.
# Whatever happens, it loads the driver and turns the radio back on at exit.
set -uo pipefail
out=${1:-/tmp/oms5-result.txt}
[[ $(id -u) == 0 ]] || { echo "run it with sudo" >&2; exit 1; }
for tool in modprobe nmcli iw ip journalctl logger; do
  command -v "$tool" >/dev/null || { echo "missing $tool" >&2; exit 1; }
done

restore() {
  modprobe brcmfmac 2>/dev/null || :
  nmcli radio wifi on 2>/dev/null || :
}
trap restore EXIT

now() { date +%s.%N; }
say() { echo "$*" | tee -a "$out"; logger -t oms5 "$*"; }

# joined: wlan0 is associated and has an IPv4 address.
joined() {
  iw dev wlan0 link 2>/dev/null | grep -q '^Connected to' &&
    ip -4 -br addr show wlan0 2>/dev/null | grep -q '[0-9]\.[0-9]'
}

# wait_join LABEL START: wait up to 120 s for joined, report seconds since START.
wait_join() {
  local label=$1 start=$2 t
  while :; do
    t=$(now)
    if joined; then
      say "$label: joined after $(awk -v a="$start" -v b="$t" 'BEGIN { printf "%.1f", b - a }') s ($(iw dev wlan0 link | sed -n 's/^\tSSID: //p'), $(iw dev wlan0 link | sed -n 's/^\tfreq: //p') MHz)"
      return 0
    fi
    if awk -v a="$start" -v b="$t" 'BEGIN { exit !(b - a > 120) }'; then
      say "$label: not joined after 120 s"
      return 1
    fi
    sleep 0.5
  done
}

# journal LABEL SINCE: iwd, NetworkManager's wlan0 lines and brcmfmac since SINCE.
journal() {
  {
    echo "---- $1: journal"
    journalctl --no-pager -o short-precise --since "@${2%.*}" |
      grep -E 'iwd\[|brcmf|NetworkManager.*(wlan0|iwd)' |
      grep -vE 'iwd\[[0-9]+\]: {2,}|Wiphy:|Bitrates|Capabilit|Band:|Mbps|Ciphers|iftypes|Short GI|MCS|0-15|Mhz operation' |
      cut -c1-220
  } >>"$out"
}

: >"$out"
say "oms5: start $(date -Is), $(uname -r), $(pacman -Q iwd networkmanager | tr '\n' ' ')"
joined || say "oms5: warning: wlan0 isn't joined before the first run"

# 1. plain reload while connected.
since=$(now)
say "plain: modprobe -r brcmfmac_wcc brcmfmac"
modprobe -r brcmfmac_wcc brcmfmac
sleep 1
start=$(now)
say "plain: modprobe brcmfmac"
modprobe brcmfmac
wait_join plain "$start"
journal plain "$since"

if joined; then
  say "waiting 70 s for iwd's blocks to expire"
  sleep 70
else
  wait_join "plain (still waiting)" "$start" || :
  sleep 70
fi

# 2. clean reload: radio off first, on after.
since=$(now)
say "clean: nmcli radio wifi off"
nmcli radio wifi off
sleep 2
modprobe -r brcmfmac_wcc brcmfmac
sleep 1
start=$(now)
say "clean: modprobe brcmfmac, nmcli radio wifi on"
modprobe brcmfmac
nmcli radio wifi on
wait_join clean "$start"
journal clean "$since"

say "oms5: done $(date -Is); result in $out"
