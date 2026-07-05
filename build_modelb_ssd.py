#!/usr/bin/env python3
"""Build doom_modelb.ssd: the rotating E1M1 wireframe for a plain Model B + SWRAM.

Same banked images + animation driver/table as the spin disc, but loaded by a
machine-code !BOOT (modelb_boot.asm) that copies each bank into sideways RAM via
ROMSEL (Acorn DFS has no *SRLOAD). Banks 4/6/7 = L0/C/L2 (writable SWRAM on a B).
Boot option 2 (*RUN) -> SHIFT-BREAK autoboots."""
import os, subprocess
os.environ.setdefault('SDL_VIDEODRIVER', 'dummy')
os.environ.setdefault('PYGAME_HIDE_SUPPORT_PROMPT', '1')
import pygame; pygame.init()
import build_anim_ssd as anim          # reuse image + sincos-table builders

SECTOR = 256
TOTAL_SECTORS = 800


def write_ssd(files, path='doom_modelb.ssd'):
    disc = bytearray(TOTAL_SECTORS * SECTOR)
    disc[0:8] = b'DOOMB\x00\x00\x00'
    n = len(files); assert n <= 31
    disc[SECTOR + 5] = n * 8
    nxt = 2; secs = []
    for _, _, _, data in files:
        ns = (len(data) + SECTOR - 1) // SECTOR
        secs.append((nxt, ns)); nxt += ns
    total = nxt; assert total <= TOTAL_SECTORS, f"disc full {total}"
    disc[SECTOR + 6] = (2 << 4) | ((total >> 8) & 3)   # boot option 2 = *RUN
    disc[SECTOR + 7] = total & 0xFF
    for i, (name, load, exe, data) in enumerate(files):
        ss, _ = secs[i]; off = (i + 1) * 8
        disc[off:off+7] = name.encode().ljust(7, b' ')[:7]
        disc[off + 7] = ord('$')
        m = SECTOR + (i + 1) * 8
        disc[m+0] = load & 0xFF; disc[m+1] = (load >> 8) & 0xFF
        disc[m+2] = exe & 0xFF;  disc[m+3] = (exe >> 8) & 0xFF
        disc[m+4] = len(data) & 0xFF; disc[m+5] = (len(data) >> 8) & 0xFF
        disc[m+6] = (((exe>>16)&3)) | (((len(data)>>16)&3)<<2) | \
                    (((load>>16)&3)<<4) | (((ss>>8)&3)<<6)
        disc[m+7] = ss & 0xFF
        disc[ss*SECTOR: ss*SECTOR + len(data)] = data
    open(path, 'wb').write(disc)
    print(f"Built {path}: {n} files, {total}/{TOTAL_SECTORS} sectors")
    for i, (name, load, exe, data) in enumerate(files):
        print(f"  {name:7s} ${load:04X}  {len(data):>6} B  sec {secs[i][0]}")


def main():
    import asmbuild
    asmbuild.build_all(banked=1, c02=0)
    subprocess.run(['./beebasm', '-i', 'anim_drv.asm', '-D', 'BANKED=1'], check=True)
    subprocess.run(['./beebasm', '-i', 'modelb_boot.asm', '-D', 'BANKED=1'], check=True)
    L0, C, L2, LOW = anim.build_images()
    BOOT = open('!BOOT', 'rb').read()
    files = [
        ('!BOOT', 0x1900, 0x1900, BOOT),
        ('BANK0', 0x3000, 0x3000, L0),     # staged to $3000, copied -> bank 4
        ('BANK1', 0x3000, 0x3000, C),      #                       -> bank 6
        ('BANK2', 0x3000, 0x3000, L2),     #                       -> bank 7
        ('LOW',   0x1B40, 0x1B40, LOW),
    ]
    write_ssd(files)


if __name__ == '__main__':
    main()
