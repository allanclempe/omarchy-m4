#!/bin/bash
# Tests for tools/camera-lab. Runs as a normal user on any Linux, no camera
# needed: bash tools/tests/camera-lab-test.sh
# With FFmpeg installed it also runs every graph and preset through FFmpeg, and
# a whole `clip --from` run on synthetic frames with stand-ins for Aurora's
# bench and metrics tools.
set -euo pipefail
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
lab=$here/../camera-lab
fixtures=$here/fixtures/camera-lab
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
failures=0

fail() { echo "FAIL $1" >&2; failures=$((failures + 1)); }
# same NAME GOT WANT
same() { [[ $2 == "$3" ]] || fail "$1: got [$2], want [$3]"; }

export CAMERA_LAB_STATE=$work/state CAMERA_LAB_DENOISE_CONF=$work/conf/denoise.conf
export CAMERA_LAB_OUT=$work/out CAMERA_LAB_PRESETS=$lab/presets.conf
export CAMERA_LAB_PIDFILE=$work/preview.pid
# shellcheck source=../camera-lab/camera-lab
source "$lab/camera-lab"

# --- Node discovery from a saved pw-dump (J616c, 2026-11-20, trimmed) --------
cl_discover "$fixtures/pw-dump.json" || fail "discover: found no filter node"
same "discover filter name" "$CL_FILTER_NAME" aurora_camera_denoise.v4l2_input.platform-580000000.isp
same "discover filter id" "$CL_FILTER_ID" 133
same "discover filter state" "$CL_FILTER_STATE" suspended
same "discover raw name" "$CL_RAW_NAME" v4l2_input.platform-580000000.isp
same "discover raw id" "$CL_RAW_ID" 131
same "discover framing" "$CL_FRAMING" false
roles=$(python3 "$CL_HELPER" nodes "$fixtures/pw-dump.json" | cut -f1,2 | paste -sd' ')
same "nodes roles" "$roles" $'raw\t131 filter\t133 named\t140 other\t150'
# No filter output (service stopped): discovery fails, the raw node is still found.
python3 - "$fixtures/pw-dump.json" "$work/no-filter.json" <<'EOF'
import json, sys
d = json.load(open(sys.argv[1]))
json.dump([o for o in d if not o.get("info", {}).get("props", {}).get("aurora.camera-denoise")], open(sys.argv[2], "w"))
EOF
if cl_discover "$work/no-filter.json"; then fail "discover: found a filter node in a dump without one"; fi
same "discover raw without filter" "$CL_RAW_ID" 131

# --- denoise.conf --------------------------------------------------------------
mkdir -p "$work/conf"
printf '[denoise]\nmode = on\n' >"$work/allan.conf"
cl_conf_parse "$work/allan.conf"
same "parse allan's conf" "$(cl_conf_summary)" "mode = on"
cl_conf_render >"$work/rendered.conf"
cmp -s "$work/allan.conf" "$work/rendered.conf" || fail "render: [denoise] mode = on doesn't round-trip byte for byte"

# Comments, other sections, spacing, unknown keys and repeats.
cat >"$work/messy.conf" <<'EOF'
# a comment
[other]
mode = ignored
[denoise]
  enter-gain=2304
; another comment
framing-supported = true
mode = auto
mode = on
exit-gain   =   1792
EOF
cl_conf_parse "$work/messy.conf"
same "parse messy" "$(cl_conf_render)" $'[denoise]\nmode = on\nenter-gain = 2304\nexit-gain = 1792\nframing-supported = true'
# A settings set as the menu builds it: an empty value leaves the key out.
CL_SET=([mode]=off [temporal]=on [threads]='' [enter-noise]=0)
CL_SET_EXTRA=()
same "render settings" "$(cl_conf_render)" $'[denoise]\nmode = off\ntemporal = on\nenter-noise = 0'
CL_SET=()
same "render empty" "$(cl_conf_render)" '[denoise]'
same "summary empty" "$(cl_conf_summary)" '(all defaults)'
cl_conf_parse "$work/does-not-exist"
same "parse missing file" "${#CL_SET[@]}" 0

