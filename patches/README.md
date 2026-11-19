# Patches

Changes to other projects' repositories, kept here as plain `git diff` output so this repo stays the source. Each applies to one upstream commit. Nothing here has been sent upstream.

| Patch | Upstream | Base commit | What it does |
| --- | --- | --- | --- |
| `j616c-installer.patch` | omacom/omarchy-mac-installer | `a576543` (PR #212's head) | J616c developer admission, the Mach-O Stage 1 Recovery modes (`macho-unpadded`, `macho-ctxr`), the engine changes and the Wi-Fi `chflags` fix |
| `omarchy-mac-boot-aurora.patch` | omacom/omarchy-mac-pkgs | `28abebee14de05c35a2caa8dd257d056d15a641e` (main, 2026-11-09, "Merge pull request #110") | Teaches omarchy-mac-boot's `omarchy-apple-silicon-boot-check` to verify Aurora's Stage 2 (OMS-16, JOURNEY 9.24). Also applies to main `76d8b72`; sent upstream as [omacom/omarchy-mac-pkgs#150](https://github.com/omacom/omarchy-mac-pkgs/pull/150) (9.36) |
| `omarchy-lock-fingerprint-scanning.patch` | omacom/omarchy | `b20d7876f5ec6a45d18b9e4383dc4b6d9e8492ab` (quattro, 2026-11-19, "Keep colors in terminal windows an agent opens (#19507)") | The lock screen shows the fingerprint reader matching a finger: the icon pulses and the field says "Checking…" while fprintd reports a finger on the reader (OMS-36, JOURNEY 9.48) |

## omarchy-mac-boot-aurora.patch

Where `/usr/bin/update-m1n1` is Aurora's (asahi-scripts with `bootchain.py`), the boot check asks `bootchain_arch.py` for its plan, the step `update-m1n1 --check` runs, and compares the image with the ESP: `m1n1/boot-ctxr.bin` on a Mach-O aura Stage 1. It passes an armed or running Stage 2 trial of exactly that image, reports a stale, fallen-back or orphaned one, and fails when `M1N1_UPDATE_DISABLED` is set. The stock asahi path is unchanged. It adds `omarchy-mac-boot/lib/aurora-stage2.sh` and `aurora-stage2.py`, tests in `test/apple-silicon-boot-check-test.sh`, and asahi-scripts 20261023-9's `update-m1n1`, `bootchain.py` and `bootchain_arch.py`, unchanged, as test fixtures. The package README and the Mac manual (`10-boot.md`) describe it.

It does not apply to `7e50e93`, the commit omarchy-mac-boot 20261104-1 (on the installed Mac) was built from: #110 later changed the ESP mount code the patch moves into functions.

Apply and test it the way the repository's CI does (`.github/workflows/tests.yml`), as a non-root user in an Arch container with `dtc` and `python`:

```
git clone https://github.com/omacom/omarchy-mac-pkgs && cd omarchy-mac-pkgs
git checkout 28abebee14de05c35a2caa8dd257d056d15a641e
git apply /path/to/aurora-m4/patches/omarchy-mac-boot-aurora.patch
docker run -d --init --name arch -v "$PWD/..:/work" -w /work/omarchy-mac-pkgs \
  archlinux:base-devel@sha256:8745817f349ed24373341ddb92776209eeec3f0364ea48f7f645ac5800d30a50 sleep infinity
docker exec arch pacman -Syu --noconfirm --needed git python dtc shellcheck libarchive bc jq
docker exec arch useradd --create-home --uid "$(id -u)" tester
docker exec -u tester -e HOME=/home/tester arch omarchy-mac-boot/test/all
```

`OMARCHY_TEST_RUNTIME=/work/runtime`, with a checkout of the runtime `test/integration/runtime` pins (omacom/omarchy `81fd2d23ca6e3462183a4dc8360de3113fa8d80c`), also runs the one test that otherwise skips.

To change it, apply it to a branch at the base commit, commit there, and regenerate it with `git diff 28abebee14de05c35a2caa8dd257d056d15a641e HEAD > patches/omarchy-mac-boot-aurora.patch`.

## omarchy-lock-fingerprint-scanning.patch

Omarchy 4 locks with omarchy-shell's Quickshell lock screen (`shell/plugins/lock`), and a fingerprint unlock runs through `pam_fprintd`, which says nothing between the finger landing and the verdict. On a match-on-chip reader (a Mac's Touch ID, matched by the Secure Enclave) that gap is long enough to read as "nothing happened". fprintd does publish the reader's finger status, as the `finger-present` property of its device over D-Bus, and Aurora's libfprint driver reports it the moment the enclave says "hold still".

The patch has the lock service watch fprintd while the session is locked with a reader enrolled and the displays on, through `gdbus monitor --system --dest net.reactivated.Fprint` (Quickshell has no D-Bus client; gdbus is GLib's, which Quickshell depends on, and flushes each line). A finger reported during the lock's own attempt sets `fingerprintScanning`; the finger leaving, the attempt settling, an unlock, a blank or a 5 s bound clears it. The lock view then shows the existing "Checking…" text in the field and pulses the fingerprint icon's opacity, off under `omarchy toggle animations` (the icon's brighter colour stands alone there). So the feedback lasts as long as the driver reports the finger: whether that reaches the verdict, or ends when the capture does, is the driver's timing, which the Mac trial in JOURNEY 9.48 measures. `test/shell.d/lock-fingerprint-scan-test.sh` checks the line parser in node and the service, its monitor process and the view in a Quickshell fixture.

Apply and test it under a Hyprland session with `quickshell`, `node` and `jq` (the fixture needs a compositor; the suite skips it otherwise):

```
git clone https://github.com/omacom/omarchy && cd omarchy
git checkout b20d7876f5ec6a45d18b9e4383dc4b6d9e8492ab
git apply /path/to/aurora-m4/patches/omarchy-lock-fingerprint-scanning.patch
bash test/shell.d/lock-fingerprint-scan-test.sh
bash test/shell.d/lock-fingerprint-service-test.sh
bash test/shell.d/lock-fingerprint-indicator-test.sh
bash test/shell.d/lock-fingerprint-retry-test.sh
```

To try it on an installed Omarchy without rebuilding, apply the patch's `shell/plugins/lock` part over `~/.local/share/omarchy` (`git apply` works outside a repository) and run `omarchy-restart-shell` from an unlocked session; JOURNEY 9.48 has the block for the Mac, with the check that the installed files are upstream's, the backup and the way back. `omarchy update` puts upstream's files back.

To change it, apply it to a branch at the base commit, commit there, and regenerate it with `git diff b20d7876f5ec6a45d18b9e4383dc4b6d9e8492ab HEAD > patches/omarchy-lock-fingerprint-scanning.patch`.
