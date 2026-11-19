#!/usr/bin/env python3
"""Helpers for camera-lab that Bash can't do well. Standard library only.

  camera-lab-helper.py nodes [PW_DUMP_JSON]   video sources from pw-dump (stdin if no file)
  camera-lab-helper.py ipc SOCKET JSON...      send mpv JSON IPC commands, print each reply
  camera-lab-helper.py specks W H              count speck marks in gray8 masks on stdin
  camera-lab-helper.py edge W H REF TEST       edge contrast of TEST against REF (gray16 Sobel)

`nodes` prints one tab-separated line per Video/Source node:
  role  id  serial  state  node.name  node.description  framing=true|false
where role is `raw` (the ISP's own V4L2 node), `filter` (aurora-camera-denoise's
default output for that camera), `named` (a named --stream output) or `other`.

`specks` reads frames of W*H bytes as the speck graph writes them: 255 marks a
pixel more than 24 below its 3x3 median (dark), 128 one more than 24 above
(bright). It prints `frames=N dark=D bright=B`, D and B per frame.

`edge` reads two gray16le streams of Sobel magnitudes, each frame of the
60-frame mean, and uses the last frame of each. The strongest 0.3% of REF's
pixels are the edge positions; it prints `edge=R positions=N`, R being TEST's
mean magnitude there over REF's.
"""
import json
import socket
import sys
from array import array

FILTER_PREFIX = "aurora_camera_denoise."
RAW_PREFIX = "v4l2_input."
EDGE_SHARE = 0.003


def nodes(text):
    data = json.loads(text)
    out = []
    raw_names = set()
    sources = []
    for obj in data:
        if obj.get("type") != "PipeWire:Interface:Node":
            continue
        info = obj.get("info") or {}
        props = info.get("props") or {}
        if props.get("media.class") != "Video/Source":
            continue
        sources.append((obj, info, props))
        name = props.get("node.name", "")
        if name.startswith(RAW_PREFIX) and props.get("api.v4l2.cap.driver") == "apple-isp":
            raw_names.add(name)
    for obj, info, props in sources:
        name = props.get("node.name", "")
        role = "other"
        if name in raw_names:
            role = "raw"
        elif name.startswith(FILTER_PREFIX) and props.get("aurora.camera-denoise") == "output":
            rest = name[len(FILTER_PREFIX):]
            if rest in raw_names:
                role = "filter"
            elif rest.split(".", 1)[-1] in raw_names:
                role = "named"
        framing = props.get("camera.framing.supported")
        fields = [
            role,
            str(obj.get("id", "")),
            str(props.get("object.serial", "")),
            str(info.get("state", "")),
            name,
            str(props.get("node.description", "")),
            "framing=" + ("true" if framing is True else "false"),
        ]
        # Bash's read collapses empty tab-separated fields: print "-" instead.
        out.append("\t".join((f.replace("\t", " ").replace("\n", " ") or "-") for f in fields))
    return out


def ipc(path, commands):
    sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    sock.settimeout(5)
    sock.connect(path)
    stream = sock.makefile("rwb")
    ok = True
    for n, command in enumerate(commands, 1):
        msg = json.loads(command)
        msg["request_id"] = n
        stream.write((json.dumps(msg) + "\n").encode())
        stream.flush()
        while True:
            line = stream.readline()
            if not line:
                raise SystemExit("mpv closed the IPC socket")
            reply = json.loads(line)
            if reply.get("request_id") == n:
                break
        print(json.dumps(reply))
        ok = ok and reply.get("error") == "success"
    sock.close()
    return ok


def specks(width, height, stream):
    size = width * height
    frames = dark = bright = 0
    while True:
        buf = stream.read(size)
        if len(buf) < size:
            break
        frames += 1
        dark += buf.count(b"\xff")
        bright += buf.count(b"\x80")
    if not frames:
        raise SystemExit("specks: no complete frame on stdin")
    return "frames=%d dark=%.0f bright=%.0f" % (frames, dark / frames, bright / frames)


def last_frame(path, size):
    with open(path, "rb") as f:
        f.seek(0, 2)
        total = f.tell()
        if total < size:
            raise SystemExit("edge: %s holds no complete frame" % path)
        f.seek((total // size - 1) * size)
        frame = array("H")
        frame.frombytes(f.read(size))
    if sys.byteorder != "little":
        frame.byteswap()
    return frame


def edge(width, height, ref_path, test_path):
    size = width * height * 2
    ref = last_frame(ref_path, size)
    test = last_frame(test_path, size)
    count = max(1, int(len(ref) * EDGE_SHARE))
    threshold = sorted(ref, reverse=True)[count - 1]
    positions = [i for i, v in enumerate(ref) if v > threshold]
    for i, v in enumerate(ref):
        if len(positions) >= count:
            break
        if v == threshold:
            positions.append(i)
    ref_sum = sum(ref[i] for i in positions)
    test_sum = sum(test[i] for i in positions)
    if not ref_sum:
        raise SystemExit("edge: the reference has no edges")
    return "edge=%.4f positions=%d" % (test_sum / ref_sum, len(positions))


def main(argv):
    if len(argv) < 2:
        print(__doc__.strip(), file=sys.stderr)
        return 2
    cmd, args = argv[1], argv[2:]
    if cmd == "nodes":
        text = open(args[0]).read() if args else sys.stdin.read()
        for line in nodes(text):
            print(line)
        return 0
    if cmd == "ipc" and len(args) >= 2:
        return 0 if ipc(args[0], args[1:]) else 1
    if cmd == "specks" and len(args) == 2:
        print(specks(int(args[0]), int(args[1]), sys.stdin.buffer))
        return 0
    if cmd == "edge" and len(args) == 4:
        print(edge(int(args[0]), int(args[1]), args[2], args[3]))
        return 0
    print(__doc__.strip(), file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
