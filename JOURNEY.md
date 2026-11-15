# Omarchy on a MacBook Pro 16" M4 Max (J616c): the journey

A running log of getting Omarchy onto this Mac (Mac16,5, board J616c, chip T6041) through
omacom/omarchy-mac-installer, and of the J616c support written along the way. It lives in the
allanclempe/omarchy-m4 repo with the scripts and patch the work produced (section 10). Paths
under `build/`, `~/` or a machine name in sections 2 to 9 are working trees on the build Mac or the
dev machines at the time, not files in the repo. Nothing has gone upstream yet: no PR to omacom or
aurora-silicon.

AI involvement: the research, code and builds were done with Claude Code (Claude Opus 5.5) at
the owner's direction. Any commit made from this work must say so (Aurora's contributing guide
requires it).

Last updated: 2026-11-15.

---

## 1. Starting point

- **Goal:** run Omarchy (Arch + Hyprland) natively on this Mac and contribute M4 Max support
  upstream.
- **Upstream status:** omarchy-mac-installer supports M1, M2, M3 and the MacBook Neo. Every M4
  Mac is refused (`scripts/supported-models.json`).
- **Advice from Marcelo Alcântara (maralcbr, installer maintainer):**
  - Use omacom/omarchy-mac-installer.
  - He had "modified our installer with an image based on the Aurora kernel".
  - Later, about the J616c image: build it ourselves.
- **Repos involved:**
  - omacom/omarchy-mac-installer
  - omacom/omarchy-pkgs and omacom/omarchy-mac-pkgs (Omarchy packages)
  - aurora-silicon/linux, aura, u-boot, alarm-aurora and aurora-installer (Aurora Silicon, where
    the M4 Max bring-up happens)

## 2. Preparing this Mac

- **Developer tools:** Xcode Command Line Tools, then full Xcode with its licence accepted.
- **macOS:** updated from 26.3 to 26.7.3. The pinned engine needs the system firmware to be at
  least as new as the 26.6.2 OS firmware it installs.
- **Local toolchain:** in `~/aurora-m4/toolchain` and `~/.local/bin`, because there is no
  Homebrew.

  | Tool | Version or note |
  | --- | --- |
  | uv | provides Python 3.12 and 3.14 |
  | Bash | 5.2, built from source |
  | GNU make | 4.4 |
  | dtc | |
  | LLVM | 23 |
  | Rust | 1.100 |
  | Lima | 2.3.0 |

- **Claude Code permissions:** `.claude/settings.local.json` allows `make`, `gmake` and
  `git clone` in this project.

## 3. Step 1: a developer-catalog admission for J616c (modelled on PR #133, J713)

- **Branch:** local and uncommitted, `j616c/developer-admission` in `omarchy-mac-installer-git/`.
- **Patch:** the whole branch is `patches/j616c-installer.patch` in this repo, against `a576543`
  (section 7).
- **Changes:**
  - **Engine patch:** chip `0x6041` (T6041) and device `j616cap`, both pinned to 26.6.2 OS
    firmware.
  - **Overlay:** a J616c board Stage 1 (`esp/aurora/stage1-j616c.bin`) and a J616c Stage 2
    (`esp/m1n1/boot-j616c.bin`).
  - **`supported-models.json`:** `apple,j616c` in the **developer** section only. Public
    builds still refuse every M4.
  - **`MacModelNames.swift`:** the friendly name for J616c.
  - **Tests:** M4 Max adapter, firmware-selection and catalog tests.
- **Engine re-pinned:** `v0.9.2-omarchy.20261113.0b0aa194ccb5`, built twice with
  byte-identical results.
- **Results:**
  - Python `test/all` passes (831+ tests).
  - `swift test` passes: 638 XCTest tests, 0 failures, 1 skipped (needs a private catalog).
    (An earlier draft of this log said 833; that was wrong.)
  - The live host test on this Mac reads `Mac16,5 / J616c / Apple M4 Max` (`apple,j616c`).
  - The engine's firmware selection with this Mac's real values picks 26.6.2 and a 6 GB stub.

## 4. Step 2: first boot files (later found to be wrong)

- **What I built from source:**
  - aura Stage 1 (`RELEASE=1 CHAINLOADING=1`).
  - aura Stage 2 (`ESP_STAGE2=1`).
  - The `t6041-j616c.dtb` device tree from aurora-silicon/linux integration/aurora.
  - A composed Stage 2 (`build/boot-j616c.bin`) using the U-Boot from Omarchy edge,
    `uboot-aurora 2026.07.aurora6`.
- **Why it's wrong:** aurora-silicon/alarm-aurora#244 shows that U-Boot before `250385f8`
  stops on T6041 with `Unsupported SoC`. The Omarchy edge `aurora6` build is one of those.
  **Don't use `build/boot-j616c.bin`.**

## 5. What Omarchy's package repos can and can't do for J616c

Omarchy edge (`pkgs.omarchy.org/edge`) on 2026-11-13:

- **Kernel:** `linux-aurora 7.2.11.aurora16` is built from omacom/linux-aurora `bed544bd`,
  which has **no T604x device trees**.
- **U-Boot:** `uboot-aurora 2026.07.aurora6` doesn't recognise T6041.
- **Boot loader:** `m1n1-aurora 1.6.1.aurora23` **replaces `aura`** and conflicts with it.

Aurora Silicon's signed ALARM testing repo (`aurorasilicon.org/alarm-aurora/testing/aarch64`,
key `A33623FB…219B20F7`) has the right set:

| Package | Version | What matters |
| --- | --- | --- |
| `linux-aurora` | 7.3.0.aurora1-36 | ships `t6041-j616c.dtb`; sha256 `9ff674b9…` |
| `uboot-aurora` | 2026.07.aurora11-1 | recognises T6041; sha256 `86c10a56…` |
| `aura` | 1.0.0b12.1-1 when first checked, 1.0.0b13-1 at derivation time | raw and Mach-O Stage 1, Stage 2 m1n1 and the `monitor-free` marker |
| `asahi-scripts` | 20261023-9 | Aurora's `update-m1n1` (bootchain.py) and the Stage 2 trial and commit services |

All four hashes match the repo database. In the derivation, pacman checked every package's
signature against Aurora's key (fingerprint confirmed before use).

## 6. The big finding: M4-class Macs boot from a padded Mach-O Stage 1

From aura's docs and aurora-installer's code (`Recovery/README.md`, `AuraStage1.swift`,
`NativeBootChain.swift`):

