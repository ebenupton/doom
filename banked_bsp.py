#!/usr/bin/env python3
"""Verify the BANKED renderer (ROM_MAIN in sideways bank L0, clipper+rasteriser
in bank C) produces a bit-identical framebuffer to the flat BspRender6502, using
the banked_mem.py $FE30 model.

Strategy: build a flat BspRender6502 (loads all tables + code at flat addrs),
copy its 64K into a BankedMemory, then patch the banked deltas:
  - ROM_MAIN (verts/nodes/ss/seg_hdr) -> bank L0 @ $8000; ZP ptrs -> $8000+off
  - clipper (span_clip_bankc.bin) + rasteriser -> bank C @ $8000/$A900
  - FHCH -> low RAM $2400 (was $B600, inside the bank window); ZP -> $2400
  - sqr tables -> low RAM $2000 (banked clipper/bsp umul8 read them there)
  - bsp_render code -> the *_bk.bin variants (PAGE inserts + $80xx clip entries)
Everything else (recip/VWH/bbox/angle subsystem/vcache) stays flat (above the
$8000-$BFFF window) — reachable in the model; real-HW relocation is a later step.
"""
import os, math
os.environ.setdefault('SDL_VIDEODRIVER', 'dummy')
os.environ.setdefault('PYGAME_HIDE_SUPPORT_PROMPT', '1')
import pygame; pygame.init()
import doom_wireframe as dw
from banked_mem import BankedMemory
from bsp_render_6502 import (BspRender6502, ROM_MAIN_BASE, ROM_FHCH_BASE,
    ZP_ROM_VERTS_LO, ZP_ROM_NODES_LO, ZP_ROM_SS_LO, ZP_ROM_SEG_HDR_LO,
    ZP_ROM_FHCH_LO, ZP_ROM_DETAIL_LO)

BANK_L0, BANK_C = 4, 6
FHCH_LOW = 0x2400
SQR_LOW = 0x2000
RASTER_OFF = 0xA900            # rasteriser window addr in bank C


def _w16(mem, addr, val):
    mem[addr] = val & 0xFF
    mem[addr + 1] = (val >> 8) & 0xFF


def build_banked(flatr):
    """flatr: a constructed BspRender6502 (flat). Returns a BankedMemory set up
    for the banked layout, sharing the same loaded tables."""
    fmem = flatr.sc.mpu.memory
    bm = BankedMemory(list(fmem))
    layout = dw.packed_layout
    off_vwh = layout['off_vwh']
    rom_main = flatr.rom_main

    # --- bank L0 = ROM_MAIN (rom_main[0:off_vwh]) at window offset 0 ($8000) ---
    l0 = bytearray(16384)
    l0[:off_vwh] = bytes(rom_main[:off_vwh])
    bm.define_bank(BANK_L0, l0)

    # --- bank C = clipper ($8000) + rasteriser ($A900) ---
    c = bytearray(16384)
    clip = open('span_clip_bankc.bin', 'rb').read()
    c[:len(clip)] = clip
    rast = open('linedraw_or_reloc.bin', 'rb').read()      # ORG $A900
    roff = RASTER_OFF - 0x8000
    c[roff:roff + len(rast)] = rast
    bm.define_bank(BANK_C, c)

    # --- FHCH -> low $2400 (copy the bytes the flat harness put at $B600) ---
    n_fhch = layout['n_segs'] * 6
    for i in range(n_fhch):
        bm[FHCH_LOW + i] = fmem[ROM_FHCH_BASE + i]

    # --- sqr tables -> low $2000 (copy from flat $A500) ---
    for i in range(0x400):
        bm[SQR_LOW + i] = fmem[0xA500 + i]

    # --- banked bsp_render code (_bk variants) into low RAM ---
    for fn, addr in [('bsp_render_bk.bin', 0x4800), ('bsp_render_lo_bk.bin', 0x1B40),
                     ('bsp_render_b_bk.bin', 0x0AA0), ('bsp_render_d_bk.bin', 0x0978),
                     ('bsp_render_w_bk.bin', 0xDAC0)]:
        if os.path.exists(fn):
            d = open(fn, 'rb').read()
            for i, b in enumerate(d):
                bm[addr + i] = b

    # --- ZP pointers: ROM_MAIN tables -> $8000 window; FHCH -> $2400 ---
    _w16(bm, ZP_ROM_VERTS_LO,   0x8000 + layout['off_verts'])
    _w16(bm, ZP_ROM_NODES_LO,   0x8000 + layout['off_nodes'])
    _w16(bm, ZP_ROM_SS_LO,      0x8000 + layout['off_ss'])
    _w16(bm, ZP_ROM_SEG_HDR_LO, 0x8000 + layout['off_seg_hdr'])
    _w16(bm, ZP_ROM_FHCH_LO,    FHCH_LOW)
    _w16(bm, ZP_ROM_DETAIL_LO,  FHCH_LOW)
    bm[0xFF00] = 0x00
    bm.select(BANK_L0)
    return bm


class BankedBspRender(BspRender6502):
    def __init__(self, *a, **k):
        super().__init__(*a, **k)
        self.bm = build_banked(self)
        self.sc.mpu.memory = self.bm     # swap in banked memory
        # span_init (pool reset) lives in the clipper -> bank C @ $8000, not $2000.
        sc = self.sc
        def banked_init():
            self.bm.select(BANK_C)
            sc._run(0x8000)              # ENTRY_INIT (jump table entry 0) in bank C
            sc.total_cycles = 0
        sc.init = banked_init


def fb_mask(r):
    s = pygame.Surface((dw.FP_RENDER_W, dw.FP_RENDER_H))
    r.blit_framebuffer_to(s)
    import pygame.surfarray as sa
    return sa.array3d(s).sum(2) > 0


def main():
    import sys
    positions = [(1056, -3616, 128), (1056, -3328, 14), (1308, -3289, 252),
                 (994, -3291, 237), (845, -3084, 215), (1056, -3291, 34)]
    if len(sys.argv) == 4:
        positions = [(int(sys.argv[1]), int(sys.argv[2]), int(sys.argv[3]))]
    flat = BspRender6502(dw.packed_layout, dw.packed_rom_main, dw.packed_rom_detail,
                         dw.packed_bbox_table, dw.MAP_CENTER_X, dw.MAP_CENTER_Y, dw.PRESCALE)
    bank = BankedBspRender(dw.packed_layout, dw.packed_rom_main, dw.packed_rom_detail,
                           dw.packed_bbox_table, dw.MAP_CENTER_X, dw.MAP_CENTER_Y, dw.PRESCALE)
    import numpy as np
    allok = True
    for (px, py, ab) in positions:
        fz = dw.player_floor(px, py)
        fc = flat.render_frame(px, py, ab, fz); fdone = flat.sc.mpu.pc == 0xFF00
        bc = bank.render_frame(px, py, ab, fz); bdone = bank.sc.mpu.pc == 0xFF00
        fm, bm_ = fb_mask(flat), fb_mask(bank)
        same = bool((fm == bm_).all())
        diff = int((fm != bm_).sum())
        print(f"({px},{py},{ab}): flat={'ok' if fdone else 'CRASH'}({fc:,}) "
              f"bank={'ok' if bdone else 'CRASH'}({bc:,}) "
              f"{'IDENTICAL' if same else f'DIFFER {diff}px'}")
        allok = allok and same and bdone
    print("\nBANKED RENDERER:", "PASS — bit-identical to flat" if allok else "FAIL")


if __name__ == '__main__':
    main()
