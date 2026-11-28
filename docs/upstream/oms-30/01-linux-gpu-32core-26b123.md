# Draft PR: aurora-silicon/linux

**Base:** `integration/aurora` (tested on omacom/linux-aurora `3058cc5c`; the patch applies to
aurora-silicon/linux `6b6b1e6ada93`, the last change to `hw/t6041.rs`).
**Patch:** `patches/linux-t6041-26b123-32core.aurora-main.patch`.

## Title

drm/asahi: t6041: admit the 32-core J616C's 26B123 GPU firmware image

## Body

On a 32-core M4 Max (J616C, Mac16,5) booted from a macOS 27.2 (26B123) stub, the GPU never starts:
`BUILD_26B123` lists only the 40-core J616C's measured image, and iBoot fills part of the loaded TEXT
per Mac, so the 32-core one measures differently. Without a render node Hyprland, and so the
desktop, cannot start.

```
aurora 28a600000.gpu: unsupported GPU firmware build: TEXT 0x64000 DATA 0xcc000 entropy 0x5d88c/0x5d96f sha256 c65e9d34de7fa3301a7e2244e55a96ba7950840c1f38db7c2fa5008e916e29dd
aurora 28a600000.gpu: supported: Apple GFX 26B123 for T6041 (normalized loaded image)
aurora 28a600000.gpu: GPU firmware image not admitted: EINVAL
aurora 28a600000.gpu: Unsupported GPU firmware image (reported macOS version Some([27, 2, 0]))
```

The table already runs a 32-core part on 26B123 with `t6041_25g83::CONFIG` ("a 32-core part runs
`super::t6041_25g83::CONFIG` on both 25G83 and 26B123"), and 25G83 lists a separate 32-core J616C
measurement for the same reason. This adds the 32-core J616C's 26B123 measurement next to the
40-core one. TEXT and DATA sizes and the entropy range are the same as the 40-core image's.

**Tested** on a 32-core J616C (14-core CPU), stub 26B123, system firmware mBoot-20457.41.3:
- The measured digest was identical on all ten probes over two boots, so no boot-filled range needs
  zeroing on this Mac.
- With the patch: `GPU firmware build: Apple GFX 26B123 for T6041 (normalized loaded image, 32-core
  J616C)`, `GPU firmware: macOS 27.2 (26B123, iBoot mBoot-20457.41.3), 32 cores`, RTKit up, `[drm]
  Initialized aurora 1.0.0`, `renderD128`.
- Hyprland runs a full Omarchy desktop on it (with an aquamarine change for the display plane, a
  separate issue), across a reboot, with audio, camera, Touch ID and x86-64 containers checked.
- Not run: the 40-core J616C and J614C/J575C on 26B123. The existing image entry is unchanged, so
  their match is untouched.