- **Enrolment:** on M4 and later (T8132, T6040/T6041, T8140 and newer), iBoot confines each
  secondary core's EL2 execution to a window (CTXR_D). It ends where the boot object's
  read-only region ends (kmutil's `kcrz`).
- **Padding:** aura's Stage 2 refuses to start the OS without a usable 128 MiB window. Aurora
  therefore enrols aura's **Mach-O** boot object (`aura-boot.macho`) with `__TEXT_EXEC` padded
  with zeros to about 146 MiB, using `kmutil configure-boot -c <obj> -v <vol> --compress`,
  never `--raw`.
- **Stage 2 location:** the padded Stage 1 loads **`m1n1/boot-ctxr.bin`**, not
  `m1n1/boot.bin`. On T604x Macs with the `monitor-free` marker, Aurora's `update-m1n1` writes
  that file.
- **Omarchy's current flow:** its Recovery app accepts only `bootMode: raw` and
  `stage2Path: m1n1/boot.bin`, and enrols with
  `--raw --entry-point 2048 --lowest-virtual-address 0`. A raw Stage 1 can't arm the window,
  so **J616c needs a new Mach-O mode in the Omarchy installer**.
- **Risks still open:**
  - Omarchy boots Limine and a UKI, not GRUB. If the kernel is loaded outside the window,
    aura's docs say it still boots, but on the boot CPU only.
  - A kmutil in Recovery hasn't yet been tested on a padded object (Aurora's README says so
    too).

## 7. Upstream work this builds on

- **omacom/omarchy-mac-installer#212:** collects M4-family (BCM4388 C2) Wi-Fi firmware from the
  installed macOS. Without it, an M4 install has no Wi-Fi, and it refuses a J616c package that
  lacks the board's Wi-Fi. Our branch is now fast-forwarded onto it (`a576543`), with the J616c
  changes re-applied uncommitted.
- **omacom/omarchy-mac-installer#157:** "Recovery: add Mach-O NV2 mode". It is open, has
  conflicts and doesn't pad. Used as a reference only.

## 8. What was built

### 8.1 The edge image (official recipe)

Built with the repo's own `image-builder/` in an arm64 Ubuntu 26.04 VM (Lima, VZ, rootful Docker).

- Inputs: `channel_set=omarchy-edge-d6cc6b6b3c83`, signed by the Omarchy key `40DFB630…`.
- Output: `omarchy-2026.11.13-aarch64-apple-silicon-mac-edge-os-package.zip`, 3,598,414,409 bytes.
  Both of the builder's contract checks pass.

### 8.2 The J616c derivation (`tools/derive-j616c-image`)

It runs in a privileged ALARM container and takes the edge image, its rootfs, Aurora's key and a
Recovery build. It:

1. adds `[aurora]` first in `pacman.conf`, with `aurora-keyring` and `IgnorePkg = m1n1-aurora`;
2. removes `m1n1-aurora` and installs `linux-aurora 7.3.0.aurora1-36`, `aura 1.0.0b13-1`,
   `uboot-aurora 2026.07.aurora11-1` and Aurora's `asahi-scripts 20261023-9`;
3. lets the image's own hooks rebuild the UKI (`EFI/Linux/omarchy_linux-aurora.efi`, kernel
   `7.3.0-1-36-ARCH`) and checks the kernel ships `t6041-j616c.dtb`;
4. builds `m1n1/boot.bin` and the confined `m1n1/boot-ctxr-j616c.bin` with Aurora's
   `update-m1n1`, then checks that the J616c tree and U-Boot are inside it and that it fits aura's
   16 MiB slot;
5. stages `esp/aurora/stage1-j616c.bin` (raw) and `stage1-j616c.macho` (Mach-O), and points the
   MacBook Neo's pair (`stage1-j700.bin`, `boot-j700.bin`) at the same aura build;
6. replaces the image's Recovery app with one built from this branch (it knows `macho-ctxr`);
7. re-seals `@factory`, runs `e2fsck` and `btrfs check`, and zips the payload.

The builder's own `mac-image-check payload edge … --profile release` passes on the result.

### 8.3 Engine: `macho-ctxr` for `j616cap`

- The engine fills the raw Stage 1 with `m1n1/boot-ctxr.bin`, copies its config block into
  aura's Mach-O object (a port of Aurora's `MachOBootObject.fill`) and stages both for Recovery
  as mode `macho-ctxr`.
- It refuses a J616c payload without the native Recovery app.
- Re-pinned as **`v0.9.2-omarchy.20261113.d0241e13f2b5`**: 17,911,222 bytes, sha256
  `db339847…66f1b5`. Two repacks were byte-identical.

### 8.4 Recovery app: the `macho-ctxr` mode

- `MachOStage1.swift` ports aurora-installer's `AuraStage1.swift` (MIT, at `b43c3d81`).
- Before enrolment, Recovery:
  - checks that the object's config block names this install's ESP and `m1n1/boot-ctxr.bin`;
  - pads `__TEXT_EXEC` to the 128 MiB window and checks free space;
  - checks that `kmutil configure-boot` offers `--compress`;
  - runs `kmutil inspect` and requires `kcbz 0` and the expected `kcrz`.
- It then enrols with `--compress`, with a 30-minute authorization timeout.
- **Cross-check on this Mac:** `kmutil inspect` on the padded real aura object reported
  `kcrz 153141248`, `kcbz 0` and `kcwf 153141248`, exactly what the code computes. The padded
  size is 153,190,400 bytes.

### 8.5 Tests

| Suite | Result |
| --- | --- |
| `test/all` (Bash 5.2, Python 3.12) | 863 tests pass (62 skipped) |
| `swift test` | 638 tests, 0 failures, 1 skipped |
| Recovery `test-all.sh` | 20 checks pass |
| Engine overlay | 162 tests (asahi) and 34 (recovery) |

### 8.6 Developer catalog and app (in progress)

- **Local key:** a local Ed25519 catalog key (`build/dev-catalog/keys/`, never shared), with trust
  root `sha256:e22b1ea6…6c47`.
- **Release descriptor:** an ad-hoc descriptor on `.invalid` hosts, so nothing can ever be
  fetched.
- **Sealed developer catalog:**
  - 36 models, sequence 1794561495, evidence revision `j616c-dev.20261113`.
  - The main group (every supported Mac, as the generator requires) shares the J616c payload.
  - `apple,j616c` has its own metadata, limited to 26.6.2 firmware.
- **J616c payload:** sha256 `704f48f5…06edb0`, 3,919,297,365 bytes. It passes the builder's
  release payload check and the engine's `validate_payload`, and its Recovery executable is
  `2db9d308…`, the `macho-ctxr` build.
- **Developer app:** `build/dev-app/Omarchy Installer.app`, version 2.3.16 (build 2611130925),
  built with `OMARCHY_DEVELOPER_BUILD=1 OMARCHY_OFFLINE_BUILD=1`.
  - Ad-hoc signed, 3.7 GB with the payload embedded.
  - Its own Recovery template is that `macho-ctxr` source, re-signed inside the app. It is used
    only for payloads without `recovery_gui`, while this payload uses its own copy.
- **Developer package:** `build/Omarchy-J616c-Developer.pkg`, unsigned, for local use only.
  - 3,948,399,572 bytes, sha256 `c44dc316…bbb9b0`.
  - Installing it registers the root helper, and the helper blocks older builds until it is
    removed (see `Packaging/README.md`).

