# Patches

Changes to other projects' repositories, kept here as plain `git diff` output so this repo stays the source. Each applies to one upstream commit. Nothing here has been sent upstream.

| Patch | Upstream | Base commit | What it does |
| --- | --- | --- | --- |
| `j616c-installer.patch` | omacom/omarchy-mac-installer | `a576543` (PR #212's head) | J616c developer admission, the Mach-O Stage 1 Recovery modes (`macho-unpadded`, `macho-ctxr`), the engine changes and the Wi-Fi `chflags` fix |
| `omarchy-mac-boot-aurora.patch` | omacom/omarchy-mac-pkgs | `28abebee14de05c35a2caa8dd257d056d15a641e` (main, 2026-11-09, "Merge pull request #110") | Teaches omarchy-mac-boot's `omarchy-apple-silicon-boot-check` to verify Aurora's Stage 2 (OMS-16, JOURNEY 9.24). Also applies to main `76d8b72`; sent upstream as [omacom/omarchy-mac-pkgs#150](https://github.com/omacom/omarchy-mac-pkgs/pull/150) (9.36) |
| `omarchy-mac-touchid-j616c.patch` | omacom/omarchy-mac-pkgs | `b4d5c2f` (the head of draft [#140](https://github.com/omacom/omarchy-mac-pkgs/pull/140), "Offer Touch ID on the 16-inch M4 Pro (J616s)", on `28abebe`) | Extends #140 to the 16-inch M4 Max: omarchy-mac offers Touch ID on the J616c and rebuilds its sealed calibration and sensor root key for chip `00006041` (OMS-2, JOURNEY 9.38). Not sent upstream |

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

## omarchy-mac-touchid-j616c.patch

omarchy-mac's Touch ID eligibility admits `apple,j616c` on `apple,t6041` beside #140's J616s (one `sealed_board` check; the 14-inch J614c stays unsupported until tried). `touchid-enable` rebuilds `apple/mesacal-j616c.bin` (FSC2) and `apple/msrk-j616c.bin` (MSRk) with `touchid-root-key --chip 00006041`, which now accepts that chip. `disable-fingerprint` deletes `msrk-j616c.bin`, and the package README names the J616c. `test/touchid-consent-test.sh` gains a J616c section, which fails when the J616c is given the M4 Pro's chip.

It needs #140 under it. Apply and test it:

```
git clone https://github.com/omacom/omarchy-mac-pkgs && cd omarchy-mac-pkgs
git fetch origin pull/140/head && git checkout b4d5c2f
git apply /path/to/aurora-m4/patches/omarchy-mac-touchid-j616c.patch
bash omarchy-mac/test/touchid-consent-test.sh
bash omarchy-mac/test/all
```

To change it, commit on a branch at `b4d5c2f` and regenerate it with `git diff b4d5c2f HEAD > patches/omarchy-mac-touchid-j616c.patch`. If #140 moves, rebase onto its new head and update the base here.
