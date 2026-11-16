# Omarchy on the MacBook Pro 16" M4 Max

This repo belongs to Allan Clempe (GitHub `allanclempe`), a member of the Omarchy M team, which
brings Omarchy (Arch Linux ARM + Hyprland) to Apple silicon Macs. The goal is an **official,
stable Omarchy release for the M4 Max**: MacBook Pro 16-inch, `Mac16,5`, board J616c, chip T6041.
Every M4 Mac is still refused by the public installer (omacom/omarchy-mac-installer).

As of 2026-11-16 one J616c runs Omarchy installed from the OMS-24 build with **zero hand steps**
(JOURNEY 9.35): aura's raw Stage 1 enrolled by the installer, U-Boot, Limine, Linux 7.3 on all 14
cores, Aurora's GPU driver, Hyprland, Wi-Fi, the camera (its tuning loads, but the picture stays noisier than on macOS, JOURNEY 9.37) and the light sensor. The week of 2026-11-16 is a
**soak test**: Allan uses the machine for real daily work, and we record how the OS behaves.

## Done means a clean reinstall

The build is done when a fresh install from it boots to a working desktop with **zero hand steps**:
no typed commands, no extra packages, no edits, through install, first boot and the first
`omarchy update`. OMS-14 is that acceptance run. So every fix found on the Mac goes into the build
(`tools/derive-j616c-image` or `patches/j616c-installer.patch`) as part of the same task, and gets a
row below. A task whose fix lives only on the Mac isn't done.

