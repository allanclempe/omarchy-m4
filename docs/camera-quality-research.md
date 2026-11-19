# Camera picture quality on the J616c: what limits it and what each fix is worth

Research for OMS-26, 2026-11-17. MacBook Pro 16-inch M4 Max (J616c, T6041), IMX958 camera,
`linux-aurora 7.3.0.aurora1-40` (aurora-silicon/linux `9125b314`, per
[alarm-aurora's PKGBUILD](https://github.com/aurora-silicon/alarm-aurora/blob/main/packages/linux-aurora/PKGBUILD)),
`aurora-camera-denoise 0.1.0-9` (camera-denoise `aa7a42ff`, today's `main`).

Nothing was changed on the Mac. All measurements here were taken at night in a nearly dark room
(0.54 to 0.63 lux at the Mac's light sensor, camera gain 9.7x to 12.2x). That is the worst case, not
a normal call. I have no daylight capture of my own, so the daylight advice rests on the source code
and on Aurora's published numbers for the same sensor.

## Short answer

1. **Put the filter in the build. Can do now, small.** The frames that leave the ISP carry the
   sensor's noise almost untouched: luma noise is 21 code values at this light, with no trace of
   temporal or spatial filtering in it. Aurora's userspace filter is what cleans the picture: it
   cut luma noise 3.8x (about 11.5 dB) here while keeping 90% of edge contrast, and Aurora measured
   2.4 against macOS's 2.1 in room light on the same sensor. On this Mac the package was installed
   by hand today (`pacman.log`, 13:15) and `tools/derive-j616c-image` doesn't install it, so a
   fresh install gets the raw camera. Ship it at `aa7a42ff`, not at the `a929985` the open Omarchy
   PRs pin.
2. **Give the J616c a low-light level. Can do now as a config, better as board data upstream.**
   With no board data the Neural Engine stage never runs in `auto` mode. With
   `enter-gain = 2304`, `exit-gain = 1792`, `enter-noise = 0` it joined in the dark room and
   halved the remaining noise (5.5 to 2.6) and removed 93% of the dark specks, at the cost of about
   a quarter of the edge contrast. In ordinary light it stays off. Don't copy the J616s noise
   levels (7/5): this sensor's raw noise is above them in every light, so the stage would never
   switch off.
3. **Keep the camera's factory record (`iCCl`) at install time. Can do now, small.** Nothing uses
   it yet and its format isn't public, so it buys no picture today. It is cheap insurance: Aurora's
   installer already keeps it, Omarchy's doesn't, and after install it can only be fetched from
   macOS.
4. **Ask Aurora for three filter changes. Needs their work.** A fix for the dark specks in the
   temporal filter (they are noise outliers the motion test lets through, not dead pixels), a
   strength setting for the low-light stage (half strength gave 3.9 noise at 80% edge contrast),
   and a Neural Engine program for 1280x720, where the stage can't run at all today.
5. **The video encoder's filter and the ISP's own ML noise reduction. Needs Aurora's kernel
   work, and nobody has it in hand for the M4 Pro or Max.** This is where macOS gets its dim-room
   result (Aurora measured 0.5 against 3.0 for the CPU filter on a J616s at 1.3 lux). In room light
   it would add little picture and mostly save CPU.

Not worth more time: the sensor setfile (loaded, no visible effect), P010, `threads`, the GPU
backend, libcamera.

## 1. What limits the picture today

### The ISP output is unfiltered in luma

Measured on raw `/dev/video0` frames, 1920x1080 NV12, static scene (table in section 7):

- **Luma temporal noise is 21.2 to 21.4 code values** (8-bit) at gain 9.7x to 10.7x, 40 ms
  exposure. Local chroma noise is 3.1 / 3.8 (U / V).
- **No temporal filtering shows.** The noise of consecutive raw frames is uncorrelated: lag-1
  autocorrelation -0.015, which is zero for a 60-frame sample. After the userspace filter the same
  figure is +0.68. The driver starts and enables the ISP's own temporal filter for the IMX958 with
  the values macOS sends ([linux#774](https://github.com/aurora-silicon/linux/pull/774),
  `isp_ch_configure_temporal_filter` in `drivers/media/platform/apple/isp/isp-cam.c`), but a
  recursive filter that was doing anything would leave frame-to-frame correlation. #774 itself found
  the grain unchanged by those commands.
- **No spatial luma filtering shows.** Luma noise correlates only with the adjacent pixel (0.47 to
  0.50) and not two pixels away (0.02 to 0.09), which is what demosaicing alone leaves. Chroma
  noise is smooth over 8 luma pixels (0.73), so some chroma filtering does run.
- The driver sends `CH_CNR_START`, `CH_MBNR_ENABLE` and the temporal filter commands on the NV12
  path, and its own documentation says that sending them "does not establish" what the firmware
  then does (`Documentation/driver-api/media/drivers/apple-isp-j616s.rst`). These measurements
  say: for luma, nothing visible.
- The setfile is the same story. It loads (`ch 0: sensor 0x958, 13 configs, platform 0x5, setfile
  apple/isp_2224_01XX.dat` in the kernel log) and the picture didn't change (JOURNEY 9.37).

I can't tell from Linux whether macOS's ISP output is any cleaner before macOS's host-side stages.
Aurora's evidence says it isn't: their CPU filter on Linux frames lands at 2.4 where macOS shows
2.1 ([linux#774](https://github.com/aurora-silicon/linux/pull/774)). A lossless capture on macOS
would settle it (section 8).

### macOS cleans it in three places Linux doesn't have on this Mac

As the M team describes it, there are three layers: the raw ISP, the ISP with each module's factory
calibration, and denoising by the Neural Engine and the video encoder together. The J616c is on
the first. In public sources the third layer is:

- **The video encoder's motion-compensated temporal filter (MCTF)**, on every frame. In the kernel
  for the MacBook Neo only ([linux#1513](https://github.com/aurora-silicon/linux/pull/1513)).
- **ML noise reduction run by the ISP on the Neural Engine** in low light: "ISP algorithm 0x143d",
  a per-board network `apple/ispane-<board>.afpp`, and a ring pair between the two firmwares. A
  draft exists on branch `camera/isp-ane-mlvnr` (commit `c5b5d15`, 2026-11-02). Its commit message
  says the doorbell between the two sides isn't known, so nothing changes at runtime.
- Aurora's `camera-denoise` stands in for both: a CPU temporal filter, plus its own small network
  on the Neural Engine.

### What each fix is worth

Luma temporal noise, static scene. Mine are at about 0.6 lux, gain about 10x. Aurora's are for the
same sensor on the J616s.

| Step | Luma noise | Source |
| --- | --- | --- |
| Raw camera | 21.2 | section 7 |
| + default filter (CPU temporal) | 5.5 (3.8x, 11.5 dB), edges 90% | section 7 |
| + low-light stage | 2.6 (8x, 18 dB), edges 69% | section 7 |
| 1280x720 instead of 1080p, filtered | 4.0 against 5.5 | section 7 |
| Frame rate free to drop (default) against fixed 30 fps, raw | 21.2 against 23.4 | section 7 |
| J616s, 150 lux: raw / CPU filter / macOS | 13.6 / 2.4 / 2.1 | [linux#774](https://github.com/aurora-silicon/linux/pull/774) |
| J616s, 1.3 lux, gain 6.9x: raw / CPU filter / macOS | 17.8 / 3.0 / 0.5 | [camera-denoise#3](https://github.com/aurora-silicon/camera-denoise/pull/3) and its closing comment |

So in room light the installed filter is already close to macOS on noise, by Aurora's numbers. The
remaining gap is in dim light, about 6x, and that is the part that needs the encoder's filter and
the ISP's ML stage.

### The earlier macOS comparison overstated the gap

JOURNEY 9.27 measured macOS at 46 to 47 dB and Linux at 20 to 22 dB (PSNR against a median copy).
The macOS side was Photo Booth H.264 at 1620x1080 and 5.4 to 6.3 Mb/s; the Linux side was 170 Mb/s
(`ffprobe` on the files in `~/oms-camera-2026-11-16/`). H.264 at that rate removes noise by itself,
so the 26 dB isn't a like-for-like figure. Aurora's flat-region numbers above are the better guide.

## 2. camera-denoise on the J616c

### What "no board data" does

Read from `src/config.c`, `src/trigger.c` and `src/main.c` at `aa7a42ff`:

- Defaults are `enter_gain = 0`, `exit_gain = 0`, `enter_noise = -1`, `exit_noise = -1`
  (`defaults()` in `src/config.c`). `boards.conf` has sections for `apple,j700` and `apple,j616s`
  only, and this Mac's compatible is `apple,j616c apple,t6041 apple,arm-platform`.
- In `auto` mode the gain test runs only if `enter_gain` is non-zero and the noise test only if
  `enter_noise > 0` (`cdn_trigger_step`). With the defaults neither runs, so **the low-light stage
  never engages**, whatever the gain. Measured: the default at gain 10.3x gives the temporal-only
  result (5.5), and so does `enter-gain = 3584` at gain 11.2x, below its level.
- The temporal filter runs on every frame regardless (`temporal = on`). It runs on the CPU:
  `temporal-backend = auto` tries the encoder's filter first and falls back because there is no
  MCTF device (`aurora-camera-denoise-bench -b ave` says "backend ave cannot run 1920x1080").
- The Neural Engine program exists for one size, a 960x540 grid, which is 1920x1080 frames
  (`docs/ane-backend.md`). At 1280x720 the bench says "backend ane cannot run 1280x720", and the
  service then keeps the temporal stage alone (`setup_backend` in `src/main.c`). So **an app that
  asks for 720p never gets the low-light stage**, even with `mode = on`.
- The network only filters luma; chroma passes through (`docs/ane-backend.md`). Its weights were
  trained on two clips of one dim scene from a MacBook Neo, a different sensor.

### What the settings did here

All through the service, back to back, gain 10.3x to 11.2x (section 7):

| Setting | Low-light stage | Luma noise | Edge contrast | Dark specks per frame |
| --- | --- | --- | --- | --- |
| default | off | 5.5 | 89 to 90% | 2,600 to 2,800 |
| `mode = on` | on | 2.6 | 70% | 180 |
| `enter-gain = 2304`, `exit-gain = 1792` | on | 2.6 | 68% | 160 |
| `enter-noise = 7`, `exit-noise = 5` | on | 2.5 | 68% | 160 |
| `enter-gain = 3584`, `exit-gain = 2816`, `enter-noise = 0` | off (gain 11.2x is below 14x) | 5.7 | 92% | 2,700 |
| `low-light-frame-rate = off` | off | 6.1 | 81% | 1,600 |

- **The low-light stage trades detail for smoothness.** Run offline on identical frames at partial
  strength: 0.25 gives 4.8 noise at 87% edge contrast, 0.5 gives 3.9 at 80%, 0.75 gives 3.2 at 74%,
  1.0 gives 2.8 at 68%. The service has no strength setting; the trigger only fades between 0 and 1.
  See `/tmp/oms-pub/cam-research/crop-chair-edge.png` and `crop-wall.png`.
- **The noise trigger would never switch off on this sensor.** The filter's noise measure,
  recomputed from `src/gain.c` on the raw frames here, is 22.7. On the J616s Aurora measured 13.2 to 13.9 at gain 1.02x in 150 lux
  ([linux#774](https://github.com/aurora-silicon/linux/pull/774)), which is base gain, so it won't
  fall much in brighter light. Both are above the 7 / 5 in the J616s board data. If that reading is
  right, the J616s runs the "low-light" stage in every light at 1080p, and the J616c would too with
  the same data.
- **`low-light-frame-rate = on` is worth keeping.** With it the camera ran 40 ms exposures at
  25 fps and gain 10.7x; with it off, 30 ms at 30 fps and gain 12.2x, and raw noise rose from 21.2
  to 23.4. It did not drop to 15 fps even at 0.6 lux.
- **`threads` doesn't matter for the picture.** One thread takes 2.9 ms a frame (9% of a core at
  30 fps), four take 1.2 ms for 11% more CPU time. The low-light stage adds 4.7 ms of latency and
  0.8 ms of CPU a frame.
- The blotchy colour seen with `mode = on` fits the design: luma gets very smooth while chroma
  only has the temporal stage. At night there is a second cause, in section 7.

### Recommended settings

- **Daylight and ordinary room light:** the defaults. The temporal filter alone is the sharpest
  result, and Aurora's J616s figure puts it near macOS. Nothing in `denoise.conf` improves on it.
  Not measured by me.
- **Dim light:** add this to `~/.config/aurora-camera-denoise/denoise.conf`, everything else
  default:

  ```
  [denoise]
  enter-gain = 2304
  exit-gain = 1792
  enter-noise = 0
  ```

  The stage then joins at 9x gain and leaves below 7x. Here gain sat at 9.7x to 11.2x in a dark
  room. It was about 2x in an earlier capture in a brighter room on this Mac and 1.0x on the J616s
  at 150 lux, so the stage stays off in normal light. I have no captures between 2x and 10x, so where
  specks start to bother is not known; `enter-gain = 1536`, `exit-gain = 1280` is the example in
  the shipped `denoise.conf` if 9x proves too late.
- `temporal-backend`, `backend`, `threads`: leave at `auto`, `auto`, `0`. `gpu` isn't built into
  the package (`-Dgpu=disabled` in the PKGBUILD) and `ave` has no device.

### Board data upstream

Worth proposing, with two points for Aurora to settle first:

- The J616s gain levels (3584 / 2816, 14x and 11x) are described as macOS's own for that machine.
  The J616c has the same sensor, but its macOS levels aren't in any public file I found. With 14x
  the stage would not have engaged in tonight's 0.6 lux room.
- The noise levels: see above. For the J616c I would propose gain levels only (`enter-noise = 0`).

Until then a private override doesn't belong in the build. Ship the package's defaults.

## 3. The dark specks

They are noise, not defective pixels.

- In the raw frames the luma noise is lopsided. On a plain wall (mean 95, std 16.8, skew -0.99),
  10.0% of samples sit more than 24 below the local median and 1.6% more than 24 above. Values
  reach code 0. A concave tone curve does this to symmetric sensor noise: dips are stretched,
  peaks compressed.
- They don't stay put. On that wall a pixel at code 16 or below in one frame is there again in
  the next 0.4% of the time, against a 0.2% base rate.
- Counted as pixels more than 24 below their 3x3 median, there are 143,000 a frame raw, 3,300
  after the default filter and 200 with the low-light stage.
- The temporal filter lets them through by design. Its motion test ramps "from about the 90th to
  the 99th percentile of noise" and a pixel that trips it takes the new frame as is
  (`set_params` and the header comment in `src/cpu/denoise_cpu.c`). The 3x3 pass after it clips
  each neighbour difference at about 2 sigma, so an outlier is pulled in by 2 sigma and no more.
  A deep dip therefore survives as a soft dark dot.
- Aurora saw the same thing. [camera-denoise#3](https://github.com/aurora-silicon/camera-denoise/pull/3)
  ("Lone noise outliers on static areas also restarted their own pixel") averaged the motion weight
  over 5x5 and cut speckle on static areas from 1.57% to 0.59% on a J616s capture. It was closed
  unmerged in favour of the encoder's filter. I did not run that branch.
- A crude test of the idea: a 3x3 median applied only to outliers (more than 12 from the median),
  after the default filter, on the same frames. Specks fell from 3,300 to 720 a frame with edge
  contrast unchanged at 92.7%. What remains is clusters of two or more pixels.

**Real fixed-position defects exist but are few and faint.** Across four raw clips over 12 minutes,
84 dark and 93 bright spots sat at the same position in every clip, nearly all one pixel, 13 to 17
code values deep at 10x gain; 122 of them are on the plain wall. That is 0.009% of pixels, and at
daylight gain they would be 2 to 3 code values. They could also be marks on the wall: I couldn't
move the camera to tell.

**No ISP command or filter option exists for either.** The driver's opcode list
(`isp-cmd.h`) and Asahi's
([`isp_opcodes.py`](https://github.com/AsahiLinux/m1n1/blob/main/proxyclient/m1n1/fw/isp/isp_opcodes.py))
have no defective-pixel command, and `denoise.conf` has no despeckle setting. Today the only
switch that removes the specks is the low-light stage.

## 4. Factory calibration (`iCCl`)

- **Format: not public.** The only descriptions are Aurora's: the record is
  `iCCl-<module serial>` in macOS's factory cache
  (`/System/Volumes/Hardware/FactoryData/System/Library/Caches/com.apple.factorydata`), and "the
  kernel currently has no validated iCCl envelope/payload parser, module-serial binding or firmware
  command" ([camera-tuning.md](https://github.com/aurora-silicon/aurora-installer/blob/main/macOS/docs/camera-tuning.md)).
  The general container for factory records is an IMG4 around a payload
  ([hack-different's notes](https://github.com/hack-different/apple-knowledge/blob/main/_docs/factory_data.md)),
  which doesn't list `iCCl`.
- **Who reads it on Apple's side.** Public string dumps show `iCCl` as a new string in iOS 26.0's
  `appleh16camerad`, `dietappleh16camerad` and `H16ISP.mediacapture`, absent in 18.5
  ([ipsw-diffs](https://github.com/blacktop/ipsw-diffs/blob/main/iOS/18_5_22F76__vs_26_0_23A5260n/MACHOS/appleh16camerad.md)),
  and it appears in diffs of the repair framework CoreRepairCore (26.3.1 and a 26.4 beta). So it
  is a factory-data class the H16 camera daemon reads, new with the 26 releases, and known to the
  code that pairs replacement parts. What the daemon
  does with it isn't shown.
- **How macOS applies per-module data in general.** The same dump adds `GICComputeFromNVMApple`
  and `LSCComputeSNFVerticalGains`: the daemon computes green-imbalance and lens-shading
  corrections from the module's own memory and sends them to the firmware. The Linux driver defines
  the matching reads (`CH_SENSOR_NVM_GET` 0x0501, `CH_SENSOR_PERMODULE_LSC_INFO_GET` 0x0507,
  `CH_SENSOR_PERMODULE_LSC_GRID_GET` 0x0511, `CH_LSC_POLYNOMIAL_COEFF_GET` 0x0142) and never
  sends them. These corrections affect shading and colour evenness more than noise. Whether `iCCl`
  feeds them is a guess.
- **Nobody parses or uploads it.** Code search across aurora-silicon, AsahiLinux and omacom finds
  `iCCl` only in Aurora's two documents. No branch name among the 748 in aurora-silicon/linux
  mentions it, and the only PR that does is
  [linux#668](https://github.com/aurora-silicon/linux/pull/668), which says the upload "require[s]
  a precise Daybreak specification before implementation".
- **Who keeps it.** Aurora's installer copies the whole factory cache into the machine's fallback
  archive (`NativeVendorFirmware.swift`: `fallback["com.apple.factorydata/" + name]`). Asahi's
  copies only the light sensor's `HmCA` records
  ([`als.py`](https://github.com/AsahiLinux/asahi-installer/blob/main/asahi_firmware/als.py)).
  Omarchy's reads the cache for Touch ID (`Engine/overlay/src/omarchy_mesa.py`) but keeps no camera
  record: on this Mac `/usr/lib/firmware/apple/` has the `HmCA` record and no `iCCl`.

**Should Omarchy's installer keep it now? Yes.** It costs one more file from a directory the engine
already reads, and without it every installed Mac needs a trip back to macOS the day a kernel can
use it. Follow Aurora's layout (raw, under `com.apple.factorydata/` in the fallback archive) so
both projects can share whatever comes next. The record is per machine and its name carries the
module's serial, so it must stay on the Mac and out of any package, log or report. Expected picture
gain today: none.

## 5. The encoder's filter (MCTF) on T6041

State on this Mac: the device tree has `video-codec@283100000` (`apple,t6041-ave`), both encoder
DARTs and both scalers, all `disabled`. `apple-ave.ko` and `apple-scaler.ko` are installed and not
loaded. In `integration/aurora` as of 2026-11-17 (`a7dd26e6`) that is unchanged.

What it would take, from the kernel source and PRs:

1. **Enable the encoder on the J614c/J616c tree.** `t6041-j614c-j616c.dtsi` doesn't include the
   file that enables it for the M4 Pro boards. The Mac Studio (J575c, same chip) got it in
   [linux#1677](https://github.com/aurora-silicon/linux/pull/1677): the six `ps_venc0_*` domains,
   `ave0_dart0/1` and `ave`. That PR also taught the driver the M4 Max firmware build (DATA
   0x130000, a TEXT word that changes each boot, CRC 0x9a080cad once zeroed) and says the J616c
   "get[s] the same variant, but [its] firmware was not seen".
2. **Find and attach the filter's DART stream.** On the Neo the filter engines do DMA on stream 12
   of both encoder DARTs. Left unattached, "the engines write device addresses straight into
   physical memory. On the MacBook Neo every filter run corrupted memory this way"
   ([linux#1516](https://github.com/aurora-silicon/linux/pull/1516)). The driver refuses to
   register the filter without it (`ave_mctf_check_build`). The T6041 node lists stream 0 only.
3. **Qualify the command layout for this firmware.** `ave_mctf_layouts[]` has entries for the
   M4 Pro and M4 Max builds marked `qualified = false`, "no capture yet"
   (`drivers/media/platform/apple/ave/ave-mctf.c`). The Neo's was captured from macOS at 1080p.
4. **Enable the scaler** for the all-hardware path (NV12, scaler, lossless 4:2:0, filter, scaler,
   NV12; [linux#1520](https://github.com/aurora-silicon/linux/pull/1520)). Its nodes sit in
   `t6041-j614-j616-j575-scaler.dtsi`, described as "Disabled M4 Max scaler resources".
5. The M4 Max's second encoder (`ave1`) isn't described anywhere.

**Is anyone on it?** No public sign. Searching aurora-silicon/linux PRs and issues for MCTF finds
the Neo work, the Neo's 27.2 firmware ([#1990](https://github.com/aurora-silicon/linux/pull/1990))
and M4 and M5 encoder bring-up that leaves the filter out. Step 2 is the kind of work to leave to
Aurora: a wrong stream corrupts memory.

**What it would buy.** Less than the name suggests, in room light. The driver runs the filter as
the public VideoToolbox session at strength 1.0, and on Neo frames that took noise from 9.2 to 4.7
where the CPU filter reached 2.1 ([camera-denoise#5](https://github.com/aurora-silicon/camera-denoise/pull/5)).
Its gains on the Neo are motion handling, 4% of a core against 39%, and 0.16 W
(`docs/measurements.md`). macOS's 0.5 in a dark room comes from the camera daemon's own session,
which the driver can't reproduce yet ("with the camera daemon's layout the engine returned every
picture unfiltered", [linux#1513](https://github.com/aurora-silicon/linux/pull/1513)), together
with the ISP's ML stage.

## 6. Anything else

- **ISP commands macOS sends that this path doesn't.** #774 says the stream-start sequence matches
  macOS apart from what it added. Still missing, from the driver source: the ML noise reduction
  endpoint (`IPC_ENDPOINT_SET2` 0x300c and algorithm 0x143d, draft branch above); the per-module
  reads in section 4; and face-weighted exposure metering (0x820e), skipped because "the H17
  firmware faults on this face-detection metering setup" (`isp-cam.c`). The last one matters for
  a backlit face, not for noise.
- **P010.** Its path skips the setfile and all noise commands, by design. Not a route to a better
  picture. I didn't capture P010: the driver's documentation says a stalled start latches a failure
  that needs a reboot, which isn't a risk to take on the soak machine.
- **1280x720.** The ISP scales it from the same crop. Raw noise is 17.5 against 21.2 and filtered
  4.0 against 5.5, but the low-light stage can't run at that size.
- **Colour range.** The NV12 data is video range as labelled: in the 2026-11-16 daylight clip the
  luma histogram has its black pile-up at code 16, with noise reaching below it to 0 (5.8% of
  samples). No mislabelling to fix.
- **libcamera.** The ISP delivers finished NV12, not raw Bayer, so libcamera's software ISP has
  nothing to work on. [AsahiLinux/linux#616](https://github.com/AsahiLinux/linux/issues/616) is
  about letting libcamera-only apps open the node, not about quality.
- **Exposure and frame rate.** The driver exposes no manual exposure or gain, only the read-only
  reports, the mains frequency and the frame-rate permission. The mains control is at its 50 Hz
  default; set 60 Hz where the supply is 60 Hz. Leave the frame-rate permission on.
- **Light.** At 0.6 lux no setting makes this camera clean. A desk lamp is worth more than any
  option above.

## 7. Measurements

2026-11-17, 20:20 to 20:35 local time. Both displays off, nobody in frame, a wall and two chairs.
Light sensor (`aop-sensors-als`) 0.54 to 0.63 lux. 1920x1080 NV12 unless noted.

Method:

- **Luma noise**: per-pixel standard deviation over 60 consecutive frames, averaged over the
  frame. **Chroma local**: the same after removing each frame's 31x31 local mean (see the last
  note below).
- **Edge contrast**: mean gradient of the 60-frame average at the strongest 0.3% of edge pixels,
  as a share of the raw clip's. It falls when edges are blurred. Repeatability between raw clips of
  the same scene was 1.5%.
- **Specks**: pixels more than 24 code values below (dark) or above (bright) their 3x3 median, per
  frame.
- **PSNR vs median**: the yardstick used before, kept for continuity. It rewards smoothing.

**Same frames.** One raw clip (gain 9.7x, 40 ms), the filter run over it offline with the
package's `aurora-camera-denoise-bench` on the Mac. The CPU filter's output was reproduced bit for
bit by an x86 build of `aa7a42ff`. "PSNR vs raw mean" uses the mean of all 120 raw frames as the
reference; exposure drifted during the clip, so read it as an ordering.

| Clip | Luma noise | Chroma local U / V | PSNR vs median | PSNR vs raw mean | Edge contrast | Dark specks | Bright |
| --- | --- | --- | --- | --- | --- | --- | --- |
| Raw camera | 21.35 | 3.07 / 3.62 | 24.9 | 21.1 | 100% | 143,158 | 23,908 |
| Default filter (CPU temporal) | 5.64 | 0.77 / 0.99 | 39.2 | 30.3 | 92.7% | 3,311 | 78 |
| + low-light stage at 0.25 | 4.75 | 0.77 / 0.99 | 41.1 | 31.4 | 86.5% | 1,813 | 33 |
| + low-light stage at 0.5 | 3.93 | 0.77 / 0.99 | 43.4 | 32.4 | 80.3% | 903 | 16 |
| + low-light stage at 0.75 | 3.23 | 0.77 / 0.99 | 46.0 | 33.2 | 74.2% | 412 | 7 |
| + low-light stage at 1.0 (`mode = on`) | 2.75 | 0.77 / 0.99 | 47.8 | 33.6 | 68.2% | 201 | 6 |
| Low-light stage alone, no temporal | 9.29 | 3.07 / 3.62 | 31.7 | 27.4 | 72.0% | 28,041 | 2,170 |
| Test: default + 3x3 median on outliers over 12 | 5.31 | 0.77 / 0.99 | 41.3 | 30.9 | 92.7% | 724 | 15 |
| Test: default with twice the averaging time | 5.09 | 0.70 / 0.89 | 39.3 | 30.6 | 91.9% | 3,283 | 74 |

**Through the service**, in this order, each a separate 160-frame capture (last 60 frames used).
The config file was written, the service reloaded, the clip captured.

| Capture | Gain, exposure | Luma noise | Chroma local U / V | PSNR vs median | Edge contrast | Dark specks |
| --- | --- | --- | --- | --- | --- | --- |
| Raw | 10.6x, 40 ms | 21.23 | 3.05 / 3.86 | 25.1 | 98.5% | 136,352 |
| Default | 10.3x, 40 ms | 5.48 | 0.76 / 1.06 | 39.7 | 89.1% | 2,632 |
| `mode = on` | 11.2x, 40 ms | 2.61 | 0.78 / 1.06 | 48.0 | 69.8% | 178 |
| `enter-gain = 2304`, `exit-gain = 1792` | 10.8x, 40 ms | 2.57 | 0.78 / 1.06 | 48.1 | 68.4% | 163 |
| `enter-noise = 7`, `exit-noise = 5` | 10.4x, 40 ms | 2.47 | 0.76 / 1.04 | 48.2 | 67.5% | 158 |
| `enter-gain = 3584`, `exit-gain = 2816`, `enter-noise = 0` | 11.2x, 40 ms | 5.65 | 0.78 / 1.07 | 39.6 | 92.1% | 2,720 |
| `low-light-frame-rate = off` | 12.2x, 30 ms | 6.11 | 0.86 / 1.19 | 40.1 | 80.9% | 1,594 |
| Raw, frame rate still fixed | 12.2x, 30 ms | 23.39 | 3.56 / 4.48 | 24.6 | 89.2% | 158,176 |
| Default again | 10.6x, 40 ms | 5.51 | 0.77 / 1.05 | 39.6 | 90.4% | 2,762 |
| Raw | 10.7x, 40 ms | 21.21 | 3.06 / 3.83 | 25.1 | 100% | 136,789 |

**1080p against 720p**, raw captures back to back, CPU filter offline:

| Clip | Luma noise | PSNR vs median | Dark specks |
| --- | --- | --- | --- |
| 1920x1080 raw / filtered | 21.25 / 5.48 | 25.1 / 39.7 | 138,256 / 2,683 |
| 1280x720 raw / filtered | 17.48 / 4.00 | 25.8 / 41.6 | 46,911 / 502 |

**Timing** (`aurora-camera-denoise-bench`, 120 frames, on the Mac):

| Run | Latency p50 | CPU per frame |
| --- | --- | --- |
| CPU filter, 1 thread | 2.93 ms | 3.08 ms |
| CPU filter, 4 threads | 1.23 ms | 3.41 ms |
| CPU filter, paced at 25 fps | 3.28 ms | 3.27 ms |
| CPU filter, 1280x720 | 1.32 ms | 1.39 ms |
| Low-light stage (Neural Engine) | 4.71 ms | 0.84 ms |

Two notes on the test itself:

- **The room light changes colour.** The frame's average V swings between 118 and 138 with a
  period of about 2 seconds, and the light sensor's colour temperature swings between 5,100 and
  6,030 K at the same rate. So something in the room cycles colour, and the camera reports it
  faithfully. It is why chroma is given as "local" above. Colour blotches seen at night may be this
  as much as noise.
- **Not covered:** daylight, a person, motion (trails and lag), and a lossless macOS reference.
  The static-scene numbers flatter any temporal filter.

Images, in `/tmp/oms-pub/cam-research/`: `frame-raw.png`, `frame-default-filter.png`,
`frame-mode-on.png` (the same frame), and `crop-wall.png`, `crop-chair-edge.png` (3x crops: raw,
default, low-light at 0.5, `mode = on`).

## 8. Open questions

For Aurora:

1. What does macOS use as the low-light gain levels on the J616c? Are they the J616s's 3584 / 2816?
   Would you take an `[apple,j616c]` section in `boards.conf`?
2. On IMX958 boards the raw noise is above the 7 / 5 noise levels at base gain. Is the low-light
   stage meant to run in every light on the J616s? Should IMX958 boards follow gain only?
3. The raw NV12 output shows no frame-to-frame correlation, so the ISP's temporal filter isn't
   acting on it. Does it act on macOS? Does it need buffers or a stream type the preview path
   doesn't set up?
4. Is the idea in camera-denoise#3 (restart averaging by area, so lone outliers don't restart
   their own pixel) still wanted for the CPU filter? Machines without the encoder's filter depend
   on it.
5. Would you add a strength setting for the low-light stage, and a program for 1280x720?
6. Is MCTF planned for T6040 and T6041? Which DART stream does the filter use there, and can a
   J616c help with the firmware capture?
7. What is in `iCCl`, and is anyone specifying its upload? Where should an installer keep it so a
   later kernel finds it?
8. Was the J616s macOS reference (2.1 at 150 lux, 0.5 at 1.3 lux) captured losslessly?

For the Omarchy M team:

1. omarchy-pkgs#2084 and omarchy#17487 pin `a929985`, 37 commits behind. It lacks the low-light
   backend, the fix that publishes only formats the filter can fill, and the user-unit guard for
   root and system users. Can they move to `aa7a42ff`?
2. Should the installer keep `iCCl` from the factory cache, as Aurora's does?
3. Until those PRs land, should the J616c derivation install `aurora-camera-denoise` from
   Aurora's repository?

For us, next time the Mac is in macOS or in daylight:

1. A lossless macOS capture of a static scene (uncompressed, not Photo Booth), to compare noise
   level and its spatial pattern with the Linux raw frames.
2. The section 7 series in room light and with a person moving, to place `enter-gain` between 2x
   and 10x.
