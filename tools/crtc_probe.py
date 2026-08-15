#!/usr/bin/env python3
"""Build a one-file SSD for tools/crtc_probe.asm.

    python3 tools/crtc_probe.py <R8> <BIAS>        # both decimal

R8   the value written to CRTC R8 (0 = what walk_drv shipped;
     &90 = the MOS MODE 4 skew with interlace off; &93 = the MOS value)
BIAS characters subtracted from the R12/R13 screen start (0 = base/8)

Writes probe.ssd, boot option 3 (*EXEC of a text !BOOT that *RUNs PROBE).
"""
import os
import subprocess
import sys

os.chdir(os.path.join(os.path.dirname(os.path.abspath(__file__)), '..'))
SECTOR, TOTAL = 256, 800


def write_ssd(files, path):
    disc = bytearray(TOTAL * SECTOR)
    disc[0:8] = b'PROBE\x00\x00\x00'
    disc[SECTOR + 5] = len(files) * 8
    nxt, secs = 2, []
    for _, _, _, data in files:
        ns = (len(data) + SECTOR - 1) // SECTOR
        secs.append(nxt)
        nxt += ns
    disc[SECTOR + 6] = (3 << 4) | ((nxt >> 8) & 3)   # opt 3 = *EXEC
    disc[SECTOR + 7] = nxt & 0xFF
    for i, (name, load, exe, data) in enumerate(files):
        ss = secs[i]
        off = (i + 1) * 8
        disc[off:off + 7] = name.encode().ljust(7, b' ')[:7]
        disc[off + 7] = ord('$')
        m = SECTOR + (i + 1) * 8
        disc[m + 0] = load & 0xFF
        disc[m + 1] = (load >> 8) & 0xFF
        disc[m + 2] = exe & 0xFF
        disc[m + 3] = (exe >> 8) & 0xFF
        disc[m + 4] = len(data) & 0xFF
        disc[m + 5] = (len(data) >> 8) & 0xFF
        disc[m + 6] = ((ss >> 8) & 3) | (((load >> 16) & 3) << 2) | \
                      (((len(data) >> 16) & 3) << 4) | (((exe >> 16) & 3) << 6)
        disc[m + 7] = ss & 0xFF
        disc[ss * SECTOR: ss * SECTOR + len(data)] = data
    open(path, 'wb').write(disc)


def main():
    r8 = int(sys.argv[1]) if len(sys.argv) > 1 else 0
    bias = int(sys.argv[2]) if len(sys.argv) > 2 else 0
    cur = int(sys.argv[3]) if len(sys.argv) > 3 else 0
    loopw = int(sys.argv[4]) if len(sys.argv) > 4 else 0
    subprocess.run(['./beebasm', '-i', 'tools/crtc_probe.asm',
                    '-D', f'R8V={r8}', '-D', f'BI={bias}',
                    '-D', f'CU={cur}', '-D', f'LW={loopw}'], check=True)
    probe = open('PROBE', 'rb').read()
    boot = b'*RUN PROBE\r'
    write_ssd([('!BOOT', 0x1900, 0x1900, boot),
               ('PROBE', 0x1900, 0x1900, probe)], 'probe.ssd')
    print(f'probe.ssd: R8=&{r8:02X} BIAS={bias} CUR={cur} LOOPW={loopw} '
          f'start=&{(0x5800 // 8) - bias:04X} ({len(probe)} B)')


if __name__ == '__main__':
    main()
