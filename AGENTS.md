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
| `pacman-key --populate aurora` before owner setup | derivation drop-in; owner setup needed no `pacman-key` on the acceptance install (JOURNEY 9.32) | OMS-14 |
| fstab mounts `/boot/efi` by PARTUUID | derivation installs `omarchy-esp-generator`, which mounts the device-tree ESP; works on the acceptance install (JOURNEY 9.35) | OMS-12 |
| Aurora's `mesa-aurora` and `vulkan-aurora` installed | derivation, pinned; on the acceptance install (JOURNEY 9.35) | OMS-14 |
| `speakersafetyd-aurora-profiles` and Aurora's `aurora-audio` installed | derivation; on the acceptance install (JOURNEY 9.32, 9.35) | OMS-1 |
| Arch's `alsa-utils` swapped for Aurora's `alsa-utils-aurora` (pacman asked when installing Aurora's audio) | derivation removes `alsa-utils` and installs `alsa-utils-aurora`, pinned; found by the first run of the audio step (2026-11-16) | OMS-14 |
| Update guards; Stage 2 trial disarmed | derivation: Stage 2 rebuilt from the pin, tried once by Aurora's trial, `owner-boot-chain` marker; in the build and enabled on the acceptance install; the trial path is still unexercised, as no boot-chain update has come (JOURNEY 9.33) | OMS-13 |
| WirePlumber state: raw mic route unmuted, hand-set default sink cleared | not needed if a fresh install starts unmuted; OMS-14 checks | OMS-9 |
| `linux-firmware-realtek` installed (USB Ethernet firmware) | derivation; on the acceptance install (JOURNEY 9.32) | OMS-7 |
| First attempt's partitions (disk0s7 to disk0s10) left on disk | removed before the reinstall | OMS-14 |
| An earlier install removed by hand with `diskutil` before reinstalling (the app refuses M4 installs) | no: the app's removal check must learn aura's boot object | OMS-23 |
| Raw Stage 1 enrolled by hand after `bputil -nc` (the build's `macho-unpadded` object is refused by Stage 2) | installer patch: `raw-ctxr` mode for J616c; the installer enrolled it on the acceptance install (JOURNEY 9.35) | OMS-24 |
| App version set above the installed app (the package otherwise keeps the old app) | `OMARCHY_APP_VERSION` passed by hand at build time; not in a script yet | OMS-14 |
| Omarchy's `libva-v4l2_request-avd` swapped for Aurora's `libva-v4l2-request-avd` (libva looks for `aurora_drv_video.so`; only Aurora's has it), 2026-11-19 | derivation removes Omarchy's, installs Aurora's pinned and checks the alias; derivation run passed 2026-11-19, not yet in an installer package (JOURNEY 9.39) | OMS-4 |
| Camera setfile `isp_2224_01XX.dat` | installer patch: the engine collects it on every Mac; installed and loading on the acceptance install (JOURNEY 9.35) | OMS-22 |
| aura `v1.0.0b17`'s Stage 1 enrolled by hand from 1TR as a padded Mach-O object (`kmutil configure-boot --compress`, `go-oms30-macho.sh`), since kmutil 27.2 wraps the installer's `raw-ctxr` image as an unpadded Mach-O and Stage 2 refuses to start the OS, 2026-11-28 | not yet: the J616c moves from `raw-ctxr` to upstream's `macho` mode with `v1.0.0b17`'s Mach-O Stage 1 (JOURNEY 9.59) | OMS-30 |
| Aurora's `aurora-touchid-rearm` installed and `-auth optional pam_aurora_touchid.so` added after the last auth line of `system-auth` and `omarchy-lock-password`, so the password re-arms Touch ID after a lockout, 2026-11-21 | not in the build yet; `omarchy-apply-lock` rewrites `omarchy-lock-password`, so its line needs a durable home (JOURNEY 9.49) | OMS-40 |
| containerd run under `userpages 4k` (drop-in `containerd.service.d/50-user4k.conf`), so x86 container libraries map on the 16 KiB kernel, 2026-11-25 | derivation installs `tools/image/containerd-user4k.conf`; not yet run (JOURNEY 9.53) | OMS-41 |
| Patched static `qemu-x86_64` (47-bit layout, Linux AIO, real `trapno`) installed as `/usr/local/bin/qemu-x86_64-oms41`, named by an `/etc/binfmt.d/qemu-x86_64-static.conf` override, so SQL Server 2022 containers start, 2026-11-25; replaced the same day by `qemu-user-static` and `-binfmt` `1:11.1.3-1` built from omacom/omarchy-pkgs#3505, override removed (JOURNEY 9.55) | derivation installs the two packages, the pinned `QEMU_PKGS` input, and checks the package's own rule is the one in force; not yet run (JOURNEY 9.55). Since 2026-11-26 the input is built from #3505 (source build, `1002`), #3602 (`1000`) and #3603 (`1001`) merged, after review; installed on the Mac the same day; `node:22` and SQL Server 2022 run through binfmt (JOURNEY 9.56). Drop the input once omarchy's repo publishes all three | OMS-41 |

## Where things are

- `JOURNEY.md` is the running log and the single source of truth for what happened and why. Read
  section 9 onward before acting on the boot chain. Add new findings as the next numbered section
  (`### 9.N Title (date)`). Record corrections there, never by rewriting history.
- `j616c-boot-fix.html` is the team write-up: root causes, test log, asks per team.
- `tools/wifi-reload-timing.sh` times Wi-Fi's rejoin after a `brcmfmac` reload, plain and with the
  radio off first, and reports whether the unload race hit (JOURNEY 9.26). Run it at the Mac with sudo.
- `tools/esp-overwrite-same-size.py` replaces a same-size file on an unmounted FAT ESP in place.
  macOS 26.7.3 on this Mac can't mount any FAT volume, so this is how Stage 2 got onto the ESP.
- `tools/derive-j616c-image` turns an edge image into the J616c image. On the OMS-30 branch it
  builds for a macOS 27.2 stub on omacom's edge stack (`[omarchy]` first, the exact builds pinned in
  `EDGE_PINS`), with Stage 1 and 2 from aura `v1.0.0b17`; `docs/oms-30-image-plan.md` says what goes
  in and why (JOURNEY 9.57). Its header has usage. The acceptance image (JOURNEY 9.34) came from the
  earlier version on Aurora's stack (`AURORA_PINS`, Stage 2 from aura `94d8e6e4`, Aurora's trial).
- `patches/j616c-installer.patch` is the installer work: J616c developer admission, the
  `raw-ctxr` Recovery boot mode for aura's raw Stage 1 (upstream's own `macho` mode serves other
  M4 Macs), the J616c's 27.2 (26B123) stub firmware and no other, and camera tuning collection on
  every Mac. Apply it to a checkout of omacom/omarchy-mac-installer at `e0aa53fd` (main,
  2026-11-22; JOURNEY 9.57). Commit installer changes back into this patch, so the repo stays the
  source.
