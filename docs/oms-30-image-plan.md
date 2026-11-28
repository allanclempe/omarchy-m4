# OMS-30 image: what goes in

The image for the J616c reinstall on **macOS 27.2 (26B123)** stub firmware. Done means what
AGENTS.md says: a fresh install that boots to a working desktop with zero hand steps, through the
first `omarchy update`. Checked 2026-11-27 against the repositories as published that day.

## The decision: build on omacom's edge stack

The acceptance image (OMS-14) puts `[aurora]` first and takes the kernel, aura, U-Boot, Mesa and
audio from Aurora. That can't carry 27.2:

| | Aurora `linux-aurora 7.3.0.aurora1-41` (`9125b314`) | omacom edge `linux-aurora 7.3.0.aurora1-1` (`3058cc5c`) |
| --- | --- | --- |
| aurora-silicon/linux#1954 (27.2 firmware on the J616c), merge `7f01c9e1` | no | yes |
| aurora-silicon/linux#2233 (the camera's computed noise filter, OMS-45), merge `51b75cb5` | no | yes |
| `t6041-j616c.dtb` | yes | yes |
| #2233's `isp_setfile_snf_radial` in `apple-isp.ko` | no (136 `isp_` symbols, none of #2233's) | yes |
| `user4k` (OMS-41) and the CTXR execute window | yes | yes, compiled in (strings in the package's `vmlinuz`) |

The two stacks don't mix. Aurora's `aura 1.0.0b14.1` needs `aurora-ctxr-execmem`, which only
Aurora's kernel declares (pacman on the Mac refuses edge's kernel alongside it), and edge's `aura`
and `omarchy-mac-boot` need omacom's `aurora-scripts`, which replaces Aurora's `asahi-scripts`.
omarchy-mac-installer#224 (merged) already builds images `[omarchy]` first. So the OMS-30 image
takes the platform from `[omarchy]` edge and keeps our own pieces only where edge lacks something.

## What goes in

