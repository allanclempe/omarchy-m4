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
| Installer changes (admission, Mach-O Recovery modes, engine, Wi-Fi fix) | `patches/j616c-installer.patch`, against omarchy-mac-installer `a576543` |
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

### 9.17 Installer: enrol the J616c Stage 1 unpadded (OMS-11, 2026-11-15)
- The installer's Recovery step padded aura's Mach-O boot object to the 128 MiB execute window (`macho-ctxr`). On the J616c that object loops silently ("Attempt 2" and the USB test, 2026-11-13). The same object unpadded boots the confined Stage 2 and Linux runs all 14 cores (9.12). That was measured with Stage 1 from aura 1.0.0b13 and Stage 2 from `94d8e6e4`. aura's `docs/macho-boot-object.md` says a current Stage 2 "refuses to start an OS under an unpadded Stage 1 on a confined machine". The working hypothesis is that it boots here because Stage 2 hands over to its embedded U-Boot rather than starting Linux itself; 9.12 found the 14 cores unexpected and didn't explain them. This is a deliberate deviation, to report to Aurora with the evidence. If a later aura Stage 2 refuses the U-Boot handover too, this needs revisiting.
- `patches/j616c-installer.patch` adds a `macho-unpadded` boot mode. Recovery stages the same filled object and `m1n1/boot-ctxr.bin`, enrols with `--compress`, and still checks the object's config block and `kmutil inspect` (`kcbz 0`, `kcrz` = load address to the end of `__TEXT_EXEC`; the hand-enrolled object read `kcrz 1769472`). The engine picks it for `j616cap`, the only board that enrols a Mach-O object, so nothing stages `macho-ctxr` today; it stays for chips whose padded object starts. The unpadded path also checks the object is aura's (entry point and `AURALOAD` header), as padding did. `tools/derive-j616c-image` now requires a Recovery app containing the literal `macho-unpadded/aura-boot.macho`.
- Checked on dev-machine-01: the engine's Recovery and asahi tests pass (35 and 162), and `test/all` passes except one script test that needs macOS's `shasum`. The engine lock's overlay digests and name were refreshed (`engine_pin.py name --write`: `v0.9.2-omarchy.20261115.f6112d89ebf1`); that engine archive is built on the Mac with the image rebuild (OMS-14). On the Mac (macOS 26.7.3, Swift 6.4.2, 2026-11-15), after the review fixes: `Recovery/test-all.sh` passes all 20 checks, and `swift test` runs 638 tests with 0 failures (1 skipped, as before). The engine `v0.9.2-omarchy.20261115.f6112d89ebf1` was built twice with `prepare-engine.py`'s own steps, byte-identical (17,911,927 bytes, sha256 `fd144c95…0978`), and pinned. The unmodified `prepare-engine.py` then reproduced it against that pin (two more identical repacks, `archive_modes=passed`). The archive is in the Mac's `build/engine/`. `test/all` on the Mac passes in full (77, 449, 303 and 36 tests) when `python3` is 3.12. With macOS's own Python 3.9 the engine tests fail on 3.10-only syntax, an environment issue, not this change.
- Other posts checked for clues: the J604 (base M4, T8132) bring-up also enrols Stage 1 by hand and uses `m1n1/boot-ctxr.bin` with Aurora's Stage 2 trials, and has nothing on padding. The M4 Max GPU post's `aurora-silicon/mesa#85` and `linux#525` ("T6041/J616c GPU, protected audio and HEVC") were merged on 2026-11-05 and are in the kernel and Mesa this Mac runs. Its open gaps include GPU "firmware reboots on concurrent calls", one to watch in the soak test, and #525's HEVC is a lead for OMS-4.

### 9.18 Mount /boot/efi from the ESP the Mac boots (OMS-12, 2026-11-15)
- Every Omarchy image carries fixed identifiers: `image-builder/bin/build-mac-image` sets `ROOT_UUID`, `BOOT_UUID` and `ESP_UUID=4F4D-5801`, `Engine/installer_data.json` formats the ESP with `volume_id 0x4f4d5801`, and `mac-image-check` requires the fstab line `UUID=4F4D-5801 /boot/efi vfat umask=0077 0 2` exactly. So the derivation can't change fstab, and any second Omarchy ESP has the same serial (9.11).
- Fix: `tools/image/omarchy-esp-generator`, a systemd generator the derivation installs at `/usr/local/lib/systemd/system-generators/`. At every boot (and every `daemon-reload`) it reads the PARTUUID aura names in `/proc/device-tree/chosen/asahi,efi-system-partition` and writes `boot-efi.mount` for `/dev/disk/by-partuuid/<it>`, with fstab's options and its fsck, into the early generator directory. That takes precedence over the unit systemd-fstab-generator makes from fstab. Without the property, or with anything but a canonical UUID, it writes nothing and fstab applies. The derivation fails if the fstab line it replaces is gone.
- What changes: if the device tree names a PARTUUID with no matching partition, boot now waits for that device and drops to emergency mode, as fstab's own line would for a missing ESP, rather than mounting some other `4F4D-5801` volume. Only systemd's mount unit changes: a plain `mount /boot/efi` outside systemd still reads fstab. The generator logs one line for each outcome (mounting PARTUUID X; no ESP named; malformed) to the kernel log, `journalctl -k`, as systemd.generator(7) asks of generators, so a bad boot shows which path it took. Like systemd's own unit for the fstab line, the unit sets `SourcePath=` and orders after the device's `blockdev@` target.
- `tools/tests/omarchy-esp-generator-test.sh` covers the property as read on the J616c (lower case, NUL-terminated) and in upper case, and the unit's mount options, fsck dependency and ordering. It checks the unit has the same name, mount point, type and options as the one systemd's own `systemd-fstab-generator` makes from the pinned fstab line, runs `systemd-analyze verify`, and checks refusals (no property, malformed or extra text) and the log line for each outcome. It skips when run as root, where the generator reads the live device tree. It passes on dev-machine-01, and a generator with wrong options or without the fsck ordering fails it. Not yet run: the generator on the Mac's own Linux, and the end-to-end check in OMS-14. Keeping the leftover ESP (disk0s8) during that reinstall would reproduce the original bug.
- Same risk, not covered here: `/boot` (ext4, shared `BOOT_UUID`) on a Mac with a second complete Omarchy install (OMS-15).
- Run on the Mac's own Linux (2026-11-15, as `clempe`, into a scratch directory, nothing installed): the generator read `272043e7-ec24-4890-93d6-545cfbb8329b` from `/proc/device-tree/chosen/asahi,efi-system-partition` and wrote `boot-efi.mount` for `/dev/disk/by-partuuid/272043e7-ec24-4890-93d6-545cfbb8329b` (`nvme0n1p4`, the mounted `/boot/efi`). Its `What=`, `Where=`, `Type=`, `Options=umask=0077` and `systemd-fsck@`/`blockdev@` ordering match field for field the unit `systemd-fstab-generator` makes today from the Mac's hand-edited fstab line (`PARTUUID=272043e7-… /boot/efi vfat umask=0077 0 2`), so with the generator the hand edit is no longer needed. `lsblk` still shows the first attempt's ESP `nvme0n1p8` (PARTUUID `406a9e32-2509-44d1-a557-7433956bef5c`) with the same serial `4F4D-5801`, the case the generator guards against. The test passes on dev-machine-01 after this run as well. What's left is the end-to-end check in OMS-14.

