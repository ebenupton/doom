#!/usr/bin/env python3
"""Build tube_test.ssd — the Tube bring-up test disc.

Files (DFS 18-bit load/exec: top bits 3 = &FFFFxxxx = host/IO processor,
top bits 0 = parasite when a copro is present):
  !BOOT   (=detect.asm)  host &0900  — Tube dispatch: MODE 4 + RUN COPROT,
                                        or the no-tube message
  COPROT  (=coprot.asm)  para &2000  — sends RUN HOSTT over R2, then the
                                        keypress-paced line-command loop
  HOSTT   (=hostt.asm)   host &1900  — triple-buffer carousel + key masks
Boot option 2 (*RUN !BOOT) — inherited from write_ssd.
"""
import os, subprocess, sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SECTOR = 256
TOTAL_SECTORS = 800


def write_ssd(files, path):
    """Acorn DFS single-sided image, boot option 2 (copy of
    build_walk_ssd.write_ssd — that module drags in pygame/the wad)."""
    disc = bytearray(TOTAL_SECTORS * SECTOR)
    disc[0:8] = b'TUBETS\x00\x00'
    n = len(files); assert n <= 31
    disc[SECTOR + 5] = n * 8
    nxt = 2; secs = []
    for _, _, _, data in files:
        ns = (len(data) + SECTOR - 1) // SECTOR
        secs.append((nxt, ns)); nxt += ns
    total = nxt; assert total <= TOTAL_SECTORS
    disc[SECTOR + 6] = (2 << 4) | ((total >> 8) & 3)
    disc[SECTOR + 7] = total & 0xFF
    for i, (name, load, exe, data) in enumerate(files):
        ss, _ = secs[i]; off = (i + 1) * 8
        disc[off:off+7] = name.encode().ljust(7, b' ')[:7]
        disc[off + 7] = ord('$')
        m = SECTOR + (i + 1) * 8
        disc[m+0] = load & 0xFF; disc[m+1] = (load >> 8) & 0xFF
        disc[m+2] = exe & 0xFF;  disc[m+3] = (exe >> 8) & 0xFF
        disc[m+4] = len(data) & 0xFF; disc[m+5] = (len(data) >> 8) & 0xFF
        disc[m+6] = ((ss>>8)&3) | (((load>>16)&3)<<2) | \
                    (((len(data)>>16)&3)<<4) | (((exe>>16)&3)<<6)
        disc[m+7] = ss & 0xFF
        disc[ss*SECTOR: ss*SECTOR + len(data)] = data
    open(path, 'wb').write(disc)
    print(f"Built {path}: {n} files, {total}/{TOTAL_SECTORS} sectors")
    for i, (name, load, exe, data) in enumerate(files):
        print(f"  {name:7s} &{load:05X}  {len(data):>5} B  sec {secs[i][0]}")


def asm(src, out):
    subprocess.run([os.path.join(ROOT, 'beebasm'), '-i',
                    os.path.join(ROOT, 'tube', src)], cwd=ROOT, check=True)
    with open(os.path.join(ROOT, out), 'rb') as f:
        data = f.read()
    os.remove(os.path.join(ROOT, out))
    return data


def main():
    detect = asm('detect.asm', 'DETECT')
    coprot = asm('coprot.asm', 'COPROT')
    hostt = asm('hostt.asm', 'HOSTT')
    write_ssd([
        ('!BOOT',  0x30900, 0x30900, detect),
        ('COPROT', 0x02000, 0x02000, coprot),
        ('HOSTT',  0x31900, 0x31900, hostt),
    ], os.path.join(ROOT, 'tube_test.ssd'))


if __name__ == '__main__':
    main()