# --- Backup and restore: the original comes back byte for byte -----------------
printf '[denoise]\nmode = on\n# kept: no newline at the end' >"$CAMERA_LAB_DENOISE_CONF"
chmod 640 "$CAMERA_LAB_DENOISE_CONF"
touch -d '2026-11-17 13:15:00' "$CAMERA_LAB_DENOISE_CONF"
cp -p "$CAMERA_LAB_DENOISE_CONF" "$work/original.conf"
cl_conf_original
CL_SET[mode]=off
cl_conf_write
same "write" "$(cat "$CAMERA_LAB_DENOISE_CONF")" $'[denoise]\nmode = off'
same "write keeps the mode" "$(stat -c %a "$CAMERA_LAB_DENOISE_CONF")" 640
cl_has_backup || fail "write: no backup"
# A second write (or a later run) keeps the first backup, the user's own file.
CL_SET[mode]=auto
cl_conf_write
cl_conf_original
same "original from backup" "$(cl_conf_summary)" "mode = on"
cl_conf_restore || fail "restore: said there was nothing to restore"
cmp -s "$work/original.conf" "$CAMERA_LAB_DENOISE_CONF" || fail "restore: not byte-identical"
same "restore mode bits" "$(stat -c %a "$CAMERA_LAB_DENOISE_CONF")" 640
same "restore mtime" "$(stat -c %Y "$CAMERA_LAB_DENOISE_CONF")" "$(stat -c %Y "$work/original.conf")"
if cl_has_backup; then fail "restore: left the backup"; fi
if cl_conf_restore; then fail "restore: restored twice"; fi
ls "$work/conf" | grep -q camera-lab && fail "write: left a temporary file"
# No conf at all: the lab's file goes away again.
rm -f "$CAMERA_LAB_DENOISE_CONF"
CL_SET=([mode]=off)
cl_conf_write
[[ -e $CAMERA_LAB_DENOISE_CONF ]] || fail "write without a conf: wrote nothing"
cl_conf_restore || fail "restore without a conf: nothing to restore"
[[ ! -e $CAMERA_LAB_DENOISE_CONF ]] || fail "restore without a conf: left the lab's file"
# A read-only conf (dotfile tooling) gets the lab's mode bits, and still comes
# back: the restore renames a copy over it instead of writing into it.
printf '[denoise]\nmode = auto\n' >"$CAMERA_LAB_DENOISE_CONF"
chmod 444 "$CAMERA_LAB_DENOISE_CONF"
cp -p "$CAMERA_LAB_DENOISE_CONF" "$work/readonly.conf"
cl_conf_original
CL_SET[mode]=off
cl_conf_write
same "write read-only: mode bits" "$(stat -c %a "$CAMERA_LAB_DENOISE_CONF")" 444
cl_conf_restore || fail "restore read-only: failed"
cmp -s "$work/readonly.conf" "$CAMERA_LAB_DENOISE_CONF" || fail "restore read-only: not byte-identical"
if cl_has_backup; then fail "restore read-only: left the backup"; fi
# A restore that can't write (the directory is read-only) keeps the backup and
# says so, instead of deleting the only copy of the original.
cl_conf_original
CL_SET[mode]=on
cl_conf_write
chmod 555 "$work/conf"
rc=0; cl_conf_restore 2>/dev/null || rc=$?
same "restore blocked: rc" "$rc" 2
cl_has_backup || fail "restore blocked: lost the backup"
# The `restore` command reports that failure in its exit code.
rc=0; cl_restore_cmd >/dev/null 2>&1 || rc=$?
same "restore cmd blocked: rc" "$rc" 2
chmod 755 "$work/conf"
cl_conf_restore || fail "restore after unblocking: failed"
cmp -s "$work/readonly.conf" "$CAMERA_LAB_DENOISE_CONF" || fail "restore after unblocking: not byte-identical"
chmod 644 "$CAMERA_LAB_DENOISE_CONF"
# A conf edited by hand after an interrupted run stays; the stale backup is
# kept aside, not restored over it.
cl_conf_original
CL_SET[mode]=off
cl_conf_write
cl_conf_keep_edits 2>/dev/null
cl_has_backup || fail "keep edits: dropped the backup though nothing was edited"
printf '[denoise]\nmode = auto\nenter-gain = 2304\n' >"$CAMERA_LAB_DENOISE_CONF"
cl_conf_keep_edits 2>/dev/null
same "keep edits: the edit stays" "$(cat "$CAMERA_LAB_DENOISE_CONF")" $'[denoise]\nmode = auto\nenter-gain = 2304'
if cl_has_backup; then fail "keep edits: still has a backup to restore"; fi
ls "$CAMERA_LAB_STATE" | grep -q '^denoise.conf.orig.kept-' || fail "keep edits: the original wasn't kept aside"
if cl_conf_restore; then fail "keep edits: restore still found something"; fi
rm -f "$CAMERA_LAB_STATE"/denoise.conf.orig.kept-* "$CAMERA_LAB_DENOISE_CONF"
# A symlinked conf: the lab writes and restores the target, and the link stays.
printf '[denoise]\nmode = on\n' >"$work/real.conf"
cp -p "$work/real.conf" "$work/real.orig"
ln -s "$work/real.conf" "$CAMERA_LAB_DENOISE_CONF"
cl_conf_original
CL_SET[mode]=off
cl_conf_write
[[ -L $CAMERA_LAB_DENOISE_CONF ]] || fail "write symlink: replaced the link"
same "write symlink: target" "$(cat "$work/real.conf")" $'[denoise]\nmode = off'
cl_conf_restore || fail "restore symlink: failed"
[[ -L $CAMERA_LAB_DENOISE_CONF ]] || fail "restore symlink: replaced the link"
cmp -s "$work/real.orig" "$work/real.conf" || fail "restore symlink: target not byte-identical"
rm -f "$CAMERA_LAB_DENOISE_CONF" "$work/real.conf"