- `tools/image/` holds files the derivation installs into the image, such as `omarchy-esp-generator`;
  `tools/tests/` has their tests (plain Bash, run on Linux).
- `LICENSE` is MIT for this repo's own work. The patches in `patches/` change other projects and
  stay under those projects' licenses (omacom's repos are MIT, as is asahi-scripts).
- `patches/omarchy-mac-boot-aurora.patch` teaches omarchy-mac-boot's boot check Aurora's Stage 2
  (OMS-16), against omacom/omarchy-mac-pkgs `28abebe`; sent upstream as omacom/omarchy-mac-pkgs#150. `patches/README.md` gives each patch's base
  and how to apply and test it.
- `patches/omarchy-lock-fingerprint-scanning.patch` makes omarchy-shell's lock screen show the
  fingerprint reader matching a finger (the icon pulses and the field says "Checking…" while the
  Secure Enclave matches), turns the icon red for a rejected finger, and holds the idle blank while
  a finger is on the reader (OMS-36, JOURNEY 9.48 to 9.51), against omacom/omarchy `b20d787`; sent upstream
  as omacom/omarchy#19537. Not part of the image: the shell comes from Omarchy itself, so it
  reaches the Mac through upstream.
- `docs/aurora-package-audit.md` sorts every `[aurora]` package for this Mac: already used, a candidate
  for a report gap (and which task), Omarchy's own, left out, not for this Mac, or opt-in, and lists the
  name collisions `[aurora]` causes by being first. It also covers the kernel dependency
  (Aurora's 7.3 kernel, until omacom's 7.3 carries the J616c).
- `tools/aura-usb/` sends a Stage 2 to aura over the USB-C cable and captures its console. Its
  README has setup, steps and the one thing this path can't test.
- `tools/qemu-user/` is the patched qemu-user that runs x86-64 containers (OMS-41, JOURNEY 9.53):
  `apply-oms41.py` changes a pristine qemu 11.1.3 tree (47-bit guest layout, Linux AIO passthrough,
  and the upstream `trapno` fix `586284af4c2c`), `build-qemu-x86_64` builds the static binary on an
  aarch64 host with Docker, `pferr.c` shows what a guest sees for a write to a `PROT_NONE` page, and
  `mmaptest.c` (a static x86-64 program) checks the guest layout cases from the PR's review (JOURNEY 9.56).
  Drop the backport block when moving to qemu 11.2.
  `aiotest.c` checks the AIO cases, and `aioharness.sh` hands it an address in QEMU's own memory.
  The image no longer uses its binary: the same three fixes now ship as patches in omacom/omarchy-pkgs
  `qemu-user-static` (QEMU 11.1.3): #3505 (source build, `1002`), #3602 (`1000`) and #3603 (`1001`),
  merged for the derivation's input (JOURNEY 9.55, 9.56).