### 8.7 Install on this Mac

**Attempt 1 (2026-11-13, approved by the owner): failed in `install_stub_and_esp`.**

- **What worked:** inspection admitted `apple,j616c`, then the plan, the macOS resize (to 857 GB), the
  6 GB stub container with its 26.6.2 Recovery, and the ESP, Boot and Root partitions.
- **Diagnosis:** the engine's stderr tail was empty, so I replayed each step offline against the
  real payload and the still-attached 26.6.2 ramdisk.
  - Stage 1, the Mach-O fill and the ESP layout all pass on the real payload.
  - Wi-Fi: board `hostomel`, and the installed macOS has every file it needs. Bluetooth is
    complete too.
  - **The cause:** the fallback firmware archive. PR #212's `_SystemWiFiArchive` copied
    `/usr/share/firmware/wifi` with `shutil.copytree`, whose `copystat` calls `chflags`. Every
    file on the sealed system volume carries SIP's `restricted` flag, which even root can't set,
    so it fails with `EPERM`.
  - This only affects M4 Pro and M4 Max Macs collecting Wi-Fi from macOS, so it is an upstream
    bug in #212 worth reporting.
- **Fix:** `omarchy_wifi._stage_tree` copies names, bytes, modes and symlinks only. A new test fails
  on the old code and passes on the new. Replayed live on this Mac, the archive builds
  (43 MB, 363 C2 entries).
- **Rebuilt:**
  - Engine `v0.9.2-omarchy.20261113.e19ff4512988` (sha256 `6f9176af…`, 17,911,578 bytes;
    two repacks identical).
  - `test/all` passes (864 tests).
  - Catalog re-signed, app build 2611131000, package sha256 `0053c6a1…f0f0`.

## 9. Things that went wrong, and the fixes

| Problem | Fix |
| --- | --- |
| No git or Python on a fresh macOS | used tarballs and curl, then CLT, uv Python 3.12 and Bash 5 |
| `apple-installer-identity-test` needs a git checkout | moved the work into a real clone |
| The dtc build failed on a clang warning flag | built with `WARNINGS=-Wall` |
| The macOS update wiped the scratchpad | rebuilt the engine and reproduced the same hash |
| `mac-image-check` refused the J700 Stage 2 | the derivation now rebuilds the J700 pair from aura too |
| loop devices leaked across derivation runs | `loop` ran in a `$(...)` subshell, so cleanup never saw them; fixed |
| the edge image's Recovery app predates `macho-ctxr` | the derivation swaps in a Recovery build from this branch |
| pr-212's Wi-Fi test fails on macOS (`/var` vs `/private/var`) | not a J616c issue; run `test/all` with a real-path `TMPDIR` |
| `sudo` doesn't work inside `!` commands | the owner accepted the Xcode licence in a separate terminal |
| Lima VZ guests use ACPI with no device tree | the image builder fakes the device tree in its chroot, so this is fine |
| Mac folders are mounted read-only in the VM | logs and outputs stay in the VM's `~/work` and are copied out with `limactl copy` |

## 10. Where things are

In this repo:

| What | File |
| --- | --- |
| Agent and team context | `AGENTS.md` |
| Installer changes (admission, `macho-ctxr` Recovery, engine, Wi-Fi fix) | `patches/j616c-installer.patch`, against omarchy-mac-installer `a576543` |
| J616c image derivation | `tools/derive-j616c-image` |
| Same-size file overwrite on an unmounted FAT ESP | `tools/esp-overwrite-same-size.py` |
| Stage 2 over USB with console capture | `tools/aura-usb/` |
| Team write-up | `j616c-boot-fix.html` |

Not in the repo, because they are build outputs or too large: the engine, payloads, signed
developer catalog and its key, the app and package, Aurora's packages, the Lima build VM and the
Mac data dump. They are rebuilt from the files above on the build Mac (sections 3 and 8).

**Attempt 2 (2026-11-13): installed, 1TR enrolment finished, boot loops.**

- **The old partitions remain.** Remove wasn't run first, so the first attempt's partitions are still
  there (its stub container `DFF95EA9…` and its unformatted ESP `406A9E32…`). The new install
  sits ahead of them: ESP `272043E7…` (disk0s4); macOS is now 720 GB.
- **The new ESP is complete:** `m1n1/boot-ctxr.bin`, `m1n1/boot.bin`, the UKI, Limine and
  `vendorfw`.
- **In 1TR,** the Recovery step padded, inspected and enrolled the object and reported success.
- **Symptom:** choosing Omarchy shows the Apple logo and iBoot's progress bar, then the Mac
  reboots. That repeats until it drops into startup options. No aura text ever appears.
- **The enrolled Stage 1 is aura's `dev` build (1.0.0b13-gf0f180af).** When it runs but can't
  start Stage 2 or the OS, it prints the reason on the panel and offers the proxy, then reboots
  after 10 s. Seeing no text means the failure comes before aura draws anything: iBoot itself, or
  aura faulting at entry.
- **Aurora's status** (aura `docs/macho-boot-object.md`): the padded Mach-O path is qualified on
  T8140 and T6040 (J616s). "Any chip other than T8140 and T6040" is listed as not tested.
  J616c is T6041.
- **No record survived:** iBoot breadcrumbs, the macOS logs and DiagnosticReports have nothing
  for the failed boots.

**USB test (2026-11-13 21:37–21:41).** `dev-machine-02` (Omarchy, Linux 7.2.11) was connected by
USB-C, and its `dmesg` is saved in `build/aura-test/aura-usb-test.log`.

