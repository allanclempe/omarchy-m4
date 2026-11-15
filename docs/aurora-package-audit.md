# Aurora packages on the J616c: audit (OMS-18, 2026-11-15)

What Aurora's `[aurora]` repo (https://aurorasilicon.org/alarm-aurora/testing/aarch64) offers,
against what the installed J616c runs (Omarchy, `linux-aurora 7.3.0.aurora1-36`). Gathered on the
Mac with `pacman -Sl aurora`, `pacman -Q`/`-Qi` and `pacman -Si aurora/<pkg>`. Of Aurora's 98
packages, 35 are installed. The rest fall into the groups below.

The image's package list is `tools/derive-j616c-image` (`AURORA_BOOT`, `AURORA_MESA`,
`AURORA_AUDIO`). A package moves into it only through its task, after it's tested on the Mac.

## The kernel: the main open dependency

The J616c runs Aurora Silicon's kernel, `linux-aurora 7.3.0.aurora1-36` (source
github.com/aurora-silicon/linux), and the image installs it from `[aurora]` on purpose. Omarchy's
repo also offers a `linux-aurora`: 7.2.11.aurora16, built from omacom/linux-aurora, the M team's
"stable" tree for M1 to M3 and the Neo. `[aurora]` comes first in pacman.conf, so Aurora's wins.

As of 2026-11-15, omacom/linux-aurora `integration/aurora` is `39d5f88` (Linux 7.2.11, 8 commits
past `bed544bd`) and still has no T604x device tree, so it can't boot a J616c. Aurora's tree is
where M4 Pro and Max support is developed (GPU, DCP, ANS, audio). Ryan Murray (Aurora) said the M4
Pro work goes into "Omarchy Mac's kernel trees after the M1–M3 + Neo release". Until then the
J616c image depends on Aurora's kernel and its matching Mesa and audio packages. The M team decides
whether an official M4 Max release ships Aurora's kernel or waits for the port. Question for
Marcelo: is there a plan or branch to bring Aurora's T6041 work into omacom/linux-aurora?

## Already Aurora's build

`linux-aurora`, `linux-aurora-headers`, `aurora-userpages`, `aura`, `uboot-aurora`,
`asahi-scripts`, `aurora-keyring`, `mesa-aurora`, `vulkan-aurora`, `aurora-audio`,
`speakersafetyd`, `speakersafetyd-aurora-profiles`, `speakerguardd`, `alsa-utils-aurora`,
`triforce-lv2`, `lsp-plugins-lv2`, `bankstown`, `lzfse`, `avd-fw`, `aurora-bless`, `plymouth`.

Kept from elsewhere, on purpose:

| Package | Installed | Aurora | Why it stays |
| --- | --- | --- | --- |
| `alsa-ucm-conf-aurora` | Omarchy 10.aurora3-1 | 10.aurora2-5 | newer, has the J616 UCM; all nine audio checks pass with it |
| `power-profiles-daemon` | `omarchy-power-profiles-daemon` 0.30-9 | 0.30-1.1 | Omarchy's build of its power menu |
| `pipewire` and its splits | Arch `extra` 1:1.6.11-1 | 1:1.6.10-1.6 | newer; audio works. What Aurora's patch level adds is unknown |
| `docker`, `udisks2` | Arch `extra` | older Aurora builds | ordinary packages |

## Install: covers a report gap (decided in each task)

| Report gap | Aurora packages | Installed now | Task |
| --- | --- | --- | --- |
| Touch ID / SEP unavailable | `aurora-sep` (pulls `fprintd-aurora`, `libfprint-aurora` "with the Aurora SEP driver", `aurora-touchid-rearm`, `aurora-xart`) | no fprintd or libfprint at all | OMS-2 |
| Ambient light not read; keyboard light follows no sensor | `iio-sensor-proxy-aurora` (replaces `iio-sensor-proxy`), `aurora-kbd-light` | neither | OMS-3 |
| No hardware video decode | `libva-v4l2-request-avd` 1.3.r11-1, built 2026-11-12 from omacom/libva-v4l2_request. Aurora's default ALARM image ships it and selects it with a system driver alias rather than a global environment override (alarm-aurora README) | Omarchy's `libva-v4l2_request-avd` 1.3.r11.r169, built 2026-10-14 (a different package name) | OMS-4 |
| Wi-Fi first join on 5 GHz | `aurora-wifi-firmware` (keeps Wi-Fi and Bluetooth firmware in step with the installed macOS); `networkmanager-aurora` (Wake-on-LAN across sleep). `iwd-aurora` only adds OWE for the Neo's MT7932 | Arch `iwd` 3.12-2, `networkmanager` 1.58.1-3 | OMS-5 |