| Hand fix on the installed Mac | In the build | Task |
| --- | --- | --- |
| Stage 2 from aura `94d8e6e4` (ANS restart) written to the ESP | derivation pins it via `M1N1=` (run 2026-11-16); the pin is unnecessary, b13.1 has the fix | OMS-25 |
| Unpadded Mach-O Stage 1 enrolled by hand in 1TR | installer patch: `macho-unpadded` mode (built and installed 2026-11-16); Stage 2 refuses it on a fresh install, see the raw row | OMS-11 |
| `pacman-key --populate aurora` before owner setup | derivation drop-in (not yet run) | OMS-14 |
| fstab mounts `/boot/efi` by PARTUUID | derivation installs `omarchy-esp-generator`, which mounts the device-tree ESP (not yet run) | OMS-12 |
| Aurora's `mesa-aurora` and `vulkan-aurora` installed | derivation (not yet run) | OMS-14 |
| `speakersafetyd-aurora-profiles` and Aurora's `aurora-audio` installed | derivation, PR #1 (not yet run); all nine audio checks pass on the Mac | OMS-1 |
| Arch's `alsa-utils` swapped for Aurora's `alsa-utils-aurora` (pacman asked when installing Aurora's audio) | derivation removes `alsa-utils` and installs `alsa-utils-aurora`, pinned; found by the first run of the audio step (2026-11-16) | OMS-14 |
| Update guards; Stage 2 trial disarmed | derivation: Stage 2 rebuilt from the pin, tried once by Aurora's trial, `owner-boot-chain` marker; kernel and Mesa update (not yet run) | OMS-13 |
| WirePlumber state: raw mic route unmuted, hand-set default sink cleared | not needed if a fresh install starts unmuted; OMS-14 checks | OMS-9 |
| `linux-firmware-realtek` installed (USB Ethernet firmware) | derivation, PR #12 (not yet run) | OMS-7 |
| First attempt's partitions (disk0s7 to disk0s10) left on disk | removed before the reinstall | OMS-14 |
| An earlier install removed by hand with `diskutil` before reinstalling (the app refuses M4 installs) | no: the app's removal check must learn aura's boot object | OMS-23 |
| Raw Stage 1 enrolled by hand after `bputil -nc` (the build's `macho-unpadded` object is refused by Stage 2) | installer patch: `raw-ctxr` mode for J616c; the installer enrolled it on the acceptance install (JOURNEY 9.35) | OMS-24 |
| App version set above the installed app (the package otherwise keeps the old app) | `OMARCHY_APP_VERSION` passed by hand at build time; not in a script yet | OMS-14 |
| Camera setfile `isp_2224_01XX.dat` | installer patch: the engine collects it on every Mac; installed and loading on the acceptance install (JOURNEY 9.35) | OMS-22 |

## Where things are

- `JOURNEY.md` is the running log and the single source of truth for what happened and why. Read
  section 9 onward before acting on the boot chain. Add new findings as the next numbered section
  (`### 9.N Title (date)`). Record corrections there, never by rewriting history.
- `j616c-boot-fix.html` is the team write-up: root causes, test log, asks per team.
- `tools/wifi-reload-timing.sh` times Wi-Fi's rejoin after a `brcmfmac` reload, plain and with the
  radio off first, and reports whether the unload race hit (JOURNEY 9.26). Run it at the Mac with sudo.
- `tools/esp-overwrite-same-size.py` replaces a same-size file on an unmounted FAT ESP in place.
  macOS 26.7.3 on this Mac can't mount any FAT volume, so this is how Stage 2 got onto the ESP.
- `tools/derive-j616c-image` turns an edge image into the J616c image (Aurora's kernel, aura, U-Boot
  and Mesa, the pinned aura `94d8e6e4` Stage 2, the Aurora keyring drop-in, and the update policy:
  Stage 2 rebuilt from the pin and tried by Aurora's trials). Its header has usage.
  It was edited after the last image build and hasn't been run since (JOURNEY 9.15).
- `patches/j616c-installer.patch` is the installer work: J616c developer admission, the
  Recovery boot modes for aura's Mach-O Stage 1 (`macho-unpadded`, which the J616c uses, and
  the padded `macho-ctxr`), the engine changes and the Wi-Fi `chflags` fix. Apply it to a
  checkout of omacom/omarchy-mac-installer at `a576543` (PR #212's head). Commit installer changes
  back into this patch, so the repo stays the source.
- `tools/image/` holds files the derivation installs into the image, such as `omarchy-esp-generator`;
  `tools/tests/` has their tests (plain Bash, run on Linux).
- `LICENSE` is MIT for this repo's own work. The patches in `patches/` change other projects and
  stay under those projects' licenses (omacom's repos are MIT, as is asahi-scripts).
- `docs/aurora-package-audit.md` sorts every `[aurora]` package for this Mac: already used, a candidate
  for a report gap (and which task), Omarchy's own, left out, not for this Mac, or opt-in, and lists the
  name collisions `[aurora]` causes by being first. It also covers the kernel dependency
  (Aurora's 7.3 kernel, until omacom's 7.3 carries the J616c).
- `tools/aura-usb/` sends a Stage 2 to aura over the USB-C cable and captures its console. Its
  README has setup, steps and the one thing this path can't test.
- Build outputs (engine, payloads, signed catalog, app, package) are too large for the repo. They
  are rebuilt from the patch and the scripts above; JOURNEY section 8 records how.

## Machines

| Machine | Reach it | Role |
| --- | --- | --- |
| The M4 Max, macOS | `allanclempe@allans-macbook-pro` over SSH | Builds the engine, app and installer package (Xcode), and runs the Lima build VM `omarchy-builder` for the image |
| The M4 Max, Omarchy | `clempe@dev-machine-mac-1` over Tailscale SSH (the name changes with each fresh install) | The system under test. No passwordless sudo; the ESP is root-only (`umask=0077`) |
| dev-machine-01 | local | Linux host on the other end of the USB-C cable for `tools/aura-usb/` |

The Mac is in one OS at a time, so only one of its two rows answers at once.

## The installed Mac (acceptance install, 2026-11-16)

Installed from `build/oms24/Omarchy-J616c-Developer.pkg` (app 2.3.18) with no hand step
(JOURNEY 9.35). The installer enrolled **aura's raw Stage 1** in `raw-ctxr` mode (`bputil -nc`,
`kmutil --raw`), loading the confined Stage 2 `m1n1/boot-ctxr.bin`. The image's own update policy
applies: Stage 2 rebuilt from the pinned aura `94d8e6e4` (`M1N1=` in `/etc/default/update-m1n1`),
tried once by Aurora's trial, `IgnorePkg = m1n1-aurora` only, and
`/etc/omarchy-mac-boot/owner-boot-chain`. No hand guards. The pin is unnecessary: aura `1.0.0b13.1`
carries the ANS fix (9.31, OMS-25).

Known-good values: ESP `nvme0n1p4`, PARTUUID `b2e659a5-fd54-454e-a7bf-75a3fa15d04a`; Boot
`nvme0n1p5`, PARTUUID `9d4a6c2a-2925-4563-ad03-c63c37147581`; camera setfile
`isp_2224_01XX.dat` sha256 `dce21e48ccd35f54…`. Every Omarchy ESP has FAT serial `4F4D-5801`.

## Working rules

- **This repo is public.** Anyone can read every file, every commit on every branch, and every
  PR's text, and a commit stays in the history after the file is changed. Keep out of all of
  them: Wi-Fi network names (write "a home mesh network"), addresses on the home network, where
  Allan lives, device serial numbers, credentials and tokens, other people's private details, and
  anything from the team's private Basecamp beyond what its authors made public. If something
  private gets committed, stop and tell Allan: taking it out means rewriting history (OMS-21).
- Anything that writes to the Mac's disk, ESP, boot policy or 1TR needs Allan's approval first,
  with a backup and an undo path stated.
- Copy identifiers (PARTUUIDs, hashes, serials) from command output, character for character.
  Reading them off a photo produced a wrong PARTUUID once (JOURNEY 9.14).
- Commands Allan types on the Mac go in one block, read-only checks before writes, with the
  expected output stated.
- Nothing goes upstream (omacom, aurora-silicon) without Allan's go-ahead.
- Questions only the M team, Aurora or others can answer go in `docs/questions-for-the-team.md`,
  with enough context to ask them cold. Move a question to **Answered** when it's settled. That
  file sums up private team discussion, so it stays on this machine: `.gitignore` excludes it.
  Never commit it, and don't quote it in public files.
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
