# Omarchy on the MacBook Pro 16" M4 Max (J616c)

Bringing [Omarchy](https://github.com/omacom/omarchy) (Arch Linux ARM and Hyprland) up on the
MacBook Pro 16-inch with M4 Max: Mac16,5, board J616c, chip T6041. One of these Macs runs Omarchy
end to end today, as a daily machine, installed from this build.

This is bring-up work, not a release. The public installer
([omacom/omarchy-mac-installer](https://github.com/omacom/omarchy-mac-installer)) doesn't offer any
M4 Mac yet, and nothing here is on Omarchy's stock edge channel. The goal is an official, stable
Omarchy release for this Mac. The bar for that: a fresh install from this build boots to a working
desktop with no hand steps, through install, first boot and the first `omarchy update`.

## Status (2026-11-16)

**The build meets that bar.** A clean install on 2026-11-16 needed no typed command, edit or extra
package, from the installer through 1TR, first boot and owner setup to the first `omarchy update`
(`JOURNEY.md` 9.35).

The machine: MacBook Pro 16" M4 Max, 14-core CPU (10 performance, 4 efficiency), 32-core GPU,
36 GB. It runs Aurora Silicon's `linux-aurora 7.3.0.aurora1-40`.

Hardware reports from [omarchy-m-test](https://omarchy-m-testing.org) 0.1.15, both on the first
install, which needed hand fixes. A report from the clean install is next.

| Report | Pass | Gaps | Skipped |
| --- | --- | --- | --- |
| [2026-11-15](https://omarchy-m-testing.org/reports/7McWSfw9veTfcjWN7SWtUoGu) | 50 | 6 | 17 |
| [2026-11-14](https://omarchy-m-testing.org/reports/KkjcZekcyQ9BDAs9oYr7HoTn), right after install | 47 | 12 | 14 |

**Works**
- All 14 CPU cores.
- The GPU, on Aurora's `aurora` driver: OpenGL 4.6, glmark2 1074, vkmark 2897.
- The Hyprland desktop.
- Speakers and microphones, with Aurora's J616 speaker profiles and DSP graphs.
- Wi-Fi: it rejoins in about 2.5 s after a driver reload.
- The ambient light sensor, with the `-40` kernel.
- The camera at 1920x1080. The picture is much noisier than on macOS, even with the sensor tuning
  loaded (`JOURNEY.md` 9.27, 9.37).
- The keyboard backlight.
- USB-C Ethernet adapters, with Arch's Realtek firmware.

**Gaps**
- Touch ID and the Secure Enclave.
- Hardware video decode: video plays, but decoded in software.
- The keyboard backlight doesn't follow the light sensor yet.
- A few device-tree nodes with no driver, such as the fingerprint sensor.
- The report's `gpu.driver` and `gpu.vulkan` gaps are the test tool's: it only knows the `asahi`
  driver, and this Mac's GPU runs on Aurora's `aurora` driver.

## How it boots

```
aura Stage 1 (raw image, enrolled in 1TR after bputil -nc)
  → aura Stage 2 (m1n1/boot-ctxr.bin on the ESP)
    → U-Boot → Limine → linux-aurora 7.3 (unified kernel image)
```

The installer enrols Stage 1 itself, in a `raw-ctxr` mode that `patches/j616c-installer.patch`
adds. The kernel, aura, U-Boot, Mesa and the audio packages come from Aurora Silicon's `[aurora]`
repository, pinned to exact builds. Stage 2 is built from aura main at `94d8e6e4`. That pin is no
longer needed, since the packaged aura `1.0.0b13.1` carries the same fix (below), and it goes next.
Updates rebuild Stage 2, and Aurora's trial boot tries each rebuild once before committing it.

## Findings that may help other M4 Pro and Max Macs

1. **The SSD controller after Stage 1.** aura releases before `1.0.0b13.1` leave the post-M4 SSD
   controller (ANS) powered off after Stage 1, so U-Boot finds no NVMe and stops at its `=>`
   prompt. aura `1.0.0b13.1` starts it again, with `564efba5`, the same diff as
   [`aaec599f`](https://github.com/aurora-silicon/aura/commit/aaec599f) on aura main.
2. **Which Stage 1 boots.** On the T6041, aura's Mach-O Stage 1 padded to the 128 MiB execute
   window reboots silently every ~10 s, before aura shows anything. Aurora's own padding tool
   makes the identical object. Unpadded, it arms too small a window, and aura's Stage 2 refuses to
   start the OS on a fresh install, as aura's docs say. What boots is aura's raw Stage 1, enrolled
   after `bputil -nc` (Kernel CTRR off), with all 14 cores. It gives up the execute window: no
   hibernation layout and none of aura's EL2 features.
3. **Shared identifiers.** Every Omarchy install gives its ESP the same FAT serial (`4F4D-5801`)
   and its Boot partition the same UUID. On a Mac with a partition left over from an earlier
   attempt, Linux can mount the wrong one, and boot updates then land where the Mac never reads
   them. The image here mounts both by the partition aura says it booted from. Reported in
   [omacom/omarchy-mac-installer#219](https://github.com/omacom/omarchy-mac-installer/issues/219).
4. **Omarchy's boot check and Aurora's Stage 2.** omarchy-mac-boot's boot check rebuilds Stage 2
   the stock way, so it fails on every Mac with Aurora's `update-m1n1`. The patch here asks
   Aurora's `bootchain.py` for the image instead. Sent upstream as
   [omacom/omarchy-mac-pkgs#150](https://github.com/omacom/omarchy-mac-pkgs/pull/150).

## What's here

| Path | What it is |
| --- | --- |
| [`JOURNEY.md`](JOURNEY.md) | The running log: what was tried, what broke and why, with the evidence. Start at section 9. |
| [`j616c-boot-fix.html`](j616c-boot-fix.html) | The write-up for the Omarchy and Aurora teams: root causes, test log, asks per team. |
| [`tools/derive-j616c-image`](tools/derive-j616c-image) | Turns an Omarchy edge image into the J616c image: Aurora's boot chain, kernel, Mesa and audio at pinned builds, Touch ID's packages, and the update policy. Usage is in its header. |
| [`tools/build-touchid-packages`](tools/build-touchid-packages) | Builds the two packages that give the image Touch ID (omarchy-mac with the J616c support, and a libfprint-git for SEP interface v5), which the derivation pins by sha256. |
| [`patches/j616c-installer.patch`](patches/j616c-installer.patch) | Installer changes: J616c admission, the `raw-ctxr` Stage 1 mode the J616c uses (and two Mach-O modes), camera tuning collection on every Mac, and a Wi-Fi collection fix. Applies to omacom/omarchy-mac-installer at `a576543`. |
| [`patches/omarchy-mac-boot-aurora.patch`](patches/omarchy-mac-boot-aurora.patch) | Teaches omarchy-mac-boot's boot check Aurora's Stage 2 (upstream as omacom/omarchy-mac-pkgs#150). [`patches/README.md`](patches/README.md) gives each patch's base and how to test it. |
| [`docs/aurora-package-audit.md`](docs/aurora-package-audit.md) | Every `[aurora]` package sorted for this Mac: used, a candidate for a gap, left out, or not for this Mac. |
| [`tools/image/`](tools/image) | Files the derivation installs into the image: a systemd generator that mounts `/boot/efi` and `/boot` from the install the Mac booted, and a drop-in that counts the Stage 2 trial guard from disk unlock. |
| [`tools/tests/`](tools/tests) | Tests for those files. Plain Bash; run them as a normal user on Linux. |
| [`tools/aura-usb/`](tools/aura-usb) | Sends a Stage 2 to aura over a USB-C cable and records its console, without touching the Mac's disk. |
| [`tools/wifi-reload-timing.sh`](tools/wifi-reload-timing.sh) | Times Wi-Fi's rejoin after a driver reload, with and without turning the radio off first. Run it at the Mac. |
| [`tools/esp-overwrite-same-size.py`](tools/esp-overwrite-same-size.py) | Replaces a same-size file on an unmounted FAT ESP, for when macOS can't mount it (macOS 26.7.3 on this Mac couldn't). |

## Building

There is no ready-made image to download. The image is rebuilt from this repo:

1. Build an Omarchy edge image with omarchy-mac-installer's image builder.
2. Build the Stage 2 from aura `94d8e6e4`. Get the two Touch ID packages the derivation pins
   (`TOUCHID_PINS`): the files built for it, since a rebuild gives new sha256s and means
   re-pinning (`tools/build-touchid-packages`). Then run `tools/derive-j616c-image` on an aarch64
   Linux host with Docker. Its header lists the inputs.
3. Build the installer from `patches/j616c-installer.patch`. Its Recovery app needs macOS and
   Xcode. Set `OMARCHY_APP_VERSION` above the app already installed, or the package keeps the old
   app.

`JOURNEY.md` sections 8, 9.29 and 9.34 record each step as it was done.

**Before you try it on your own Mac:** this changes the Mac's boot policy in 1TR (One True
Recovery), turns Kernel CTRR off for the Omarchy install, and writes new partitions. A mistake can
leave the Mac needing a restore from another Mac. Back up first, and read `JOURNEY.md` section 9 to
see what went wrong here. The app can't remove an M4 install yet; it was removed by hand with
`diskutil` here.

## License

MIT, see [`LICENSE`](LICENSE). The patches in `patches/` change other projects and stay under
those projects' licenses.
