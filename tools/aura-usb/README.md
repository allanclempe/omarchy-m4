# Sending a Stage 2 to the Mac over USB

`capture.sh` runs on a Linux machine connected to the Mac by a USB-C data cable. When aura's Stage 1
waits for a host, the script sends it a Stage 2 from memory, so nothing on the Mac's disk changes,
and records the console output until USB drops at the handover.

Setup, once:

- A checkout of [aurora-silicon/aura](https://github.com/aurora-silicon/aura). The runs in
  `JOURNEY.md` used `94d8e6e`.
- A Python with `pyserial` and `construct`, passed as `PYTHON`, and `clang` (`USE_CLANG=1` builds
  the copy stub).
- An `aura-proxy` file at the root of the Mac's ESP. Stage 1 then waits 15 s for a host at each
  boot. Without a host it carries on and loads Stage 2 from the ESP as usual.

Each run:

1. Plug the cable into the same Mac port as before; aura's proxy only answers on that one.
2. `AURA=/path/to/aura PYTHON=/path/to/venv/bin/python tools/aura-usb/capture.sh STAGE2.bin`,
   enter the sudo password, wait for "Waiting for the Mac...".
3. Restart the Mac, hold the power button, choose Omarchy.
4. The script prints "Found /dev/ttyACM0", sends the file and saves `capture-HHMM.log` after
   "Valid payload found". What follows the handover is only on the Mac's screen.

This path can't test the SSD hand-off. With `aura-proxy` present, Stage 1 powers ANS off before
waiting, and `chainload.py` doesn't pass the `nvme.sart=` entries Stage 2 needs to restart it
(JOURNEY 9.8). Test Stage 2 changes that touch ANS from the ESP instead, with
`tools/esp-overwrite-same-size.py`.
