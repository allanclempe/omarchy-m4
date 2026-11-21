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