# --- A session: the EXIT trap restores after SIGTERM, with stubbed services ----
mkdir -p "$work/stubs"
printf '#!/bin/bash\nexit 0\n' >"$work/stubs/systemctl"
printf '#!/bin/bash\nexit 0\n' >"$work/stubs/v4l2-ctl"
chmod +x "$work/stubs"/*
printf '[denoise]\nmode = on\n' >"$CAMERA_LAB_DENOISE_CONF"
cp -p "$CAMERA_LAB_DENOISE_CONF" "$work/session.orig"
PATH=$work/stubs:$PATH bash -c 'source "$1"; cl_start_session; CL_SET[mode]=off; cl_conf_apply; sleep 10 & wait $!' \
  _ "$lab/camera-lab" >/dev/null 2>&1 &
spid=$!
for ((i = 0; i < 50; i++)); do
  grep -qs 'mode = off' "$CAMERA_LAB_DENOISE_CONF" && break
  sleep 0.1
done
grep -qs 'mode = off' "$CAMERA_LAB_DENOISE_CONF" || fail "session: the lab never wrote its conf"
kill -TERM "$spid"
wait "$spid" 2>/dev/null || true
cmp -s "$work/session.orig" "$CAMERA_LAB_DENOISE_CONF" || fail "session TERM: conf not byte-identical"
if cl_has_backup; then fail "session TERM: left the backup"; fi
pkill -P "$spid" sleep 2>/dev/null || true
# A pid file left by a crash names a process that isn't a preview: leave it be.
sleep 10 &
stale=$!
printf '%s\n' "$stale" >"$CAMERA_LAB_PIDFILE"
CL_PREVIEW_PID=''
cl_preview_stop
kill -0 "$stale" 2>/dev/null || fail "preview stop: killed an unrelated process with the stale pid"
kill "$stale" 2>/dev/null || true
[[ ! -e $CAMERA_LAB_PIDFILE ]] || fail "preview stop: left the stale pid file"

# --- The preview's commands, as the Mac runs them ------------------------------------
same "capture cmd" "$(cl_capture_cmd 1280 720 aurora_camera_denoise.v4l2_input.platform-580000000.isp 30)" \
  'gst-launch-1.0 -q pipewiresrc target-object=aurora_camera_denoise.v4l2_input.platform-580000000.isp num-buffers=30 \! video/x-raw\,format=NV12\,width=1280\,height=720\,framerate=30/1 \! fdsink fd=1 '
preview=$(cl_preview_cmd 1920 1080 node.name /run/s.sock /run/in.conf)
[[ $preview == "$(cl_capture_cmd 1920 1080 node.name)| mpv --no-config --input-conf=/run/in.conf --demuxer=rawvideo --demuxer-rawvideo-mp-format=nv12 --demuxer-rawvideo-w=1920 --demuxer-rawvideo-h=1080 --demuxer-rawvideo-fps=30 "* ]] ||
  fail "preview cmd: $preview"
[[ $preview == *"--input-ipc-server=/run/s.sock "*" - " ]] || fail "preview cmd: no IPC socket or stdin: $preview"

# --- The saved post stack: empty is empty, not one blank name --------------------------
declare -a got=()
CL_STACK=()
cl_stack_save
same "empty stack file" "$(wc -c <"$CAMERA_LAB_STATE/stack")" 0
cl_stack_load got
same "empty stack load" "${#got[@]}" 0
CL_STACK=(despeckle cas)
cl_stack_save
cl_stack_load got
same "stack load" "${got[*]}" "despeckle cas"

# --- Presets file --------------------------------------------------------------
cat >"$work/p1.conf" <<'EOF'
# comment

good|hqdn3d=4:3:6:4.5|A note|temporal,slow
plain|median=radius=1
two-stage|split[a][b];[b]median=radius=1[m];[a][m]lut2=c0='if(gt(abs(x-y),12),y,x)':c1=x:c2=x|Despeckle|
bad name|eq|x|
toomany|eq|note|flags|extra
nochain||note|
EOF
printf 'good|cas=strength=0.4|Overridden|\n' >"$work/p2.conf"
CL_PNAMES=() CL_PCHAIN=() CL_PNOTE=() CL_PFLAGS=()
msgs=$(cl_load_presets "$work/p1.conf" "$work/missing.conf" "$work/p2.conf" 2>&1 >/dev/null)
cl_load_presets "$work/p1.conf" "$work/missing.conf" "$work/p2.conf" 2>/dev/null
same "presets names" "${CL_PNAMES[*]}" "good plain two-stage"
same "presets override chain" "${CL_PCHAIN[good]}" "cas=strength=0.4"
same "presets override note" "${CL_PNOTE[good]}" "Overridden"
same "presets no note" "${CL_PNOTE[plain]}" ""
same "presets chain with quotes" "${CL_PCHAIN[two-stage]}" "split[a][b];[b]median=radius=1[m];[a][m]lut2=c0='if(gt(abs(x-y),12),y,x)':c1=x:c2=x"
same "presets skipped" "$(grep -c skipped <<<"$msgs")" 3
grep -q 'p1.conf:7: more than 4 fields' <<<"$msgs" || fail "presets: didn't name the line with a | too many"
CL_PFLAGS[x]=temporal,slow
cl_has_flag x slow || fail "flags: slow not found"
if cl_has_flag x low; then fail "flags: matched part of a word"; fi
same "filters in a chain" "$(cl_filters_in "${CL_PCHAIN[two-stage]}" | paste -sd' ')" "split median lut2"
same "filters with *" "$(cl_filters_in "scale=w=iw*2:h=ih*2,eq" | paste -sd' ')" "scale eq"

# The shipped catalogue parses with no complaint and has what the task names.
CL_PNAMES=() CL_PCHAIN=() CL_PNOTE=() CL_PFLAGS=()
msgs=$(cl_load_presets "$lab/presets.conf" 2>&1 >/dev/null)
cl_load_presets "$lab/presets.conf"
same "shipped presets: complaints" "$msgs" ""
for name in hqdn3d-light hqdn3d-medium atadenoise tmix-2 tmix-3 nlmeans vaguedenoiser median despeckle \
  unsharp-light cas contrast-sat warm curves-s deband scale-720p; do
  [[ -n ${CL_PCHAIN[$name]:-} ]] || fail "shipped presets: no $name"
done

# --- Graphs ----------------------------------------------------------------------
same "namespace" "$(cl_namespace_chain p2 "split[a][b];[b]median[m];[a][m]lut2")" "split[p2_a][p2_b];[p2_b]median[p2_m];[p2_a][p2_m]lut2"
same "stack none" "$(cl_stack '' '')" "null"
same "stack one" "$(cl_stack '' '' eq)" "eq"
same "stack labelled" "$(cl_stack B R eq cas)" "[B]eq[cl1];[cl1]cas[R]"
same "view a" "$(cl_view_graph a 1920 1080)" ""
same "view b empty" "$(cl_view_graph b 1920 1080)" "scale=1920:1080"
same "view b" "$(cl_view_graph b 1280 720 hqdn3d-light cas)" "hqdn3d=2:1.5:3:2.25[cl1];[cl1]cas=strength=0.4[cl2];[cl2]scale=1280:720"
same "view split empty" "$(cl_view_graph split 1920 1080)" \
  "split[A][B];[A]crop=iw/2:ih:0:0[L];[B]scale=1920:1080,crop=iw/2:ih:iw/2:0,drawbox=x=0:y=0:w=2:h=ih:color=white@0.6:t=fill[R];[L][R]hstack"
same "view split stacked" "$(cl_view_graph split 1920 1080 despeckle hqdn3d-light despeckle)" \
  "split[A][B];[A]crop=iw/2:ih:0:0[L];[B]split[p1_a][p1_b];[p1_b]median=radius=1[p1_m];[p1_a][p1_m]lut2=c0='if(gt(abs(x-y),12),y,x)':c1=x:c2=x[cl1];[cl1]hqdn3d=2:1.5:3:2.25[cl2];[cl2]split[p3_a][p3_b];[p3_b]median=radius=1[p3_m];[p3_a][p3_m]lut2=c0='if(gt(abs(x-y),12),y,x)':c1=x:c2=x[cl3];[cl3]scale=1920:1080,crop=iw/2:ih:iw/2:0,drawbox=x=0:y=0:w=2:h=ih:color=white@0.6:t=fill[R];[L][R]hstack"
if cl_view_graph split 1920 1080 no-such-preset 2>/dev/null; then fail "view: accepted an unknown preset"; fi
same "render graph" "$(cl_render_graph 1920 1080 scale-720p)" "scale=1280:720:flags=lanczos[cl1];[cl1]scale=1920:1080,format=nv12"

# The mpv command carries the graph intact through JSON.
graph=$(cl_view_graph split 1920 1080 despeckle curves-s)
json=$(cl_vf_json "$graph")
back=$(python3 -c 'import json,sys; c=json.loads(sys.argv[1])["command"]; print(c[0], c[1], c[2][0]["label"], c[2][0]["params"]["graph"])' "$json")
same "vf json" "$back" "set_property vf cl $graph"
same "vf json clear" "$(cl_vf_json '')" '{"command":["set_property","vf",[]]}'
same "json escapes" "$(cl_json_str $'a"b\\c\nd')" '"a\"b\\c\nd"'

# --- Metrics -----------------------------------------------------------------------
same "parse cdn-metrics" "$(cl_parse_cdn_metrics <"$fixtures/cdn-metrics.txt")" "6.775 0.657 0.806 24.87 0.8678"
if echo "garbage" | cl_parse_cdn_metrics >/dev/null; then fail "parse cdn-metrics: accepted garbage"; fi
same "parse bench" "$(cl_parse_bench wall_ms_per_frame <"$fixtures/cdn-bench.txt")" "1.67"
same "parse kv" "$(cl_parse_kv dark <<<"frames=60 dark=3311 bright=78")" "3311"
# specks: two 4x2 frames, 255 = dark, 128 = bright.
printf '\xff\xff\x80\x00\x00\x00\x00\x00\xff\x00\x00\x00\x00\x00\x00\x00' |
  python3 "$CL_HELPER" specks 4 2 >"$work/specks" || fail "specks: failed"
same "specks" "$(cat "$work/specks")" "frames=2 dark=2 bright=0"
# edge: 0.3% of 1000 pixels is 3: REF's three strongest (one tied with a
# fourth), where TEST has half the gradient. Only the last frame counts.
python3 - "$work" <<'EOF'
import sys
from array import array
w = sys.argv[1]
ref = array("H", [10] * 1000); test = array("H", [10] * 1000)
for i, v in ((100, 40000), (200, 30000), (300, 20000), (400, 20000)):
    ref[i] = v; test[i] = v // 2
open(w + "/ref.grad", "wb").write(array("H", [0] * 1000).tobytes() + ref.tobytes())
open(w + "/test.grad", "wb").write(test.tobytes())
EOF
same "edge" "$(python3 "$CL_HELPER" edge 100 10 "$work/ref.grad" "$work/test.grad")" "edge=0.5000 positions=3"
same "row" "$(cl_fmt_row "Raw" 21.351 3.07 3.62 21.1 0.8575 1 143158 23908 -)" \
  "| Raw | 21.35 | 3.07 / 3.62 | 21.1 | 0.858 | 100.0% | 143,158 | 23,908 | - |"
same "row n/a" "$(cl_fmt_row "X" n/a n/a n/a n/a n/a 0.927 724 15 41)" \
  "| X | n/a | n/a / n/a | n/a | n/a | 92.7% | 724 | 15 | 41 |"
same "loopback missing" "$(CAMERA_LAB_SYS_MODULE=$work/none cl_loopback_dev || echo none)" none

# --- With FFmpeg: the graphs and presets run, and a whole clip run ----------------
if command -v ffmpeg >/dev/null; then
  ff=(ffmpeg -v error -nostdin -f lavfi -i "testsrc2=s=320x180:r=30:d=0.3")
  for view in split b; do
    for stack in "" "despeckle hqdn3d-light despeckle" "scale-720p cas"; do
      # shellcheck disable=SC2086
      g=$(cl_view_graph "$view" 320 180 $stack)
      size=$("${ff[@]}" -vf "$g" -frames:v 1 -f rawvideo -pix_fmt gray - | wc -c)
      same "ffmpeg view $view [$stack]" "$size" $((320 * 180))
    done
  done
  # The speck graph tells dark from bright: one pixel 80 below a flat 100
  # field and one 100 above it, in a 16x16 NV12 frame.
  python3 - "$work" <<'EOF'
import sys
y = bytearray([100] * 256)
y[5 * 16 + 5] = 20
y[10 * 16 + 10] = 200
open(sys.argv[1] + "/speck.nv12", "wb").write(bytes(y) + bytes([128] * 128))
EOF
  same "specks dark and bright" "$(ffmpeg -v error -nostdin -f rawvideo -pix_fmt nv12 -s 16x16 -i "$work/speck.nv12" \
    -vf "$CL_SPECK_GRAPH" -f rawvideo -pix_fmt gray - | python3 "$CL_HELPER" specks 16 16)" "frames=1 dark=1 bright=1"
  cl_graph_check "$(cl_view_graph split 320 180 despeckle cas)" 320 180 >/dev/null || fail "graph check: refused a good graph"
  if cl_graph_check "eq=gamma=abc" 320 180 >/dev/null; then fail "graph check: passed a bad graph"; fi
  for name in "${CL_PNAMES[@]}"; do
    "${ff[@]}" -vf "$(cl_render_graph 320 180 "$name")" -f null - 2>"$work/err" ||
      fail "preset $name doesn't run in FFmpeg: $(head -n 1 "$work/err")"
  done

  # clip --from on synthetic frames: noise with a hard edge and dark specks.
  mkdir -p "$work/stubs" "$work/from"
  cat >"$work/stubs/aurora-camera-denoise-bench" <<'EOF'
#!/bin/bash
# Stand-in: copies the input to -o. The Neural Engine stage "runs" at every
# strength, or refuses the size when STUB_ANE_FAIL is set.
while getopts b:t:s:l:o:r: o; do case $o in b) b=$OPTARG ;; s) s=$OPTARG ;; o) out=$OPTARG ;; *) ;; esac; done
shift $((OPTIND - 1))
[[ $b == ane && -n ${STUB_ANE_FAIL:-} ]] && { echo "backend ane cannot run $1x$2" >&2; exit 1; }
cp "$3" "$out"; echo "backend=${b:-cpu} strength=${s:-} cpu_ms_per_frame=1.00 wall_ms_per_frame=2.00 cpu_pct_at_30fps=3.0"
EOF
  cat >"$work/stubs/aurora-camera-denoise-metrics" <<'EOF'
#!/bin/bash
printf 'frames=%s ref_frames=1 mean_luma=100.0\ntemporal_std y=5.500 cb=0.770 cr=0.990\npsnr_y=30.30 psnr_c=45.00 ssim_y=0.9000\n' "$6"
EOF
  chmod +x "$work/stubs"/*
  ffmpeg -v error -nostdin -f lavfi -i "color=c=0x606060:s=160x90:r=30,drawbox=x=80:y=0:w=80:h=90:color=0xc0c0c0:t=fill,noise=alls=30:allf=t" \
    -frames:v 12 -pix_fmt nv12 -f rawvideo "$work/from/raw.nv12"
  # The clip's size comes from its notes, so no --size is passed here.
  printf 'Clip: 160x90 NV12, 12 frames, the last 8 measured\nReadings during the capture: gain 1.44x (368), exposure 40.0 ms, 84.0 lux, 4958 K\n' >"$work/from/notes.txt"
  # A wrong size is refused, not measured as sheared frames.
  if PATH=$work/stubs:$PATH bash "$lab/camera-lab" clip --from "$work/from" --size 100x100 --last 2 --presets none --no-ane \
    --out "$work/clip-wrong" >/dev/null 2>"$work/clip-wrong.err"; then
    fail "clip --from: accepted a size the clip isn't whole frames of"
  else
    grep -q "isn't whole 100x100" "$work/clip-wrong.err" || fail "clip --from wrong size: $(tail -n 1 "$work/clip-wrong.err")"
  fi
  if PATH=$work/stubs:$PATH bash "$lab/camera-lab" clip --from "$work/from" --last 8 \
    --presets "median,despeckle+cas,scale-720p" --out "$work/clip" >"$work/clip.out" 2>"$work/clip.err"; then
    report=$work/clip/report.md
    grep -q '^| Raw camera (mode = off) | 5.50 | 0.77 / 0.99 | 30.3 | 0.900 | 100.0% |' "$report" ||
      fail "clip: no raw row as expected"
    grep -q '^| Filter: CPU temporal (the default) |.*| 500 |$' "$report" || fail "clip: no filter row at 500 fps"
    grep -q '^| Post on CPU temporal: despeckle + cas |' "$report" || fail "clip: no stacked post row"
    grep -q '^| Post on CPU temporal: scale-720p |' "$report" || fail "clip: no scale row"
    # Every strength gives a row; the label at 1.0 names mode = on. (The row
    # at 0.25 once ended the run through errexit, on the J616c.)
    grep -q '^| Filter: + low-light stage at 0.25 |' "$report" || fail "clip: no low-light row at 0.25"
    grep -q '^| Filter: + low-light stage at 1.0 (mode = on) |' "$report" || fail "clip: no low-light row at 1.0"
    grep -q '84.0 lux' "$report" || fail "clip: lost the readings"
    same "clip rows" "$(grep -c '^| [A-Z]' "$report")" 10 # the header and 9 variants
    # The median removes specks the raw frames have.
    raw_dark=$(awk -F'\t' '$1 ~ /^Raw/ { print $8 }' "$work/clip/metrics.tsv")
    med_dark=$(awk -F'\t' '$1 ~ /median$/ { print $8 }' "$work/clip/metrics.tsv")
    ((raw_dark > 0 && med_dark < raw_dark)) || fail "clip: specks raw $raw_dark, median $med_dark"
    edge=$(awk -F'\t' '$1 ~ /median$/ { print $7 }' "$work/clip/metrics.tsv")
    awk -v e="$edge" 'BEGIN { exit !(e > 0.5 && e < 1.2) }' || fail "clip: median edge contrast $edge"
    same "clip frames" "$(ls "$work/clip/frames" | wc -l)" 9
    if command -v montage >/dev/null; then [[ -s $work/clip/sheet.png ]] || fail "clip: no contact sheet"; fi
    [[ -z $(ls "$work/clip/work"/*.nv12 2>/dev/null) ]] || fail "clip: left the variant files"
    [[ -e $work/from/raw.nv12 ]] || fail "clip: removed the --from clip"
  else
    fail "clip --from failed: $(tail -n 3 "$work/clip.err")"
  fi
  # A Neural Engine stage that refuses the size is noted, and the run goes on.
  if STUB_ANE_FAIL=1 PATH=$work/stubs:$PATH bash "$lab/camera-lab" clip --from "$work/from" --last 8 --presets none \
    --out "$work/clip-noane" >/dev/null 2>"$work/clip-noane.err"; then
    grep -q "Neural Engine stage didn't run: backend ane cannot run 160x90" "$work/clip-noane/report.md" ||
      fail "clip: didn't note the Neural Engine refusing the size"
    same "clip rows without the Neural Engine" "$(grep -c '^| [A-Z]' "$work/clip-noane/report.md")" 3
  else
    fail "clip --from without the Neural Engine failed: $(tail -n 3 "$work/clip-noane.err")"
  fi
else
  echo "SKIP the FFmpeg checks: ffmpeg isn't installed" >&2
fi

if ((failures)); then
  echo "$failures failure(s)" >&2
  exit 1
fi
echo "PASS camera-lab: node discovery, denoise.conf round trip and byte-identical restore, presets, graphs, metrics$(command -v ffmpeg >/dev/null && echo ", every preset and a clip run in FFmpeg")"