- **The cable and port carry data.** The J616c appears as `05ac:1905` "Mac" (Apple's CDC NCM) in
  macOS, at 21:37 and 21:41, and in recoveryOS (startup options), at 21:38:41 and 21:40:38.
- **During the Omarchy attempts (21:39:18 to 21:40:38),** only Type-C power events
  (`ucsi_acpi`) appear, in pairs at 21:39:22/23 and 21:39:32/33. That is one reboot cycle about every
  10 s. aura never shows up as a USB device: no proxy, and no `ttyACM`.
- **With `aura-proxy` on the ESP,** a running aura would wait 15 s before going on. A 10 s cycle
  means it never got as far as reading the ESP.

**Test 2 plan: an unpadded Mach-O.** `build/aura-test/aura-unpadded-test.macho` (sha256 `1140f3a6…`)
is the same aura b13 object, filled for ESP `272043e7…` and `m1n1/boot-ctxr.bin`, but not padded.
`kmutil inspect` reports `kcbz 0` and `kcrz 1769472`. It gets enrolled by hand in 1TR with
`--compress` (`enroll-test.sh`).

- If aura shows its "no usable window" refusal and comes up on USB, Mach-O entry works on T6041 and
  the padding is the problem.
- If it still loops silently, the Mach-O object fails on T6041 altogether.

**Test 2 result (2026-11-13 22:57): the unpadded Mach-O boots.** It was enrolled in 1TR by hand
(`go.sh`: `kmutil configure-boot -c aura-unpadded-test.macho -v <stub> --compress`).

- **22:57:43:** `dev-machine-02` sees `1209:316d` "aura uartproxy 1.0.0b13-gf0f18" (Aurora
  Silicon) on ttyACM0/1. It disconnects 15 s later, which is the `aura-proxy` wait.
- **Then:** aura Stage 1 loads `m1n1/boot-ctxr.bin` from the ESP. Stage 2 starts U-Boot
  `2026.07-g250385f8c8aa`, which stops at its `=>` prompt with no other output on the panel.
- **Conclusions:**
  - On T6041 the same aura object boots when unpadded and does not when padded to the 128 MiB
    window. The silent loop with the padded object happens in iBoot or at aura's entry; it is
    not caused by our ESP, Stage 2 or U-Boot.
  - The chain from Stage 2 to U-Boot works on J616c.
- **Still open:** why U-Boot doesn't autoboot. Without the window, Linux would also run on the
  boot CPU only.
- **At the U-Boot `=>` prompt** the built-in keyboard does nothing. On M2 and later laptops it is
  not a USB or SPI device, and U-Boot apparently has no driver for it on T6041. No autoboot
  output was shown.
- **Where Aurora stands** (aura `94d8e6e`; aurora-installer `1b6c895`, 2026-11-13):
  - The b11 and b12 release qualifications boot padded Stage 1 to gdm on J616s and J700, never
    on J616c.
  - The 1.0.0b10 notes say no M4 Mac had booted from a padded Stage 1 at that time.
  - aurora-installer pads T6041 the same way (128 MiB window, `--compress`). It warns that J616c
    is experimental: "Aurora has run on one, but not from this installer … Aurora may not start".
  - So the padded silent loop on J616c is new information for Aurora.
- **Tools on `dev-machine-02`:** aura's proxyclient is in `~/aura-tools` (venv with pyserial and
  construct; `USE_CLANG=1` for the copy stub). It can drive the 15 s `aura-proxy` window, but
  needs `sudo` or the `uucp` group for `/dev/ttyACM*`.

## 9. Online check after the U-Boot stop (2026-11-13, 23:15)

