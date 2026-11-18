# Aurora packages on the J616c: audit (OMS-18, 2026-11-15)

What Aurora's `[aurora]` repo (https://aurorasilicon.org/alarm-aurora/testing/aarch64) offers,
against what the installed J616c runs (Omarchy, `linux-aurora 7.3.0.aurora1-36`). Gathered on the
Mac on 2026-11-15 with `pacman -Sl aurora`, `pacman -Q`/`-Qi` and `pacman -Si aurora/<pkg>`; the
installed versions quoted below (including `bluez`, `iwd`, `networkmanager`, the power and firmware
packages and the VA-API driver) come from the same `pacman -Q`/`-Qi` runs. Of Aurora's 98 packages,
33 are installed under their own name, and two more are satisfied by other packages:
`power-profiles-daemon` by Omarchy's `omarchy-power-profiles-daemon`, and `pipewire-session-manager`
by Arch's `wireplumber` (`pacman -Qq` on the Mac). The rest fall into the groups below.

This is a snapshot of the first install. The clean reinstall of 2026-11-16 (OMS-14) runs
`linux-aurora 7.3.0.aurora1-40` with the same package choices, now pinned in the derivation
(`AURORA_PINS`); JOURNEY 9.28 to 9.33 record what changed and what its first update did.

The image's package list is `tools/derive-j616c-image` (`AURORA_BOOT`, `AURORA_MESA`,
`AURORA_MESA_OPTIONAL`, `AURORA_AUDIO`). A package moves into it only through its task, after it's
tested on the Mac. `AURORA_MESA_OPTIONAL` (`mesa-aurora-fex-guest`, `vulkan-lavapipe-aurora`) only
upgrades those packages when the edge image already has them; this Mac has neither.

This audit raises three questions for the M team, each marked below: the kernel, Aurora's builds,
and Aurora's defaults. They are open.

## The kernel: the main open dependency

The J616c runs Aurora Silicon's kernel, `linux-aurora 7.3.0.aurora1-36` (source
github.com/aurora-silicon/linux), and the image installs it from `[aurora]` on purpose. Omarchy's
repo also offers a `linux-aurora`: 7.2.11.aurora16, built from omacom/linux-aurora, the M team's
"stable" tree for M1 to M3 and the Neo. `[aurora]` comes first in pacman.conf, so Aurora's wins.

As of 2026-11-15, omacom/linux-aurora `integration/aurora` is `39d5f88` (Linux 7.2.11, 8 commits
past `bed544bd`) and still has no T604x device tree, so it can't boot a J616c. Aurora's tree is
where M4 Pro and Max support is developed (GPU, DCP, ANS, audio). In the M4 Max GPU thread on
Basecamp (https://public.app.basecamp.com/p/bLeYEF6QUmZZaSPDHGmBK2Uf, relayed by the owner on
2026-11-15), Ryan Murray ("Omarchy Borealis at Omacom", comment of 2026-10-29) promised to review
and merge the M4 Max work and said it will go into Omarchy Mac's kernel trees after the M1–M3 and
Neo release. By his account the port is Omarchy's own plan; its timing and branch are still open.
On 2026-11-16 omacom/linux-aurora `integration/aurora` was still `39d5f88`, with no T604x tree. The
public sign of the port is omacom/omarchy-pkgs#2738, a draft test pin ("DO NOT MERGE") that builds
`linux-aurora` 7.3 from `scottjones/aurora-linux` `824a2eb`, and that commit carries
`arch/arm64/boot/dts/apple/t6041-j616c.dts`. Until a port like that is released, the J616c image
depends on Aurora's kernel and its matching Mesa and audio packages. Whether an official M4 Max
release ships Aurora's kernel or waits for the port is the M team's call (open question 1).

## Already Aurora's build

`linux-aurora`, `linux-aurora-headers`, `aurora-userpages`, `aura`, `uboot-aurora`,
`asahi-scripts`, `aurora-keyring`, `mesa-aurora`, `vulkan-aurora`, `aurora-audio`,
`speakersafetyd`, `speakersafetyd-aurora-profiles`, `speakerguardd`, `alsa-utils-aurora`,
`triforce-lv2`, `lsp-plugins-lv2`, `avd-fw`, `aurora-bless`, `plymouth`.

