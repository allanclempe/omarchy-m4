#!/usr/bin/env python3
"""score.py: how close a camera frame is to a reference frame, framing-independent.

    score.py REFERENCE TEST [TEST...]

Each argument is a picture (png/jpg) or a raw NV12 clip (the last frame of a
file named *.nv12 next to a notes.txt with a `Clip: WxH` line, or
WxH:file.nv12). Pictures of different sizes are scaled to the reference's
height first. Needs ffmpeg. Standard library only.

Per picture, from the 8-bit luma plane and the RGB means:
  noise     the 20th percentile of the standard deviation over 16x16 blocks
            that aren't clipped: the grain in flat areas, wherever they are
            (lower is cleaner)
  sharp     mean gradient magnitude at the strongest 1% of edges (higher is
            crisper; sharpening and noise both raise it, so read with noise)
  detail    share of blocks whose std is above 2x the noise floor: texture
            kept (hair strands, tattoos) against smoothed away
  luma      5th, 50th and 95th luma percentiles: tone (black level, mid, highlights)
  sat       mean saturation (max(r,g,b) - min) / max over the frame: colour
Then a distance to the reference per metric and a weighted total (lower is closer).
"""
import math
import os
import re
import subprocess
import sys


def run(cmd):
    return subprocess.run(cmd, check=True, capture_output=True).stdout


def nv12_size(path):
    m = re.match(r"^(\d+)x(\d+):(.*)$", path)
    if m:
        return int(m.group(1)), int(m.group(2)), m.group(3)
    notes = os.path.join(os.path.dirname(path) or ".", "notes.txt")
    try:
        for line in open(notes):
            m = re.match(r"Clip: (\d+)x(\d+) ", line)
            if m:
                return int(m.group(1)), int(m.group(2)), path
    except OSError:
        pass
    sys.exit(f"{path}: give the size as WxH:{path} (no notes.txt with a Clip: line)")


def planes(path, height):
    """The luma plane (bytes) and 1/8-scale RGB (bytes) of the picture's last frame, at HEIGHT."""
    if path.endswith(".nv12") or ":" in path and path.split(":", 1)[1].endswith(".nv12"):
        w, h, f = nv12_size(path)
        frames = os.path.getsize(f) // (w * h * 3 // 2)
        src = ["-f", "rawvideo", "-pix_fmt", "nv12", "-s", f"{w}x{h}", "-i", f]
        pick = ["-vf", f"select=eq(n\\,{frames - 1})"]
        sel = ",".join([f"select=eq(n\\,{frames - 1})"])
    else:
        src = ["-i", path]
        sel = "null"
    vf = f"{sel},scale=-2:{height}:flags=lanczos"
    y = run(["ffmpeg", "-v", "error", "-nostdin", *src, "-vf", f"{vf},format=gray", "-frames:v", "1",
             "-f", "rawvideo", "-pix_fmt", "gray", "-"])
    rgb = run(["ffmpeg", "-v", "error", "-nostdin", *src, "-vf", f"{vf},scale=iw/8:ih/8,format=rgb24",
               "-frames:v", "1", "-f", "rawvideo", "-pix_fmt", "rgb24", "-"])
    # width from the byte count
    w = len(y) // height
    return y, w, height, rgb


def metrics(y, w, h, rgb):
    # block stds
    bs = 16
    stds = []
    for by in range(0, h - bs + 1, bs):
        for bx in range(0, w - bs + 1, bs):
            s = 0
            ss = 0
            for r in range(by, by + bs):
                row = y[r * w + bx:r * w + bx + bs]
                for v in row:
                    s += v
                    ss += v * v
            n = bs * bs
            mean = s / n
            # Clipped blocks (blown highlights, crushed blacks) carry no
            # noise and would drag the floor to zero.
            if 16 <= mean <= 236:
                stds.append(math.sqrt(max(ss / n - mean * mean, 0)))
    stds.sort()
    noise = stds[len(stds) // 5]
    detail = sum(1 for s in stds if s > 2 * noise + 2) / len(stds)
    # gradient magnitude, strongest 1%
    grads = []
    for r in range(1, h - 1, 2):
        base = r * w
        for c in range(1, w - 1, 2):
            gx = y[base + c + 1] - y[base + c - 1]
            gy = y[base + w + c] - y[base - w + c]
            grads.append(abs(gx) + abs(gy))
    grads.sort()
    top = grads[-max(len(grads) // 100, 1):]
    sharp = sum(top) / len(top)
    # luma percentiles
    hist = [0] * 256
    for v in y:
        hist[v] += 1
    total = len(y)
    pct = {}
    acc = 0
    want = {5: None, 50: None, 95: None}
    for v, c in enumerate(hist):
        acc += c
        for p in want:
            if want[p] is None and acc >= total * p / 100:
                want[p] = v
    # saturation
    sat = 0.0
    n = len(rgb) // 3
    for i in range(0, len(rgb), 3):
        r, g, b = rgb[i], rgb[i + 1], rgb[i + 2]
        mx = max(r, g, b)
        if mx:
            sat += (mx - min(r, g, b)) / mx
    sat /= n
    return {"noise": noise, "sharp": sharp, "detail": detail, "luma5": want[5], "luma50": want[50],
            "luma95": want[95], "sat": sat}


def main(argv):
    if len(argv) < 3:
        sys.exit(__doc__)
    ref_path, tests = argv[1], argv[2:]
    yr, wr, hr, rgbr = planes(ref_path, 1080)
    ref = metrics(yr, wr, hr, rgbr)
    print(f"{'picture':40s} {'noise':>6s} {'sharp':>6s} {'detail':>6s} {'luma 5/50/95':>14s} {'sat':>5s} {'dist':>6s}")

    def row(name, m, dist):
        print(f"{name[-40:]:40s} {m['noise']:6.2f} {m['sharp']:6.1f} {m['detail']:6.3f} "
              f"{m['luma5']:4d}/{m['luma50']:3d}/{m['luma95']:3d}  {m['sat']:5.3f} {dist:>6s}")

    row(ref_path, ref, "ref")
    for t in tests:
        y, w, h, rgb = planes(t, 1080)
        m = metrics(y, w, h, rgb)
        d = (abs(m["noise"] - ref["noise"]) / max(ref["noise"], 1) * 1.0
             + abs(m["sharp"] - ref["sharp"]) / max(ref["sharp"], 1) * 1.0
             + abs(m["detail"] - ref["detail"]) / max(ref["detail"], 0.01) * 1.0
             + (abs(m["luma5"] - ref["luma5"]) + abs(m["luma50"] - ref["luma50"]) + abs(m["luma95"] - ref["luma95"])) / 255 * 1.0
             + abs(m["sat"] - ref["sat"]) / max(ref["sat"], 0.01) * 0.5)
        row(t, m, f"{d:.3f}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