### 9.19 Updates without hand guards: pin + Aurora's trials (OMS-13, 2026-11-15)
- The installed Mac survives `omarchy update` only through hand guards (9.14): Stage 2 rebuilds off, kernel and Mesa held, and the `owner-boot-chain` marker. The owner chose this policy for the image: **pin + trials**. The kernel, Mesa, U-Boot and aura update from `[aurora]`. Every boot-chain change rebuilds Stage 2 from the pinned aura `94d8e6e4` Stage 2 (`M1N1=` in `/etc/default/update-m1n1`, 9.15). Aurora's trial boots each rebuild once: `update-m1n1` writes `m1n1/boot-ctxr.bin.next` and arms `aura-try`; `aurora-stage2-commit.service` commits it once `multi-user.target` is reached; `aurora-stage2-guard.timer` returns a trial that reached Linux but never committed after 12 minutes. A trial that never reaches Linux (stuck at U-Boot, for instance) falls back only after a reset. aura's 178 s boot watchdog is armed when no host is attached and should provide that, but it's unproven here; otherwise it takes a hard power-off.
- Omarchy's update check (`omarchy-mac-boot` `update-verify` → `omarchy-apple-silicon-boot-check --boot-chain`) rebuilds `m1n1/boot.bin` the stock way, so it can never verify Aurora's `boot-ctxr.bin`. As the owner chose, the image ships `/etc/omarchy-mac-boot/owner-boot-chain` naming the chain, the mechanism Omarchy's manual gives for this case: updates finish with a warning instead of refusing. The proper fix in the check is OMS-16.
- `tools/derive-j616c-image` now fails if `/etc/default/update-m1n1` sets `M1N1_UPDATE_DISABLED`, if Aurora's `95-m1n1-install.hook` is missing or overridden in `/etc/pacman.d/hooks` or any other `HookDir`, or if pacman's resolved configuration (`pacman-conf`, Include files and all) ignores anything but `m1n1-aurora` or any group. It enables `aurora-stage2-commit.service` and `aurora-stage2-guard.timer` and checks them with `systemctl is-enabled` (the asahi-scripts install script presets them too). As a defensive guard it removes any Stage 2 trial state before the image is sealed: `aura-try*` at the ESP root, `m1n1/*.next`, `*.next.json` receipts, `*.failed-*` candidates, and `/var/lib/aurora-stage2/attempts/*`. That way a fresh install can't commit a candidate built before the pin. In this build the hook can't arm a trial anyway: the chroot's device tree names no Apple board and no aura Stage 1, so `update-m1n1` refuses during package installs, and the two explicit Stage 2 builds write their targets directly. It writes the marker with a short chain name, `aurora-silicon aura-94d8e6e4`, as its first line. Checked with `bash -n`, and the cleanup on a fake image tree that had every kind of trial file.
- Aurora commits a trial only if `update-m1n1 --commit` passes its sanity check: `/sys/kernel/debug/devices_deferred` readable (debugfs mounted) with no device-tree device still deferred, root on NVMe, and the display controller bound. Otherwise the guard returns the trial at 12 minutes and that candidate is never re-armed, so the first real trial on the Mac should be watched. Risks: `[aurora]` is a testing channel, and a future kernel could want a newer aura Stage 2 than the pin. A bad Stage 2 is caught by the trial, but a bad kernel or Mesa isn't. The guard timer counts from boot, so a slow disk password could roll back a good trial (OMS-17; the J604 bring-up patched this). Remove the pin and the marker once an aura release has `aaec599f` and OMS-16 is done.
- Not yet proven: an `omarchy update` across a kernel or aura update on a Mac running this policy. The installed Mac still has the freeze guards from 9.14.