Kept from elsewhere, on purpose:

| Package | Installed | Aurora | Why it stays |
| --- | --- | --- | --- |
| `alsa-ucm-conf-aurora` | Omarchy 10.aurora3-1 | 10.aurora2-5 | newer, has the J616 UCM; all nine audio checks pass with it |
| `power-profiles-daemon` | `omarchy-power-profiles-daemon` 0.30-9 | 0.30-1.1 | Omarchy's build of its power menu |
| `pipewire` and its splits | Arch `extra` 1:1.6.11-1 | 1:1.6.10-1.6 | newer; audio works. What Aurora's patch level adds is unknown |
| `docker` | Arch `extra` 1:29.9.3-1 | 1:29.9.2-1.1 | newer |
| `bankstown` | `asahi-alarm` 1.1.0-2 | 1.1.0-1 | newer, the Asahi ALARM build |
| `lzfse` | 1.0-1, packaged by the asahi-alarm maintainer | 1.0-1 | same version |

## Name collisions with `[aurora]` first

`[aurora]` is first in pacman.conf (the derivation puts it there, for the kernel and boot chain).
For a package name several repos carry, pacman takes the `[aurora]` build on install. On update
(`-Syu`) it compares the installed package only with the first repo that carries the name and
never looks at later repos: a newer installed build is kept ("local is newer"), not downgraded,
but it no longer gets updates from its own repo, and once Aurora publishes a higher version the
update switches it to Aurora's build. That has side effects beyond the boot chain:

- **Held back now:** `udisks2` is installed at 2.11.2-1, the version `[aurora]` has, while Arch
  `extra` has 2.12.0-1. Updates don't move it to 2.12.
- **Frozen until Aurora passes them:** every package in "Kept from elsewhere" whose name
  `[aurora]` also carries: `pipewire` and its installed splits, `docker`, `bankstown`, `lzfse`, and
  `alsa-ucm-conf-aurora`, the Omarchy build the audio checks pass with. They stop getting updates
  from Arch, asahi-alarm or Omarchy, and switch to Aurora's build when Aurora's version overtakes
  them. (`omarchy-power-profiles-daemon` isn't affected: a different package name.)
- **Already swapped to Aurora's build:** `plymouth` (Arch 26.134.222-3), `lsp-plugins-lv2` (Arch
  1.2.37-1), `avd-fw` (Omarchy and asahi-alarm 0.1-1), `aurora-bless` (Omarchy 0.4.4.aurora2-1),
  `speakerguardd` (Omarchy 0.1.0.aurora3-1), `speakersafetyd` and `triforce-lv2` (asahi-alarm).
  They came in as dependencies or through updates; none is in the derivation's lists. (`asahi-scripts`
  is Aurora's on purpose: the derivation installs it for Aurora's `update-m1n1`.)
- **Seen again on the clean reinstall:** its first `omarchy update` (2026-11-16) switched `avd-fw`
  (0.1-1 → 0.1.aurora3-1) and `aurora-bless` (0.4.4.aurora2-1 → 0.4.4.aurora5-1) to Aurora's builds,
  as described above (JOURNEY 9.33). `alsa-utils-aurora` is now installed on purpose: Aurora's audio
  packages need it, and the derivation swaps Arch's `alsa-utils` for it (JOURNEY 9.29).
