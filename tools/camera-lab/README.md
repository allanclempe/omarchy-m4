# Camera lab

`camera-lab` runs on the J616c in Omarchy and lets you change the camera's filters and settings
and see the result at once, to find what gets the picture closest to macOS. It builds on
[`docs/camera-quality-research.md`](../../docs/camera-quality-research.md) (OMS-26) and reproduces
its section 7 metrics.

It works in two layers:

- **Layer 1, the camera as every app sees it:** Aurora's `aurora-camera-denoise` filter
  (`~/.config/aurora-camera-denoise/denoise.conf`), the camera's V4L2 controls and the capture size.
  A change here reaches every app on the camera, Meet included, until the lab restores it.
- **Layer 2, experiments:** FFmpeg filters applied in the lab's preview only (in clip mode, offline).
  Nothing else sees them, unless you send them to a virtual camera (`camera-lab virtual`).

## Setup on the Mac

The repo isn't checked out on the Mac. Copy the tool across from a checkout, to any directory:

```sh
rsync -a tools/camera-lab/ clempe@dev-machine-mac-1:~/camera-lab-dev/
```

(or clone the repo on the Mac and run it from `tools/camera-lab/`). Then, on the Mac:

```sh
~/camera-lab-dev/camera-lab check
```

`check` lists every dependency, finds the camera's PipeWire nodes and runs each preset through
FFmpeg. In a terminal on the Omarchy desktop the environment is already right. Over SSH, set it
first:

```sh
export XDG_RUNTIME_DIR=/run/user/$(id -u)       # PipeWire and the user services
export WAYLAND_DISPLAY=wayland-1                 # live only: ls $XDG_RUNTIME_DIR/wayland-*
```

Everything it needs was on the Mac on 2026-11-20 (`camera-lab check` tells you): GStreamer's `pipewiresrc`, `mpv`,
`ffmpeg`, `gum`, `v4l2-ctl`, ImageMagick, Python 3 (standard library only) and Aurora's
`aurora-camera-denoise` with its `-bench` and `-metrics` tools. No sudo, nothing in `/etc`.

## What it changes, and how it puts it back

- The first time the lab writes `denoise.conf`, it copies yours to
  `~/.local/state/camera-lab/denoise.conf.orig` (or notes that you had none). The first time it
  sets a V4L2 control, it saves the old values to `~/.local/state/camera-lab/v4l2.orig`.
- On every exit, Ctrl-C included, it copies your file back byte for byte, sets the controls back,
  turns off any effect it turned on and reloads the filter (`systemctl --user reload
  aurora-camera-denoise`).
- If the lab was killed before it could (a closed terminal, a crash), the backup stays.
  `camera-lab restore` puts it back; `live` and `clip` also restore a leftover backup before they
  start. `camera-lab status` shows whether one is there. If you edited `denoise.conf` by hand after
  such a run, your edit stays: the lab moves the old backup aside
  (`denoise.conf.orig.kept-<time>`) and says so.
- A restore that can't write (a full disk, a directory made read-only) keeps the backup and says
  so; it never deletes the only copy of your file.
- It never opens `/dev/video0` for frames. It streams from the filter's PipeWire node
  (`aurora_camera_denoise.v4l2_input.platform-580000000.isp`) and changes the filter's `mode`
  instead, because only one client can drive the ISP. The stream carries on through a filter
  reload (checked on the J616c), so a layer 1 change shows within a second.

Snapshots and clip runs go to `~/camera-lab/`.

## `camera-lab live`

Opens a preview window ("Camera lab") and a menu in the terminal. `--size 1280x720` starts at 720p
(default 1920x1080). The menu header shows, refreshed on each draw: layer 1's settings, what the
filter says it is running (`--print-config`, and its log line for the stream, such as
`1920x1080@30/1, temporal cpu, low light ane`), the camera's gain and exposure, the light level in
lux and the colour temperature, and the layer 2 stack.