- u-boot#42 (T6041 "Unsupported SoC" panic) is already in our U-Boot: `strings` on aurora11 shows `apple,t6041`. That fits U-Boot reaching `=>` instead of hanging at the logo.
- aura#1 (J616C DAPF SError + NVMe split-BAR, merged Oct 24) predates b13.
- The only reported J616C Linux boot (aura#1) used a separately built aura with `ESP_STAGE2=1`. It doesn't say whether Stage 1 was padded. aurora-installer#97 says the installer has never installed on a J616C.
- aura#114 (J616s padded, works): it needs kernel linux#1184 (boot CPU stays at EL2). A Mach-O enrolment silently re-enables Kernel CTRR. Before going back to a raw Stage 1, run `bputil -nc` again, or only one CPU comes up.
- u-boot#42 notes that on T6041, U-Boot skips the MTP keyboard handoff and leaves the keyboard to Linux. That explains the dead built-in keyboard at `=>`.
- No public report of a padded Stage 1 boot loop on T6041.
- The session transcript and this file were copied to dev-machine-02 (`~/.claude/projects/-home-clempe/`, `~/aurora-m4/`).

### 9.1 Next: capture the boot log over USB
- dev-machine-02 `~/aura-tools/capture.sh` waits for aura's proxy and sends `boot-ctxr.bin` itself; it's `boot-ctxr-j616c.bin` from the J616c payload. It records 90 s of console output to `~/aura-tools/capture-HHMM.log`.
- Nothing changes on the Mac's disk. The enrolled unpadded test object stays as it is.

### 9.2 Capture result (23:27) and the SSD controller handoff
- `capture-output.log` (dev-machine-02): aura b13 Stage 1 runs at EL2 on J616c (T6041). It initializes NVMe, reads `m1n1/boot-ctxr.bin` (4,518,605 B) and logs `nvme: ANS powered off, 9 SART entries kept`. It also logs `cpufreq: Chip 0x6041 is unsupported`. Stage 2 then reports "Valid payload found" (U-Boot), and USB drops as it hands over.
- aura's `chainload_load()` always ends with `nvme_shutdown()`, and Stage 2 has the string "FDT: ANS will be off; %d SART entries passed on". So U-Boot receives the SSD controller (ANS) powered off.
- U-Boot aurora11 (`250385f8`) has only the adopt path: "ANS is not running …: post-M4 ANS can only be adopted from the boot loader". Starting ANS from off is u-boot#38/#48, still drafts and not in aurora11.
- Likely result: no NVMe in U-Boot → `bootflow scan` finds nothing → `=>`. This is not yet confirmed: a photo of the full U-Boot screen should show the NVMe probe error.
- The USB keyboard at `=>` fits too: the T6041 ports are USB 2 only without aura#147 (ATC tunables, merged Nov 11, after b13), and u-boot#42 leaves the built-in keyboard to Linux on T6041.

### 9.3 Test: U-Boot with u-boot#48 (start ANS from off), sent over the cable
- Source: aurora-silicon/u-boot `pull/48/head` = `cfebc31da5`. It includes #38's series and is based on aurora-wip, which contains aurora11 `250385f8` and the T6041 fix #42.
- Built in the Lima VM with `apple_m1_defconfig` (stock, no changes). `u-boot-nodtb.bin` is 767,640 B, sha256 `7a24e1b4…998c`.
- `build/uboot-pr48/boot-ctxr-pr48.bin` is the first 4,164,055 B of the payload's `boot-ctxr-j616c.bin` (aura Stage 2 + J616c DTB) followed by `gzip -9 -n` of the new U-Boot. Size 4,531,811 B, sha256 `187985d0…3f44`.
- Run on dev-machine-02: `~/aura-tools/capture.sh ~/aura-tools/boot-ctxr-pr48.bin`. Nothing on the Mac's disk changes.

### 9.4 Move to dev-machine-01 (2026-11-14)
- dev-machine-02 went down. The tools now live on dev-machine-01 `~/aura-tools`: aura clone at `94d8e6e`, a venv with pyserial and construct, both Stage 2 files and `capture.sh` (which takes the file as an argument). The steps are in `~/aura-tools/UBOOT-TEST.txt`.
- The session is resumed on dev-machine-01. The build files stay on the Mac and are reached with `ssh allanclempe@allans-macbook-pro` once Remote Login is on.

### 9.5 PR #48 run (2026-11-14 07:02, dev-machine-01)
- aura b13 Stage 1 behaved as before: NVMe up, `boot-ctxr.bin` read from the ESP, `ANS powered off, 9 SART entries kept`, then the 15 s `aura-proxy` wait. The host attached at 8.72 s (boot watchdog off).
- `chainload.py` sent `boot-ctxr-pr48.bin` (kernel image 0x452667 bytes, so the PR #48 build) and vectored at 9.1 s. `capture-0659.log` holds only `[9.708154] Valid payload found`, then USB dropped (07:02:44), as in the first capture.
- After that, the Mac rebooted several times and ended up in macOS. dev-machine-01's kernel log shows **no** USB device from the Mac between 07:02:44 and 07:04:15: no aura proxy, no `05ac:1905`. So the extra reboots never reached aura's USB setup, which takes about 7 s in Stage 1. Still to note: what the screen showed after the handover, and how fast the reboots came.

### 9.6 Kernel source, checked on the Mac (2026-11-14)
- The image's kernel is Aurora Silicon's, not omacom's. `tools/derive-j616c-image` sets `AURORA_SERVER='https://aurorasilicon.org/alarm-aurora/testing/$arch'` and installs `aurora/linux-aurora`. The package in `build/alarm-pkgs/` is `linux-aurora-7.3.0.aurora1-36`.
- omacom/linux-aurora (the kernel Marcelo calls stable) has no T604x device trees on `integration/aurora` (`bed544bd`, unchanged since 2026-11-10) or on `aurora-wip`. aurora-silicon/linux `integration/aurora` (`5d112b1d`) has `t6041-j616c.dts` and the rest of the T604x set.
- No kernel has run on this Mac yet: every failure so far happened in iBoot, aura or U-Boot. Changing the kernel can't explain them.

### 9.7 Cause of the U-Boot `=>` stop: aura b13 Stage 2 (2026-11-14)
- aura `aaec599f` (2026-11-13, after b13): "payload: start a post-M4 ANS an earlier stage powered off before any payload". In an ESP Stage 2 that boots its embedded U-Boot, b13 never runs `nvme_init()`. It passes the SART entries and leaves ANS off, and U-Boot aurora11 can only adopt a running ANS (`Failed to probe 'nvme@…': err=-19`). This matches the `=>` stop. Neither b13 (`f0f180af`) nor the packaged `1.0.0b13.1` (`5dcf62d0`) contains the fix.
- Built Stage 2 on the Mac from aura `94d8e6e`, which is b13 plus 11 commits including `aaec599f`, with the PKGBUILD's flags `RELEASE=1 CHAINLOADING=1 ESP_STAGE2=1 USE_CLANG=1 BUILTIN_LOGO=aurora`. Source and log: `build/aura-stage2-94d8e6e/`, `build/stage2-94d8e6e-build.log`. `aura.bin` is 4,063,232 B, sha256 `46fd25ed…d068`.
- `boot-ctxr-ansfix.bin` = new Stage 2 + the payload's own J616c DTB and gzipped U-Boot aurora11, byte for byte. 4,518,605 B, sha256 `a0f493b4…f552`. Copies are in dev-machine-01 `~/aura-tools/` and the Mac's `build/aura-stage2-94d8e6e/`. It is sent over USB with `capture.sh`; nothing is written to the Mac.

### 9.8 ANS-fix run over USB (2026-11-14 13:17): reboot, and why the USB test can't show the fix
- `capture-1317.log`: Stage 1 as before; `chainload.py` sent `boot-ctxr-ansfix.bin` (0x44f2d1 bytes); Stage 2 printed `[9.553] Valid payload found`, then USB dropped. The owner saw a logo briefly, then a reboot back to macOS, the same as the PR #48 run.
- The USB path doesn't reproduce the real hand-off. With `aura-proxy` on the ESP, Stage 1 powers ANS off before waiting for the host (`chainload.c`). Only Stage 1's own ESP load adds `nvme.sart=` to Stage 2's config (`chainload.c:382`). `chainload.py` passes only iBoot's boot args. So both USB runs gave Stage 2 ANS off with no SART entries. The `aaec599f` restart only happens when `nvme.sart=` arrived (`nvme_post_m4_passed_off()`), and `nvme_init()` refuses "ANS is off and no earlier stage passed its SART entries".
- Still unexplained: why the USB runs reboot instead of stopping at `=>`. Not recorded: whether the 2026-11-13 23:27 USB run with the original file rebooted too.
- Next: the faithful test is the ESP path. Replace `m1n1/boot-ctxr.bin` on the Omarchy ESP (disk0s4, `272043E7…`) with `boot-ctxr-ansfix.bin`, keeping the original as a backup. That needs the owner's approval because it writes to the Mac's disk.

### 9.9 New Stage 2 written to the Omarchy ESP (2026-11-14, approved by the owner)
- macOS wouldn't mount disk0s4 ("supported but damaged"), even read-only and after restarting `com.apple.fskit.msdos` and `fskitd`. A fresh `newfs_msdos` FAT32 image wouldn't mount either, so the problem is FSKit on this Mac, not the ESP. `fsck_msdos -n /dev/rdisk0s4` is clean (exit 0, 163 files). The boot sector is a macOS `newfs_msdos` FAT32 with 4096-byte sectors, labelled `EFI - OMARC`.
- `tools/esp-overwrite-same-size.py` overwrites a same-size file's data clusters in place without mounting. It checks the label, the long-name lookup, the cluster chain in both FATs and the old and new sha256, then re-reads the file to verify. It was tested first on a full read-only copy of the ESP (`build/esp-test/esp-disk0s4-before.img`): only clusters 8–913 changed, and `fsck_msdos` gave the same result as on the original.
- Real run: `m1n1/boot-ctxr.bin` (first cluster 8, 4,518,605 B) went from `b6daef1f…` to `a0f493b4…`, written and verified. Backups: `build/esp-test/boot-ctxr.bin.b13` and the full ESP image. To undo, run the same command with the files and hashes swapped.

### 9.10 Result: boots past U-Boot (2026-11-14 13:44)
- Normal boot with the new Stage 2 on the ESP and no host program: aura appeared on USB at 13:44:47, waited its 15 s and handed over at 13:45:02. After that, the Mac didn't reboot or appear on USB again through 13:52. The owner reports that it booted through; how far (Limine, login, desktop) is still to be recorded.
- Team write-up: `j616c-boot-fix.html` (published as a claude.ai artifact).

### 9.11 Owner setup fails: wrong ESP mounted, Aurora key not trusted (2026-11-14)
- Linux 7.3.0 reached Omarchy's owner setup ("Press Return to Start Setup"). The built-in keyboard works. The root is LUKS2 (nvme0n1p6), unlocked at first boot with the staged key, so no password was asked.
- First attempt: a blank screen with an echoing cursor for 10+ minutes. Second attempt: "Setup hit an error". From the root shell, the log shows two problems:
  1. **Aurora's key is not in the keyring.** `pacman: aurora: key "A33623FB30665BEFAA0FFB6DE35EC749219B20F7" is unknown ... Import PGP key? [Y/n]`. omarchy-mac-boot's first boot builds the keyring from `archlinuxarm asahi-alarm omarchy` only, so the `[aurora]` repo our derivation adds has no trusted key. The Y/n prompt goes to the log while pacman waits on tty1, which is the likely cause of the first silent hang. This is a derivation bug.
  2. **The wrong ESP is mounted.** `omarchy-mac-esp: the system ESP (PARTUUID=272043e7-…) is not mounted at /boot/efi or /boot`. fstab mounts `/boot/efi` by `UUID=4F4D-5001`, a FAT serial every Omarchy ESP shares. The first attempt's leftover ESP (nvme0n1p8, `406a3e32-…`) has it too, and Linux mounted that one. First boot's deferred Limine step therefore wrote to p8, not to the ESP the Mac boots from (p4).
- Proposed fix in the root shell: mount `/boot/efi` by the PARTUUID the device tree names, then `pacman-key --populate aurora`, then rerun `omarchy-provision-owner`. Afterwards check that `m1n1/boot-ctxr.bin` is still `a0f493b4…`. Later: remove the first attempt's partitions (disk0s7–s10) from macOS, and report the shared FAT serial upstream.

### 9.12 Owner setup completes; all 14 CPU cores online (2026-11-14 14:37)
- In the root shell: mounted nvme0n1p4 at `/boot/efi`, populated the Aurora keyring (`pacman-key --populate aurora`), and reran `omarchy-provision-owner`. Setup ran to 100%: initramfs, UKI and `/boot/efi/limine.conf` were rebuilt on p4, and the log ends `oem-setup: first-boot setup complete` (14:37:09). Warnings only: possibly missing firmware for `aop_als` and `mt7932_fullmac`.
- Checked after setup: `/boot/efi` = `/dev/nvme0n1p4`, and `m1n1/boot-ctxr.bin` is still `a0f493b4…f552`, so setup didn't touch Stage 2. fstab still read `UUID=4F4D-5001` (the first sed didn't apply), so it was re-edited with the literal `PARTUUID=272043e7-ec24-4890-9346-545cfbb8329b`.
- **`nproc` = 14 and `/sys/devices/system/cpu/online` = `0-13`** with the unpadded Mach-O Stage 1. Every M4 Max core is online, contrary to the expectation (aura docs) that an OS outside the CTXR_D window gets the boot CPU only. Worth reporting to Aurora with the boot details; the padded object's silent loop may matter less than thought for J616c.

### 9.13 Omarchy desktop on the M4 Max (2026-11-14 ~15:00)
- After owner setup, SDDM's greeter died 2 s after start (black screen). Journal: `MESA-EGL: egl: failed to create dri2 screen`, then `ZINK: vkEnumeratePhysicalDevices failed (VK_ERROR_INITIALIZATION_FAILED)`. Hyprland (the greeter's compositor) aborted with signal 6, and `sddm-greeter-qt6` aborted with "Could not load the Qt platform plugin wayland".
- The kernel side was fine: `card0` = `aurora` GPU driver (`[drm] Initialized aurora 1.0.0 for 28a600000.gpu`; GPU firmware "Apple GFX 25G83 for T6041, 32-core J616C"), `card1` = `apple-drm` (DCP), plus `renderD128`.
- Cause: the edge image's Mesa (`mesa-aurora 26.3.0_devel.20261107`, from Omarchy's repo, built for its 7.2.11 kernel) can't drive the GPU under Aurora's 7.3 kernel. Wi-Fi works (`wlan0` with the BCM4388 firmware collected from macOS). After connecting, `pacman -Sy mesa-aurora vulkan-aurora` from `[aurora]` installed `26.3.0_devel.202611130318.8f013bf96bd-1`. After `systemctl restart sddm`, the greeter and the Hyprland desktop work.
- Confirmed in a desktop terminal: `linux-aurora 7.3.0.aurora1-36`, `uname -r` 7.3.0-1-36-ARCH, `nproc` 14. GPU vs software rendering not yet checked (`eglinfo` not installed).
- fstab still showed `UUID=4F4D-5001` at this point; the owner was asked to apply the PARTUUID edit again and check it.
- **Derivation bugs to fix in `tools/derive-j616c-image`:** (1) put `aurora` in the first-boot keyring, or don't leave `[aurora]` enabled; (2) install Aurora's `mesa-aurora` and `vulkan-aurora` with the kernel; (3) take Stage 2 from aura with `aaec599f`. **Installer bug to report:** every ESP gets FAT serial `4F4D-5001` and fstab mounts it by that, so leftover partitions from an earlier attempt take over `/boot/efi`.