- **Would replace Omarchy's or Arch's on install:** `steam` (Omarchy 1.0.0.87-2), `gtk2` (Omarchy
  2.24.33-5), `mil-hwx-compiler` (Omarchy 0.1.0-1; Aurora's is 0.3.1-1), `firefox` (Arch 160.0-1;
  Aurora's 160.0-1.2), `kinfocenter` (both 6.8.2-1). None of these is installed on this Mac now,
  but installing one would get Aurora's build.
- **Replaces that matter here, offered by `-Syu` on its own** (the KDE, GNOME and FEX packages
  declare Replaces too, harmless on Hyprland): `aurora-nvram` replaces `asahi-nvram`,
  `aurora-btsync`
  replaces `asahi-btsync`, `vulkan-lavapipe-aurora` replaces `vulkan-swrast`,
  `opencl-rusticl-aurora` replaces `opencl-rusticl` and `opencl-mesa`, `fprintd-aurora` replaces
  `fprintd`, `iio-sensor-proxy-aurora` replaces `iio-sensor-proxy` (the same mechanism the
  derivation guards against for `m1n1-aurora`). None of the replaced packages is installed on this
  Mac (`pacman -Qq`), so nothing is swapped today; installing one later would pull Aurora's in.
- **Conflicts declared by the Aurora package:** `networkmanager-aurora` conflicts with
  `networkmanager` and depends on `aurora-keep-config`. `upower-aurora` conflicts with `upower`
  and depends on `aurora-keep-config` (it has no Replaces, so it must be swapped in explicitly).
  `iio-sensor-proxy-aurora` conflicts with and replaces `iio-sensor-proxy`. `iwd-aurora` conflicts
  with `iwd`.

Whether `[aurora]` should stay first for everything or only for the boot-chain packages is a
question for the M team (open question 2).

## Install: candidates for a report gap (decided in each task)

| Report gap | Aurora packages | Installed now | Task |
| --- | --- | --- | --- |
| Touch ID / SEP unavailable | `aurora-sep` (pulls `fprintd-aurora`, `libfprint-aurora` "with the Aurora SEP driver", `aurora-touchid-rearm`, `aurora-xart`). Omarchy's M1–M3 and Neo image installs Touch ID at first boot with Aurora's `install-aurora-sep.sh` (omarchy-mac-installer `docs/one-image-m123-neo.md`); that script also edits `/etc/default/update-m1n1`, where the J616c image keeps its Stage 2 pin. **Decided (OMS-2, JOURNEY 9.38): left out.** Touch ID takes Omarchy's own consent path (omarchy-mac with `patches/omarchy-mac-touchid-j616c.patch`, and Omarchy's `libfprint-git` once it takes SEP interface v5) | no fprintd or libfprint at all, and no `install-aurora-sep.sh` | OMS-2 |
| Ambient light not read; keyboard light follows no sensor | `iio-sensor-proxy-aurora` (replaces `iio-sensor-proxy`), `aurora-kbd-light`. These are userspace. The kernel half is done: on `7.3.0.aurora1-40` the AOP exposes `aop-sensors-als` and reads lux (JOURNEY 9.32), so OMS-3 is down to these two packages | neither | OMS-3 |
| No hardware video decode | `libva-v4l2-request-avd` 1.3.r11-1, built 2026-11-12 from omacom/libva-v4l2_request. Aurora's default ALARM image ships it and selects it with a system driver alias rather than a global environment override (alarm-aurora README) | Omarchy's `libva-v4l2_request-avd` 1.3.r11.r169, built 2026-10-14 (a different package name) | OMS-4 |
| Wi-Fi first join on 5 GHz | `aurora-wifi-firmware` (keeps Wi-Fi and Bluetooth firmware in step with the installed macOS); `networkmanager-aurora` (Wake-on-LAN across sleep; pulls `aurora-keep-config`). `iwd-aurora` only adds OWE for the Neo's MT7932 | Arch `iwd` 3.12-2, `networkmanager` 1.58.1-3 | OMS-5 |

## Available, not adopted: improvements without a report gap

None of these answers a gap in the report, where battery, charge limit, idle draw, sleep drain,
CPU frequency, camera and trackpad all pass. Neither team has asked for them in Omarchy: three are
Aurora's defaults for Aurora's own distributions, and Omarchy's edge image (the M team's choice)
includes none of them. Left out of the J616c image. Raise with the M team if Omarchy should adopt
Aurora's defaults for all Apple silicon Macs (open question 3), or if the soak
test finds a reason (a reboot that hangs for 10 minutes would argue for `aurora-system-fixes`'
2-minute reboot watchdog).