- `tools/vm-timer-probe/` has the KVM guest-timer probes (OMS-42, JOURNEY 9.54): a module that checks
  `VM_TMR_FIQ_ENA_EL2` writes on every core (refuses to stay loaded) and a tracefs script for a
  hanging 2-vCPU guest. Both run at the Mac with sudo.
- After a reinstall, Allan's own setup of the Mac (remote access, git, the development tools) comes
  from a script kept on dev-machine-01 at
  `~/.local/share/omarchy-mac-setup/`, outside git: it carries credentials, so it is never
  committed, and `.gitignore` refuses its file names (OMS-39). Its README has the steps.
- Build outputs (engine, payloads, signed catalog, app, package) are too large for the repo. They
  are rebuilt from the patch and the scripts above; JOURNEY section 8 records how.

## Machines

| Machine | Reach it | Role |
| --- | --- | --- |
| The M4 Max, macOS | `allanclempe@allans-macbook-pro` over SSH | Builds the engine, app and installer package (Xcode), and runs the Lima build VM `omarchy-builder` for the image |
| The M4 Max, Omarchy | `clempe@dev-machine-mac-2` over Tailscale SSH (the name changes with each fresh install; find the online `dev-machine-mac-<n>` in `tailscale status`) | The system under test. No passwordless sudo; the ESP is root-only (`umask=0077`) |
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
- Nothing goes upstream (omacom, aurora-silicon) without Allan's go-ahead. When it does, send
  each change to the project that owns it:

  | Change | Goes to |
  | --- | --- |
  | Kernel: drivers, device trees (`t6041-j616c.dts`), kernel config | a PR on aurora-silicon/linux, never omacom/linux-aurora |
  | aura (Stage 1 and 2), Mesa, U-Boot, `[aurora]` packaging (alarm-aurora) | the aurora-silicon repo for it |
  | The installer: admission, boot modes, engine, ESP creation | omacom/omarchy-mac-installer |
  | Omarchy Mac packages, such as omarchy-mac-boot's boot check | omacom/omarchy-mac-pkgs |

  Before opening one, check that no open PR carries kernel work into an omacom repo; move any
  such PR to aurora-silicon/linux.
- Questions only the M team, Aurora or others can answer go in `docs/questions-for-the-team.md`,
  with enough context to ask them cold. Move a question to **Answered** when it's settled. That
  file sums up private team discussion, so it stays on this machine: `.gitignore` excludes it.
  Never commit it, and don't quote it in public files.
- No Claude Code or AI credit lines anywhere: not in files, code comments, commit messages
  (no `Co-Authored-By` trailer) or PR descriptions. Aurora's contributing guide asks for AI
  disclosure, so before sending anything to aurora-silicon, ask Allan how to handle it.

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

### Running `omarchy-m-test`

The test tool comes from maralcbr/omarchy-m-testing; a fresh install doesn't have it. Allan
installs it at the Mac, as his user (not root). The installer fetches the latest tagged release,
checks its ssh-ed25519 signature against the key pinned in the installer, and installs under
`~/.local/share/omarchy-m-test`, linked from `~/.local/bin`. Running it again upgrades.

```
curl -fsSL https://omarchy-m-testing.org/install | bash
omarchy-m-test --dry-run                        # a full run that writes the report but never uploads
omarchy-m-test --skip network,power,sleep       # the run without the disruptive sections
```

- Run it at the Mac's own seat in the Hyprland session: the video, display, camera and other
  human checks need the desktop and are skipped over SSH. `--unattended` runs only the automatic
  checks, for a run over SSH.
- What a run changes: it may install temporary test packages with sudo (removed at the end;
  never kernel, firmware or boot packages), reloads `brcmfmac` in the network section, sets and
  restores the battery charge limit in the power section, and asks for a lid-close sleep test.
  Skip `network`, `power` and `sleep` unless those are what's being tested. Sections: boot,
  hardware, graphics, video, display, audio, network, sleep, input, touch-id, camera, ports,
  power, cpu, thermal, sensors, storage, benchmarks.
- It asks before uploading. An uploaded report is public on omarchy-m-testing.org; the tool
  scrubs addresses, network names, serials and hostnames first. Upload only a run Allan wants
  public, and record the report's URL in `JOURNEY.md`. For a check of one section, use
  `--dry-run` and quote the result from the local report.
- The tool expects the asahi GPU driver, so `gpu.driver` and `gpu.vulkan` report a gap on this
  Mac whatever happens (OMS-8).