### 9.14 First `omarchy update` on the M4 Max (2026-11-14 15:28)
- `pacman -Syu` completed. Among other packages it upgraded `aura` 1.0.0b13 → 1.0.0b13.1. The kernel (`linux-aurora 7.3.0.aurora1-36`) and Aurora's Nov 13 `mesa-aurora`/`vulkan-aurora` were unchanged. The update's last step, "Verify the Apple Silicon boot files", failed with `/usr/bin/update-m1n1 does not build m1n1/boot.bin the way this check rebuilds it`. That is expected on this image: `update-m1n1` is Aurora's (asahi-scripts 20261023-9, bootchain.py), and on this Mac it writes `m1n1/boot-ctxr.bin`, not `boot.bin`. The fix the check suggests (`mkinitcpio -P && update-m1n1 && omarchy-mac-boot-update`) was **not** run.
- Aurora's `95-m1n1-install.hook` armed a one-shot Stage 2 trial on p4: `m1n1/boot-ctxr.bin.next` (sha256 `f24b7091…3325`), with the marker `/aura-try` = `armed`. The live `boot-ctxr.bin` was kept. aura b13.1 is source commit `5dcf62d0` (release/1.0.0b13.1), which does **not** contain the ANS fix `aaec599f` or `94d8e6e`. So the trial would stop at U-Boot `=>`, and only a hard power-off would fall back to the live Stage 2. The plan is to disarm it before rebooting (rename `/boot/efi/aura-try`). The attempt record in `/var/lib/aurora-stage2/attempts/` stops the hook from re-arming the same candidate.
- **Correction to 9.11–9.13:** the ESP FAT serial is `4F4D-5801`, not `4F4D-5001`, and p4's PARTUUID is `272043e7-ec24-4890-93d6-545cfbb8329b` (`…93d6…`, not `…9346…`). Both p4 and p8 still have `4F4D-5801`. fstab was never changed: it still mounts `/boot/efi` by `UUID=4F4D-5801`. The earlier sed matched nothing, which was lucky, because the mistyped PARTUUID would have stopped `/boot/efi` from mounting at all.
- Access: the Mac's Linux is reachable as `clempe@dev-machine-macos` over Tailscale (no passwordless sudo, and the ESP is root-only with `umask=0077`).
- Applied by the owner before rebooting (2026-11-14): `/boot/efi/aura-try` renamed to `aura-try.disarmed` (checked), live `m1n1/boot-ctxr.bin` still `a0f493b4…f552` (checked), and fstab now mounts `/boot/efi` by `PARTUUID=272043e7-ec24-4890-93d6-545cfbb8329b` (it resolves to nvme0n1p4; `findmnt --verify` gives 0 errors).

