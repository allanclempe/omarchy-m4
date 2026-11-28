# Draft issue: aurora-silicon/linux

**AI disclosure:** Allan to decide before sending.

## Title

drm/apple: the T6041 primary plane offers no XRGB8888 on firmware 27, so kmscon and aquamarine fail

## Body

Since linux#2492, a T6041 DCP on firmware 27 (`xrgb_is_alpha`) offers its primary plane only formats
with alpha (`dcp_overlay_formats`), because the firmware blends the X byte as alpha and ignores the
opaque-X property. The colours are right, but two stock clients that ask for XRGB8888 cannot draw at
all on a 32-core J616C with a 26B123 stub:

- **kmscon** (Omarchy runs owner setup in it): tty1 stays black. The kernel logs
  `format XR24 little-endian (0x34325258) not supported` / `No compatible format found`, and fbcon
  falls back to AR24 (`plane-0 … format=AR24`). `kmscon --no-drm` works.
- **aquamarine 0.16 / Hyprland 0.57.2:** Hyprland crash-loops on
  `GBM: Failed to allocate a GBM buffer: format XR24 isn't supported by primary backend` /
  `Swapchain: Failed acquiring a buffer`. aquamarine with the alpha-variant fallback
  (omacom/omarchy-pkgs#2739, from hyprwm/aquamarine#496, which hyprwm closed) starts. It then needs a
  Hyprland change so `ensureBufferPresent` does not swap in a stale buffer on every commit (the
  frame-k−2 effect omacom/omarchy-pkgs#2956 measured on the M5).

On the M5 Max the same symptom went the other way: the alpha-only plane PR (#1873) was closed, and
the driver now offers XRGB8888 there. Is that possible on T6041 firmware 27, for example by having
the DCP treat the surface as opaque, or by the driver forcing the alpha byte? Then stock userspace
works unchanged. Otherwise, any XRGB client (kmscon, simple DRM programs, wlroots compositors) needs
the userspace workarounds above.

Kernel: omacom/linux-aurora `3058cc5c` (contains #2492), aura `v1.0.0b17`, Omarchy edge.