| Piece | Source and version | Covers | Notes |
| --- | --- | --- | --- |
| Kernel | `[omarchy]` `linux-aurora 7.3.0.aurora1-1` | OMS-30, OMS-45 | Replaces Aurora's kernel pin |
| Mesa, Vulkan | `[omarchy]` `mesa-aurora 1:26.3.0_devel.20261122.232644.e705eca833f-1` and its `vulkan-aurora` | GPU | The edge kernel conflicts with anything older than `20261120` (omarchy-pkgs#3282) |
| Stage 2 | built from aura **`v1.0.0b17`** (`5a244b5b`), named by `M1N1=` in `/etc/default/update-m1n1` | OMS-30 | Contains aura#265 (merge `7680e35a`) and 205 commits past `b14.1`, among them the M4 GPU hand-off and internal DCP clocks on 27.2. Edge's `aura 1.0.0b13.r20261118` is built from omacom/m1n1 `703a0a92` (2026-11-18), which predates #265. Replaces the `94d8e6e4` pin (OMS-25) |
| Stage 1 | aura's raw Stage 1 from the same `v1.0.0b17` build, `raw-ctxr` mode | OMS-24 | Built with Stage 2, so the two match |
| Boot scripts | `[omarchy]` `aurora-scripts 20261023-2`, `omarchy-mac-boot 20261123-1` (carries omarchy-mac-pkgs#150) | OMS-37, OMS-13 | Nothing left for the first update to replace. After a kernel or U-Boot change, omarchy-mac-boot's `omarchy-mac-boot-ctxr` hook rebuilds `m1n1/boot-ctxr.bin` with the stock `update-m1n1`, which honours `M1N1=`, held to aura's 16 MiB slot, keeping `.old`. Its boot check reads the same `M1N1=` and verifies Stage 2, so the image ships no `owner-boot-chain` marker. No Aurora Stage 2 trial |
| U-Boot | `[omarchy]` `uboot-aurora 2026.07.aurora9-1` | boot | Has the `apple,t6041` nodes; Aurora's is `aurora11`. See open question 3 |
| Touch ID | `[omarchy]` `omarchy-mac 0.2.7-2` (#140, #160) and `libfprint-git 1:1.94.100.r10.g6f9479c-6` | OMS-2, OMS-27, OMS-28 | Replaces the natively built pins on the OMS-28 branch; #160 sets the xART guard |
| Audio | `[omarchy]` `aurora-audio 4.1.aurora3-6`, `alsa-ucm-conf-aurora 10.aurora3-2`, `speakersafetyd 2.0.1-2`, plus `tools/image/96-speakersafetyd-j616.rules` | OMS-1 | The J616 `graph.json`, `mic.json` and the speaker safety profile `j616.conf` hash the same as the working set on the soak-test Mac. New: a WirePlumber `99-asahi-j616.conf`. speakersafetyd's own udev rule lists no `AppleJ616`, so without the rule the daemon never starts and the amps stay locked; Aurora's `speakersafetyd-aurora-profiles` carried the same line. Drops that package and the `alsa-utils-aurora` swap |
| PipeWire | Arch `[extra]` | OMS-38 | With `[aurora]` no longer first, Arch's `spandsp` 3 rebuild comes through |
| VA-API | `[omarchy]` `libva-v4l2_request-avd 1.3.r11.r169.gc653eaa-2` | OMS-4 | Now ships `aurora_drv_video.so`; the swap for Aurora's build is no longer needed |
| Camera tuning | installer, as now | OMS-22 | The noise filter comes with the kernel |
| x86 containers | the `PKGS` input: `qemu-user-static` and `-binfmt` `1:11.1.3-1` from the OMS-41 branch (omarchy-pkgs #3505, #3602, #3603 merged; all three still open upstream) and Aurora's `aurora-userpages 7.3.0.aurora1-41`, each pinned by sha256; the containerd `userpages 4k` drop-in | OMS-41 | `aurora-userpages` depends on `glibc` alone and ships a `user4k=on` GRUB drop-in; omarchy-mac-boot's setup adds `user4k=on` on `linux-aurora` too. The derivation requires both. The edge kernel has `user4k` compiled in |
| ESP mount, USB Ethernet firmware, keyring | as now | OMS-12, OMS-7 | Unchanged |
| App version | scripted, not passed by hand | OMS-14 | |

Firmware admission: the payload's `installer_data.json` stays the builder's own (`13.5`, `14.8.3`,
`26.5.1`, `26.6.2`), since `mac-image-check payload` holds it to exactly that. The J616c is offered
27.2 by the developer catalog's per-model `installer_data-j616c.json`, whose `supported_fw` is
`["27.2"]` alone. `patches/j616c-installer.patch` is rebased
onto the installer's main `e0aa53fd` and offers the J616c only the 27.2 (26B123) stub (JOURNEY 9.57).
Before building the installer: build and test its Swift and Recovery parts on the Mac, rebuild the
engine archive, and check that a 27.x stub fits the 6 GB stub size.

## What stays out

- `aurora-camera-denoise` (OMS-33), the PipeWire temporal filter: not started. This is not the
  kernel's noise filter from linux#2233, which is in, with the edge kernel.
- The echo canceller (OMS-44): parked, with review findings open.
- The Touch ID re-arm (OMS-40): `aurora-touchid-rearm` is in `[omarchy]`, but its PAM line has no
  durable place yet.
- Docker's `containerd-snapshotter: false`: left out to find out whether containers need it.
- The lock screen work (OMS-36): reaches the Mac through upstream Omarchy.
- `[aurora]` as a pacman repository: nothing in the list above needs it at install or update.

## Open questions, before building

1. **Settled: Stage 2 updates after install.** Edge's omarchy-mac-boot keeps
   `m1n1/boot-ctxr.bin` current itself (`omarchy-mac-boot-ctxr`), with every device tree rather
   than the J616c's alone, as Aurora's `bootchain.py` did. The 16 MiB check guards the size.
2. **Edge's `aura` package.** Nothing rebuilds Stage 2 from the package while `M1N1=` is set, so
   the pin holds. Ask omacom to move the package past aura#265 (`7680e35a`) and the M4 27.2
   hand-off, so the pin can go.
3. **U-Boot.** Edge's `aurora9` against Aurora's `aurora11`, which the acceptance install boots.
   Check the J616c boots with edge's.
4. **Update safety without Aurora's trial** (OMS-13): a bad Stage 2 after an update has no
   automatic fallback; `boot-ctxr.bin.old` stays beside it for a recovery by hand. Accepted for
   this test unless Allan says otherwise.
5. **macOS build.** Apple has released 27.2.1 (26B131), and aura#265 refuses 27.2.1's display
   firmware. The installer pins the stub's IPSW to 27.2 (26B123), whatever version macOS itself
   runs. Settle whether the system can run 27.2.1 over a 27.2 stub, or should stay on 27.2.
6. **`libfprint-git` against Arch's `libfprint`.** If the edge image already has `libfprint`, the
   pinned install may stop on the conflict; the derivation's `pacman.log` will show it.

## Before the reinstall

Back up home; remove the current install by hand (OMS-23); update macOS from 26.7.3 to 27.2;
check the internal panel, GPU, AOP (light sensor) and ANE, plus external displays if one is at
hand. Log the run in `JOURNEY.md`.
