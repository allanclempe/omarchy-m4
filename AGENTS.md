# Omarchy on the MacBook Pro 16" M4 Max

This repo belongs to Allan Clempe (GitHub `allanclempe`), a member of the Omarchy M team, which
brings Omarchy (Arch Linux ARM + Hyprland) to Apple silicon Macs. The goal is an **official,
stable Omarchy release for the M4 Max**: MacBook Pro 16-inch, `Mac16,5`, board J616c, chip T6041.
Every M4 Mac is still refused by the public installer (omacom/omarchy-mac-installer).

As of 2026-11-14 one J616c runs Omarchy end to end: aura, U-Boot, Limine, Linux 7.3 on all 14 cores,
Aurora's GPU driver, Hyprland and Wi-Fi. It took several hand fixes. The week of 2026-11-16 is a
**soak test**: Allan uses the machine for real daily work, and we record how the OS behaves.

## Done means a clean reinstall

The build is done when a fresh install from it boots to a working desktop with **zero hand steps**:
no typed commands, no extra packages, no edits, through install, first boot and the first
`omarchy update`. OMS-14 is that acceptance run. So every fix found on the Mac goes into the build
(`tools/derive-j616c-image` or `patches/j616c-installer.patch`) as part of the same task, and gets a
row below. A task whose fix lives only on the Mac isn't done.