- **View.** *Split*: one frame, its left half as the camera gives it (layer 1), its right half
  through the layer 2 stack, with a thin line between. *Full A*: the camera's picture. *Full B*:
  the whole frame through the stack. In the preview window, `t` flips the stack off and on.
- **Camera (layer 1).** Each `denoise.conf` key, with its current value; pick one to change it.
  "default" leaves the key out of the file. A change rewrites the file and reloads the filter.

  | Key | What it does |
  | --- | --- |
  | `mode` | `auto`: the low-light stage by gain and noise (on this board it never engages, see the research); `on`: always; `off`: frames untouched, the raw camera |
  | `temporal` | the CPU temporal filter on every frame (the main noise reduction) |
  | `temporal-backend` | `ave` (the video encoder's filter) has no device on this chip and `gpu` isn't built: both fall back to `cpu` |
  | `backend` | the low-light stage: `auto` uses the Neural Engine, which only runs at 1920x1080 |
  | `low-light-frame-rate` | lets the camera slow to 25 or 15 fps for longer exposures; off raises gain instead |
  | `threads` | CPU threads for the filter; no effect on the picture |
  | `enter-gain`, `exit-gain` | the low-light stage turns on at this gain and off below that one (256 = 1x). The research suggests 2304 and 1792 for dim light |
  | `enter-noise`, `exit-noise` | the noise trigger; `0` turns it off, which the research recommends on this sensor |

  Below them, the two writable V4L2 controls: `power_line_frequency` (anti-flicker: 1 = 50 Hz,
  2 = 60 Hz; set it to the mains frequency) and `exposure_dynamic_framerate` (the filter sets it
  from `low-light-frame-rate` when a stream starts, so a value here may not last). Shortcuts set
  whole configurations: your own, the package defaults, the raw camera, the low-light stage always
  on, and the research's dim-light levels. *Resolution* switches between 1920x1080 and 1280x720
  and restarts the preview; at 720p the filter has no Neural Engine stage.
- **Post filters (layer 2).** The presets from `presets.conf`. Pick one to add it to the end of the
  stack, again to take it out; the number is its place. Presets marked slow (`nlmeans`, `fftdnoiz`)
  aren't expected to hold 30 fps at 1080p (not yet measured on the J616c: clip mode reports each
  preset's render fps) and are offered at 720p only; try them at full size in clip mode. Before
  a stack reaches the preview, FFmpeg runs it over three test frames, so a preset that doesn't parse
  is refused with FFmpeg's error instead of silently showing an unfiltered picture.
- **Effects.** Background blur or replacement and face framing, set on the filter's node with
  `pw-cli set-param`. They need Aurora's `libaurora-camera-effects.so`, which isn't installed on the
  Mac, so the menu says so and offers nothing; framing is also off on this board
  (`camera.framing.supported` is false). This part is untested.
- **Snapshot.** Saves into `~/camera-lab/<date-time>/`: `split.png` (A and B from the same frame),
  `A.png` and `B.png` (full frames, taken a moment apart, B after a second so temporal filters
  settle), and `notes.txt` with every layer 1 and 2 setting, the graphs, gain, exposure, lux,
  colour temperature and the filter's log lines. If a setting looks right, `notes.txt` has the
  `denoise.conf` to keep.
- **Restore and quit.** Stops the preview and restores everything. Esc or Ctrl-C in the menu does
  the same.

## `camera-lab clip`

Records one clip with the filter off (`mode = off`), puts your `denoise.conf` back straight away,
then renders every variant from the same frames and measures each, so the comparison is free of
changes in light and exposure between captures:

- the raw camera;
- the filter's own stages, run offline with `aurora-camera-denoise-bench`: the CPU temporal filter
  (the default), then the Neural Engine low-light stage on top of it at strength 0.25, 0.5, 0.75
  and 1.0 (1.0 is `mode = on`; the service itself has no strength setting). At 1280x720 the Neural
  Engine stage can't run and the report says so;
- each post preset, by default on the CPU filter's output as in `live` (`--base raw` for the raw
  frames).

