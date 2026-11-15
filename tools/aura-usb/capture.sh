#!/bin/sh
# Send a Stage 2 to aura over USB and record its console output.
#
# Start this before restarting the Mac into Omarchy, with the USB-C cable in.
# It waits (no time limit) for aura's proxy, sends STAGE2 itself, and records
# 90 s of console output. aura only waits for a host when the ESP has an
# aura-proxy file at its root. See README.md.
#
#   AURA=/path/to/aura [PYTHON=python3] [OUT=file] capture.sh STAGE2.bin
#
# AURA is a checkout of aurora-silicon/aura; PYTHON needs pyserial and construct.
set -eu
STAGE2=$(realpath "${1:?usage: AURA=/path/to/aura capture.sh STAGE2.bin}")
: "${AURA:?set AURA to an aurora-silicon/aura checkout}"
PYTHON=$(command -v "${PYTHON:-python3}")
OUT=$(realpath -m "${OUT:-capture-$(date +%H%M).log}")
cd "$AURA/proxyclient"
sudo -v
echo "Waiting for the Mac... restart it now and choose Omarchy (Ctrl-C to give up)."
while :; do
  for d in /dev/ttyACM*; do [ -e "$d" ] && break 2; done
  sleep 0.2
done
echo "Found $d"
sleep 0.3
sudo AURADEVICE="$d" USE_CLANG=1 "$PYTHON" tools/chainload.py -r --vector-only \
  --capture "$OUT" --capture-seconds 90 "$STAGE2"
echo "Saved: $OUT"
