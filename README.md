# Omarchy on the MacBook Pro 16" M4 Max (J616c)

Bringing [Omarchy](https://github.com/omacom/omarchy) (Arch Linux ARM and Hyprland) up on the
MacBook Pro 16-inch with M4 Max: Mac16,5, board J616c, chip T6041. One of these Macs runs Omarchy
end to end today, as a daily machine.

This is bring-up work, not a release. The public installer
([omacom/omarchy-mac-installer](https://github.com/omacom/omarchy-mac-installer)) doesn't offer any
M4 Mac yet, and nothing here is on Omarchy's stock edge channel. The goal is an official, stable
Omarchy release for this Mac. The bar for that: a fresh install from this build boots to a working
desktop with no hand steps, through install, first boot and the first `omarchy update`.

## Status (2026-11-15)

The machine: MacBook Pro 16" M4 Max, 14-core CPU (10 performance, 4 efficiency), 32-core GPU,
36 GB. It runs Aurora Silicon's `linux-aurora 7.3.0.aurora1-36`.

Hardware reports from [omarchy-m-test](https://omarchy-m-testing.org) 0.1.15, both on the first
install, which needed hand fixes:

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
- The camera at 1920x1080. The picture is much noisier than on macOS, even with the sensor tuning file loaded (`JOURNEY.md` 9.27, 9.37).
- The keyboard backlight.
- USB-C Ethernet adapters, with Arch's Realtek firmware.

**Gaps**
- Touch ID and the Secure Enclave.
- The ambient light sensor. It's disabled in this kernel build's device tree. Aurora enabled it in
  [`5b192f8d`](https://github.com/aurora-silicon/linux/commit/5b192f8d), after this build was made.
- Hardware video decode: video plays, but decoded in software.
- A few device-tree nodes with no driver, such as the fingerprint sensor.
- The report's `gpu.driver` and `gpu.vulkan` gaps are the test tool's: it only knows the `asahi`
  driver, and this Mac's GPU runs on Aurora's `aurora` driver.

## How it boots

```
aura Stage 1 (Mach-O, enrolled in 1TR)
  → aura Stage 2 (m1n1/boot-ctxr.bin on the ESP)
    → U-Boot → Limine → linux-aurora 7.3 (unified kernel image)
```

The kernel, aura, U-Boot, Mesa and the audio packages come from Aurora Silicon's `[aurora]`
repository. Stage 2 is built from aura main at `94d8e6e4`, because no aura release yet has the
fix this Mac needs (below). Updates rebuild Stage 2 from that pinned build, and Aurora's trial
boot tries each rebuild once before committing it.

## Findings that may help other M4 Pro and Max Macs

1. **The SSD controller after Stage 1.** aura releases up to `1.0.0b13.1` leave the post-M4 SSD
   controller (ANS) powered off after Stage 1, so U-Boot finds no NVMe and stops at its `=>`
   prompt. aura
   [`aaec599f`](https://github.com/aurora-silicon/aura/commit/aaec599f) starts it again, and it's
   on aura main.
2. **Padded vs unpadded Stage 1.** On the T6041, aura's Mach-O Stage 1 padded to the 128 MiB
   execute window reboots silently every ~10 s, before aura shows anything. The same object
   unpadded boots fine.
3. **Shared identifiers.** Every Omarchy install gives its ESP the same FAT serial (`4F4D-5801`)
   and its Boot partition the same UUID. On a Mac with a partition left over from an earlier
   attempt, Linux can mount the wrong one, and boot updates then land where the Mac never reads
   them. The image here mounts both by the partition aura says it booted from.

## What's here

| Path | What it is |
| --- | --- |
| [`JOURNEY.md`](JOURNEY.md) | The running log: what was tried, what broke and why, with the evidence. Start at section 9. |
| [`j616c-boot-fix.html`](j616c-boot-fix.html) | The write-up for the Omarchy and Aurora teams: root causes, test log, asks per team. |
| [`tools/derive-j616c-image`](tools/derive-j616c-image) | Turns an Omarchy edge image into the J616c image: Aurora's boot chain, kernel, Mesa and audio, and the pinned Stage 2. Usage is in its header. |
| [`patches/j616c-installer.patch`](patches/j616c-installer.patch) | Installer changes: J616c admission, the Mach-O Stage 1 modes, and a Wi-Fi collection fix. Applies to omacom/omarchy-mac-installer at `a576543`. |
| [`tools/image/`](tools/image) | Files the derivation installs into the image: a systemd generator that mounts `/boot/efi` and `/boot` from the install the Mac booted, and a drop-in that counts the Stage 2 trial guard from disk unlock. |
| [`tools/tests/`](tools/tests) | Tests for those files. Plain Bash; run them as a normal user on Linux. |
| [`tools/aura-usb/`](tools/aura-usb) | Sends a Stage 2 to aura over a USB-C cable and records its console, without touching the Mac's disk. |
| [`tools/wifi-reload-timing.sh`](tools/wifi-reload-timing.sh) | Times Wi-Fi's rejoin after a driver reload, with and without turning the radio off first. Run it at the Mac. |
| [`tools/esp-overwrite-same-size.py`](tools/esp-overwrite-same-size.py) | Replaces a same-size file on an unmounted FAT ESP, for when macOS can't mount it (macOS 26.7.3 on this Mac couldn't). |

Still in review: a patch teaching Omarchy's boot check to verify Aurora's Stage 2, and an audit of
Aurora's packages for this Mac.

## Building

There is no ready-made image to download. The image is rebuilt from this repo:

1. Build an Omarchy edge image with omarchy-mac-installer's image builder.
2. Build the Stage 2 from aura `94d8e6e4`, then run `tools/derive-j616c-image` on an aarch64
   Linux host with Docker. Its header lists the inputs.
3. Build the installer from `patches/j616c-installer.patch`. Its Recovery app needs macOS and
   Xcode.

`JOURNEY.md` section 8 records each step as it was done.

**Before you try it on your own Mac:** this changes the Mac's boot policy in 1TR (One True
Recovery) and writes new partitions. A mistake can leave the Mac needing a restore from another
Mac. Back up first, and read `JOURNEY.md` section 9 to see what went wrong here.

## Thanks

- [Aurora Silicon](https://github.com/aurora-silicon) for the kernel, aura, U-Boot, Mesa and audio
  work this stands on.
- The T6041/J616c GPU bring-up, in
  [aurora-silicon/mesa#85](https://github.com/aurora-silicon/mesa/pull/85) and
  [aurora-silicon/linux#525](https://github.com/aurora-silicon/linux/pull/525).
- M4 Wi-Fi collection in the installer,
  [omacom/omarchy-mac-installer#212](https://github.com/omacom/omarchy-mac-installer/pull/212).
- Omarchy and its Apple silicon team.

This work was done with AI assistance (Claude Code).

## License

MIT, see [`LICENSE`](LICENSE). The patches in `patches/` change other projects and stay under
those projects' licenses.