| Package | Origin | What it does here |
| --- | --- | --- |
| `aurora-system-fixes` (pulls `aurora-panel-nits`, `aurora-nvram`, `aurora-btsync`; needs `bluez>=5.87`, the Mac has 5.88-1) | required by Aurora's Fedora `aurora-release` | `RebootWatchdogSec=2min` so a stalled reboot resets within the SoC watchdog's 178 s range instead of after 10 min; host-driven haptic trackpad clicks like macOS; the DMI model name unmangled; wake-for-network following the power adapter; a NetworkManager-dispatcher drop-in (`--persist`, ordered before NetworkManager), which applies on Omarchy too. The rest are KDE, GNOME, malcontent, mutter and swapfile drop-ins that do nothing here |
| `aurora-panel-nits` | with `aurora-system-fixes` | panel brightness shared with the boot loader through NVRAM |
| `aurora-nvram` | with `aurora-system-fixes` | reads and writes Apple NVRAM variables (replaces `asahi-nvram`) |
| `aurora-btsync` | with `aurora-system-fixes` | uses the Bluetooth pairings made in macOS |
| `upower-aurora` (conflicts with `upower`) | in Aurora's default ALARM image | battery time remaining from macsmc |
| `aurora-power-budget` | pulled in by `aurora-boot`, Aurora's ALARM base | CPU power budget for the power-saver profile |
| `aurora-camera-denoise` | in `[aurora]`, not a default | PipeWire filter that denoises the built-in camera, like macOS |
| `opencl-rusticl-aurora`, `vulkan-lavapipe-aurora`, `omarchy-ane-tools` | in `[aurora]` | OpenCL, software Vulkan, Neural Engine tools |

## Omarchy has its own

| Aurora package | Omarchy's | Note |
| --- | --- | --- |
| `aurora-firmware` | `omarchy-aurora-firmware` 20261014-7 | same firmware ordering and peripheral admission, wired into Omarchy's vendor-firmware flow, plus a regulatory-domain fallback. Both ship a file at `/usr/lib/modprobe.d/aurora-firmware-order.conf` (from Aurora's file list and `pacman -Ql omarchy-aurora-firmware` on the Mac), so pacman refuses to install them together, though neither declares a conflict (`pacman -Si` and `pacman -Qi` show none) |
| `aurora-boot` | omarchy-mac-boot, Limine | Aurora's is the GRUB-based ALARM integration and pulls `aurora-firstboot` and the Neo config |
| `aurora-firstboot` | Omarchy's first boot and owner setup | |
| `plymouth-theme-aurora` | Omarchy's splash | |
| `mil-hwx-compiler` | Omarchy's build 0.1.0-1, not installed here | Aurora's 0.3.1-1 would win on install (see name collisions) |

## Not for this Mac or this desktop

`kwin-aurora`, `mutter-aurora`, `gnome-settings-daemon-aurora`, `plasma-setup`, `kinfocenter`,
`aurora-logos` (KDE and GNOME); `aurora-neo-platform-config` (MacBook Neo); `aurora-secboot`
(Aurora's secure-boot path); `aurora-speaker-upgrade`, `speakerguardd-v2` (preview, ship
disabled); `aurora-diag` (development only); `aurora-keep-config` (a dependency, only pulled in by
`networkmanager-aurora`, `upower-aurora` and `gnome-settings-daemon-aurora`); `aurora-flatpak-gl`,
`mesa-aurora-fex-guest`,
`fex-emu`, `fex-emu-steam`, `aurora-steam-native`, `steam`, `firefox`, `gtk2`, `udisks2-*`,
`pipewire-*` extras (applications and extras, not hardware support; see name collisions).

## Opt-in only

`aurora-fido` (Touch ID as a FIDO2 key), `aurora-sep-luks` (unlock the disk with the Secure
Enclave), `aurora-sep-sk` (SSH keys in the Secure Enclave), `omdrop-awdl` (AirDrop). They need
OMS-2's Secure Enclave first. Document them; don't install by default.
