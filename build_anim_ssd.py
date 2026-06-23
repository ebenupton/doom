#!/usr/bin/env python3
"""Build doom_spin.ssd: an autobooting rotating E1M1 wireframe.

The animation driver ($3C00) + a 64-frame sincos table ($3E00) are overlaid into
the LOW image (both sit in the clipper-vacated $3C00-$47FF region the render never
touches), so there is NO separate driver file — !BOOT just *SRLOADs the banks,
*LOADs LOW, MODE 4, and jumps to $3C00. SHIFT-BREAK autoboots it."""
import os, subprocess
os.environ.setdefault('SDL_VIDEODRIVER', 'dummy')
os.environ.setdefault('PYGAME_HIDE_SUPPORT_PROMPT', '1')
import pygame; pygame.init()
import doom_wireframe as dw
import fp
from banked_bsp import BankedBspRender, BANK_L0, BANK_C, BANK_L2

SECTOR = 256
TOTAL_SECTORS = 800
SSD_SIZE = TOTAL_SECTORS * SECTOR
DRV_ADDR = 0x3C00
TAB_ADDR = 0x3E00
N_FRAMES = 64
ANGLE_STEP = 256 // N_FRAMES        # 4


def sincos_table():
    """64 entries x 8 bytes: smag,sneg,sone,cmag,cneg,cone,ab,pad."""
    t = bytearray(N_FRAMES * 8)
    for i in range(N_FRAMES):
        a = (i * ANGLE_STEP) & 0xFF
        sm, sn, so, cm, cn, co = fp.fp_sincos(a)
        e = i * 8
        t[e+0] = sm & 0xFF
        t[e+1] = 1 if sn else 0
        t[e+2] = 1 if so else 0
        t[e+3] = cm & 0xFF
        t[e+4] = 1 if cn else 0
        t[e+5] = 1 if co else 0
        t[e+6] = a
        t[e+7] = 0
    return bytes(t)


def build_images():
    r = BankedBspRender(dw.packed_layout, dw.packed_rom_main, dw.packed_rom_detail,
                        dw.packed_bbox_table, dw.MAP_CENTER_X, dw.MAP_CENTER_Y, dw.PRESCALE)
    bm = r.bm
    L0 = bytes(bm._banks[BANK_L0]); C = bytes(bm._banks[BANK_C]); L2 = bytes(bm._banks[BANK_L2])
    low_end = 0x4800 + os.path.getsize('bsp_render_bk.bin')
    assert low_end <= DRV_ADDR or low_end >= 0x4800, low_end
    low = bytearray(bm[0x1B40:max(low_end, TAB_ADDR + N_FRAMES*8)])
    def overlay(addr, data):
        off = addr - 0x1B40
        low[off:off+len(data)] = data
    overlay(DRV_ADDR, open('ANIMDRV', 'rb').read())
    overlay(TAB_ADDR, sincos_table())
    # sanity: render code starts at $4800, must not be clobbered by table/driver
    assert TAB_ADDR + N_FRAMES*8 <= 0x4800, "table collides with bsp_render code"
    return L0, C, L2, bytes(low)


def write_ssd(files, path='doom_spin.ssd'):
    disc = bytearray(SSD_SIZE)
    disc[0:8] = b'DOOMSPN\x00'
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
        ss, ns = secs[i]; off = (i + 1) * 8
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
        print(f"  {name:8s} ${load:04X}  {len(data):>6} B  sec {secs[i][0]}")


def main():
    for src in ['slope_div.asm', 'bsp_render.asm', 'span_clip.asm']:
        subprocess.run(['./beebasm', '-i', src, '-D', 'BANKED=1'], check=True, capture_output=True)
    subprocess.run(['./beebasm', '-i', 'anim_drv.asm', '-D', 'BANKED=1'], check=True)
    subprocess.run(['./beebasm', '-i', 'anim_boot.asm', '-D', 'BANKED=1'], check=True)
    L0, C, L2, LOW = build_images()
    BOOT = open('ANIMBOOT', 'rb').read()
    files = [
        ('!BOOT', 0x0900, 0x0900, BOOT),
        ('BANK0', 0x3000, 0x3000, L0),
        ('BANK1', 0x3000, 0x3000, C),
        ('BANK2', 0x3000, 0x3000, L2),
        ('LOW',   0x1B40, 0x1B40, LOW),
    ]
    write_ssd(files)


if __name__ == '__main__':
    main()
