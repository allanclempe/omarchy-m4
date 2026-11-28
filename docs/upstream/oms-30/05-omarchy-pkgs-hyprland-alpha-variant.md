# Draft PR: omacom/omarchy-pkgs

**Patch:** `patches/hyprland-alpha-variant-buffer-present.patch`, added to `pkgbuilds/hyprland` as
the last patch in `prepare()`.

## Title

hyprland: keep the rendered frame when the scanout buffer is the alpha variant

## Body

#2739 carries aquamarine's alpha-variant fallback for scanout planes that offer only formats with
alpha. On such a plane Hyprland 0.57.2 then repeats old frames: `CMonitorState::ensureBufferPresent()`
compares the buffer's format (AR24) with the monitor's (XR24) on every commit, finds them
different, and attaches the swapchain's next, stale buffer in place of the frame just rendered.
This is the frame-k−2 effect #2956 measured on the M5. Typed text appears, vanishes and reappears.

This patch compares the two formats with the alpha bit ignored (ARGB8888/XRGB8888,
ABGR8888/XBGR8888 and their 2101010 forms), so the rendered buffer is kept. Nothing changes where
the plane offers the opaque format, because then the formats are equal anyway.

**Where it matters now:** the 16-inch M4 Max (J616c, T6041) on macOS 27.2 firmware, whose primary
plane offers no XRGB8888 (aurora-silicon/linux#2492). Stock aquamarine crash-loops there (`format
XR24 isn't supported by primary backend`); with #2739 it starts but repeats frames; with #2739 and
this patch the desktop is normal.

**Tested** on that Mac: built natively from this package at `167f408d` (0.57.2-7) plus the patch,
with aquamarine from #2739. Typed text no longer flickers, and it survives a reboot. It applies
with `--fuzz=0` after the package's own patches, including `hypr-monitor-added-zoom.patch`, the
other one touching `Monitor.cpp`. The current `-9` needs #2739 rebased on the aquamarine that
provides `showsAdoptedPicture` (`hypr-startup-hold.patch`); I haven't built that combination.
