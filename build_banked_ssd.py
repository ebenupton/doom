#!/usr/bin/env python3
"""Build doom_banked.ssd: the banked standalone renderer as a bootable BBC disc.

Reuses banked_bsp.BankedBspRender to construct the (verified) bank + low-RAM
images, assembles banked_boot.asm (BOOT loader + DRV render-one-frame driver),
and writes a DFS disc. Boot it on a Model B + sideways RAM (banks 4/6/7).
"""
import os, subprocess
os.environ.setdefault('SDL_VIDEODRIVER', 'dummy')
os.environ.setdefault('PYGAME_HIDE_SUPPORT_PROMPT', '1')
import pygame; pygame.init()
import doom_wireframe as dw
from banked_bsp import BankedBspRender, BANK_L0, BANK_C, BANK_L2

SECTOR = 256
TOTAL_SECTORS = 800
SSD_SIZE = TOTAL_SECTORS * SECTOR

# LOW spans $1B40 up to the end of the highest low-RAM blob (bsp_render_bk @
# $4800). It MUST cover all of bsp_render or the walk crashes off the end, and
# MUST stay below the framebuffer at $5800.
def _low_end():
    end = 0x4800 + os.path.getsize('bsp_render_bk.bin')
    assert end <= 0x5800, f"bsp_render code (${end:04X}) collides with framebuffer $5800"
    return end


def build_images():
    r = BankedBspRender(dw.packed_layout, dw.packed_rom_main, dw.packed_rom_detail,
                        dw.packed_bbox_table, dw.MAP_CENTER_X, dw.MAP_CENTER_Y, dw.PRESCALE)
    bm = r.bm
    LOW_END = _low_end()
    L0 = bytes(bm._banks[BANK_L0])    # -> sideways bank 4
    C  = bytes(bm._banks[BANK_C])     # -> bank 6
    L2 = bytes(bm._banks[BANK_L2])    # -> bank 7
    LOW = bytes(bm[0x1B40:LOW_END])   # low code+tables (all >= PAGE)
    return L0, C, L2, LOW


def write_ssd(files, path='doom_banked.ssd'):
    disc = bytearray(SSD_SIZE)
    disc[0:8] = b'DOOMBNK\x00'
    n = len(files)
    assert n <= 31
    disc[SECTOR + 5] = n * 8
    nxt = 2
    secs = []
    for _, _, _, data in files:
        ns = (len(data) + SECTOR - 1) // SECTOR
        secs.append((nxt, ns)); nxt += ns
    total = nxt
    assert total <= TOTAL_SECTORS, f"disc full {total}>{TOTAL_SECTORS}"
    disc[SECTOR + 6] = (2 << 4) | ((total >> 8) & 3)   # *RUN boot, sector hi
    disc[SECTOR + 7] = total & 0xFF
    for i, (name, load, exe, data) in enumerate(files):
        ss, ns = secs[i]
        off = (i + 1) * 8
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
    for flag, src in [('1', 'slope_div.asm'), ('1', 'bsp_render.asm'), ('1', 'span_clip.asm')]:
        subprocess.run(['./beebasm', '-i', src, '-D', f'BANKED={flag}'], check=True,
                       capture_output=True)
    subprocess.run(['./beebasm', '-i', 'banked_boot.asm', '-D', 'BANKED=1'], check=True)
    L0, C, L2, LOW = build_images()
    BOOT = open('BOOT', 'rb').read()
    DRV = open('DRV', 'rb').read()
    files = [
        ('!BOOT', 0x0900, 0x0900, BOOT),
        ('BANK0', 0x3000, 0x3000, L0),     # -> bank 4 (L0)
        ('BANK1', 0x3000, 0x3000, C),      # -> bank 6 (C)
        ('BANK2', 0x3000, 0x3000, L2),     # -> bank 7 (L2)
        ('LOW',   0x1B40, 0x1B40, LOW),
        ('DRV',   0x3C00, 0x3C00, DRV),
    ]
    write_ssd(files)


if __name__ == '__main__':
    main()