## Available, not adopted: improvements without a report gap

None of these answers a gap in the report, where battery, charge limit, idle draw, sleep drain,
CPU frequency, camera and trackpad all pass. Neither team recommends them for Omarchy: three are
Aurora's defaults for Aurora's own distributions, and Omarchy's edge image (the M team's choice)
includes none of them. Left out of the J616c image. Raise with the M team if Omarchy should adopt
Aurora's defaults for all Apple silicon Macs, or if the soak test finds a reason (a reboot that
hangs for 10 minutes would argue for `aurora-system-fixes`' 2-minute reboot watchdog).

| Package | Origin | What it does here |
| --- | --- | --- |
| `aurora-system-fixes` (pulls `aurora-panel-nits`, `aurora-nvram`, `aurora-btsync`; needs `bluez>=5.87`, the Mac has 5.88) | required by Aurora's Fedora `aurora-release` | `RebootWatchdogSec=2min` so a stalled reboot resets within the SoC watchdog's 178 s range instead of after 10 min; host-driven haptic trackpad clicks like macOS; the DMI model name unmangled; wake-for-network following the power adapter. The rest are KDE, GNOME and malcontent drop-ins that do nothing here |
| `aurora-panel-nits` | with `aurora-system-fixes` | panel brightness shared with the boot loader through NVRAM |
| `aurora-btsync` | with `aurora-system-fixes` | uses the Bluetooth pairings made in macOS |
| `upower-aurora` (replaces `upower`) | in Aurora's default ALARM image | battery time remaining from macsmc |
| `aurora-power-budget` | pulled in by `aurora-boot`, Aurora's ALARM base | CPU power budget for the power-saver profile |
| `aurora-camera-denoise` | packaged by Aurora, not a default | PipeWire filter that denoises the built-in camera, like macOS |
| `opencl-rusticl-aurora`, `vulkan-lavapipe-aurora`, `omarchy-ane-tools` | packaged by Aurora | OpenCL, software Vulkan, Neural Engine tools |

## Omarchy has its own

| Aurora package | Omarchy's | Note |
| --- | --- | --- |
| `aurora-firmware` | `omarchy-aurora-firmware` 20261014-7 | same firmware ordering and peripheral admission, wired into Omarchy's vendor-firmware flow, plus a regulatory-domain fallback. Both ship `/usr/lib/modprobe.d/aurora-firmware-order.conf`, so they can't be installed together |
| `aurora-boot` | omarchy-mac-boot, Limine | Aurora's is the GRUB-based ALARM integration and pulls `aurora-firstboot` and the Neo config |
| `aurora-firstboot` | Omarchy's first boot and owner setup | |
| `plymouth-theme-aurora` | Omarchy's splash | |
| `mil-hwx-compiler` | Omarchy's build | |

## Not for this Mac or this desktop

`kwin-aurora`, `mutter-aurora`, `gnome-settings-daemon-aurora`, `plasma-setup`, `kinfocenter`,
`aurora-logos` (KDE and GNOME); `aurora-neo-platform-config` (MacBook Neo); `aurora-secboot`
(Aurora's secure-boot path); `aurora-speaker-upgrade`, `speakerguardd-v2` (preview, ship
disabled); `aurora-diag` (development only); `aurora-keep-config` (only a dependency);
`aurora-flatpak-gl`, `mesa-aurora-fex-guest`, `fex-emu`, `fex-emu-steam`, `aurora-steam-native`,
`steam`, `firefox`, `gtk2`, `udisks2-*`, `pipewire-*` extras (applications and extras, not
hardware support).

## Opt-in only

`aurora-fido` (Touch ID as a FIDO2 key), `aurora-sep-luks` (unlock the disk with the Secure
Enclave), `aurora-sep-sk` (SSH keys in the Secure Enclave), `omdrop-awdl` (AirDrop). They need
OMS-2's Secure Enclave first. Document them; don't install by default.
