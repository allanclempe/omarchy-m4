#!/usr/bin/env python3
"""Overwrite one file on an unmounted FAT32 volume in place, without mounting it.

The new contents must be exactly the same size as the file already there, so only
that file's data clusters change: the FATs, directory entries and FSInfo stay as
they are. Before writing, it checks:
  - the volume is FAT32 with the expected label and is not mounted;
  - the path resolves through long names to one short entry;
  - the cluster chain is in range, loop-free, the right length, ends with EOC,
    and is the same in every FAT copy;
  - the current contents hash to --expect-old;
  - the new file hashes to --expect-new.
Without --write it only reports. With --write it saves the current contents to
--backup first, writes cluster by cluster (keeping the slack after EOF in the last
cluster), syncs, then re-reads the file from the device and checks --expect-new.

All device I/O is aligned to the sector size, as raw (character) devices require.
"""
import argparse, hashlib, os, struct, subprocess, sys

EOC = 0x0FFFFFF8


def die(msg):
    sys.exit(f"REFUSED: {msg}")


class Vol:
    def __init__(self, path, writable):
        self.fd = os.open(path, os.O_RDWR if writable else os.O_RDONLY)
        # The boot sector is in the first sector; read 4096, a multiple of any sector size.
        bs = os.pread(self.fd, 4096, 0)
        if len(bs) != 4096 or bs[510:512] != b"\x55\xaa":
            die("no boot sector signature")
        self.bps, self.spc, self.rsvd, self.nfats = struct.unpack_from("<HBHB", bs, 11)
        if struct.unpack_from("<H", bs, 22)[0] != 0:
            die("FAT12/16 (FATSz16 != 0)")
        self.totsec = struct.unpack_from("<I", bs, 32)[0]
        self.fatsz = struct.unpack_from("<I", bs, 36)[0]
        self.rootclus = struct.unpack_from("<I", bs, 44)[0]
        self.label = bs[71:82].decode("ascii", "replace").rstrip()
        if bs[82:90] != b"FAT32   ":
            die(f"not FAT32 ({bs[82:90]!r})")
        if self.bps not in (512, 1024, 2048, 4096) or self.spc == 0 or self.nfats == 0:
            die("bad geometry")
        self.csize = self.bps * self.spc
        self.data = (self.rsvd + self.nfats * self.fatsz) * self.bps
        self.nclus = (self.totsec - self.rsvd - self.nfats * self.fatsz) // self.spc
        self.fats = [self.read(( self.rsvd + i * self.fatsz) * self.bps, self.fatsz * self.bps)
                     for i in range(self.nfats)]

    def read(self, off, n):
        assert off % self.bps == 0 and n % self.bps == 0
        out = b""
        while len(out) < n:
            chunk = os.pread(self.fd, min(n - len(out), 1 << 20), off + len(out))
            if not chunk:
                die(f"short read at {off + len(out)}")
            out += chunk
        return out

    def write(self, off, buf):
        assert off % self.bps == 0 and len(buf) % self.bps == 0
        done = 0
        while done < len(buf):
            done += os.pwrite(self.fd, buf[done:], off + done)

    def entry(self, fat, c):
        return struct.unpack_from("<I", self.fats[fat], c * 4)[0] & 0x0FFFFFFF

    def chain(self, first):
        out, seen, c = [], set(), first
        while True:
            if not (2 <= c < self.nclus + 2):
                die(f"cluster {c} out of range")
            if c in seen:
                die(f"cluster chain loops at {c}")
            seen.add(c)
            out.append(c)
            nxt = self.entry(0, c)
            for f in range(1, self.nfats):
                if self.entry(f, c) != nxt:
                    die(f"FAT copies disagree at cluster {c}")
            if nxt >= EOC:
                return out
            if nxt in (0, 1) or nxt == 0x0FFFFFF7:
                die(f"bad FAT entry {nxt:#x} after cluster {c}")
            c = nxt

    def coff(self, c):
        return self.data + (c - 2) * self.csize

    def dir_entries(self, first):
        """Yields (long name or None, short name, attr, first cluster, size)."""
        lfn = {}
        for c in self.chain(first):
            buf = self.read(self.coff(c), self.csize)
            for i in range(0, self.csize, 32):
                e = buf[i:i + 32]
                if e[0] == 0x00:
                    return
                if e[0] == 0xE5:
                    lfn = {}
                    continue
                attr = e[11]
                if attr == 0x0F:
                    seq = e[0] & 0x1F
                    part = e[1:11] + e[14:26] + e[28:32]
                    lfn[seq] = (part, e[13])
                    continue
                short = e[0:11]
                csum = 0
                for b in short:
                    csum = (((csum & 1) << 7) + (csum >> 1) + b) & 0xFF
                long = None
                if lfn and all(lfn[k][1] == csum for k in lfn) and sorted(lfn) == list(range(1, len(lfn) + 1)):
                    raw = b"".join(lfn[k][0] for k in sorted(lfn))
                    long = raw.decode("utf-16-le").split("\x00")[0]
                lfn = {}
                if attr & 0x08:  # volume label
                    continue
                first_c = (struct.unpack_from("<H", e, 20)[0] << 16) | struct.unpack_from("<H", e, 26)[0]
                size = struct.unpack_from("<I", e, 28)[0]
                yield long, short, attr, first_c, size

    def lookup(self, path):
        cur, attr, size = self.rootclus, 0x10, 0
        for comp in [p for p in path.split("/") if p]:
            if not attr & 0x10:
                die(f"{comp}: parent is not a directory")
            hits = []
            for long, short, a, fc, sz in self.dir_entries(cur):
                base = short[:8].decode("ascii", "replace").rstrip()
                ext = short[8:].decode("ascii", "replace").rstrip()
                sname = base + ("." + ext if ext else "")
                if (long or "").lower() == comp.lower() or sname.lower() == comp.lower():
                    hits.append((a, fc, sz))
            if len(hits) != 1:
                die(f"{comp}: {len(hits)} matching entries")
            attr, cur, size = hits[0]
        if attr & 0x10:
            die(f"{path} is a directory")
        return cur, size


