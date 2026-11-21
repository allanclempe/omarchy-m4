# What macOS's camera daemon sends that Linux doesn't (J616c)

Research for OMS-34, 2026-11-21. MacBook Pro 16-inch M4 Max (J616c, T6041), IMX958 front camera,
macOS 26.7.3's `appleh16camerad` (source version 5.605.2, SDK 26.7.2) against Aurora's ISP driver at
the installed kernel's commit with [linux#2233](https://github.com/aurora-silicon/linux/pull/2233)
applied. It follows [`camera-pipeline-gap.md`](camera-pipeline-gap.md) (sections 1 and 3) and
JOURNEY 9.40 and doesn't repeat them.

This file records facts only: opcodes, argument values, the order of commands, conditions, and
the daemon's own names for things (its log strings and preference keys). No code or data from
Apple's binary is reproduced. Nothing was changed on the Mac; the only reads there were the kernel
log, `/sys/module` and a hash of the setfile.

## Short answer

- The daemon builds its firmware commands itself (the ISP library is compiled into it, not
  linked) and sends them through one function, so every command it sends shows up as an opcode
  and a payload in the disassembly. There are 69 send sites. Linux already sends most of them,
  with the same values.
- **Four things the daemon sends on this Mac and Linux doesn't** can be sent tomorrow, because
  their payloads are a word or two:
  1. `0x0a4e`, which the daemon logs as the lens shading (LSC) "FW Ideal Percent": **84** for the
     IMX958, sent at camera power-on, before the setfile.
  2. `0x0a49` `LTMHWConfigSet`, value **0**, and `0x0a4a` `CLRProcGammaConfigSet`, value **1**,
     at every stream start. LTM is local tone mapping; this pair is the only tone-related input
     the daemon gives the firmware.
  3. `0x820e`, the face/scene metering record that Linux skips on H17 because it faulted.
     macOS sends **byte-for-byte the same values** Linux has. The differences: macOS sends it
     without asking for a reply, and later in the sequence.
  4. `0x0b17`/`0x0b18`, semantic video and semantic AWB, with a flag from the stream's
     configuration (its value isn't resolved statically).
- **Sharpness and field of view probably come from the sensor mode, not a filter.** A hypervisor
  trace of macOS 27.2 on a J815 (same IMX958 sensor, same setfile family) shows macOS streaming
  **config 6, the full-resolution SIFR mode**, with highlight recovery on, framing about a 1.5x
  zoom and running Apple's ML denoiser (MLVNR) on every frame
  ([linux#2645](https://github.com/aurora-silicon/linux/pull/2645), open, WIP). Allan's
  measurement fits this: macOS shows about 960 of the 1520 binned pixels, a 1.58x zoom. From the
  full-resolution frame, that crop is about 1900 to 2030 pixels wide and is **scaled down** to
  1920. Our binned crop of 1216 is **scaled up** 1.58x. That would explain the book's lettering.
- **Not visible in this daemon:** the noise-reduction and sharpness "use cases", `SetLTMCurve`,
  local histograms, and highlight recovery. None of them is among the 69 send sites. They come
  from the client-side library in the dyld shared cache, or from the kernel extension, or are new
  in macOS 27 (where the J815 trace sees highlight recovery and an AE gain cap).
- A test module with all of these as parameters, default off, is built on the Mac (section 5).
  The ranked list is in section 4.

## 1. Method

- The daemon is a universal Mach-O; the arm64e slice was taken with `llvm-lipo` and disassembled
  with `llvm-objdump --macho -d`. A short script resolved `adrp`/`add` pairs to strings, CFStrings
  and selector names, so each function could be named by its log strings.
- The daemon doesn't link `H16ISPServices`; its ISP library is compiled in. Every firmware command
  goes through one sender. That sender passes a buffer, its size, a reply size and a timeout to
  the camera kernel extension (`IOConnectCallScalarMethod`, selector `0xa`). The buffer has the
  same layout as Linux's: the opcode in the upper half of the first 64-bit word, the channel at
  `+0x8`, the arguments after it. Each of the 69 callers writes a 16-bit opcode at `+0x4` and
  fixed-size fields after the channel. That gives the opcode, the size and the layout. A caller's
  error log names the step, for example `"LTMHWConfigSet"` or `"EnableSemanticVideo"`.
- The daemon's embedded `2224_01XX` setfile (size `0x6ff4`) is byte-identical to this Mac's
  `/usr/lib/firmware/apple/isp_2224_01XX.dat` over the same length (sha256 compared).
- Limits:
  - This is the daemon only. Stream properties that applications set (exposure bias, highlight
    recovery, LTM curves, the NR and sharpness use cases) go through the client library or the
    kernel extension, which aren't here.
  - Values the daemon fills in at run time, from the stream configuration or preferences, are
    named but not resolved.
  - Which sensor config a FaceTime call gets on this Mac isn't decided in code that can be read
    statically: the output presets arrive from the kernel extension at run time.

## 2. The stream start, macOS against Linux

The daemon's `StartStreaming`, in order, with what Linux's `isp_ch_configure_capture()` does.
"Same" means the same opcode and the same arguments.

| # | macOS 26.7.3 sends | Arguments | Linux (H17 path) |
| --- | --- | --- | --- |
| 1 | `0x013b` SBS enable | from the preset | same (1) |
| 2 | `0x0107` config select, `0x010e` recycle mode, `0x010f` recycle start | preset index | same |
| 3 | kernel-extension calls: MIPI, charge-pump and pixel-clock frequency selection | | none (firmware defaults) |
| 4 | `0x010d` channel info | | at detection |
| 5 | if the `EnableMSTF` preference is set (default off): `0x0122` property write, property `0x600`, value 1. If `EnableRawMLVNR` is set (default off): `0x0122`, property `0x143d` (the ML denoiser algorithm), value 1. Then the host-side MCTF graph, if `EnableMCTF` is on (its default comes from a per-platform table) | | none. MCTF is the encoder's temporal filter, as `camera-pipeline-gap.md` describes |
| 6 | `0x0126` metadata section enable, then `0x014f` metadata required, for sections `0x02` (logged `CISP_META_DATA_AE`), `0x08` (`RGBPROC`), `0x13` (`LTMLUTS`) and `0x36` (`SIFR`); one more section when a client asks for it | section, 1 | none |
| 7 | **`0x0a49` `LTMHWConfigSet`** | `{chan, u32 0}`, `0x10` bytes | **none** |
| 8 | **`0x0a4a` `CLRProcGammaConfigSet`** | `{chan, u32 1}`, `0x10` bytes | **none** |
| 9 | `0x0801`/`0x0b01` crop and output; `0x080c`/`0x0b09` for the second scaler | | same (first scaler) |
| 10 | `0x0b0d` preview stream | 1 | same |
| 11 | `0x0a1c` ALS enable, when the channel's configuration says | 2 | none |
| 12 | `0x0a2f` CNR start | | same |
| 13 | `0x0a3a` MBNR | 0, 1, 1 | same |
| 14 | temporal filter: `0xc100` start, then `0xc120`, `0xc11c`, `0xc11d` (float thresholds to 8.8), `0xc102`, `0xc113`; or `0xc114`, `0xc103`, `0xc101` to stop | from the stream's configuration | the same family, values from linux#774 |
| 15 | **`0x0b17` semantic video, `0x0b18` semantic AWB** | `{chan, u8 flag}`, the flag from the stream's configuration | **none** |
| 16 | starting the frame receiver: when a client asks for faces, `0x0d02` get, `0x0d03` set (five flag bytes from the client's request), `0x0d05` enable, `0x0d00` start; then `0x0105` current config, `0x0260` (0), `0x0208`/`0x020a` frame rate, the temporal filter again, `0x0750` (0), and the buffer pools (`0x0117`) | | pools and frame rate only |
| 17 | **`0x820e` face/scene metering** | twelve u16s from `+0xc`: `0xb8, 0, 0x200, 0x200, 0x800, 0x28, 0x28, 0xe1, 0x399, 0xa, 0x2cc, 0x3cc`; reply size 0 | **skipped on H17**. Off H17, Linux sends the same bytes (as six u32s) and asks for a reply |
| 18 | `0x8206` metering mode | 3 | same |
| 19 | `0x021a` AE stability, `0x0229` to stable | 32, 20 | same (macOS 27.2 on the J815 sends 16, 8: linux#2645) |
| 20 | `0x0115` SIF pixel format | 3, 1, compression from the preset, 0 | same with compression off |

Things only macOS 27.2 sends, from the J815 trace in linux#2645 (none of them is in this
26.7.3 daemon):
- `0x1008` SIFR skip interval 1 and `0x1005` highlight recovery on, in SIFR configs;
- `0x020c` AE gain cap 96.0;
- `0x060f` status-LED brightness. This 26.7.3 daemon sends it too, with the same layout (a u16
  at `+0xc`);
- `0xc11f` MLVNR auto mode.

## 3. At camera power-on: the setfile and lens shading

The daemon's `ISP_PowerOnCamera`:

1. Powers the sensor on and reads each channel's module data through the kernel extension. That
   this is the module NVM is an inference, from the four per-channel calls and the daemon's "NVM
   not valid" check that follows them.
2. Takes the setfile from `/usr/local/share/firmware/isp/cam<N>setfile.dat` if that exists, else
   the embedded one. For `0x958` there is a single choice, `2224_01XX`.
3. Adjusts the setfile in memory, then loads it.

A setfile is a list of firmware commands: each section's tag is an opcode. `2224_01XX` holds
`0xc003` (LSC configure), `0x0a2a`, `0xc404` (the spatial noise filter's radial gains), the
`0x83xx` AE and colour tables, `0x8104`, `0x011c`, `0x0806`, `0x0221`, `0x0a27` and `0x050f`.
It has no `0xc406`, `0xc407` or `0xc408`.

What the daemon does to it, for the IMX958:

- **`0x0a4e` LSC ideal percent, sent before the setfile load:** `{chan, u16 percent}`, `0x10`
  bytes. The percentage comes from a per-sensor table and can be overridden by the preference
  `LsIdealPctCam<N>`. Values in the table:

  | Sensor | Ideal percent |
  | --- | --- |
  | `0x958`, `0x814`, `0x923`, `0x614`, `0x558` | 84 |
  | `0x633`, `0x703`, `0x713`, `0x714`, `0x772`, `0x803`, `0x853`, `0x903` to `0x905`, `0x913`, `0x914`, `0x954`, `0x972`, `0x973`, `0x982` | 100 |
  | `0x356`, `0x613` | 97 |
  | `0x372`, `0x505` | 72 |
  | `0xd56` | 70 |
  | anything else | 90, with the adjustment off |

  The same switch gives the IMX958 an optical centre of -156 shading-frame pixels, which matches
  linux#2233's `snf_centre_dy`. It also gives a gain limit of `0x4fff` (about 5.0 in Q12) for the
  per-module shading computation, and turns lens shading adjustment on (preference
  `LsAdjustEnableCam<N>`, default -1, meaning "as the table says"). If the command fails, the
  daemon logs it and carries on. Linux never sends `0x0a4e`.
- **Per-module lens shading:** when the module's NVM is valid, `LSCComputeFromNVMApple`-style
  code rewrites the shading tables in `0xc003` (and `0xc01c`, `0xc01f`, `0xc021` where present)
  from the module's own calibration, and fills a buffer for the `0x0a2a` record. Related preferences, with their
  defaults: `LsInterpMode` 1, `LsEnableGreenAvg` 0, `LsBypassVerify` 0, `LsAdjustInvertCam<N>` 0,
  `UnitInfoNVMChannelMask` -1. Linux uses the model-average tables as shipped.
- **Spatial noise filter:** radial gains into `0xc404` behind `RadialGainEnable` (default 1). That
  is what linux#2233 does. The asymmetric, vertical and low-light variants (`0xc406` to `0xc408`)
  apply only when the setfile has those sections; `2224_01XX` doesn't, so linux#2233 covers this
  sensor completely.
- After the load: `0x8212` mains frequency (Linux sends it too).

## 4. Experiments for this Mac, ranked

All of these are in the test module (section 5) as parameters that are off by default. A
firmware fault leaves the camera dead until a reboot, and a reboot also brings back the stock
module. The firmware keeps its state between streams, so after a command has been sent, turning
its parameter back off doesn't undo it. To get back to the baseline, reload the module.

| Rank | Experiment | Command and payload | Why | Expected effect | Risk |
| --- | --- | --- | --- | --- | --- |
| 1 | `lsc_ideal_pct=84`, then `100` | `0x0a4e {chan, u16 84}`, before the setfile load | macOS sends it on every power-on for this sensor; Linux never does. The binned frame's walls and bench fall off by up to 35% towards the bottom and right, where macOS is flat. In config 5 the crop covered only the centre, so its flat look never showed whether shading correction was on | Flatter walls and bench at the edges; the right side and bottom brighter. No change would mean the firmware's default was already this, and the falloff has another cause | Low: one u16 that macOS always sends |
| 2 | `ltm_hw_config=0 clr_gamma_config=1` together, then each alone; if neither changes anything, other small values (1, 2) for `ltm_hw_config` | `0x0a49 {chan, u32 0}`, `0x0a4a {chan, u32 1}`, before the crop | The only tone-mapping inputs the daemon sends. Linux leaves both at the firmware's defaults | Shadows lifted on the right, a brighter face, slightly brighter overall; or no change | Low to medium: exact macOS values; what the values mean is unknown |
| 3 | `binned_config=7 binned_crop=1013`, then `binned_config=6`; `binned_crop=960` gives a 1920x1080 crop read out 1:1 | config select 7 or 6 instead of 8; crop 2024x1136, centred, from 3040x2880; in config 6 also `0x1008 {chan, 1}` and `0x1005 {chan, 0, 1}` | macOS streams the full-resolution SIFR mode with highlight recovery (J815 trace), and frames a crop that it scales down | The book's lettering much sharper (scaled down, not up); the lamp's highlight kept in 6. More noise: config 7 measured 4.6 on the J813 and about 5 on the J714s, against about 1 for config 8 here, and macOS hides it with MLVNR, which Linux doesn't have yet | Medium: config 6's double-height frame worked on the J815, untested on T6041 |
| 4 | `binned_config=9` (highlight recovery, binned) | config 9 plus `0x1008`/`0x1005` as above | Highlight recovery at binned noise: 1.52 against 1.29 for config 8 on the J815 | The bright bench and the lamp less clipped; auto exposure may expose brighter | Medium: the J815 accepted it |
| 5 | `fd_metering=1` | `0x820e`, the same twelve u16s, no reply asked, at the slot Linux uses off H17 (after MBNR; macOS sends it later, after the temporal filter and the frame receiver start) | macOS sends this on every stream; Linux skips it on H17 | Exposure weighted towards the centre and faces; possibly the doll's face brighter | High: Linux's version with a reply faulted on H17. Run it last in a session |
| 6 | `semantic=1` | `0x0b17 {chan, u8 1}`, `0x0b18 {chan, u8 1}` after the temporal filter | macOS sends both with a flag from the stream's configuration; the flag's value isn't known | Skin and sky rendering, white balance; or nothing, if it needs a segmentation network | Medium |

Not for tomorrow:
- **Per-module lens shading from the NVM.** It needs the NVM read on Linux (`0x0501`,
  `0x0507`, `0x0511`, unused today) and the daemon's shading computation worked out. That is days
  of reading the functions around `LSCComputeSNFVerticalGains`. It corrects per-unit shading and
  colour, not a 35% falloff.
- **Metadata sections** (`0x0126`/`0x014f`). They make the firmware report AE, colour, LTM look-up
  tables and SIFR data per frame. They are useful for reading back what the LTM does, but need
  the metadata buffers re-sized, and they don't change the picture by themselves.
- **Face detection start** (`0x0d02`, `0x0d03`, `0x0d05`, `0x0d00`). It needs the FD buffer pool
  and a reader for its output. It goes with experiment 5 once that doesn't fault.
- **MLVNR**: linux#2645 and #2647. It is the only way config 6 reaches macOS's noise.
- **The 1.5x framing with de-warp.** macOS de-warps the ultra-wide lens; Linux would do it on the
  host (the lab's `lenscorrection` preset) or not at all.
- **The noise-reduction and sharpness use cases.** They aren't in this daemon. Next step: the
  client-side library from macOS's dyld shared cache.

## 5. The test module

- **Source:** Aurora's ISP driver at the installed kernel's commit, with linux#2233 and the
  earlier `binned_presets`/`binned_crop` test parameters, plus the commands above. It is a copy in
  `~/isp-2233-exp/isp` on the Mac. Its changes:
  - `isp-cmd.h` and `isp-cmd.c`: the opcodes, packed structs with size asserts, and send
    functions;
  - `isp-cam.c`, `isp_ch_configure_capture()`: the sends, placed where macOS places them;
  - `isp-drv.c`, `apple_isp_init_presets()`: `binned_config`.
- **Build:** on the Mac with `make -C /usr/lib/modules/$(uname -r)/build M=$PWD LLVM=1 modules`.
  The build is clean, with no warnings. The vermagic matches the running kernel.
- **Parameters:**
  - `lsc_ideal_pct`, `ltm_hw_config`, `clr_gamma_config`, `fd_metering`, `semantic` and
    `sifr_hr` are writable at run time under `/sys/module/apple_isp/parameters/` and are read at
    each stream start. Changing one needs no reload, only a new stream.
  - `binned_presets`, `binned_crop` and `binned_config` are read when the module loads.
- **Logging:** every test command logs `OMS-34: <what> (<err>)` to the kernel log.

### Running it

Run these at the Mac, with the camera closed. The read-only checks come first.

```sh
# read-only: the ten parameters are listed; sha256 db06aecbdf850acb…
modinfo -F parm ~/isp-2233-exp/isp/apple-isp.ko | cut -d: -f1
sha256sum ~/isp-2233-exp/isp/apple-isp.ko
# swap the module; a reboot is the undo
systemctl --user stop aurora-camera-denoise
sudo rmmod apple_isp
sudo insmod ~/isp-2233-exp/isp/apple-isp.ko binned_presets=1 binned_crop=1216
systemctl --user start aurora-camera-denoise
journalctl -k -b | grep -E 'apple-isp|OMS-34' | tail -5   # "preset 0: 1920x1080 from sensor config 8, crop 1216x684 ..."
```

Then record one `camera-lab clip` of the still scene per step. Between steps, set the next
parameter and start a new stream. The kernel log should show `OMS-34: <what> (0)` for each
command sent.

```sh
echo 84 | sudo tee /sys/module/apple_isp/parameters/lsc_ideal_pct          # step 1; then 100
echo 0  | sudo tee /sys/module/apple_isp/parameters/ltm_hw_config          # step 2, with:
echo 1  | sudo tee /sys/module/apple_isp/parameters/clr_gamma_config
```

The sensor-mode steps (3 and 4) need the module reloaded:

```sh
sudo rmmod apple_isp
sudo insmod ~/isp-2233-exp/isp/apple-isp.ko binned_presets=1 binned_config=7 binned_crop=1013   # or 6, or 9 with binned_crop=1216
```

`fd_metering` (step 5) and `semantic` (step 6) go last, because a fault ends the session.

## 6. What macOS's unified log shows during a camera session (2026-11-21)

With the `com.apple.isp` and `com.apple.cmio` subsystems at debug level, a one-minute Photo Booth
session on the J616c logged the stream setup by name. The daemon itself (`appleh16camerad`,
`com.apple.isp:daemon`) only logs property ids (`setProperty - 1, 2, 9`, and `105` on every frame,
with one `Could not set CIL Brightness` while property 105 was first set). The ISP plugin, running in
`cameracaptured` (`com.apple.isp:plugin` and `com.apple.isp:services`), logs the sequence:

- `InitDeviceConfigsCache`, `SetMultipleOutputSupportEnabled - True`, `SetVideoOutputsEnabled -
  SecondaryScaler:1` (the app's frames come from the secondary scaler output);
- `SetStreamingTuningProfile - ISP tuning profile = 0`;
- `SetObjectDetectionConfiguration` with `overrideMaxFaceCount=10`, then
  `ObjectDetectionSetCurrentOverrideMaxHumanFaceCount` 10 (0 at the end): face detection runs for
  the whole session;
- `SetAEFDSceneMeteringConfig`: the face/scene metering the Linux driver skips on H17;
- `SetZoomFactor` (value redacted), and the frame-rate band `min 15`, `max 30`;
- `H16ISPCaptureStreamStart` on channel 0, `First good frame` after about 50 ms, the
  `SecondaryScaler` frame to the client; `H16ISPServicesRemote: SetProperty 1, 2, 9` round trips.

Every value is `<private>` in the log, so the sequence is known and the payloads aren't; those
are in the plugin (`H16ISP.mediacapture`) and `H16ISPServices`, both only in the dyld shared
cache. The capture was `log stream --level debug --predicate 'process == "appleh16camerad" OR
subsystem BEGINSWITH "com.apple.isp" OR subsystem BEGINSWITH "com.apple.cmio"'` after
`sudo log config --mode "level:debug,persist:debug" --subsystem com.apple.isp` (and `com.apple.cmio`).

## 7. The ISP capture plugin: what an app's stream sends (2026-11-21, evening)

The plugin `H16ISP.mediacapture`, the service library `H16ISPServices` and `CMCaptureCore` were
extracted from macOS 26.7.3's dyld shared cache and read like the daemon (section 1), with the
debug log of section 6 for the order and the values it prints. The plugin keeps its local symbols,
so every function has its C++ name (`H16ISP::H16ISPDevice::SetSharpness` and so on). Each
`H16ISPDevice` method builds one command (opcode at `+0x4`, channel at `+0x8`) and calls
`ISP_SendCommand`, which hands it to the camera kernel extension with `IOConnectCallScalarMethod`
selector `0xa`, the same as the daemon's sender. A script mapped about 300 methods to their
opcodes. Calls into other images of the cache can't be followed from an extracted image, so
CoreFoundation calls are read from context and dictionary keys from the plugin's import list. The
kernel extension wasn't extracted (`kext/` is empty): it supplies the output presets and may send
commands of its own, which nothing here shows.

### 7.1 Corrections to sections 2 to 5

- **The plugin, not the daemon, runs an app's stream.** In the Photo Booth session the plugin, in
  `cameracaptured`, powers the camera on, selects the format and starts the stream; the daemon
  only answers four properties: `1` and `9` when the device is created, `2` when the stream starts
  and stops, and `105` on every frame. The daemon's `StartStreaming` (section 2) is not on this
  path. The plugin's `ISP_PowerOnCamera` is the same code as the daemon's (the same setfile
  adjustment, the same ideal-percent table with 84 for `0x958`), so section 3 still holds.
- **The plugin never sends `0x0a49` or `0x0a4a`.** `LTMHWConfigSet` and `CLRProcGammaConfigSet`
  are compiled in and have no caller. That fits the test of JOURNEY 9.40, where the pair made the
  frame darker: an app on macOS doesn't get it. Experiment 2 of section 4 is withdrawn.
- **The third argument of the sender is not a reply size.** The plugin passes 0 for every command,
  including the reads whose answers it uses (`0x0d02`, the face-detection configuration read,
  and `0x0a0a`, the sharpness read). The kernel extension decides what comes back. So "macOS sends
  `0x820e` without asking for a reply" (section 2, row 17) isn't supported.
- **Property `105` is the camera indicator light.** The daemon's `setProperty` sends `0x060f`
  (`ISP_SetCILDutyCycle`) for it; `Could not set CIL Brightness to 419` in the log is that path.
  It has nothing to do with the picture.

### 7.2 What the plugin sends for the session, in order

From the log's order and the code behind each line. Commands that run only when a debug
preference is set are listed in 7.5 and left out here.

| # | Step | Command and payload | Linux |
| --- | --- | --- | --- |
| 1 | `SetFormatIndex` (format 4) | `0x013b` SBS (from the preset), `0x0107` config select (the preset's sensor config), and when the preset uses the front-end scaler (FES): `0x0901` FES output size `{chan, u32 w, u32 h}` (`0x14` bytes) and `0x0900` FES crop `{chan, u32 x, y, w, h}` (`0x1c`); then `0x010e` recycle mode 1, `0x010f` recycle start, `0x0903` FES auto-adjust 1 | same, without the FES pair: Linux crops with `0x0801`/`0x080c` |
| 2 | frame rate 15 to 30 | kept; sent at the frame receiver start (`0x020a`, `0x0208`) | sent, with Linux's own limits |
| 3 | `Enable CNR: True` | `0x0a2f` | same |
| 4 | gain cap `0x6000` "for next stream start" | `0x020c` `{chan, u32 0x6000}` at the stream start: 96.0 in 8.8, the value of the J815 trace | **none** |
| 5 | object detection, `featureFlags=0x8`, ten faces | kept for the face-detection start (7.4) | none |
| 6 | `SetStreamingTuningProfile` 0 | **nothing**: a command goes out only when the profile changes (`0x0b19`, ProRes sharpening tuning, 1 for a ProRes output, else 0) | none needed |
| 7 | `SetAEFDSceneMeteringConfig` | `0x820e`, client's values (7.4) | skipped on H17 |
| 8 | exposure bias `0x100`, tag 0 | `0x0204` `{chan, u16 0x100, u32 tag 0}` (`0x14`) | none |
| 9 | AE stability `0x10/0x08` | `0x021a` 16, `0x0229` 8 | 32, 20 |
| 10 | AE convergence 100/100 | `0x0243` `{chan, u8 100, u8 100}` (`0x10`) | none |
| 11 | zoom 1.0 | kept; sent at the stream start only when it isn't 1.0, as `0x0810` `{chan, u16 zoom x 1024}` | none needed |
| 12 | `Enable TNR: True` | the `0xc100` family at the frame receiver start, values from the TNR configuration | the same family |
| 13 | stream start: metadata | `0x0126`/`0x014f` for sections chosen by client options and preferences | none |
| 14 | stream start: colour space | **`0x200a` `LTMGammaSet` `{chan, u32}`, `0x2004` `LTMModeSet` `{chan, u16}`, `0x0a48` `EnableHDRC` `{chan, u8}`, `0x831d` `SetAWBRGBColorspace` `{chan, u8}`**, every stream, before the channel starts (7.5) | **none** |
| 15 | stream start: clocks | MIPI, charge-pump and pixel-clock frequency indexes (`0x011b`, `0x0146`, `0x0120`) | none |
| 16 | stream start: outputs | `0x0816` secondary scaler source, `0x080c` crop, `0x0b09` output config; ALS `0x0a1c` when the stream's ALS mode asks | first scaler only |
| 17 | stream start | `0x020c` gain cap (row 4) | none |
| 18 | frame receiver start | face detection: `0x0d02`, `0x0d03`, `0x0d05`, `0x0d00` (7.4); frame rate; TNR; first buffers; then the kernel extension's start-camera call (user-client selector `0x36`) | pools, frame rate, `0x0100` |
| 19 | after the first frame | `0x0a0f` histogram on; `0x820e` a second time | none |

### 7.3 Item 1: the tuning profile and the noise/sharpness use cases

- **Tuning profile 0 sends nothing.** `SetStreamingTuningProfile` compares the value with the
  stream's current profile (0 at creation) and, on a change, sends only `0x0b19` (ProRes sharpening
  tuning). The log's `ISP tuning profile = 0 (err = 0)` is a no-op.
- **`ApplyNoiseReductionConfiguration`** runs for use case 0 (video) when the client sets the
  stream property `NoiseReductionAndSharpeningConfiguration`, and for use cases 1 and 2 from
  still captures. Its dictionary keys are `RawNoiseFilterStrength`, `SharpeningControl`,
  `LocalContrastEnhancementStrength` and `MultiBandNoiseReductionConfiguration` (`Enabled`,
  `MultiBandEnabled`, five `LumaProcessingStrength`, `ChromaProcessingEnabled`, five
  `ChromaProcessingStrength`). A missing key means **128**; a value above 255 is refused. The
  commands, in order:

  | Command | Payload | Default |
  | --- | --- | --- |
  | `0x0a3d` raw noise filter (RNF) strength | `{chan, u32 use case, u8 strength}`, `0x14` | 128 |
  | `0x0a13` knob to manual, then `0x0a09` sharpness | `{chan, u32 knob 1}`, `0x10`; `{chan, u32 use case, u8 sharpness}`, `0x14` | 128 |
  | `0x0a40` local contrast enhancement (LCE) strength | `{chan, u32 use case, u8 strength}`, `0x14` | 128 |
  | `0x0a3a` MBNR enable | `{chan, u32 use case, u32 mode, u8 chroma}`, `0x18` | mode 2, chroma 0 without an MBNR dictionary |
  | `0x0a3b` MBNR bands | `{chan, u32 use case}`, then five pairs of u8 (luma, chroma) strengths from `+0x10` and five u8 band enables from `+0x1a`, `0x20` | 128 each, all enabled |

- Whether Photo Booth's stream gets this property can't be read here: the function logs only
  failures and the dictionary comes from `CMCapture`, which wasn't extracted. What is certain is
  the shape: four strengths centred on 128 and a five-band MBNR table, each one small command.
  The same plugin also exposes single knobs as properties (`0x0a0b` noise reduction level,
  `0x0a2d` CNR level, `0x0a07` scaler sharpening, `0xc402` SNF parameters, one u8 each); none of
  them shows in the log.
- Linux sends `0x0a3a` with mode 1 and chroma on, and none of the rest.
- Confidence: high for the opcodes, layouts and defaults; unknown for the values macOS's client
  passes.

### 7.4 Item 2: face metering and face detection

- **`0x820e`** has the daemon's layout: `0x24` bytes, the channel at `+0x8` (with bit 31 set in one
  multi-stream case, not this one), twelve u16 from `+0xc`. The values come from the client's
  `AEFaceDetectionMetering` dictionary (twelve keys, all required), so the session's numbers aren't
  in the binary; the daemon's defaults (section 2) are the best available. The first send comes
  right after the format setup (row 1) and CNR, before the stream starts; the second after the
  first frame.
- **Face detection** starts in the frame receiver, before the start-camera call, only when the
  face-detection output pool (pool type 3) exists:
  1. `0x0d02` read, `{chan}`, `0x1c` bytes; the u32 at `+0x10` of the answer goes into the next
     command;
  2. `0x0d03` `{chan, u32 from the read, five u8}` (`0x18`): bits 0, 1 and 2 of the feature flags,
     then bit 3 and bit 4 inverted. For the session's flags `0x8`: `0, 0, 0, 0, 1`;
  3. `0x0d05` `{chan, u8 face-detection mode}` (`0x10`), the mode from the client's
     `FaceDetectionMode` property (not logged);
  4. `0x0d00` `{chan}` (`0xc`).
- **Why `0x820e` faults on Linux** is not settled. It isn't the reply (7.1). What differs: the
  values (the client's against the daemon's defaults), the timing (macOS also sends it on a
  running stream) and the face-detection engine, which on macOS is set up in the same stream.
- `CMCaptureCore` names LTM look-up tables "WithoutFaceBoost", which suggests the firmware's LTM
  lifts faces with its own face detection. That is an inference from a name.

### 7.5 Item 3: local tone mapping

- **`ApplyColorSpaceConfiguration` is the LTM setup an app's stream gets**, at every stream
  start, before the frame receiver starts the channel. A colour-space change while outputs are
  streaming is refused ("Unable to set ltm mode while streaming is active"). Values by the
  client's colour space; a stream starts with colour space 0's:

  | Colour space | `0x200a` gamma | `0x2004` mode | `0x0a48` HDRC | `0x831d` AWB colour space |
  | --- | --- | --- | --- | --- |
  | 0 (default) | 0 | 1 | 0 | 0 |
  | 1 | 0 | 1 | 0 | 1 |
  | 2 | 0 | 1 | 0 | 2 |
  | 3 | 1 | 1 | 0 | 1 |
  | 4 | 1 | 1 | 1 | 1 |
  | 5 | 3 | 0 | 0 | 2 |
  | 6 | 3 | 0 | 0 | 3 |

  Colour spaces 0 to 2 all get gamma 0, LTM mode 1 and HDRC off; which colour space Photo Booth
  asks for isn't logged. Linux sends none of the four, so its firmware runs with its own defaults.
- Client properties: `LTMCurve` sends `0x0a44` `{chan, u32 curve}`, clamped to 0 to 3 (its error
  string calls the command `CISP_CMD_CH_LTM_PROCESSING_MODE_SET`); `LockLTMNow` and `UnlockLTMNow`
  suspend and resume LTM updates. LTM look-up-table metadata (section `0x13`)
  and local histograms (`0xc01a` `{chan, u8}`) are statistics for the host. None shows in the log.
- Only behind debug preferences (`Cam<N>HRLTM`, `Cam<N>HR`, `Cam<N>SNF`,
  `Cam<N>BinningCompensation`, `Cam<N>FullLSC`, `EnableLTMStaticCLUT`), whose default is "leave the
  firmware alone": LTM start and stop (`0x2000`, `0x2001`), highlight recovery start and stop
  (`0x1000`, `0x1001`), static LUT for LTM (`0x2006`), binning compensation (`0xc200`), SNF start
  (`0xc400`), full-resolution LSC (`0x0a11`, `0x0a12`). A normal session sends none of them.

### 7.6 Item 4: lens shading

- Power-on as in section 3: NVM reads, per-module shading rewritten into the setfile, `0x0a4e`
  84 before the load.
- `EnableFullResLSC` `0x0a11` `{chan}` and `DisableFullResLSC` `0x0a12` exist, behind the
  `Cam<N>FullLSC` preference only. `SetLSCStrength` `0x0a4c` `{chan, float}` is a client property
  (the plugin also sends −1.0, which looks like "default"); `0x0a4d` reads it. The per-module grids (`0x0507`, `0x0511`) are
  read for clients that ask for them.
- No stream-time code ties shading to the sensor mode. So the falloff Linux shows in configs 7 and
  8 is not corrected by a command macOS sends per stream; the candidates stay the per-module
  tables (section 4), the kernel extension, and `0x0a11`, which macOS doesn't send but the
  firmware has.

### 7.7 Item 5: the window, the zoom and the secondary scaler

- Zoom 1.0 sends nothing (row 11).
- The window comes from the output preset, a `0x78`-byte record per format: `+0x10` sensor
  config, `+0x24` FES on, `+0x28`/`+0x2c` FES output size, `+0x30` FES crop rectangle, `+0x68` SBS.
  The presets come from the kernel extension at run time; the plugin holds no 2132 or 1080
  constant. When a preset turns the FES on, macOS cuts the window with the **front-end scaler**
  at format selection (row 1); the secondary scaler (`0x080c`, `0x0b09`) then delivers the app's
  frames. A 2132x1080 FES crop at 454,784 with a 1920x1080 FES output would give the geometry
  measured by eye in JOURNEY 9.40, scaled in the front end rather than after the pipeline.
  Whether format 4's preset turns the FES on, and its numbers, are inferences; the mechanism is
  in the code.

### 7.8 Experiments, ranked

Parameters of the test module (7.9), off by default, writable under
`/sys/module/apple_isp/parameters/` and read at each stream start, except where noted. As before, the
firmware keeps state between streams: to get back to the baseline, reload the module. Leave
`ltm_hw_config` and `clr_gamma_config` unset.

| Rank | Parameters | Commands | Why | Expected effect | Risk |
| --- | --- | --- | --- | --- | --- |
| 1 | `ltm_gamma=0 ltm_mode=1 hdrc=0 awb_colorspace=0`; then `ltm_mode=1` alone | `0x200a {chan, 0}`, `0x2004 {chan, 1}`, `0x0a48 {chan, 0}`, `0x831d {chan, 0}`, after the recycle start, before the crop | Every macOS app stream gets these four; Linux none. The only LTM input macOS gives per stream | Shadows and faces lifted, highlights held; or no change if the firmware's default is already mode 1 | Low to medium: exact macOS values for colour space 0, sent before the channel start as the plugin does |
| 2 | `gain_cap=24576 ae_stability=16 ae_stability_to_stable=8 ae_speed=100 exposure_bias=256` | `0x020c`, `0x021a`/`0x0229` with 16/8, `0x0243`, `0x0204` | macOS's values from the session's log | Less noise in dim light (gain capped at 96x), calmer exposure changes | Low |
| 3 | `fes_window=1` with the 9.40 window: `binned_presets=1 binned_config=7 binned_crop=1066 binned_crop_h=540 binned_crop_dy=-58` (insmod line) | `0x0901` output 1920x1080 and `0x0900` crop 2132x1080 at 454,784 after the config select; then `0x0801`/`0x080c` crop of the whole 1920x1080 | macOS's presets cut the window in the front end | The same framing with the downscale before the pipeline: finer detail and less noise per output pixel, or no change | Medium: if the FES refuses, the log says so and the stream may not start; a reload undoes it |
| 4 | `lce_strength` 128, then 192, 64; `sharpness` 128, then 192; `rnf_strength` 128, then 64 and 192; `mbnr_strength=128` | `0x0a40`, `0x0a13`+`0x0a09`, `0x0a3d`, `0x0a3a` (mode 2, chroma 0)+`0x0a3b`, video use case | macOS's noise and sharpness controls, 128 when its client gives no value | LCE: local contrast, face modelling. Sharpness: edge crispness. RNF and MBNR: the noise against texture balance. 128 should look like today if it's the firmware's default | Low to medium: the sharpness knob stays manual until a reload |
| 5 | `full_res_lsc=1`; then `lsc_strength_bits=0x3f800000` (1.0) | `0x0a11 {chan}`; `0x0a4c {chan, float}`, before the LTM set | The firmware has a switch for shading in full-resolution configs; config 7's falloff is the main gap left | Flatter walls and bench in config 7 | Low to medium |
| 6 | `ltm_curve` 0 to 3 | `0x0a44 {chan, curve}` | A client property; the curves' meaning is unknown | A different tone curve per value | Low |
| 7 | `fd_metering_late=1`; then `fd_metering=1` | `0x820e` with the daemon's values, right after the channel start; then before it | macOS sends it on a running stream as well | Exposure weighted to faces | High: it faulted before. Last in a session |

Not now:
- **Face detection** (`0x0d02`, `0x0d03`, `0x0d05`, `0x0d00`): it needs the face-detection pool
  and a reader for its output, and the mode value isn't known. Payloads are in 7.4.
- **The client's `0x820e` values, its colour space and its noise/sharpness dictionary**: they live
  in `CMCapture` and the camera tuning it loads, which weren't extracted. The next read if the
  ranked experiments leave a gap.
- **The kernel extension**: the presets (and so the exact FES numbers) and whatever it sends at
  the start-camera call.

### 7.9 The test module, second round

- **Source:** the test module of section 5 with the parameters above added, all earlier
  parameters kept: `ltm_gamma`, `ltm_mode`, `hdrc`, `awb_colorspace`, `ltm_curve`, `full_res_lsc`,
  `lsc_strength_bits`, `sharpness`, `rnf_strength`, `lce_strength`, `mbnr_strength`, `gain_cap`,
  `ae_stability`, `ae_stability_to_stable` (defaults 32 and 20, Linux's), `ae_speed`,
  `exposure_bias`, `fes_window` and `fd_metering_late`. All of them are read at each stream start;
  the binned window parameters are read at load, so they go on the insmod line. Every test
  command logs `OMS-34: <what> (<err>)`.
- **Build:** not built on the Mac yet: it was in macOS when this was written. The changed files
  (`isp-cam.c`, `isp-cmd.c`, `isp-cmd.h`) compile without warnings against another kernel's
  headers (`W=1`), with the size asserts holding. Build it on the Mac as in section 5.

```sh
# read-only: the 30 parameters are listed
modinfo -F parm ~/isp-2233-exp/isp/apple-isp.ko | cut -d: -f1
# swap the module; a reboot is the undo
systemctl --user stop aurora-camera-denoise
sudo rmmod apple_isp
sudo insmod ~/isp-2233-exp/isp/apple-isp.ko binned_presets=1 binned_config=7 binned_crop=1066 binned_crop_h=540 binned_crop_dy=-58
systemctl --user start aurora-camera-denoise
journalctl -k -b | grep -E 'apple-isp|OMS-34' | tail -5   # "preset 0: 1920x1080 from sensor config 7, crop 2132x1080 at 454,784 ..."
# step 1, then a new stream; the kernel log shows four "OMS-34: ... (0)" lines
echo 0 | sudo tee /sys/module/apple_isp/parameters/ltm_gamma
echo 1 | sudo tee /sys/module/apple_isp/parameters/ltm_mode
echo 0 | sudo tee /sys/module/apple_isp/parameters/hdrc
echo 0 | sudo tee /sys/module/apple_isp/parameters/awb_colorspace
```