### 9.15 Derivation fixes, and protecting the running Mac (2026-11-14)
- **Risk on the installed Mac:** Aurora's repo now has `aura 1.0.0b13.1-1`, which lacks `aaec599f`. asahi-scripts' `95-m1n1-install.hook` runs `update-m1n1` after any change to `usr/lib/modules/*/dtbs/*` or `usr/lib/asahi-boot/*`, so every kernel, U-Boot or aura update. That rebuilds `boot-ctxr.bin` from `/usr/lib/asahi-boot/m1n1.bin` (still b13 on the Mac), which would put back the U-Boot `=>` stop. (Superseded on the Mac by 9.14: aura is now b13.1 there, and the guards at the end of this section disable that rebuild.) `update-m1n1` sources `/etc/default/update-m1n1` and honours `M1N1=`, and omarchy-mac-boot marks every file under `etc/` as a backup file, so a local `M1N1=` line survives upgrades.
- **`tools/derive-j616c-image` updated** (previous version kept as `derive-j616c-image.pre-20261114`):
  1. A new `STAGE2` argument takes the aura `94d8e6e4` Stage 2, pinned by sha256 `46fd25ed…d068`. It is installed at `/usr/local/lib/aura/m1n1-94d8e6e4.bin` and named by `M1N1=` in `/etc/default/update-m1n1`. The script checks that `boot.bin` and `boot-ctxr-j616c.bin` both start with it.
  2. Installs `aurora/mesa-aurora` and `aurora/vulkan-aurora` (plus the `-fex-guest` and lavapipe variants when present), checks they are Aurora's builds, and records them in `versions.txt`.
  3. Adds `/etc/systemd/system/omarchy-provision-owner.service.d/30-aurora-keyring.conf` (`ExecStartPre=/usr/bin/pacman-key --populate aurora`). Owner setup already runs `After=omarchy-mac-first-boot.service`, so the keyring exists by then.