| Hand fix on the installed Mac | In the build | Task |
| --- | --- | --- |
| Stage 2 from aura `94d8e6e4` (ANS restart) written to the ESP | derivation pins it via `M1N1=` (not yet run) | OMS-14 |
| Unpadded Mach-O Stage 1 enrolled by hand in 1TR | installer patch: `macho-unpadded` mode for J616c (not yet built; Recovery's Swift checks still to run on macOS) | OMS-11 |
| `pacman-key --populate aurora` before owner setup | derivation drop-in (not yet run) | OMS-14 |
| fstab mounts `/boot/efi` by PARTUUID | no | OMS-12 |
| Aurora's `mesa-aurora` and `vulkan-aurora` installed | derivation (not yet run) | OMS-14 |
| `speakersafetyd-aurora-profiles` and Aurora's `aurora-audio` installed | derivation, PR #1 (not yet run); all nine audio checks pass on the Mac | OMS-1 |
| Update guards; Stage 2 trial disarmed | no | OMS-13 |
| WirePlumber state: raw mic route unmuted, hand-set default sink cleared | not needed if a fresh install starts unmuted; OMS-14 checks | OMS-9 |
| First attempt's partitions (disk0s7 to disk0s10) left on disk | removed before the reinstall | OMS-14 |

## Where things are

- `JOURNEY.md` is the running log and the single source of truth for what happened and why. Read
  section 9 onward before acting on the boot chain. Add new findings as the next numbered section
  (`### 9.N Title (date)`). Record corrections there, never by rewriting history.
- `j616c-boot-fix.html` is the team write-up: root causes, test log, asks per team.
- `tools/esp-overwrite-same-size.py` replaces a same-size file on an unmounted FAT ESP in place.
  macOS 26.7.3 on this Mac can't mount any FAT volume, so this is how Stage 2 got onto the ESP.
- `tools/derive-j616c-image` turns an edge image into the J616c image (Aurora's kernel, aura, U-Boot
  and Mesa, the pinned aura `94d8e6e4` Stage 2, the Aurora keyring drop-in). Its header has usage.
  It was edited after the last image build and hasn't been run since (JOURNEY 9.15).
- `patches/j616c-installer.patch` is the installer work: J616c developer admission, the
  Recovery boot modes for aura's Mach-O Stage 1 (`macho-unpadded`, which the J616c uses, and
  the padded `macho-ctxr`), the engine changes and the Wi-Fi `chflags` fix. Apply it to a
  checkout of omacom/omarchy-mac-installer at `a576543` (PR #212's head). Commit installer changes
  back into this patch, so the repo stays the source.
- `docs/aurora-package-audit.md` sorts every `[aurora]` package for this Mac: already used, a candidate
  for a report gap (and which task), Omarchy's own, left out, not for this Mac, or opt-in, and lists the
  name collisions `[aurora]` causes by being first. It also covers the kernel dependency
  (Aurora's 7.3 kernel; omacom/linux-aurora has no T604x support yet).
- `tools/aura-usb/` sends a Stage 2 to aura over the USB-C cable and captures its console. Its
  README has setup, steps and the one thing this path can't test.
- Build outputs (engine, payloads, signed catalog, app, package) are too large for the repo. They
  are rebuilt from the patch and the scripts above; JOURNEY section 8 records how.

## Machines

| Machine | Reach it | Role |
| --- | --- | --- |
| The M4 Max, macOS | `allanclempe@allans-macbook-pro` over SSH | Builds the engine, app and installer package (Xcode), and runs the Lima build VM `omarchy-builder` for the image |
| The M4 Max, Omarchy | `clempe@dev-machine-macos` over Tailscale | The system under test. No passwordless sudo; the ESP is root-only (`umask=0077`) |
| dev-machine-01 | local | Linux host on the other end of the USB-C cable for `tools/aura-usb/` |

The Mac is in one OS at a time, so only one of its two rows answers at once.

## The installed Mac: guards that must stay

The live boot depends on a Stage 2 built from aura `94d8e6e` (it has `aaec599f`, the post-M4 ANS
restart). No aura release has that fix yet: `1.0.0b13.1` lacks it. These guards keep updates from
putting the broken Stage 2 back. Keep them until an aura release contains `aaec599f` (JOURNEY 9.14):

- `M1N1_UPDATE_DISABLED=1` in `/etc/default/update-m1n1`: Aurora's hook no longer rebuilds Stage 2
  or arms Stage 2 trials.
- `IgnorePkg = m1n1-aurora linux-aurora mesa-aurora vulkan-aurora`: the kernel and its Mesa stay in
  step with the device tree inside the frozen Stage 2.
- `/etc/omarchy-mac-boot/owner-boot-chain`: Omarchy's update check only warns, because its boot
  check always fails on Aurora's `update-m1n1`. Its suggested fix
  (`mkinitcpio -P && update-m1n1 && omarchy-mac-boot-update`) rebuilds Stage 2: leave it unrun.

Known-good values: live `m1n1/boot-ctxr.bin` sha256 `a0f493b4…f552`; ESP `nvme0n1p4`,
PARTUUID `272043e7-ec24-4890-93d6-545cfbb8329b`; every Omarchy ESP has FAT serial `4F4D-5801`.

## Working rules

- Anything that writes to the Mac's disk, ESP, boot policy or 1TR needs Allan's approval first,
  with a backup and an undo path stated.
- Copy identifiers (PARTUUIDs, hashes, serials) from command output, character for character.
  Reading them off a photo produced a wrong PARTUUID once (JOURNEY 9.14).
- Commands Allan types on the Mac go in one block, read-only checks before writes, with the
  expected output stated.
- Nothing goes upstream (omacom, aurora-silicon) without Allan's go-ahead.
- Questions only the M team, Aurora or others can answer go in `docs/questions-for-the-team.md`,
  with enough context to ask them cold. Move a question to **Answered** when it's settled.
- Any commit or PR from this work says it was made with AI assistance (Aurora's contributing guide
  requires it).

## Tasks

Track work in **Clocktopus**, project **OMarchy Silicon**, task keys `OMS-<n>`. Create tasks there
with Clocktopus's `create_task`, not in Linear: this project declares no tracker prefixes. Name
branches after the key (`oms-12-short-title`) and use it as the commit scope (`fix(oms-12): …`) so
work is attributed.

## Soak test week

Baseline: the post-install test report,
https://omarchy-m-testing.org/reports/KkjcZekcyQ9BDAs9oYr7HoTn (omarchy-m-test 0.1.15,
2026-11-14): 47 pass, 0 fail, 12 gaps, 14 skips. GPU passes on Aurora's driver (OpenGL 4.6,
"Apple M4 Max (G16C B1)", glmark2 1074, vkmark 2897). The report's gaps are where to look first:

- Speakers: `speakersafetyd.service` failed, so there's no speaker DSP sink and the amps stay locked.
- Touch ID and SEP unavailable; ambient light sensor not read; keyboard light follows no sensor.
- Video: no hardware decode (VA-API fails; mpv decodes in software).
- Wi-Fi first join on 5 GHz didn't associate within 45 s of a driver reload.
- Unclaimed device-tree nodes (`apple,mesa-fingerprint`, `apple,t6041-display-power`) and a missing
  `rtl_nic/rtl8153b-2.fw` for a USB Ethernet adapter.
- `gpu.driver` and `gpu.vulkan` flag a missing *asahi* driver: the tool expects asahi, while this
  Mac runs Aurora's `aurora` driver, which works.

Log each soak-test observation in `JOURNEY.md` with date, what Allan was doing, and the evidence
(`journalctl`, `dmesg`, a re-run of the relevant `omarchy-m-test` check). Anything to fix becomes
an `OMS` task.