```sh
camera-lab clip                                    # 160 frames at 1080p, all presets
camera-lab clip --presets despeckle,hqdn3d-light+cas --no-ane
camera-lab clip --from ~/camera-lab/clip-20261120-0830 --presets cas   # same frames, no camera
```

`--frames` (160) and `--last` (60) follow the research: the first frames settle exposure and
temporal filters, the last 60 are measured. A `+` stacks presets into one variant. `--crop
WxH+X+Y` picks the contact sheet's region (default the centre quarter). It refuses to record while
another app uses the camera, unless `--force`. Hold the Mac still and keep the scene static: the
metrics assume nothing moves.

The run directory holds `report.md` (the table below and notes), `metrics.tsv`, `sheet.png` (the
same crop of the last frame from each variant at 2x, numbered as in the table), full last frames
in `frames/`, `notes.txt` and `raw.nv12` (about 3 MB a frame at 1080p; delete it when done). The
variants' own files are deleted unless `--keep`.

### Reading the metrics

As in the research's section 7, over the measured frames:

| Column | Meaning | Better |
| --- | --- | --- |
| Luma noise | per-pixel standard deviation over time, mean over the frame (`aurora-camera-denoise-metrics`'s `temporal_std y`) | lower |
| Chroma U / V | the same for the colour planes. Room light that cycles colour (seen at night) inflates it | lower |
| PSNR vs raw mean | against the average of all raw frames; read it as an ordering | higher |
| SSIM | structural similarity to the same reference | higher |
| Edge contrast | the mean Sobel gradient of the measured frames' average at the raw clip's strongest 0.3% of edge pixels, as a share of the raw clip's. Falls when edges are blurred; above 100% means sharpened | near 100% |
| Dark / bright specks | pixels more than 24 code values below / above their 3x3 median, per frame | lower |
| Render fps | offline speed on all cores (the filter rows: its own per-frame time). Live needs 30 | 30 or more |

A filter wins when it lowers noise and specks without losing much edge contrast. A static scene
flatters every temporal filter: check motion in `live` before trusting a temporal result.

## `camera-lab virtual` (untested)

Sends the camera through a layer 2 stack to a v4l2loopback device, so Meet can use the result:
`camera-lab virtual --size 1280x720 --presets despeckle,cas` (default: the last stack used in
`live`). It needs the v4l2loopback module, which isn't installed. Without it the command prints
what to run:

```sh
sudo pacman -S v4l2loopback-dkms
sudo modprobe v4l2loopback exclusive_caps=1 card_label="Camera lab"
```

## `camera-lab status`, `restore`, `check`

- `status`: the nodes, `denoise.conf`, whether a lab backup is present, the effective config, the
  filter's log lines, the V4L2 controls, the readings and the saved stack. Changes nothing.
- `restore`: puts back what an interrupted run left and reloads the filter. Does nothing when there
  is no backup.
- `check`: every dependency and both nodes; exits 1 if something required is missing.

## Adding a preset

Add a line to `~/.config/camera-lab/presets.conf` (same format; a name that exists replaces the
shipped one), or to `presets.conf` here to share it:

```
name|lavfi chain|note shown in the menu|flags
my-denoise|hqdn3d=3:2:4:3,cas=strength=0.3|hqdn3d then a little sharpening|temporal
```

The chain is any FFmpeg filter chain with one input and one output (`ffmpeg -filters` lists what
is there). Labels inside a chain are fine; the lab renames them per stage. Flags: `slow` (720p
only in `live`), `temporal` (uses past frames). `camera-lab check` runs every preset through
FFmpeg and reports any that fail.

## Tests

`bash tools/tests/camera-lab-test.sh` on any Linux, no camera: node discovery from a saved
`pw-dump` of the J616c, `denoise.conf` parsing and rendering, the byte-identical restore, the
presets parser, the graphs, the metrics parsers, and with FFmpeg installed every preset and a whole
`clip --from` run on synthetic frames (with stand-ins for Aurora's two tools).
