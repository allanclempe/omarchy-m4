# Closing the camera gap to macOS on the J616c

Research and plan for OMS-34, 2026-11-20. MacBook Pro 16-inch M4 Max (J616c, T6041), IMX958
12 MP ultra-wide front camera, `linux-aurora 7.3.0.aurora1-40` (aurora-silicon/linux `9125b314`),
`aurora-camera-denoise 0.1.0-9` (camera-denoise `aa7a42ff`). It builds on
[`camera-quality-research.md`](camera-quality-research.md) (OMS-26) and JOURNEY 9.40, and doesn't
repeat them.

Nothing was changed on the Mac. The only reads there were `v4l2-ctl --list-ctrls` and
`--log-status` (which prints the driver's cached sensor configurations to the kernel log without
sending the firmware anything), the device tree under `/sys`, `journalctl -k`, the kernel config and
the setfile's bytes.

## Short answer

The biggest part of the gap is in the ISP, and two fixes for it already exist upstream for other
Macs with the same sensor. Neither has reached this Mac yet.

1. **The setfile's spatial noise filter ships switched off, in effect.** Section `0xc404` of
   `isp_2224_01XX.dat` holds the ISP's spatial noise filter gain by radius, and it ships flat
   (all 257 entries 4096, checked on this Mac's file today). macOS's camera daemon recomputes it
   from the lens shading tables before uploading the setfile; Linux uploaded it as shipped.
   [linux#2233](https://github.com/aurora-silicon/linux/pull/2233), merged into
   `integration/aurora` today (05:36 UTC, merge `51b75cb5`), does the same computation for every
   setfile with a flat `0xc404`, including ours. On the J714s (M5 Pro, IMX958, same setfile) it took
   dim-room luma grain from 11.9 to 2.4; on a J813 (M5 Air, IMX958, same setfile) frame-to-frame
   luma went from 19.8 to 4.7 in room light. The installed kernel (`9125b314`, 2026-11-15) predates
   it, and alarm-aurora still pins `9125b314`.
2. **The J616c runs an unbinned sensor mode.** Its presets use firmware configuration 5
   (1920x2160, cropped to the top 1920x1080). This Mac's ISP reports the same 13 configurations as
   the J714s and J813, including config 8, the full field binned 2x2 to 1520x1440. With the
   computed filter, config 8 measured 0.9 luma against 5.8 for config 5 on the J714s, and 2.2
   against 4.6 for config 7 on the J813 ([linux#2237](https://github.com/aurora-silicon/linux/pull/2237)).
   Nobody has proposed it for the M4 Pro or Max boards.

Together these are worth more than everything host-side in the earlier research: on the same
sensor they take the raw camera to about the noise our CPU filter reaches today (2.75 at 241 lux),
before any filter runs (2.2 and 0.9 luma on the J813 and J714s at config 8). The specks should go at the source too, since the filter acts before the
tone curve that makes them (research section 3). This changes the earlier conclusion that macOS's
advantage in normal light is the encoder's filter and the Neural Engine (section 7 below).

The rest of the gap is face rendering (macOS's face is about 30 code values darker and better
modelled while the walls match), sharpness, and dim light. For the face, the firmware's
face detection never starts and its metering setup is skipped on this firmware because it faults;
macOS's ISP library also has handlers for local tone mapping, content-aware rendering and a
noise-reduction and sharpness "use case" that Linux never sets. Their H17 records can only come
from reading macOS's camera stack. For dim light, the encoder's filter and the ISP's Neural Engine
stage stay Aurora's kernel work, as before.

### Ranked plan

| # | What | Owner | Expected gain | Effort | First step |
| --- | --- | --- | --- | --- | --- |
| 1 | Computed spatial noise filter gains (linux#2233) on the J616c | Aurora (kernel bump in alarm-aurora); us for an A/B module | Raw luma noise roughly 3x lower at config 5 (J714s, J813), specks cut at the source | Small: merged, needs a `linux-aurora` bump; or a one-patch module build | Build `apple-isp.ko` from `9125b314` plus commit `b29dcf53` on the Mac and run `camera-lab clip` with and without it (needs Allan's go-ahead to load a test module) |
| 2 | Binned config 8 presets for the J614c/J616c (and J614s/J616s) | Us, PR to aurora-silicon/linux (DT), with Aurora's review | A further 2x to 6x less luma noise, half the colour noise (J714s, J813); costs some fine detail | Small DT change; the work is choosing crops and measuring | Same test module with a throwaway parameter that remaps the presets to configs 7 and 8; measure noise, edge contrast and field of view against config 5 |
| 3 | Re-tune Aurora's filter for the cleaner input | Aurora camera-denoise; us measuring | Keeps detail the CPU stage now trades away; decides whether the low-light stage is needed in room light at all | Small to medium | Repeat the research's section 7 series on the new input; propose `[sensor:imx958-uw]` levels and a strength setting to camera-denoise |
| 4 | Find what macOS selects on the J616c: sensor config, noise and sharpness use case, face-metering record | Us on macOS (read-only), facts to Aurora | Settles items 2 and 5 instead of guessing; no picture by itself | One macOS session, then days of reading per question | Lossless `macos-capture` and a chart for field of view; copy `appleh16camerad`, `H16ISP.mediacapture` and the camera extension (section 5) |
| 5 | Send the stream setup Linux skips: face detection and the H17 face-metering record (`0x0d00` to `0x0d05`, `0x820e`), the noise reduction and sharpness use case | Aurora kernel, with the facts from item 4 | Face exposure and modelling; possibly sharper, cleaner luma from the right tuning use case | Medium; needs the H17 records | Ask Aurora whether Daybreak has these records; if not, find their builders in `H16ISP.mediacapture` |

Further out, unchanged from the earlier research: per-module shading and green-imbalance data from
the module's NVM (`0x0501`, `0x0507`, `0x0511`), `iCCl`, the encoder's filter on T6041 and the
ISP's Neural Engine stage; their rows are in section 1.

Shipping `aurora-camera-denoise` in the build (the gap found in JOURNEY 9.40) is a prerequisite for
any of this reaching a fresh install, and has its own task.

## 1. What macOS does that Linux doesn't, stage by stage

Sources: the driver on `integration/aurora` at `09c7ad0e` (`isp-cam.c`, `isp-cmd.h`,
`Documentation/driver-api/media/drivers/apple-isp-j616s.rst`), the PRs cited, and reads on this
Mac today.

For macOS's side, the best public source is the [H16ISP.mediacapture 26.6 diff](https://github.com/blacktop/ipsw-diffs/blob/main/macOS/26_6_25G5043d_vs_26_6_25G5052e/DYLIBS/System/Library/MediaCapture/H16ISP.mediacapture.md): every function's hash changed in that
build, so the diff names about 1,400 symbols of the camera stack's ISP library, including one
`Set*` or `Copy*` handler per stream property. Names in the table come from it unless another
source is given. A symbol shows that a stage exists and what it takes; it doesn't show that
FaceTime turns it on on this Mac.

| Stage | macOS | Linux on the J616c today | Kind | Status |
| --- | --- | --- | --- | --- |
| Sensor mode | Not known which of the 13 (`GetMaxResolutionSensorConfigIndex`, `H16ISPSetfileSelector`, `BinningModeToFactor` exist; no public string shows the choice); Photo Booth shows a wider 3:2 crop | Config 5, crop (0, 0, 1920, 1080), no scaling at 1080p | Firmware command `CH_CAMERA_CONFIG_SELECT` (0x0107), chosen by the DT presets | Config 8 is the measured best on two IMX958 Macs (#2237). Which config macOS uses here is open |
| Model tuning (setfile) | `isp_2224_01XX.dat` on 26.x, as far as public sources show | `isp_2224_01XX.dat` | `CH_SET_FILE_LOAD` (0x0111) | On the 26.x daemon, 2224 is the only one of 32 setfiles that names sensor 0x958, and with it the firmware logs the same module match as macOS ([linux#384](https://github.com/aurora-silicon/linux/pull/384)). macOS 27.2 adds J815 module tunings (`2226_01`, `2226_02`, [linux#2194](https://github.com/aurora-silicon/linux/pull/2194)), which fixed dark corners there. Worth a check on this Mac's daemon (section 5) |
| Spatial noise filter gains (`0xc404`) | Recomputed from the lens shading tables (`0xc003`) at load, gated by a `RadialGainEnable` preference that defaults on (#2233's author). The library also has `LSCComputeSNFRadialGains`, `LSCComputeSNFVerticalGains` and `LSCComputeSNFGainsLLM`, which fill command records (`sCIspCmdAppleChSNFRadialGainSet`, `...AsymScaleSet`, `...VerticalGainSet`, `...VerticalGainLLMSet`) from the shading configuration | Uploaded flat until #2233 | Daemon-side compute, sent in the setfile and, by the record names, as commands | **Radial part fixed upstream today**, not yet on this Mac. The vertical, asymmetric and low-light variants have no Linux counterpart yet (inference from the names) |
| Per-module lens shading and channel imbalance | `LSCComputeFromNVMApple` (into `sCIspCmdAppleChLSCConfigure`), `CICComputeFromNVMApple` (into `...ChannelImbalanceCorrectionConfigure`), `GICInterpolateNvm`, `SetLSCStrength`; `GICComputeFromNVMApple` and `iCCl` in the [26.0 daemon](https://github.com/blacktop/ipsw-diffs/blob/main/iOS/18_5_22F76__vs_26_0_23A5260n/MACHOS/appleh16camerad.md) | Never read | Firmware reads `0x0501`, `0x0507`, `0x0511`, `0x0142`; the configure commands' opcodes aren't known | Open. Affects shading and colour evenness more than noise |
| Defective pixels | `sendCmdChDPCSet` ([15.4 diff](https://github.com/blacktop/ipsw-diffs/blob/main/macOS/15_3_2_24D81__vs_15_4_24E248/DYLIBS/H16ISP.mediacapture.md)); `CopyDefectivePixelTable`, and calibration files loaded by `LoadFDRDataFileCMPM` and `LoadFDRCalDataFile` | None | A DPC command plus factory data | Open. The research's fixed defects are few and faint, so low priority |
| Noise reduction and sharpening by use case | `ApplyNoiseReductionConfiguration(device, stream, eCIspNoiseReductionUseCase, eCIspSharpnessUseCase, eCIspTuningKnobUseCase, dict)`, `SetNoiseReductionLevel`, `SetChromaNoiseReductionEnabled`, `CopyNRSharpeningConfiguration`, `SetStreamingTuningProfile` | Never sent: the firmware runs its default use case | Firmware commands choosing setfile tuning | Open, and a strong lead for both "luma barely filtered" and "less sharp" (inference) |
| Factory calibration `iCCl` | Read by the H16 camera daemon (new in the 26 releases) | None | Unknown format and command | Open (research section 4) |
| ISP temporal filter | Start record, band 0 thresholds 120/100, high strength off ([linux#774](https://github.com/aurora-silicon/linux/pull/774)) | The same commands | Firmware commands `0xc100` to `0xc120` | Sent; no frame-to-frame correlation shows in the output (research section 1). Open whether it acts on macOS |
| Chroma and multi-band NR | `CH_CNR_START`, `CH_MBNR_ENABLE` 0/1/1 | The same | Firmware commands | Sent; chroma is smoothed, luma isn't. Probably the flat `0xc404`, to be confirmed with #2233 |
| Face detection | `StartFaceDetect`, `SetFaceDetectionEnabled`, `SetFaceDetectionConfiguration`, `SetAEFaceDetectionMetering` | Never started | `CH_FACE_DETECTION_*` (0x0d00 to 0x0d05) and an FD pool (type 2), defined, unused | Open |
| Face-weighted exposure | Inferred from the face rendering today | Skipped: "the H17 firmware faults on this face-detection metering setup" | `APPLE_CH_AE_FD_SCENE_METERING_CONFIG_SET` (0x820e). Its values are the M1-era record in Asahi's driver | The H17 layout is needed |
| Semantic rendering | Unknown | Never sent | `CH_SEMANTIC_VIDEO_ENABLE` (0x0b17), `CH_SEMANTIC_AWB_ENABLE` (0x0b18), defined, unused | Open; a candidate for the face and skin rendering |
| Local tone mapping | `SetLTMCurve`, `LockLTMNow`, `SetLocalHistogramsEnabled`, `SetHighlightRecoveryEnabled`, `SetHDRFusionEnable`; firmware strings `ctrlModeLTMLTC`, `ctrlModeLTMGTC` in an H16 ISP firmware ([15.4 firmware diff](https://github.com/blacktop/ipsw-diffs/blob/main/macOS/15_3_2_24D81__vs_15_4_24E248/FIRMWARE/adc-nyx-bc6x.im4p.md)) | Whatever the firmware does by default | Firmware, with host overrides | Open. The firmware has local tone mapping; whether it runs by default, and whether macOS feeds it local histograms, isn't known. A candidate for the face's modelling |
| Content-aware colour and exposure | `SetContentAwareEnhancement`, `SetContentAwareAWBEnabled`, `SetMultiIlluminantWhiteBalanceEnabled`, `SetLuxAdaptiveSettings`, `SetSceneClassifierVersion`, `CopyForegroundSegmentationNetwork` | Never sent | Firmware features the host enables | Open; another candidate for face and skin rendering |
| Frame rate in low light | Slows to 15 fps before raising gain | The filter sets exposure priority on (`exposure_dynamic_framerate = 1` today); #2233 makes it the H17 default | V4L2 control | Done |
| Encoder's temporal filter (MCTF) | On every frame, through the camera daemon's own session | None: encoder disabled in the J616c DT, filter layout unqualified, DART stream unknown | Host-side, hardware | Aurora; [linux#2266](https://github.com/aurora-silicon/linux/pull/2266) (open) enables the encoder on every M4 Max but not the filter |
| ML noise reduction on the Neural Engine | ISP algorithm 0x143d with `ispane-<board>.afpp`, in low light. H16 ISP firmware logs `MLVNR MacOS Auto Mode ch=%zu,Threshold=%d:%d,FPS=%d:%d,RampDownCnt=%d` ([15.5 firmware diff](https://github.com/blacktop/ipsw-diffs/blob/main/macOS/15_4_24E248__vs_15_5_24F5042g/FIRMWARE/adc-eris-j129.im4p.md)): a gain and frame-rate gated auto mode, as Aurora's board data describes | Draft only (`camera/isp-ane-mlvnr`, `c5b5d15`, unchanged since 2026-11-01): doorbell unknown | Firmware endpoint `0x300c` plus the ANE | Aurora |
| Center Stage, Portrait, Studio Light | Host-side Video Effects, per app, user toggled | Aurora's optional `libaurora-camera-effects` (not installed) | Host-side | Not part of the default look |

What today's macOS still showed (JOURNEY 9.40, and the side-by-side the same evening): the global
luma histograms of a live Linux frame and the macOS still match almost quantile for quantile and
the walls agree within a few code values. So exposure and white balance as a whole are right. The
differences are local: the face, sharpness, and specks and softness on Linux. The table's open
rows that touch those are the sensor mode, the noise filter gains, the noise and sharpness use
case, face detection and metering, local tone mapping and content-aware rendering.

## 2. Evidence for the two ISP fixes

### The flat `0xc404`

- On this Mac, `/usr/lib/firmware/apple/isp_2224_01XX.dat` (28,672 bytes) has 32 sections. Its
  `0xc404` has a radius step of 4 and all 257 gains at 4096 (1.0 in Q12); there is no `0xc407`. Its
  `0xc003` describes a 3072x3024 shading frame. So #2233's condition holds and the driver would
  compute the table, as it does on the J813, which loads the same file (sithglan's comment on #2233:
  four 49x49 tables, frame 3072x3024).
- What the filter does: lens shading correction multiplies the signal and its noise by a gain that
  rises towards the edges; the filter's gain by radius should fall to match. With the table flat
  "the filter barely acts" (the commit's comment). That fits the research's measurements: no
  spatial luma filtering, chroma filtered.
- How it was found: by reading the macOS camera daemon. The author wrote in the PR that the daemon
  recomputes `0xc404` for any sensor whose setfile has `0xc003` and `0xc404`, behind a
  `RadialGainEnable` preference that defaults on, with the optical centre hard-coded per sensor
  (-156 shading-frame pixels for the IMX958). Aurora then asked for the code and comments to
  describe only the setfile and the maths. This is the clearest evidence so far that reading the
  daemon pays.
- Numbers on the same sensor:

  | Machine, light | Config | Before | With the computed gains | Metric |
  | --- | --- | --- | --- | --- |
  | J714s, dim room | 6 | 11.9 | 2.4 | grain: std of (frame minus 9x9 box blur), centre quarter |
  | J714s, dim room | 6, then 8 | 12.1 | 1.07 | frame-to-frame luma |
  | J714s, lamp-lit room | 5 | not given | 5.8 | frame-to-frame luma |
  | J813, morning room light | 7 | 19.8 | 4.7 | frame-to-frame luma, 1% largest changes dropped |
  | J813, same | 7 | 12.7 | 3.6 | grain |

  Ours is a different measure (per-pixel standard deviation over 60 frames), close to the
  frame-to-frame one. Raw room light here was 13.16 (JOURNEY 9.40), about what the J813 and the
  J616s show, so a cut of 3x to 4x at config 5 is the expectation, to be measured.
- Not yet measured on any M4. Aurora said on the PR they will post rows from their M4 Pro (J616s),
  M1 Pro, M2 and A18 Pro after the merge.
- For an A/B on this Mac before a package bump: the computation is one commit,
  [`b29dcf53`](https://github.com/aurora-silicon/linux/commit/b29dcf53522c). Its `isp-cam.c`
  part applies to the installed kernel's source (`9125b314`) except for the setfile table hunk,
  which conflicts only because the table gained a sensor name field after `9125b314`; adding `-156`
  to the IMX958 entry by hand is the whole fix-up (checked with `patch --dry-run`). The module
  would be built on the Mac against `linux-aurora-headers` with `LLVM=1`.

### The sensor configuration

- `v4l2-ctl --log-status` on this Mac lists the IMX958's 13 configurations: 0 3072x3024, 1
  3072x6048, 2 2016x2272, 3 1136x4032, 4 2352x4704, 5 1920x2160, 6 3040x5760, 7 3040x2880,
  8 1520x1440, 9 1520x2880, 10 1520x1440, 11 1536x6048, 12 1536x3024. The heights that double
  another config's are stacked frames; the driver's documentation warns that input rows can hold
  stacked exposures. The J714s and J813 lists in #2233 and #2237 match by index for the configs
  they name.
- The J616c's presets (`t6041-j614c-j616c.dtsi`, the same as the J616s's
  `t604x-j614-j616.dtsi`) use config 5 and crop the top 1920x1080. The 1080p stream is not scaled.
- Config 8 bins 2x2, which averages four pixels. On the J714s with the computed gains: config 8
  0.9 luma, 0.6 / 0.5 colour; configs 5, 6, 7 and 0 4.8 to 5.8 luma. On the J813: config 8 2.2
  against config 7 4.6.
- Costs and traps:
  - Binning costs detail. 1920x1080 from config 8 is scaled up from at most 1520 pixels across.
    The J813's PR found the ISP sharpens the result and saw no less high-frequency power in a
    30-frame mean at 1080p; the J714s's noted smoother skin and hair under magnification and stepped
    edges. Today's Linux/macOS comparison found macOS far sharper, so detail has to be measured,
    not assumed (section 6).
  - Config 10 has the same size as 8, but the firmware's white balance stays at the setfile's
    default there and the picture turns magenta (#2237). Use 8.
  - The field of view changes. Config 5's field isn't documented; config 8 covers the whole
    3040x2880 field. The crop decides what a call shows, and Photo Booth's framing is a reference
    for it (section 6).
  - The J616s and J614s share the J616c's presets in their own dtsi; a change should cover all four
    boards, tested on at least the J616c here.
- Config 7 (full resolution, 3040x2880) is the other candidate: about twice config 8's noise on the
  J813, but nothing scaled up. With the computed gains it may be the better trade at 1080p in good
  light. Measure both.

## 3. The remaining gaps, after the ISP fixes

- **Face rendering.** macOS's face was about 30 code values darker and better modelled while the
  walls matched. A face-weighted meter alone would change the whole frame's exposure, which didn't
  differ, so local tone mapping (`SetLTMCurve`, `SetLocalHistogramsEnabled`) or content-aware
  rendering (`SetContentAwareEnhancement`, a foreground segmentation network) is also a candidate;
  that part is inference. On Linux the firmware's face detection never starts (`0x0d00` to
  `0x0d05` are defined and unused), and the metering setup `0x820e` is skipped on H17 because it faults. Its
  record (`unk_c = 0xb8`, then five words that look like metering windows) comes from Asahi's
  M1-era sequence and has never been validated on H17. Fixing it needs the H17 record and probably face
  detection started first.
- **Sharpness.** Part of the softness today is the CPU temporal filter (edge contrast 92.7% after
  it in the research) and the noise itself. macOS picks a sharpness use case together with the
  noise reduction one (`ApplyNoiseReductionConfiguration`); Linux never picks either, so the
  firmware runs its default. Which use case FaceTime picks, and its opcode, are for the daemon
  reading (section 4). camera-denoise#13 (open) adds an unsharp stage for the J815; the lab's
  `cas` and `unsharp` presets try the same on top.
- **Dim light.** Aurora's numbers on the J616s at 1.3 lux were 3.0 for the CPU filter against 0.5
  on macOS. The ISP fixes help most in dim light (the J714s's numbers are dim-room ones), so the
  remaining gap there should be re-measured before anyone waits on the encoder's filter or the
  ISP's Neural Engine stage.

## 4. Reverse engineering: what each path gives

How the existing "as macOS sends" facts in Aurora's driver were obtained matters for choosing a
path. None came from a trace of macOS on an M4:

- linux#774 (the temporal filter values): "parameter facts from Daybreak's reading of the macOS
  27.0 camera stack (opcodes and values only)". Daybreak appears in Aurora's public PRs as their
  internal specification work (task numbers like `t-4662`); its documents aren't public.
- linux#2233 (the noise filter gains): its author read the camera daemon, and Aurora asked that
  the code and comments describe only the setfile sections and the maths.
- linux#384 (the setfile): extracted from `appleh16camerad`. linux#462 and the J616s bring-up
  ([m1n1#20](https://github.com/aurora-silicon/m1n1/pull/20), Ryan, closed unmerged): the m1n1
  proxy driving the ISP firmware from a Linux host, with no macOS running.
- linux#1513 (the encoder's filter): output compared bit for bit with macOS's public VideoToolbox
  temporal noise filter on the same frames.
- The basic stream-start sequence (CNR, MBNR, metering, AE stability) is Asahi's M1-era one
  ([AsahiLinux/linux `isp-cam.c`](https://github.com/AsahiLinux/linux/blob/asahi/drivers/media/platform/apple/isp/isp-cam.c)),
  from the time m1n1's hypervisor could run macOS and its ISP tracer
  ([`trace_isp.py`](https://github.com/AsahiLinux/m1n1/blob/f560eed8e9a3858f7db7b293d8473fcf9ffcd6db/proxyclient/hv/trace_isp.py))
  could read the command rings.

### (a) Tracing macOS's ISP traffic under a hypervisor on this Mac

- Asahi's m1n1 hypervisor doesn't run macOS on M4-class chips: its documentation says that "due
  to numerous bugs and the requirement for SPTM to be running to boot XNU" no M4 target is pinned
  ([m1n1-hypervisor.md](https://github.com/AsahiLinux/docs/blob/e8bcfeab975acd87f3be21ff1cddbd498b9e5045/docs/sw/m1n1-hypervisor.md)).
- aura has a different hypervisor, `SPTM_VIRT`, which runs Apple's own SPTM, TXM and XNU as a
  guest ([sptm-nv2-virt.md](https://github.com/aurora-silicon/aura/blob/0beafec9d946d92bc5139c2168c61c25175a88aa/docs/sptm-nv2-virt.md)).
  On a J616c it has reached macOS 27.2.1's single-user shell, on all 16 cores, without exclaves,
  and no further ([aura#181](https://github.com/aurora-silicon/aura/pull/181), merged
  2026-11-17). Its workaround entry is tied to that one kernelcache, the boot object has to be
  enrolled on the booted macOS's volume group, and the Neural Engine is hidden from the guest by
  default.
- Its tracing records raw MMIO accesses into a ring; the classic `trace_isp.py`, which decodes the
  ISP's command rings, can't run there. Nobody has published an ISP trace from a macOS guest on any
  M4 or M5.
- To trace FaceTime on this Mac we would need: macOS 27.2.1 on the Mac (it runs 26.7.3) or a new
  workaround entry; aura enrolled in 1TR on that macOS's volume group (a boot policy write); the
  guest taken from a single-user shell to a desktop with the camera working, which nobody has done
  on this chip, and which may need exclaves (inference: newer macOS draws the camera indicator from
  them); then new tooling to hook the ISP doorbells and read the H17 rings through DARTs that SPTM
  manages. Roughly two to five weeks of expert work, high risk at the desktop step, and boot policy
  changes on the soak machine.
- What it would give: the complete command stream, with every value, for every app and light.
  The best evidence, at the highest price.

### (b) Reading macOS's camera stack on this Mac

- The daemon is a userspace program (`/usr/sbin/appleh16camerad` on 26.x per linux#384,
  `/usr/libexec/appleh16camerad` on 27.2 per [aurora-installer#151](https://github.com/aurora-silicon/aurora-installer/pull/151));
  the stream properties live in `/System/Library/MediaCapture/H16ISP.mediacapture`, whose
  symbols are public (section 1); the kernel side is the camera extension. All can be copied off
  the Mac in a normal macOS session with no security changes.
- What it gives: the conditions and values the daemon computes and sends, as #2233 showed:
  setfile choice, the `0xc404` computation, the optical centre, per-sensor defaults, preference
  keys and their defaults (such as `RadialGainEnable`), and the builders of command records such
  as the H17 `0x820e`, the noise and sharpness use cases, the SNF vertical and asymmetric gains,
  local tone mapping and face detection: each named handler leads to an opcode and a payload.
  What it doesn't give: which config index a given app ends up with, and values the daemon only
  computes at run time from statistics.
- Cost: a disassembler (Ghidra) and a few days per question. The work must stay facts only in
  public files (opcodes, values, conditions, maths), as Aurora asks of its contributors; no code or
  text copied from Apple's binaries.

### (c) What Aurora has for the J616s and other IMX958 Macs

- Directly reusable: the temporal filter values (#774), the computed gains (#2233), the binned
  config finding (#2233, #2237), the J616s's 13 configs, which match this Mac's.
- Not public: Daybreak's camera notes, and the second and third layers as the M team describes
  them (per-module calibration, and denoising by the Neural Engine and the encoder together). No
  public branch carries either for the J616s.
- The J616s and J616c share the sensor, the setfile, the firmware ABI and the device-tree presets,
  so nearly everything transfers. The exceptions are board-level: the J616c's AMCC count
  (linux#2216) and, for the encoder's filter, the T6041 firmware build.

### (d) Black-box measurement against macOS

- `macos-capture.swift` and a chart give macOS's field of view, noise, sharpness and face
  rendering on this Mac, losslessly. Matching the field of view tells which config macOS uses;
  running VideoToolbox's temporal filter on Linux frames tells what the encoder's filter would buy.
- Cheap, safe, and it is the yardstick every other path needs anyway.

### Recommendation

**(d) first, then (b), with (c) as questions to Aurora. Not (a).** The measurement session costs
one evening in macOS and nothing on the boot chain. Reading the daemon found the biggest win so
far (#2233) and is how Aurora gets its own facts; on this Mac it needs only copies of a few files.
The hypervisor would answer everything but is weeks of research on a path nobody has taken past a
single-user shell on this chip, and it means boot policy writes during the soak test.

What it needs from Allan: one macOS session (about an hour) to run `macos-capture` on the chart
and his face, copy the daemon, the ISP library and the camera extension (section 5), and allow the camera for Terminal
once. Then, back in Omarchy, approval to install `clang` and `lld` (the kernel was built with
clang 23 and LLD; the Mac has only gcc) and to load a test `apple-isp.ko` with the camera closed,
with a reboot as the undo.

## 5. What to pull from macOS next time

One session in macOS 26.7.3, read-only, nothing on the boot chain. Copies go to dev-machine-01 and
stay out of the repo: they are Apple's binaries, and some carry this Mac's serials.

1. **Measurements first** (section 6, items 3 to 6): `macos-capture` at 1920x1080 with the chart,
   then with Allan in the seat, room light, the light sensor's reading noted. Photo Booth stills of
   the same scene for framing.
2. **The daemon and the extension.**
   - `/usr/sbin/appleh16camerad`, or `/usr/libexec/appleh16camerad` if it has moved (linux#384
     found it in the first on 26.x, aurora-installer#151 in the second on 27.2).
   - `/System/Library/MediaCapture/H16ISP.mediacapture` and
     `/System/Library/PrivateFrameworks/H16ISPServices.framework` (the `sendCmd*` list).
   - The camera extension actually loaded: `kextstat | grep -i -e cam -e isp` names it (whether
     this Mac loads an `AppleH13CameraInterface` or an H16 one isn't known); copy that bundle.
   - The ISP firmware this board boots: `find /System/Volumes/Preboot /usr/standalone -ipath
     '*isp*' 2>/dev/null` (the public diffs show them as `adc-*.im4p`; which one is the J616c's isn't
     known). Its strings name the `CISP_CMD_*` table and log formats such as the MLVNR one.
   - The Neural Engine networks for the ISP: `find / -xdev \( -iname 'ispane*' -o -iname '*.afpp' \)
     2>/dev/null`.
   - For later: `CMCapture.framework`, `CameraColorProcessing.framework` and
     `/System/Library/Video/Plug-Ins/AppleMCTF.bundle`.
   - What to look for first, as facts only: the setfiles the daemon carries (is 2224 still the only
     one naming 0x958?), preference keys next to `RadialGainEnable` and their defaults, the H17
     `0x820e` record and the face detection setup before it, `ApplyNoiseReductionConfiguration`'s
     use-case enums and opcode, `SetStreamingTuningProfile`, `LSCComputeSNFVerticalGains` and its
     command, `SetLTMCurve` and `SetLocalHistogramsEnabled`, and whatever picks the sensor config
     for a 1080p session (`H16ISPSetfileSelector`, `GetMaxResolutionSensorConfigIndex`).
3. **The daemon's own log while Photo Booth and FaceTime run:**
   `log stream --level debug --predicate 'process CONTAINS "camerad"'` during the session, or
   `log show --last 5m --info --debug` with the same predicate right after. It may name the config,
   setfile and noise reduction use case it picks, and whether the ML stage switches on in room
   light. Keep the output private until read: it can
   carry serials.
4. **The IORegistry entry**, `ioreg -rlw0 -c AppleH16CamIn`, kept private (module serials).
5. **The factory record** `iCCl-<module serial>` from
   `/System/Volumes/Hardware/FactoryData/System/Library/Caches/com.apple.factorydata/`, kept on
   dev-machine-01 only, as the research proposed. Nothing reads it yet.

## 6. What the camera lab should measure next

In order of use for the plan above.

1. **A test-module mode for `clip`.** Record which ISP driver and which sensor config made the
   clip (`modinfo` srcversion, the preset table from `--log-status`) in `report.md`, so a run with
   the computed gains or config 8 can't be confused with a stock one. Nothing new to measure; it
   keeps the A/B honest.
2. **Aurora's metrics next to ours.** Add #2233's grain (standard deviation of frame minus its 9x9
   box blur, centre quarter) and #2237's frame-to-frame noise (standard deviation of the difference
   of consecutive frames over root 2, the 1% largest changes dropped). Then our J616c rows sit in
   the same columns as the J714s, J813 and, soon, Aurora's J616s rows.
3. **Sharpness on a chart.** Edge contrast against the raw clip can't compare two sensor configs or
   two operating systems, because the reference changes. Use a slanted-edge target (a black square
   printed on paper and tilted about 5 degrees, at a fixed distance in the middle of the frame) and
   compute MTF50 in cycles per pixel with the ISO 12233 slanted-edge method. Same chart, same
   distance, on Linux (each config) and on macOS through `macos-capture`. That answers "macOS is far
   sharper" with a number, and tells whether config 8's scaling loses detail.
4. **Field of view.** The same chart with marks at known spacing, or two marks on the wall, gives
   the field of view of each config and of macOS's 1920x1080 capture. Matching macOS's field tells
   which config and crop macOS uses, without any tracing.
5. **A face metric.** The comparison that matters most to Allan has a face in it. The lab has no
   face detector and should keep to the standard library, so use a fixed region instead: `--roi
   x,y,w,h` picked once from a snapshot, the same on both systems (same seat, same laptop angle).
   Report, inside the region: mean luma, the 5th and 95th percentile (modelling), local contrast
   (standard deviation after removing a 31x31 mean) and mean U/V (skin colour), plus the same for a
   wall patch. Today's finding (the face 30 code values darker on macOS, walls equal) becomes a
   pair of numbers to drive towards.
6. **A like-for-like macOS clip.** Run `tools/camera-lab/macos-capture.swift` at 1920x1080 `420v`,
   same scene, same light within 10%, chart in frame, and feed it to `camera-lab clip --from`.
   Record the device's exposure duration and ISO (AVFoundation reports both) so gain is known on
   both sides. This is the reference the research has been missing since OMS-26.
7. **macOS's temporal filter on our frames.** On macOS, run the public VideoToolbox temporal noise
   filter (the one linux#1513 matched bit for bit on the Neo) over a raw clip recorded on Linux.
   That shows what the encoder's filter would buy on this sensor before anyone qualifies it on
   T6041. It needs a second small Swift program; worth it only after items 1 to 6.

## 7. Where this changes the earlier research

- **"I can't tell from Linux whether macOS's ISP output is any cleaner ... Aurora's evidence says
  it isn't"** (`camera-quality-research.md` section 1). It is, or can be. The ISP's own spatial
  filter was left with a flat gain table; with the computed table the same sensor's raw output
  reaches 1 to 5 luma (#2233, #2237). linux#774's conclusion that "the bigger gap to macOS isn't in
  the ISP" was drawn with the flat table too.
- **"So in room light the installed filter is already close to macOS on noise ... the remaining
  gap is in dim light ... needs the encoder's filter and the ISP's ML stage"** (section 1). Close in
  numbers, but the ISP route gets there without the CPU filter's softness and specks, and the
  dim-light gap has to be re-measured after it. The encoder's filter and the ML stage drop from
  "where macOS gets its result" to "what is left after the ISP is set up as macOS sets it".
- **"The setfile ... loads, no visible effect"** (research, JOURNEY 9.37). Right for the file as
  shipped; the part of it that matters most for noise only acts once the driver fills it in.
- **"No ISP command or filter option exists for either"** (the specks, research section 3). The
  ISP's spatial filter, once its gains are set, acts before the tone curve that makes the dips
  deep, so it should remove most specks at the source. Unmeasured.
- **"Don't copy the J616s noise levels (7/5)"** (research section 2). camera-denoise#14 (merged
  2026-11-19) keys the profile on the sensor, `[sensor:imx958-uw]`, so the J616c will get the
  J616s's levels, 7/5 included, once a kernel with the sensor attribute (linux#2216) and a newer
  package arrive. With the computed gains the raw noise should fall below 7 in room light, which
  may make those levels right after all. Re-measure before proposing different ones.
- **JOURNEY 9.40's "beyond noise, white balance and tone are part of the gap".** The side-by-side
  the same evening found the global histograms and the walls matching. White balance and global
  tone are not the gap; the face's local rendering is. The lab's `warm`, `gamma-lift` and
  `contrast-sat` presets are the wrong knobs.