### 9.21 Ambient light sensor: disabled in the kernel build we run (OMS-3, 2026-11-15)
- The keyboard backlight works: `/sys/class/leds/apple::kbd_backlight` (driver `leds_pwm`, 128/255), and the owner confirmed it lights. The J616c has no keyboard-brightness keys (F1/F2 are display brightness). What's missing is following the room light.
- The sensor hardware is found. The AOP (`apple_aop 510c10000.aop`) starts, and its firmware logs "[ALS1] VD6286 -- Found device with ID: 0x1c" and "AOP IS READY". The calibration file is present (`/lib/firmware/apple/aop-als-cal.bin`, 193 bytes, extracted from macOS). So the first-boot mkinitcpio warning about it (9.12) was likely from building the initramfs before extraction; the file carries no timestamp to confirm it.
- But the `aop_als` IIO driver never binds, so there's no `/sys/bus/iio` device. The ALS node (`aop@510600000/als`, `apple,t6041-aop-als`) is disabled in the tree the running kernel sees (`/proc/device-tree/aop@510600000/als/status` reads `disabled`), and so is `las` (lid angle). The kernel package's own `/usr/lib/modules/7.3.0-1-36-ARCH/dtbs/t6041-j616c.dtb` (`pacman -Qo`: `linux-aurora 7.3.0.aurora1-36`) has both disabled too, so the live tree matches what Aurora's kernel ships.
- Aurora's tree enabled it in `5b192f8d` (Jos Dehaes, "t6041-j614c-j616c: enable the AOP light and motion sensors": removes the `&aop_als`/`&aop_las` disables and adds the M4 Pro's accel, gyro, devmotion6 and als-temp nodes). PR #1466 was merged into `integration/aurora` at 2026-11-12 22:18 UTC, about ten hours after our package was built (`pacman -Qi` Build Date: 2026-11-12 22:20:57 +1000, 12:20 UTC). `pacman -Sl aurora` on 2026-11-15 still offers only 7.3.0.aurora1-36.
- So OMS-3 waits for Aurora's next kernel build. Linux gets its device tree from Stage 2 (`m1n1/boot-ctxr.bin`), so even a new kernel package doesn't change it until Stage 2 is rebuilt, and that rebuild must use the pinned aura `94d8e6e4` (`M1N1=`) for the ANS restart. On this Mac the guards block both steps: `IgnorePkg` holds `linux-aurora` back and `M1N1_UPDATE_DISABLED=1` stops the rebuild. They come off with the pin-and-trials policy (9.19, OMS-13, PR #4 pending) or once an aura release has `aaec599f` (Aurora question 1). This Mac has no `M1N1=` pin yet (`/etc/default/update-m1n1` has none, and there's no `/usr/local/lib/aura`), so lifting the guards also means installing the pinned Stage 2 and its `M1N1=` line first. On the reinstall, the image's kernel, and with it the device tree `tools/derive-j616c-image` puts into Stage 2, come from whatever `[aurora]` has when the script runs; the Stage 2 code itself stays the pinned aura `94d8e6e4`. So the image has to be rebuilt after Aurora's build lands (OMS-14), not installed from an older one. The script accepts only a 7.3 kernel (`[[ $kver == 7.3.* ]]`), so a 7.4 build needs that check relaxed. Then: install `iio-sensor-proxy-aurora` and `aurora-kbd-light`, check `monitor-sensor` reads lux and the keyboard light follows the room, and add them to the image build.

### 9.22 Mount /boot from the partition after the ESP (OMS-15, 2026-11-15)
- Same flaw as 9.18, one partition along: every Omarchy Boot partition is ext4 with `BOOT_UUID=4f4d5801-424f-4f54-8000-000000000001`, and fstab mounts `/boot` by it. A leftover Boot partition that an earlier attempt had already written could be mounted instead, along with its initramfs and, on encrypted installs, its `encrypt.state` and staged key. This Mac's leftover Boot partition (`nvme0n1p9`) has no filesystem, so it didn't happen here.
- What ties `/boot` to the booted install is the installer's layout. A complete install is always four partitions next to each other on the disk: APFS stub, ESP, Boot, Root (`omarchy_planner.collect_existing_installs`, which walks the partitions in disk order). Its Replace removes complete installs, but not a partial leftover. Partition numbers needn't follow position: this Mac's first attempt holds slots 7 to 10 and the current install slots 3 to 6. sysfs gives each partition's `PARTUUID` (`/sys/class/block/*/uevent`) and start sector (`start`), so the partition after aura's ESP can be found without probing devices.
- Root is already safe on encrypted installs: the command line's `rd.luks.name=79598f87-…` names this install's own LUKS volume. An unencrypted install would mount root by the fixed btrfs UUID too. That's the initramfs's job, outside this fix.
- Fix: `omarchy-esp-generator` also writes `boot.mount` for the partition on the ESP's disk that starts next after the ESP. It mounts by PARTUUID, with fstab's options (`defaults,noatime`) and fsck. It does this only when that partition's ext4 superblock has ext4's magic and the image's Boot UUID. In every other case it logs why and leaves `/boot` to fstab: no ESP in sysfs, the ESP's PARTUUID on two partitions, no next partition, an unreadable device, or another filesystem. The derivation checks that fstab's `/boot` line is the one it stands in for.
- The tests model the J616c's disk: stub p3, ESP p4, Boot p5, and the first attempt's ESP p8 and p9 after them. On this Mac p9 has no filesystem; the fixture gives it the Boot UUID, to stand for a leftover that does. A second disk carries a Boot-UUID partition 5 that starts just after the ESP's sector. The tests check that p5 is chosen, that a reused low slot loses to the partition that starts next, and that the unit matches `systemd-fstab-generator`'s for the image's `/boot` line, and they cover each refusal. Mutating the generator makes them fail: scanning every disk, picking by the wrong order, taking a partition before the ESP, no UUID check, no magic check, accepting an ambiguous ESP, or other options.
- On the Mac (2026-11-15, scratch output directories):
  - As `clempe`, the generator found `nvme0n1p5` through sysfs but couldn't read its superblock, so it left `/boot` to fstab.
  - As root (typed by Allan), it wrote `boot.mount` for `/dev/disk/by-partuuid/3c464bd8-909c-42fb-ac75-d47f02ff8504`, `Where=/boot`, `Type=ext4`, `Options=defaults,noatime`, matching the live mount (`nvme0n1p5`, udev `ID_FS_UUID=4f4d5801-424f-…0001`). It logged both mounts to the kernel log.
  - That run used the first version, which picked the partition numbered after the ESP's. Review changed it to pick by start sector, so it was repeated with the current generator (sha256 `1059c259…7716`, root, 2026-11-15). The result was the same `boot.mount`: `What=/dev/disk/by-partuuid/3c464bd8-909c-42fb-ac75-d47f02ff8504`, `Where=/boot`, `Type=ext4`, `Options=defaults,noatime`. sysfs start sectors confirm `nvme0n1p5` (1419596152) is the first partition after the ESP `nvme0n1p4` (1418572152). The first attempt's partitions come later (p7 at 1675288952, p8, p9).
  - End to end in OMS-14.

### 9.23 Count the Stage 2 trial guard from unlock (OMS-17, 2026-11-15)
- Aurora's trial units (asahi-scripts 20261023-9, read on the Mac):
  - `aurora-stage2-commit.service` runs `update-m1n1 --commit` `After=local-fs.target multi-user.target`.
  - `aurora-stage2-guard.timer` (`OnBootSec=12min`, `ConditionPathExists=/proc/device-tree/chosen/aurora,trial`) runs `update-m1n1 --guard`. If the trial's marker is still `spent`, the guard calls `systemctl --no-block reboot` back to the configured Stage 2 (`bootchain.py` `guard()`). That candidate's attempt record then keeps it from being armed again: `stage_trial()` prints "Stage 2 trial already attempted for candidate …" and arms nothing for a digest it has a record of.
- `OnBootSec` counts from kernel start. On an encrypted install, the disk password is asked in the initrd, before the root exists. On this boot the initrd stage, password included, took 7.8 s (`systemd-analyze`: "7.848s (initrd)"; the journal's monotonic clock has "Finished Cryptography Setup for root" at 7.81 s). Every second at the prompt adds to that, and `OnBootSec` counts all of it.
- If the owner leaves the prompt for over 12 minutes after an update, the guard timer is already due when the root comes up. A monotonic timer that is already due fires when it starts. The timer starts early, after `sysinit.target` and before `timers.target`, which can be before the commit service, ordered after `multi-user.target`. A good trial is then rolled back and not retried. That leaves the new kernel booting with the previous Stage 2's device tree until the next boot-chain change.
- Fix: a drop-in, `tools/image/aurora-stage2-guard-from-unlock.conf`, which the derivation installs at `/usr/local/lib/systemd/system/aurora-stage2-guard.timer.d/`. It clears `OnBootSec=` and sets `OnActiveSec=12min`. The timer is activated in the booted system, after unlock, so the trial gets its 12 minutes from there. The commit service has run by then, so a committed trial makes the guard a no-op, as before. Unencrypted installs change by seconds. This follows the J604 bring-up's fix ("the trial's guard timer counts from unlock instead of kernel start"), done as a drop-in instead of a patched asahi-scripts. The derivation stops if Aurora's timer no longer triggers on `OnBootSec=12min` alone, so an upstream change gets a fresh look.
- Checked:
  - `systemd-analyze --root=… cat-config` on an image-like tree finds the drop-in from `/usr/local/lib` next to the timer in `/usr/lib`.
  - `tools/tests/aurora-stage2-guard-test.sh` loads a copy of Aurora's timer into a user manager on dev-machine-01. It reads `TimersMonotonic`: `OnBootUSec=12min` without the drop-in, only `OnActiveUSec=12min` with it, `AccuracySec` kept. It fails if the reset line is removed.
  - In review, `tools/derive-j616c-image` gained two checks.
    - It checks every trigger line of Aurora's timer, `OnCalendar=` included, since the empty `OnBootSec=` resets them all.
    - After installing, it reads what systemd will merge (`systemd-analyze cat-config` in the image). That must be exactly `OnBootSec=12min OnBootSec= OnActiveSec=12min`, so an override in `/etc` or another drop-in stops the build.
  - The test also does three things:
    - it starts the throwaway timer, checks it comes due 720 s after starting, and stops it;
    - it runs the same `cat-config` check on an image-like tree;
    - it fails for a drop-in using `OnStartupSec` or missing the reset.
  - Whether aura's 178 s boot watchdog (9.19) would reset the Mac at the password prompt, before 12 minutes could pass:
    - `watchdog0` is the built-in `apple-watchdog` driver (`50836c000.watchdog`, `CONFIG_APPLE_WATCHDOG=y`).
    - The kernel has `CONFIG_WATCHDOG_HANDLE_BOOT_ENABLED=y` and `CONFIG_WATCHDOG_OPEN_TIMEOUT=0`. So a watchdog the driver reports as already running is pinged by the kernel until userspace opens it, with no time limit. Mainline `apple_wdt` reports it when aura left reset enabled; Aurora's 7.3 driver wasn't read.
    - Nothing in userspace opens it here. systemd doesn't (`RuntimeWatchdogUSec=0`), `aurora-system-fixes` (Aurora's reboot watchdog) isn't installed, and no watchdog daemon runs; the only `watchdog` processes are the kernel's `watchdogd` thread and unrelated ones (Hyprland's `--watchdog-fd`, `omarchy-audio-watchdog`).
    - The driver binds before the initrd asks for the password, so the prompt can last past 12 minutes and the case fixed here can happen. Aurora's own `guard()` comment expects this ("even if Linux feeds the hardware watchdog").
    - This build has no watchdog sysfs attributes (`CONFIG_WATCHDOG_SYSFS` not set), so whether aura left it running couldn't be read directly. The direct evidence is uptime: this boot has run for nearly two hours, far past 178 s, with nothing in userspace feeding the watchdog. So either aura left it off, or the kernel feeds it. The kernel feeds it the same way during the initrd's prompt as afterwards, so either way nothing resets the Mac at the prompt.
    - Read 2026-11-15: `/sys/class/watchdog/watchdog0`, `/proc/config.gz`.
  - Not yet run: a real trial with a slow password, which needs the image's update policy on the Mac (OMS-14). Aurora question 3 asks whether Aurora takes this upstream. 9.19's "counts from boot" describes Aurora's timer as shipped; this section changes it for the image.

### 9.25 Realtek firmware for USB-C dongles (OMS-7, 2026-11-15)
- The post-install report's `hardware.firmware` check flagged "r8152 2-1.4:1.0: Direct firmware load for rtl_nic/rtl8153b-2.fw failed with error -2" with a USB Ethernet adapter plugged in. In the boot of 2026-11-14 15:57, the adapter enumerated as `enu1u4` at 16:14:32 without its firmware patch ("unable to load firmware patch rtl_nic/rtl8153b-2.fw (-2)"). It dropped off the bus three times, each with "Stop submitting intr, status -71" and a USB disconnect (16:17:16, 16:29:17, 17:22:03). It re-enumerated without the patch after the first two (16:17:22, and 17:17:04 after a 48-minute gap), and didn't return after the third. NetworkManager kept `enu1u4` `unavailable` (no carrier) the whole time, so no traffic ever ran over it. The drops may be hand unplugs (that log pattern is what an unplug looks like), the cable, or the missing patch. So the check with the firmware should have a link up and watch for drops.
- Cause: the Mac has no `linux-firmware*` package at all, so `/usr/lib/firmware/rtl_nic/` doesn't exist. The Mac's own firmware comes from macOS, and Omarchy's Mac images (`image-builder/bin/build-mac-image`, the Apple package list) don't add Arch's `linux-firmware` splits.
- `rtl_nic/rtl8153b-2.fw` is in `core/linux-firmware-realtek`. On the Mac's mirror (`arm-mirror.omarchy.org`) that's 20261019-1: 3.99 MiB to download, 46.22 MiB installed, depending only on `linux-firmware-whence`. It ships plain `.fw` files; x86 Arch's build compresses them as `.fw.zst`, and this kernel loads either (`CONFIG_FW_LOADER_COMPRESS_ZSTD=y`, `CONFIG_USB_RTL8152=m`). It also carries the RTL8153A/C and RTL8156A/B patches, and the Realtek USB Wi-Fi (`rtw88`, `rtw89`, `rtlwifi`) and Bluetooth (`rtl_bt`) firmware common in USB-C docks and dongles. `[aurora]` and `[omarchy]` don't shadow it: Aurora's `aurora-firmware` is Apple device firmware, and `[omarchy]` only has `linux-firmware-qcom`.
- Fix: the derivation installs `core/linux-firmware-realtek` and checks that the package owns `rtl_nic/rtl8153b-2.fw(.zst)`. The module loads after the root is up, from the root, so the initramfs doesn't need the firmware. Whether mkinitcpio puts it there anyway wasn't checked (the initramfs is root-only), and nothing depends on it. pacman's mkinitcpio hooks trigger on `usr/lib/firmware/*`, though, so installing or updating the package rebuilds the initramfs, the UKI and `limine.conf` on the ESP. That's one extra rebuild in the derivation, before its UKI check, and one on the Mac with each package update. Stage 2 isn't touched.
- On the Mac, Allan installed it by hand (2026-11-15 19:43, `pacman -S --needed core/linux-firmware-realtek`, 20261019-1 with `linux-firmware-whence`). The hooks rebuilt the initramfs and UKI, and `/usr/lib/firmware/rtl_nic/rtl8153b-2.fw` exists. Reloading `r8152` without the adapter plugged in only registered the driver.
- With the firmware installed (2026-11-15, same boot):
  - The adapter (Realtek `0bda:8153`, "USB 10/100/1000 LAN", bcdDevice 31.11, now on bus 4) enumerated at 19:55:43 and became `enu1u4` with no "Direct firmware load … failed" line, where every connect on 2026-11-14 had logged one. r8152 logs nothing when the patch loads.
  - A cable plugged in at 19:59:14 brought carrier up (one off/on blip at 19:59:16–18 while seating) and traffic arrived on `enu1u4` at 192.168.4.32. Carrier went off at 19:59:26 when Allan unplugged the cable.
  - No `status -71` or USB disconnect this time.
  - That closes the firmware gap. The earlier drops were most likely hand unplugs too.
- Not yet run: the derivation (OMS-14).

### 9.26 Wi-Fi rejoin after a driver reload: a race in the test's unload (OMS-5, 2026-11-15)
- The report's `network.wifi-first-join` failed: "Wi-Fi didn't associate within 45 s of the driver loading". The check unloads `brcmfmac` while connected (`modprobe -r brcmfmac_wcc brcmfmac`), loads it again and waits for an association.
- Joins outside the test are quick (BCM4388, firmware 23.50.20.2.41.51.209, iwd 3.12, NetworkManager 1.58.1, a home mesh network with six access points, regulatory domain AU):
  - After the four cold boots in the journal from 2026-11-14 15:57 to 2026-11-15 16:44, iwd reached `connected` 1.29–1.38 s after the firmware loaded. The final DHCP lease line came 0.16–2.3 s after that.
  - The earlier installer boot (2026-11-14 13:45) is left out: it had no known network yet and waited for a manual connect.
  - The report has an IPv4 address again 2.6 s after resume. The live link is 5180 MHz, 160 MHz HE, about −40 to −47 dBm.
- What happened in the test (boot of 2026-11-14 15:57, 17:14):
  - 13.654 `modprobe -r`. 13.666 iwd got the deauthentication (reason 1) and went to `autoconnect_quick`.
  - 14.172, 0.52 s after the unload began, the quick scan's trigger failed ("CMD_TRIGGER_SCAN: Input/output error"), and iwd moved to `autoconnect_full`. From its cached results it tried all six access points within 1.5 ms, and every one ended `connect-failed, status: 1` on a radio already going away.
  - 14.178 iwd dropped its scan context, 6 ms after the failed trigger. 14.270 the driver was gone.
  - 16.714 the firmware was back, and 17.398 iwd went from `autoconnect_quick` to `autoconnect_full` without a connect attempt.
  - At 17:15:00, 45 s after the load, the check's retry ran (`modprobe brcmfmac` again, then a NetworkManager activation from `nmcli`), and iwd connected in 0.3 s.
- Why iwd didn't reconnect by itself, from iwd 3.12's source:
  - A failed connect with status 1 goes through `station_retry_with_status`, which blocks that access point (`blacklist_add_bss`, `[Blacklist] InitialTimeout` 60 s by default; the Mac has no `/etc/iwd/main.conf`).
  - Autoconnect skips blocked access points, while an explicit connect, like the activation at 17:15:00, doesn't.
  - So the stall is consistent with all six being blocked, but not shown: iwd's debug log was off, and the check's retry ended the stall before the block would have expired (17:15:14). The first periodic scan after that would likely have come later still.
- Repeated on purpose (2026-11-15 21:18, `tools/wifi-reload-timing.sh`, run by Allan at the Mac):
  - A plain reload, as the check does it, rejoined in 2.6 s from the `modprobe` that loads the driver.
  - A clean reload, radio off first and on after, also rejoined in 2.6 s.
  - In the plain run, iwd dropped its scan context 0.52 s after the deauthentication with no failed scan trigger before it, so it never tried to connect on the dying radio, and nothing was blocked.
- So the failure is a race during the unload: whether the driver's error reply to iwd's quick scan arrives a few milliseconds before iwd drops its scan context. A reload that misses the race rejoins in 2.6 s. The failure itself wasn't reproduced (one plain run), so the race is narrowed, not proven, and how often it hits isn't known. The script now takes a number of plain runs and reports for each whether the race hit (failed connects before the load).
- Decision (owner): no change to the image for the test. The check should turn the Wi-Fi radio off before unloading (`nmcli radio wifi off`, reload, `nmcli radio wifi on`), so iwd makes no connect attempts on a radio that's going away; that's noted on OMS-8, the test-tool task. Whether radio-off avoids the race was also not shown, since the plain run missed it.
- Found in review: Omarchy's own `omarchy-wifi-resume-fix` (`omarchy-mac` 0.2.3-2) reloads `brcmfmac` the same plain way, after a resume where Wi-Fi didn't come back, and gives up after 30 s. It can meet the same race, possibly with access points already blocked from failed associations before the reload. Every run in these journals said "no reload needed", so there's no field data. Filed as OMS-20.

### 9.27 Camera: streaming without its sensor tuning (OMS-22, 2026-11-16)
- Allan found the camera picture soft and "a bit pixelated" during the 2026-11-15 report run, and much sharper in macOS. The report's `camera.image` was answered "yes", so the uploaded report shows the camera as a pass.
- Linux offers one format, NV12, at 1920x1080, 1280x960, 1280x720, 1080x1080 and 640x480, 30 fps at most (`v4l2-ctl --list-formats-ext` on `/dev/video3`, driver `apple-isp`, card "FaceTime HD Camera"). The test streamed 1920x1080, so it isn't a small mode scaled up.
- Compared on 2026-11-16, same seat, laptop position and room, minutes apart: two Photo Booth videos on macOS 26.7.3 (H.264, 1620x1080, Video Effects off) against a Linux still and two 4 s videos (ffmpeg from `/dev/video3`, 1920x1080). The face is about the same size in both, so the field of view is close. Measured with ffmpeg on whole frames:
  - Pixel noise, as PSNR between a frame and a median-filtered copy (higher is cleaner): macOS 46.5 and 47.3 dB, Linux 20.2, 20.4 and 21.6 dB. About 26 dB, roughly twenty times the noise amplitude on Linux.
  - Average brightness (YAVG): macOS 119 and 130, Linux 101, 103 and 117.
  - Colour: Linux has purple speckle in the shadows and orange highlights; macOS looks natural.
  - ffmpeg's `blurdetect` rated Linux sharper (2.7 against 8.3), because noise reads as fine edges. Not used.
  So "soft and pixelated" is colour noise and missing processing, not focus or resolution. The frames stay off the repo.
- Cause, from the kernel log when the camera opened: `apple-isp 580000000.isp: setfile 'apple/isp_2224_01XX.dat' missing, streaming without sensor tuning`. The Mac has setfiles for sensors 1820, 1822, 1921, 1922, 8720 and 8723 in `/usr/lib/firmware/apple/`. No package owns them (dated 1970): they come from the vendor firmware the installer collects from macOS.
- Why it's missing: omacom/omarchy-mac-installer's `Engine/overlay/src/omarchy_isp.py` (at `a576543`, this repo's installer base) extracts only setfiles in a fixed registry from macOS's `appleh13camerad` and `appleh16camerad`: the inherited list plus IMX558 `1925`. "Other unqualified sensor IDs are not" added, and 2224 is one of them.
- Who has this already:
  - Aurora's kernel (`drivers/media/platform/apple/isp/isp-cam.c` on `integration/aurora`) has the entry: `[ISP_IMX958_2224_01] = {0x958, 0x22240106, "apple/isp_2224_01XX.dat", 0x6ff4, 0, ISP_TEMPORAL_FILTER_BAND0}`. The IMX958 is the 16" M4 Pro's (J616s) sensor too, and it gets the ISP's temporal noise filter. The J616s camera work and its docs (`Documentation/driver-api/media/drivers/apple-isp-j616s.rst`) are by GitHub user RyanTheTide. Recent changes to the driver are by DjDeveloperr, axboe and satchlj.
  - Aurora's own installer collects it: aurora-silicon/aurora-installer `a88e1d16c` (RyanTheTide, 2026-10-31, "firmware: extract H17 camera tuning from current daemon locations"), documented in `macOS/docs/camera-tuning.md` as "IMX958 (J616s) `apple/isp_2224_01XX.dat`", 0x6ff4 bytes from the daemon and uploaded.
  - So the fix is a port, not new work: add IMX958 2224 to the omacom installer's registry, as `omarchy_isp.py` already does for IMX558 1925. The camera-tuning doc also notes that per-module calibration (`iCCl`) isn't uploaded by any kernel yet, so that stays out.
- Next (OMS-22): on macOS, check this Mac's `appleh16camerad` carries a 2224 setfile with that magic and size. Put it in place by hand on the Linux side, confirm the log line is gone and the picture is close to macOS, re-run `camera.image`. Then add the registry entry to `patches/j616c-installer.patch` with a test, so a fresh install collects it (OMS-14). Mention it to the Omarchy M team: J604, J704 and other M4 and M5 cameras likely need their own entries.
- Ported (2026-11-16): `patches/j616c-installer.patch` adds `IMX958_2224 = SetFile(0x958, 0x22240106, "2224_01XX", 0x6FF4)` to `omarchy_isp.py`, next to IMX558 1925, with the same values as Aurora's kernel and installer. Two new tests: the 2224 file extracted at its size rounded to 64 bytes (0x7000; the driver uploads the first 0x6ff4) and refused when truncated, and an `appleh16camerad` carrying both new sensors. Without the entry, three tests fail. The lock's two overlay digests are updated and the engine renamed `v0.9.2-omarchy.20261116.e5ff013ee6b2` (`engine_pin.py name --write`, `check` passes). Its archive size and digest still describe the previous engine until it's rebuilt on the Mac (OMS-14).
  - On dev-machine-01 the engine overlay suite runs 451 tests with none failing. `test/all` also has script and shell tests that need macOS's `shasum`; they fail the same way with and without the change, so the full run is part of the Mac build.
  - One difference from Aurora's extractor, left as it is: ours copies the padding up to 64 bytes from the daemon, Aurora's pads with zeros ("padding is never copied from the next object in the daemon"). For 2224 the driver uploads exactly 0x6ff4 bytes, so the padding is never read. For IMX558 1925 (the MacBook Neo), the registry size 0xcbc0 is what the driver uploads while the daemon's file is 0xcba6, so ours sends 0x1a bytes of whatever follows in the daemon as tuning. That's for the Neo's owners and omacom, not this Mac.

### 9.28 The clean reinstall: build inputs and plan (OMS-14, 2026-11-16)
- `tools/derive-j616c-image` now pins the exact `[aurora]` builds (`AURORA_PINS`) and stops before installing if the repo offers anything else, and again if anything else got installed. Aurora's repo keeps only its latest build, so a pin can't fetch an old one: it makes a moved repo a decision instead of a surprise. Checked with `bash -n` and a fake repo (matching versions pass; a newer kernel stops the build).
- Pinned, read from `[aurora]`'s package database on 2026-11-16:
  - `linux-aurora` and `-headers` `7.3.0.aurora1-40`, built 2026-11-15 05:59 UTC from aurora-silicon/linux `9125b314` (alarm-aurora `3fbe46d57`, "pin cand/7.3.0-40"). That source contains `5b192f8d` (1222 commits ahead, none behind), so the light sensor and motion nodes are enabled (OMS-3).
  - `mesa-aurora` and `vulkan-aurora` `1:26.3.0_devel.202611150611.d4ad4a4dce6-1`, built 2026-11-15 07:29 UTC, the Mesa built with that kernel.
  - `aura 1.0.0b13.1-1`, `uboot-aurora 2026.07.aurora11-1`, `asahi-scripts 20261023-9`, `aurora-audio 4.1.aurora2-16`, `speakersafetyd-aurora-profiles 1-2`.
- Untested on this Mac until the reinstall: kernel `-40` (it runs `-36`), that Mesa, and aura `b13.1`'s Stage 1. The live Stage 1 was enrolled from the `b13` object (9.17), and the repo no longer has `b13`. Stage 2 stays the pinned aura `94d8e6e4` build. If the new chain doesn't boot, macOS still starts from Startup Options. The fallback is the previous developer package on macOS (`build/Omarchy-J616c-Developer.pkg`, the 2026-11-13 build with kernel `-36`), so the new build must not overwrite it. The pacman cache can't serve as one: it has `aura 1.0.0b13.1-1` (the live install's package, updated on 2026-11-14), Mesa `202611130318`, `aurora-audio` and the speaker profiles, but no `linux-aurora`, since the kernel came with the image.
- The engine is `v0.9.2-omarchy.20261116.e5ff013ee6b2` once rebuilt: OMS-11's unpadded Stage 1 mode plus OMS-22's IMX958 camera tuning.
- Plan:
  1. Merge OMS-22 (the camera port) and this branch.
  2. On the Mac's Linux: back up the home folder (3.4 GB, about 1.5 GB without `.cache`) to dev-machine-01. On macOS, keep the previous build's package and app as the fallback.
  3. On macOS: make `~/aurora-m4` a clone of this repo, so the build uses main's scripts and patch, not hand copies. Then rebuild the engine (and run `test/all` there), the Recovery app, the edge image (or reuse 2026-11-13's), the derivation, the developer catalog, the app and the package. Check the camera daemon yields `isp_2224_01XX.dat`.
  4. Remove the first attempt's leftover partitions (disk0s7 to disk0s10), with the owner's approval and a listing first.
  5. Install with Replace, then first boot, owner setup and the first `omarchy update`, with no hand steps.
  6. Report with omarchy-m-test, compared with 2026-11-15's (7McWSfw9…). Check the camera log line is gone and `input.ambient-light` passes.

### 9.29 The OMS-14 build (2026-11-16)
- Built on the Mac's macOS from main (`a47b078`, cloned to `~/aurora-m4/omarchy-m4`) and a fresh installer checkout (`work/omi-oms14`: `a576543` plus `patches/j616c-installer.patch`). Outputs are in `build/oms14/`; the 2026-11-13 package in `build/` stays as the fallback.
- **Engine** `v0.9.2-omarchy.20261116.e5ff013ee6b2`: built twice with `prepare-engine.py`'s own steps, byte-identical (17,912,085 bytes, sha256 `45d55b29…154d`), pinned, then reproduced by the unmodified `prepare-engine.py` (`archive_modes=passed entries=1546`). `test/all` on the Mac with Python 3.12 passes in full: 77, 451, 303 and 36 tests.
- **Camera:** the new `omarchy_isp.py`, run on this Mac's `/usr/libexec/appleh16camerad` (and `/usr/sbin`'s copy), extracts `isp_2224_01XX.dat` (0x7000 bytes, sha256 `dce21e48ccd3…`) beside 1921, 1922 and 1925. The old registry skips it, which is why the installed Mac has none.
- **Recovery app** from `work/omi-oms14` (`Recovery/build-recovery.sh`), with the `macho-unpadded` mode. Stage 2 is `build/aura-stage2-94d8e6e/build/aura.bin`, matching `STAGE2_SHA256`.
- **Derivation** in the Lima VM, on the 2026-11-13 edge image and rootfs, Aurora's key from `build/alarm-pkgs/aurora-alarm.asc`:
  - First run stopped at the audio step, its first ever run: `alsa-utils-aurora-1.2.16-1 and alsa-utils-1.2.16-1 are in conflict. Remove alsa-utils? [y/N]`, and `--noconfirm` answers no. On the Mac this had been answered yes by hand. The derivation now removes `alsa-utils` and installs `alsa-utils-aurora` (which provides `alsa-utils=1.2.16`), pins it, and checks `pacman -Dk`. It also now copies its logs to `OUTPUT/failed-logs` on a failure; before, they went with the container's work volume.
  - Second run passed (228 s): kernel `7.3.0-1-40-ARCH`, every `AURORA_PINS` version, `aurora-audio 4.1.aurora2-16` over the image's `4.1.aurora3-3` (as intended, 9.16), Realtek firmware, the ESP generator, the update policy and trial-guard drop-in, the new Recovery app. Payload 4,017,381,908 bytes, sha256 `34f74fd3…dd1f`.
  - `mac-image-check payload edge`: "ok - the edge mac image payload meets the contract", run on the payload and metadata under the standard edge file name, since the checker refuses the `-j616c-dev` name.