- Not yet rebuilt. The ESP-serial / fstab problem is the installer's and isn't addressed by the derivation.
- Guards for safe `omarchy update` (applied by the owner and checked over SSH, 2026-11-14 ~17:00): `/etc/omarchy-mac-boot/owner-boot-chain` (Omarchy's update-verify then only warns when the boot check fails; the check always fails on this image because `update-m1n1` is Aurora's), `M1N1_UPDATE_DISABLED=1` in `/etc/default/update-m1n1` (Aurora's hook no longer rebuilds Stage 2 or arms trials from the packaged aura b13.1, which lacks the ANS fix), and `IgnorePkg = m1n1-aurora linux-aurora mesa-aurora vulkan-aurora` (holds the kernel and its Mesa in step with the device trees inside the frozen Stage 2). Undo all three once an aura release contains `aaec599f`, or once the hook is pointed at a fixed Stage 2 payload.

### 9.16 Speakers: speakersafetyd has no J616 profile (OMS-1, 2026-11-15)
- Post-install report (https://omarchy-m-testing.org/reports/KkjcZekcyQ9BDAs9oYr7HoTn, omarchy-m-test 0.1.15): `speakersafetyd.service` failed, `speakerguardd` inactive, no speaker DSP sink, amps locked; the default sink is "Raw Speaker Device (do not use)". Installed: `speakersafetyd 2.0.1-1.2`, `aurora-audio 4.1.aurora3-3`, `alsa-ucm-conf-aurora 10.aurora3-1`.
- Likely cause, from source and packages, not yet confirmed on the Mac: speakersafetyd's `get_machine()` takes the first device-tree compatible and trims trailing letters (`trim_end_matches(is_ascii_alphabetic)`), so on a J616c it loads `apple/j616.conf` and opens `hw:AppleJ616`. Aurora's own build, `speakersafetyd 2.0.1-1.2` ("Aurora build"), ships configs up to j615 and none for j616, so it panics on "Failed to read config file", and the unit (`Restart=on-failure`, 10 starts per 60 s) gives up.
- Open: speakersafetyd's own udev rule has no `AppleJ616` line, so something else started the unit. Most likely the unit is enabled (`WantedBy=multi-user.target`); the confirm step below checks.
- Hypothesis for the rest of the report's audio gaps: with speakersafetyd down the amps stay locked, and the audio policy keeps the speaker DSP sink hidden. If the sink is still missing once speakersafetyd runs, look next at `aurora-audio` (J616 speaker graph) and `alsa-ucm-conf-aurora` (J616 UCM).
- Aurora's `[aurora]` repo has `speakersafetyd-aurora-profiles 1-2`: `apple/j616.conf` (J616s and J616c: speakersafetyd's j316.conf model values with the J616 V/I sense layout, six `[Speaker/...]` sections), a udev rule that starts the daemon for card `AppleJ616`, and a drop-in that keeps warm-restart state across daemon restarts.
- `tools/derive-j616c-image` installs it, then fails unless `apple/j616.conf` has speaker sections and the `AppleJ616` udev rule is live (not commented out). Checked with `bash -n` and against the real package files; the derivation hasn't been run since (as in 9.15).
- To confirm and fix on the installed Mac, read-only first, in one block:

  ```
  systemctl is-enabled speakersafetyd; pacman -Q speakersafetyd
  journalctl -b -u speakersafetyd --no-pager | grep -E 'Config file|Failed to read'
  ```

  Expected: `enabled`, `speakersafetyd 2.0.1-1.2`, then `Config file: "/usr/share/speakersafetyd/apple/j616.conf"` and `Failed to read config file`. If the log shows anything else, stop there. Otherwise `sudo pacman -S aurora/speakersafetyd-aurora-profiles` and reboot. Then `systemctl is-active speakersafetyd` should print `active`, and `wpctl status` should list a speaker sink other than the raw device. Play sound at low volume first, then re-run the `omarchy-m-test` checks `audio.speaker-dsp`, `audio.speaker-protection`, `audio.speaker-amps-unlocked` and `audio.speaker-tone`.
- **Confirmed and fixed on the Mac (2026-11-15).** This boot's journal (13:47) showed exactly the predicted failure: `Machine: apple,j616c`, `Config file: "/usr/share/speakersafetyd/apple/j616.conf"`, `Device: hw:AppleJ616`, then a panic because the file was missing. The unit was `enabled`. After `pacman -S aurora/speakersafetyd-aurora-profiles` (13:56), its udev rule started the daemon, which loaded all six J616 speakers and has run since with no restarts. `Speaker Volume Unlock` reads 1.
- **Second cause: no J616 DSP graph.** With speakersafetyd running there was still no speaker or mic DSP. The edge image installs Omarchy's `aurora-audio 4.1.aurora3-3` (from `omarchy-candidates`), which has graphs for j274 to j415 and j700 but none for J616. Aurora's `aurora-audio 4.1.aurora2-16` adds `asahi-audio/j614` and `j616` (`graph.json`, `mic.json`) and depends on `alsa-utils-aurora`. Its pkgrel sorts below Omarchy's, so `pacman -S aurora/aurora-audio` reports a downgrade; `[aurora]` is first in pacman.conf, so updates keep it. Omarchy's `alsa-ucm-conf-aurora 10.aurora3-1` already has the J616 UCM and stays.
- After installing Aurora's `aurora-audio` and rebooting, WirePlumber builds `audio_effect.j616-convolver` ("MacBook Speakers", priority 850), linked to all six channels of the hidden `RawSpeakers` node, and `effect_output.j616-mic` ("MacBook Microphone (Mono)") from `RawMics`, feeding Omarchy's `omarchy_asahi_mic`. The default sink didn't resolve at first: WirePlumber still had `default.configured.audio.sink=alsa_output.platform-sound.RawSpeakers` saved from before the fix, and that node is now hidden behind the filter. `wpctl set-default` on the convolver fixed it. Only this Mac is affected: a fresh install has no saved default, and the filter wins on priority.
- `speaker-test -D pipewire -c 2 -t wav` at 20 % and 50 %: the owner heard "Front Left" and "Front Right" on the right sides, cleanly. speakersafetyd logged no gain reduction. Still to run: the `omarchy-m-test` audio checks, which need consent at the Mac.
- `tools/derive-j616c-image` now also installs `aurora/aurora-audio`, and fails unless `asahi-audio/j616/graph.json` and `mic.json` are present. The mic DSP likely also bears on OMS-9 (the weak-mic reading predates this fix).
- **omarchy-m-test audio checks (2026-11-15).** First run, audio sections only, `--dry-run`: the four speaker checks and `system.failed-units` passed. Two were still gaps: `audio.microphone-signal` captured exact zeros (`peak 0, rms 0.0`) from `effect_output.j616-mic`, and `audio.headphone-detection` didn't switch to the jack.
- Both came from WirePlumber's saved state on this Mac, not the build. The raw mic route was saved as muted (`alsa_card.platform-audio.7.auto:input:[In] Mic` with `"mute":true` in `~/.local/state/wireplumber/default-routes`). It had been muted before this fix too, and with `hide-parent` nothing on the desktop can unmute it. The hand-set default sink (`wpctl set-default`) kept the speakers default even with headphones plugged in: Aurora's config gives the jack priority 1100 over the speakers' 850, "but a default chosen by hand still wins". With WirePlumber stopped, the route was unmuted and the `default.configured.audio.sink*` lines removed (backups `*.bak`). What muted the mic route in the first place is unknown; the clean reinstall (OMS-14) will show whether it happens on a fresh install.
- Second run: **all nine audio checks pass**. Default sink "MacBook Speakers"; mic `omarchy_asahi_mic` peak 202, rms 30.3; the tone was heard; plugging in headphones switched the output to `alsa_output.platform-sound-jack.HiFi__Headphones__sink`.

### 9.18 Mount /boot/efi from the ESP the Mac boots (OMS-12, 2026-11-15)
- Every Omarchy image carries fixed identifiers: `image-builder/bin/build-mac-image` sets `ROOT_UUID`, `BOOT_UUID` and `ESP_UUID=4F4D-5801`, `Engine/installer_data.json` formats the ESP with `volume_id 0x4f4d5801`, and `mac-image-check` requires the fstab line `UUID=4F4D-5801 /boot/efi vfat umask=0077 0 2` exactly. So the derivation can't change fstab, and any second Omarchy ESP has the same serial (9.11).
- Fix: `tools/image/omarchy-esp-generator`, a systemd generator the derivation installs at `/usr/local/lib/systemd/system-generators/`. At every boot (and every `daemon-reload`) it reads the PARTUUID aura names in `/proc/device-tree/chosen/asahi,efi-system-partition` and writes `boot-efi.mount` for `/dev/disk/by-partuuid/<it>`, with fstab's options and its fsck, into the early generator directory. That takes precedence over the unit systemd-fstab-generator makes from fstab. Without the property, or with anything but a canonical UUID, it writes nothing and fstab applies. The derivation fails if the fstab line it replaces is gone.
- What changes: if the device tree names a PARTUUID with no matching partition, boot now waits for that device and drops to emergency mode, as fstab's own line would for a missing ESP, rather than mounting some other `4F4D-5801` volume. Only systemd's mount unit changes: a plain `mount /boot/efi` outside systemd still reads fstab. The generator logs one line for each outcome (mounting PARTUUID X; no ESP named; malformed) to the kernel log, `journalctl -k`, as systemd.generator(7) asks of generators, so a bad boot shows which path it took. Like systemd's own unit for the fstab line, the unit sets `SourcePath=` and orders after the device's `blockdev@` target.
- `tools/tests/omarchy-esp-generator-test.sh` covers the property as read on the J616c (lower case, NUL-terminated) and in upper case, and the unit's mount options, fsck dependency and ordering. It checks the unit has the same name, mount point, type and options as the one systemd's own `systemd-fstab-generator` makes from the pinned fstab line, runs `systemd-analyze verify`, and checks refusals (no property, malformed or extra text) and the log line for each outcome. It skips when run as root, where the generator reads the live device tree. It passes on dev-machine-01, and a generator with wrong options or without the fsck ordering fails it. Not yet run: the generator on the Mac's own Linux, and the end-to-end check in OMS-14. Keeping the leftover ESP (disk0s8) during that reinstall would reproduce the original bug.
- Same risk, not covered here: `/boot` (ext4, shared `BOOT_UUID`) on a Mac with a second complete Omarchy install (OMS-15).
- Run on the Mac's own Linux (2026-11-15, as `clempe`, into a scratch directory, nothing installed): the generator read `272043e7-ec24-4890-93d6-545cfbb8329b` from `/proc/device-tree/chosen/asahi,efi-system-partition` and wrote `boot-efi.mount` for `/dev/disk/by-partuuid/272043e7-ec24-4890-93d6-545cfbb8329b` (`nvme0n1p4`, the mounted `/boot/efi`). Its `What=`, `Where=`, `Type=`, `Options=umask=0077` and `systemd-fsck@`/`blockdev@` ordering match field for field the unit `systemd-fstab-generator` makes today from the Mac's hand-edited fstab line (`PARTUUID=272043e7-… /boot/efi vfat umask=0077 0 2`), so with the generator the hand edit is no longer needed. `lsblk` still shows the first attempt's ESP `nvme0n1p8` (PARTUUID `406a9e32-2509-44d1-a557-7433956bef5c`) with the same serial `4F4D-5801`, the case the generator guards against. The test passes on dev-machine-01 after this run as well. What's left is the end-to-end check in OMS-14.