def sha(b):
    return hashlib.sha256(b).hexdigest()


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("device")
    ap.add_argument("path", help="path in the volume, e.g. m1n1/boot-ctxr.bin")
    ap.add_argument("newfile")
    ap.add_argument("--label", required=True)
    ap.add_argument("--expect-old", required=True)
    ap.add_argument("--expect-new", required=True)
    ap.add_argument("--backup", help="where to save the current contents (required with --write)")
    ap.add_argument("--write", action="store_true")
    a = ap.parse_args()

    new = open(a.newfile, "rb").read()
    if sha(new) != a.expect_new:
        die(f"new file sha256 {sha(new)} != --expect-new")
    if a.write and not a.backup:
        die("--write needs --backup")
    dev_names = {a.device, a.device.replace("/dev/rdisk", "/dev/disk")}
    mounts = subprocess.run(["mount"], capture_output=True, text=True).stdout
    if any(line.split(" on ")[0] in dev_names for line in mounts.splitlines()):
        die(f"{a.device} is mounted")

    v = Vol(a.device, a.write)
    print(f"volume: label={v.label!r} bps={v.bps} spc={v.spc} clusters={v.nclus} fats={v.nfats}")
    if v.label != a.label:
        die(f"label {v.label!r} != --label {a.label!r}")
    first, size = v.lookup(a.path)
    chain = v.chain(first)
    need = -(-size // v.csize)
    print(f"{a.path}: first cluster {first}, size {size}, {len(chain)} clusters")
    if size != len(new):
        die(f"size {size} != new file size {len(new)}")
    if len(chain) != need:
        die(f"chain has {len(chain)} clusters, size needs {need}")
    old_clusters = [v.read(v.coff(c), v.csize) for c in chain]
    old = b"".join(old_clusters)[:size]
    print(f"current sha256 {sha(old)}")
    if sha(old) != a.expect_old:
        die("current contents != --expect-old")
    if not a.write:
        print("dry run: all checks passed; nothing written")
        return

    with open(a.backup, "xb") as f:
        f.write(old)
        f.flush()
        os.fsync(f.fileno())
    print(f"backup saved: {a.backup}")
    for i, c in enumerate(chain):
        piece = new[i * v.csize:(i + 1) * v.csize]
        if len(piece) < v.csize:  # last cluster: keep the slack after EOF
            piece = piece + old_clusters[i][len(piece):]
        if piece != old_clusters[i]:
            v.write(v.coff(c), piece)
    os.fsync(v.fd)
    os.close(v.fd)

    check = Vol(a.device, False)
    c2 = check.chain(first)
    got = b"".join(check.read(check.coff(c), check.csize) for c in c2)[:size]
    print(f"re-read sha256 {sha(got)}")
    if sha(got) != a.expect_new:
        sys.exit("FAILED: re-read contents != --expect-new; restore from the backup")
    print("written and verified")


if __name__ == "__main__":
    main()
