# Draft issue: aurora-silicon/linux

**AI disclosure:** Allan to decide before sending.

## Title

t6041: ANE and AVE refuse the 32-core J616C's macOS 27.2 (26B123) firmware

## Body

On a 32-core M4 Max (J616C, Mac16,5) booted from a macOS 27.2 (26B123) stub, with the GPU admitted
(separate PR), two more blocks refuse their firmware at probe:

```
ane_t6021 484000000.ane: H16 preload matches none of 6 firmware profiles, error -8
ane_t6021 484000000.ane: H16 stage program refused before RUN, error -8
apple-ave 283100000.video-codec: error -EINVAL: unexpected firmware segment sizes
apple-ave 283100000.video-codec: probe with driver apple-ave failed with error -22
```

So the Neural Engine is unavailable and video decodes in software. linux#1954 added an H16 26B123
profile, measured on the 40-core J616C; like the GPU image, the 32-core part's preload probably
measures differently. The AVE refusal reads like a firmware layout change on 27.2.

Kernel: omacom/linux-aurora `3058cc5c` (contains linux#1954 and #2492). Stage 1 and 2: aura
`v1.0.0b17`. I can capture whatever helps: the measured ANE preload, the AVE segment table, or a
test build.
