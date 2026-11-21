#!/usr/bin/env python3
"""shading-gain.py: a lens-shading gain map for the `shading-*` presets.

    shading-gain.py OUT.png [WxH] [top,row2,row3,row4,row5,bottom] [edge] [centre-x]

Writes a gray PNG where 128 means gain 1.0 (the presets multiply by it with
`blend=all_expr='min(A*B/128,255)'`). The vertical profile is a ramp through
the six row gains (top to bottom, interpolated); the horizontal profile adds
`edge` (a fraction) at the left and right edges, quadratically, around the
column `centre-x` (a fraction of the width).

The defaults are the fit for the J616c's binned sensor config 8 with the
1216-wide centred crop (OMS-34, 2026-11-21): the ISP corrects lens shading
in the device tree's config 5 but not in the binned mode, so the frame falls
off toward the bottom (about 1.35x) and the sides (about 10%). Fitted on the
wall and bench of one scene against macOS's frame of the same scene, not on a
flat field, so it is this unit and this crop only. Standard library only;
needs ffmpeg to write the PNG.
"""
import subprocess
import sys


def main(argv):
    if len(argv) < 2:
        sys.exit(__doc__)
    out = argv[1]
    w, h = (int(v) for v in (argv[2] if len(argv) > 2 else "1920x1080").split("x"))
    rows = [float(v) for v in (argv[3] if len(argv) > 3 else "1.00,1.00,1.04,1.10,1.26,1.35").split(",")]
    edge = float(argv[4]) if len(argv) > 4 else 0.10
    cx = float(argv[5]) if len(argv) > 5 else 0.45
    if len(rows) != 6:
        sys.exit("six row gains, top to bottom")

    def vertical(y):
        t = y / h * 6 - 0.5
        i = max(0, min(4, int(t)))
        f = max(0.0, min(1.0, t - i))
        return rows[i] * (1 - f) + rows[i + 1] * f

    buf = bytearray(w * h)
    half = w * max(cx, 1 - cx)
    for y in range(h):
        gy = vertical(y)
        for x in range(w):
            d = abs(x - w * cx) / half
            g = gy * (1 + edge * d * d)
            buf[y * w + x] = max(0, min(255, int(round(g * 128))))
    subprocess.run(["ffmpeg", "-v", "error", "-nostdin", "-y", "-f", "rawvideo", "-pix_fmt", "gray",
                    "-s", f"{w}x{h}", "-i", "-", out], input=bytes(buf), check=True)
    print(f"{out}: {w}x{h}, rows {rows}, edge {edge:+.2f}, centre x {cx:.2f}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
