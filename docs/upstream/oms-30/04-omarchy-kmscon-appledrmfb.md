# Draft comment: omacom/omarchy#20512 ("Fall back to fbdev in kmscon on Snapdragon msm DRM")

## Comment

The same fallback is needed on the 16-inch M4 Max (J616c, T6041) with macOS 27.2 firmware, whose
framebuffer is `appledrmfb`. There the DCP's primary plane offers only formats with alpha
(aurora-silicon/linux#2492), so kmscon's DRM backend, which asks for XRGB8888, draws nothing:
owner setup's tty1 stays black and the first boot looks hung (`omarchy-provision-owner.service`
running, `sddm` waiting). With `--no-drm` kmscon draws through `appledrmfb`, which the kernel
already gives an AR24 framebuffer, and owner setup completes normally. Tested by editing
`omarchy_kmscon` on the installed Mac and restarting the service.

Would you take `appledrmfb` into the same check?

```bash
if [[ $fb_name == "msmdrmfb" || $fb_name == "appledrmfb" ]]; then
  drm_args=(--no-drm)
fi
```

This changes every Mac, including M1 to M3 and firmware 26, where DRM kmscon works. fbdev kmscon
should be fine on all of them, since the kernel console uses the same framebuffer, but I've only
run it on the J616c. If you'd rather keep DRM where it works, the narrower test is whether the
primary plane lacks XRGB8888, which takes a small DRM query rather than a sysfs read. Happy to send
either as a PR once #20512 lands.