- **Developer catalog:** inputs as on 2026-11-13 with evidence revision `j616c-dev.20261116`; the J616c metadata is the derivation's with `supported_fw` cut to `26.6.2`. `make-unsigned-catalog.py --developer` (36 models, sequence 1794801570, URLs on `https://j616c-dev.invalid/assets`), signed with the local key (`catalog-signing.swift sign`), verified against the trust root, 4 offline artifacts bundled. `build-app.sh` needs the engine copied into the checkout's `Engine/artifacts/`.
- **App and package:** `OMARCHY_DEVELOPER_BUILD=1 OMARCHY_OFFLINE_BUILD=1 Packaging/build-app.sh`, then `Packaging/build-developer-pkg.sh`: `build/oms14/Omarchy-J616c-Developer.pkg`, 4,043,608,952 bytes, sha256 `c98dfb12e8a49d28ea9d5c891d232c5f9c026316d19261f2d3043b4f225b75bd`.

### 9.30 The reinstall: installed, but Stage 2 refuses to start the OS (OMS-14, 2026-11-16)
- **Clearing the disk.** The first attempt's partitions (disk0s7 to s10: an empty stub container, ESP `406A9E32…`, and Boot and Root with no filesystem) were removed by the owner with `diskutil`, each partition found by its PARTUUID. Then the app (2.3.17) found the running install and offered only Installation → Remove Omarchy, which refused: "the boot object in its startup container isn't m1n1. It can't be confirmed as one installation, so nothing was changed." Its check looks for `##m1n1_ver##` in the stub's boot object, and aura's Mach-O object has none, so the app can't remove any M4 install (OMS-23). The running install (disk0s3 to s6, ESP `272043E7…`) was removed by hand the same way, after the home folder was backed up to dev-machine-01. The disk then held macOS, 274.9 GB free and macOS Recovery.
- **Packaging.** The first package (version 2.1.0, `build-app.sh`'s default) installed but left the 2026-11-13 app (2.3.16) in `/Applications`: macOS's installer doesn't replace an app with a lower version. Rebuilt with `OMARCHY_APP_VERSION=2.3.17` and the catalog's `latest_version` to match (package sha256 `3dfcda5d…05cb`). The build has to set the version above whatever is installed.
- **Install.** The fresh install made disk0s3 to s6 again: stub container, ESP `6A2FB892-AD59-47D7-811E-9E64269D36FB`, Boot, Root; volume group `D0250F82-1ADD-4E65-AA4D-95A9108F576D`, stub system volume `8213D71C-4BD0-400F-B2ED-ED1A4CABD0F1`, stub OS 25G83 (26.6.2).
- **1TR.** The Recovery app's gate ("Open Omarchy's paired Recovery … belongs to a different installation") was right twice: `bputil -d -v D0250F82…` read `OS Type: ordinary recoveryOS`, `OS Pairing Status: Not Paired`. A press before the hold gives ordinary recoveryOS. Shutting down from the Apple menu, then holding the power button continuously from off until "Loading startup options", gave One True Recovery, and the app enrolled the packaged aura `1.0.0b13.1` object unpadded (`macho-unpadded`). After that, choosing Omarchy boots its Stage 1, so hand enrolment goes through Options (macOS's 1TR), where `kmutil` needs `one true recoveryOS` too ("could not change boot policy" otherwise).
- **First boot: Stage 2 refuses.** aura's Stage 2 (`94d8e6e4`) restarts ANS ("ANS started from off"), starts all 14 CPUs, measures the device tree and U-Boot, then:
  `CTXR exec: CPU 0 could not run the heap probe (ESR 0x8600000c): secondaries are confined at EL2` / `CTXR exec: armed [0x10005d74000, 0x10006020000)` / "the secondary CPUs can only run code in a window, and there is none for the OS: this Stage 1 did not arm a large enough window. Not starting the OS." It then runs the proxy.
  aura's `src/ctxr_exec.c` at `94d8e6e4` says the installer pads the boot object (16 MiB for aura, then a 128 MiB window) and the OS gets that window; an unpadded object arms about 2.7 MB, so whenever the probe finds the secondaries confined, Stage 2 must refuse.
- **What was ruled out, one change at a time, each with the same refusal:**
  1. Stage 1: aura's `1.0.0b13-gf0f180af` dev object, the one hand-enrolled on 2026-11-13 and booted daily since, refilled for the new ESP with the installer's `fill_aurora_stage1` (only the 32-byte config block changed, CRC recomputed; `build/oms14/stage1-b13dev-unpadded.macho`, sha256 `e6e2c4ca…a9dc`) and enrolled by hand from Options (`go-oms14.sh`). Armed window `[0x100063d4000, 0x10006680000)`.
  2. Stage 2 image: the exact 2026-11-14 image (`a0f493b4…f552`, kernel `-36`'s device tree) in place of the new one (`1a0b3993…`, `-40`'s, 4,288 bytes larger). Armed `[0x10005ce8000, 0x10005f94000)`.
  3. `aura-proxy` at the ESP root, as the old ESP had during 9.8–9.10, with the new image back.
- So the objects that booted this Mac daily refuse under this installation. Not compared yet: the old installation's boot policy (never recorded) against the new one (`Security Mode: Permissive`, `Kernel CTRR Status: Disabled`, a custom kernel hash set). Left as is on the Mac: the new install, the b13 dev Stage 1 enrolled, the new Stage 2 image at `m1n1/boot-ctxr.bin`, a copy of it as `m1n1/boot-ctxr.bin.oms14`, `aura-proxy` at the ESP root, and the two files from step 1 (`go-oms14.sh`, `stage1-b13dev-unpadded.macho`). macOS is unaffected. This is Aurora question 2 with a new fact: the unpadded path isn't just undocumented, its success depends on something beyond the two objects.

### 9.31 The fix: a raw Stage 1 after `bputil -nc` (OMS-14, 2026-11-16)
- **What Aurora's docs say** (aurora-silicon/aura main, `docs/macho-boot-object.md`, `docs/recovery-enroll.md`; aurora-installer `macOS/Recovery/README.md`): with `kcbz` zero, iBoot leaves the CTXR windows armed and locked on the secondary CPUs for *every* Mach-O boot object. An unpadded object "arms only about 5 MiB … To boot an OS it has to be padded", and "a Stage 2 from this tree refuses to start an OS under an unpadded Stage 1 on a confined machine". That is the 9.30 refusal, as designed. The padded object is Aurora's path on M4-class chips, qualified on the J616s (T6040) release after release ("`m1n1/boot-ctxr.bin` …, padded Stage 1: boots to gdm"), with the OS running at EL2 inside the 128 MiB window on a kernel built with `CONFIG_ARM64_CTXR_EXECMEM` (ours is). So the unpadded boots of 2026-11-13 to 11-16 were the anomaly, never the path; the engine's own comment in `patches/j616c-installer.patch` called it "a working hypothesis".
- **For a raw boot object the rule differs:** "For a raw image, Kernel CTRR is not enabled. Enrolling a Mach-O object turns it back on, and a raw Stage 1 then gets no secondary CPUs." A raw Stage 1 enrolled with Kernel CTRR *off* boots with the secondaries free, "seen on a J616s". The recipe is `bputil -nc -v <group>` first, then `kmutil configure-boot --raw --entry-point 2048 --lowest-virtual-address 0`, which is exactly Omarchy's stock `raw` Recovery mode for M1 to M3.
- **The padded loop isn't our port's fault.** Aurora's own padding tool (`macOS/Recovery/Tools/ExecuteWindowTool.swift` with `AuraStage1.swift`, aurora-installer `832788c85`), compiled on the Mac and run on the refilled b13 object, produced an object of 153,190,400 bytes with `kcrz 153141248`, `kcbz 0`, `kcwf 153141248` (`kmutil inspect`), the same figures as our port on 2026-11-13 (8.4) and as aura's J713 notes (`kcrz 0x920c000`). The padding function in our `MachOStage1.swift` is Aurora's line for line (one `public` differs). So the object that reboots this J616c silently every ~10 s is the one Aurora's tool makes: a report for Aurora, with the object attached.
- **Test (2026-11-16, by Allan):** `stage1-b13dev-raw.bin` is the raw image inside the refilled b13 object (ESP `6a2fb892-…`, Stage 2 `;m1n1/boot-ctxr.bin`, proxy window 0; 1,703,936 bytes, sha256 `78268eb7817f2ee35f20a6f1edbd08b872ce984d537e4d1cd3b49f7845d1034f`), with `aura-proxy` removed from the ESP. From One True Recovery (Options, continuous hold from off), `go-oms14-raw.sh` ran `bputil -nc -v D0250F82-…` then `kmutil configure-boot -c stage1-b13dev-raw.bin -v /Volumes/Omarchy --raw --entry-point 2048 --lowest-virtual-address 0`. **The Mac booted to Omarchy**: aura, no CTXR refusal, U-Boot, Limine, Linux, owner setup, with no typed command on the Linux side. Evidence from the running system (cores, the device tree's `/chosen`, the ESP generator, the camera setfile, the light sensor) follows once Tailscale is signed in.
- **What this means for the build:** the J616c should enrol aura's *raw* Stage 1 in Omarchy's existing `raw` mode, not the `macho-unpadded` object OMS-11 added. The engine already stages `esp/aurora/stage1-j616c.bin` (`BOARD_STAGE1`); dropping `j616cap` from `BOARD_MACHO_STAGE1` and pointing the raw fill at `m1n1/boot-ctxr.bin` is the change (OMS-24). Aurora's `update-m1n1` keeps writing `boot-ctxr.bin` on T6041 regardless of how Stage 1 was enrolled. What a raw Stage 1 gives up: the execute window, so no hibernation layout (`hib=1`) and none of aura's EL2 features that need the window; Linux runs as on M1 to M3.
- **Side finding, from aura's history:** `1.0.0b13.1` is a maintenance branch (`v1.0.0b13..v1.0.0b13.1`: the release commit, a CI change, and `564efba5 payload: start a post-M4 ANS an earlier stage powered off before any payload`), and `564efba5` is the identical diff to `aaec599f`. So the packaged aura `1.0.0b13.1-1` has the ANS restart, and 9.14's "no aura release has it" was wrong: the Stage 2 pin (`M1N1=` to `94d8e6e4`) and the m1n1 guards exist for a fix the package already carries (OMS-25). This install's Stage 2 (`1a0b3993…`, built from the pin) and the package's would differ only in the commits between them.
- **Also seen today:** the `kmutil`/`bputil` policy changes need `one true recoveryOS`; a press-and-release before the hold gives ordinary recoveryOS, which `bputil -d -v <group>` shows as `OS Type`. The scripts now check it before doing anything.

### 9.32 The new install, checked; the camera tuning never reached the J616c (OMS-14, OMS-22, 2026-11-16)
- Read over Tailscale (`dev-machine-mac`) 28 minutes after the raw-Stage-1 boot, nothing changed:
  - Kernel `7.3.0-1-40-ARCH`, 14 CPUs online. `/proc/device-tree/chosen` has no `aurora,ctxr-exec-window`: an unconfined boot, as a raw Stage 1 with Kernel CTRR off should give.
  - `omarchy-esp-generator` mounted `/boot/efi` from PARTUUID `6a2fb892-…` (the ESP in `chosen/asahi,efi-system-partition`) and `/boot` from `b7377d7f-…` (`nvme0n1p5`, the partition after the ESP). OMS-12 and OMS-15 work on a fresh install.
  - The update policy as built: `M1N1=/usr/local/lib/aura/m1n1-94d8e6e4.bin`, `IgnorePkg = m1n1-aurora`, `/etc/omarchy-mac-boot/owner-boot-chain`, `aurora-stage2-commit.service` and `aurora-stage2-guard.timer` enabled. No hand guard anywhere (OMS-13, OMS-17).
  - Aurora's key in pacman's keyring with ultimate trust and the `30-aurora-keyring.conf` drop-in in place, so owner setup needed no `pacman-key` (OMS-14). The journal notes a left-over `gpg-agent` in the unit's cgroup from that run; harmless.
  - **Light sensor works** with kernel `-40`: `aop-sensors-als` (`iio:device0`) reads 115.7 lux, beside `las`, `devmotion6`, `als-temp`, `accel` and `gyro`. OMS-3's kernel half is done; `iio-sensor-proxy-aurora` and `aurora-kbd-light` aren't installed yet, as planned.
  - `speakersafetyd` active, no failed units, `alsa-utils-aurora 1.2.16-1`, `linux-firmware-realtek` installed, packages exactly the pins.
- **Camera: still untuned, and now for a known reason.** The kernel names `apple/isp_2224_01XX.dat` at probe, and a 5-frame stream on `/dev/video0` (the ISP is `video0` on this boot) logged `setfile 'apple/isp_2224_01XX.dat' missing, streaming without sensor tuning`. `/usr/lib/firmware/apple/` has the six old setfiles only, and `/usr/lib/firmware/vendor/.vendorfw.manifest` lists the same six: that is what first boot unpacked from the installer's `firmware.tar` (`omarchy-vendorfw.service`: "vendor firmware changed: extracted /boot/efi/vendorfw/firmware.tar"). So the engine on macOS never collected the IMX958 file. Cause, in our own patch: upstream's `stub.py` collects camera setfiles with `ISPFWCollection("recovery/usr/sbin/")`, its stock class, and the engine swaps our upgraded class (`omarchy_isp.collection_class`) into `stub.ISPFWCollection` only inside `_neo_peripheral_collectors`, which does nothing unless the board is `j700ap`. OMS-22's registry entry was right and never used on this board. (The Linux-side `asahi-fwextract 0.9.2` has no 2224 either, 48 entries, but it didn't run here: first boot took the ready-made tar.)
- Fix, in `patches/j616c-installer.patch`: `_camera_tuning_collector(installer)`, entered for every firmware collection, swaps the upgraded class in on every Mac but the Neo (which keeps its own), and requires `isp_2224_01XX.dat` on `j616cap` (`BOARD_CAMERA_SETFILES`), as the Neo's collector requires its sensors. It steps aside when the engine's `asahi_firmware` has no `isp` or `stub` no `ISPFWCollection`, like the Wi-Fi collector beside it: without that guard seven existing tests broke on their minimal mocks. Six new tests: the J616c collects the file and the hook is restored; a J616c without it stops; other Macs get the upgraded registry with no requirement; the Neo keeps its collector; a registry error becomes an adapter error; and `collect_firmware` runs under the collector (fails if the wiring is removed). Overlay suite: OK, 31 skipped. Engine renamed `v0.9.2-omarchy.20261116.f5386904f65a`; the archive is built with OMS-24's rebuild, and the lock's `validation_artifact` describes the previous engine until then.
- Not yet: the first `omarchy update` on this install, the report, and a hand copy of the setfile onto this Mac for the soak test (it comes from macOS's `appleh16camerad`; the next time the Mac is in macOS).

### 9.33 The first `omarchy update` on the fresh install (OMS-14, 2026-11-16)
- Run by Allan at 18:36 (local). 84 package changes, all userland (dbus, git, Qt 6, KDE frameworks 6.32, Docker tools, cmake and others), no prompt and no typed command. `update-verify` ran twice (18:37, 19:09) and didn't refuse: the `owner-boot-chain` marker turns the boot check's known false failure (OMS-16) into a warning.
- No boot-chain package changed: `[aurora]` still offered exactly the `AURORA_PINS` builds, so `95-m1n1-install.hook` didn't run, no Stage 2 was rebuilt, and `/var/lib/aurora-stage2/attempts/` is empty. The pin-and-trial update policy (OMS-13, OMS-17) is therefore still unexercised on hardware; its first real run comes with Aurora's next kernel.
- As the package audit (9.20) predicted for `[aurora]` first: `avd-fw` (0.1-1 → 0.1.aurora3-1) and `aurora-bless` (0.4.4.aurora2-1 → 0.4.4.aurora5-1) switched to Aurora's builds.
- Running kernel = installed kernel (`7.3.0-1-40-ARCH`), so no reboot needed; no failed units.
- OMS-14 status: install, first boot, owner setup and first update needed no hand step on the Linux side. Two hand steps remain, both before Linux: enrolling the raw Stage 1 (OMS-24), and the camera setfile the engine didn't collect (OMS-22, fixed in the patch, needs the rebuild).

### 9.34 The installer enrols the J616c's raw Stage 1 (`raw-ctxr`) (OMS-24, 2026-11-16)
- `patches/j616c-installer.patch` adds a boot mode, `raw-ctxr`: aura's raw Stage 1, enrolled exactly as Omarchy's stock `raw` mode (`bputil -nc`, then `kmutil configure-boot --raw --entry-point 2048 --lowest-virtual-address 0`), but chainloading the confined Stage 2 at `m1n1/boot-ctxr.bin`, the file Aurora's `update-m1n1` writes on T6041. That is what booted the reinstall by hand (9.31).
  - Engine (`omarchy_asahi.py`): `j616cap` leaves `BOARD_MACHO_STAGE1` (now empty; the Mach-O modes stay for other chips) for a new `BOARD_CONFINED_RAW_STAGE1`. The raw image is filled with the ESP and `;m1n1/boot-ctxr.bin`, `boot-ctxr-j616c.bin` still lands at `m1n1/boot-ctxr.bin`, and Recovery is told `raw-ctxr` with no Mach-O object. Ordinary Macs call Recovery exactly as before. `esp/aurora/stage1-j616c.macho` in older payloads is dropped from the ESP (`RETIRED_ESP_MEMBERS`).
  - Recovery staging (`omarchy_recovery.py`): `raw-ctxr` stages `raw-ctxr/aura-raw.bin` and `raw-ctxr/boot-ctxr.bin`, with its ESP path `m1n1/boot-ctxr.bin`; a Mach-O object is required exactly for the two Mach-O modes.
  - Recovery app (Swift): `AuraBootMode.rawCtxr`, with raw enrolment arguments and the confined Stage 2 path, accepted by the configuration decoder, the enrolment guard and the old-payload inventory. The macho-unpadded doc comment no longer claims it boots the J616c.
  - `tools/derive-j616c-image` stages only the raw Stage 1 for the J616c and requires a Recovery app that knows `raw-ctxr/aura-raw.bin`.
- Tests: engine overlay 461 OK (31 skipped), with the seven J616c tests rewritten for the new behaviour (a payload without the Mach-O object is admitted; any Mach-O object is ignored; the raw image is refused when missing; only the confined Stage 2 is required) and new ones for `raw-ctxr` staging and for only `j616cap` using it. Flipping the J616c back to plain `raw` fails three tests. On the Mac: `Recovery/test-all.sh` 20 PASS (with `rawCtxr` assertions in the boot-selection check), `swift test` 638 tests, 0 failures, 1 skipped, as before. Engine renamed `v0.9.2-omarchy.20261116.87a727c96a25`.
- **Build (2026-11-16, on the Mac, `work/omi-oms24`, outputs in `build/oms24/`):** `test/all` with Python 3.12 passes in full (77, 461, 303, 36). Engine `v0.9.2-omarchy.20261116.87a727c96a25` built twice, byte-identical (17,913,054 bytes, sha256 `f6d62c20d71fda705f9fea85c7c62dc67ecf0c67c1c12c858d0598796a72613a`), pinned and reproduced by `prepare-engine.py`. Recovery app built with `raw-ctxr`. The derivation ran with `AURORA_PINS` still matching `[aurora]` (236 s); payload 4,019,118,998 bytes, sha256 `df0ed3994bd2…e377`, passes `mac-image-check payload edge`. Catalog sequence 1794828697, evidence `j616c-dev.20261116b`, `latest_version` 2.3.18, signed and verified, 4 offline artifacts. App 2.3.18 (build 2611161131) with that engine. Package `build/oms24/Omarchy-J616c-Developer.pkg`, 4,045,313,521 bytes, sha256 `14a298efa59c4373426765678f62842510cfcfc6b084cdc77bc93f1ddc4dc766`.
- The Mac slept mid-build once and the SSH session's build died with it. Long Mac builds now run detached (`nohup`) with `caffeinate -dims` held in a Terminal; a package left by the interrupted run (`.first-run`) was set aside, since it carried the earlier catalog.
