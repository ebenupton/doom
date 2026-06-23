#!/usr/bin/env python3
"""On the SAME bare memory the driver fails on, drive the render entries in the
MODEL's exact order (view_setup -> span_init -> clear -> init_frame ->
render_frame) instead of the driver's order (span_init -> ... -> view_setup).
If this renders, the bug is purely the driver's call ORDER."""
import os
os.environ.setdefault('SDL_VIDEODRIVER', 'dummy')
os.environ.setdefault('PYGAME_HIDE_SUPPORT_PROMPT', '1')
import pygame; pygame.init()
import doom_wireframe as dw
from banked_mem import BankedMemory
from banked_bsp import BankedBspRender, BANK_L0, BANK_C, BANK_L2
from span_clip_6502 import SpanClip6502

ENTRY_VIEW, ENTRY_RENDER, ENTRY_INIT_FRAME = 0x4809, 0x4815, 0x481B
ENTRY_SPAN_INIT = 0x8000
FB_LO, FB_HI = 0x5800, 0x8000

# spawn ZP values (verified == driver pokes)
ZP = {0x00:0x00,0x01:0xEE,0x02:0x40,0x03:0xD2,0x04:0x06,0x05:0,0x06:0,0x07:0,
      0x08:0,0x09:1,0x0A:1,0x90:0x70,0x91:0xFF,0x92:0x92,0x93:0xFE}
PTRS = {0x42:0x4C,0x43:0x87}
BLK = [0x00,0x24,0x00,0x8E,0x00,0x80,0x00,0x00,0x0C,0x96,0xC0,0x99,0x00,0xA2,0x00,0x24]

def main():
    ref = BankedBspRender(dw.packed_layout, dw.packed_rom_main, dw.packed_rom_detail,
                          dw.packed_bbox_table, dw.MAP_CENTER_X, dw.MAP_CENTER_Y, dw.PRESCALE)
    ref.render_frame(1056,-3616,128, dw.player_floor(1056,-3616))
    ref_fb = bytes(ref.bm[FB_LO:FB_HI]); ref_nz = sum(1 for b in ref_fb if b)

    src = BankedBspRender(dw.packed_layout, dw.packed_rom_main, dw.packed_rom_detail,
                          dw.packed_bbox_table, dw.MAP_CENTER_X, dw.MAP_CENTER_Y, dw.PRESCALE)
    L0,C,L2 = (bytes(src.bm._banks[b]) for b in (BANK_L0,BANK_C,BANK_L2))
    LOW = bytes(src.bm[0x1B40:0x5785])

    sc = SpanClip6502()
    bare = BankedMemory([0]*65536)
    for n,img in [(BANK_L0,L0),(BANK_C,C),(BANK_L2,L2)]: bare.define_bank(n,img)
    for i,b in enumerate(LOW): bare[0x1B40+i]=b
    for a,v in ZP.items(): bare[a]=v
    for a,v in PTRS.items(): bare[a]=v
    for i,v in enumerate(BLK): bare[0xBE8+i]=v
    bare[0x3A2F]=0x80
    bare[0xFF00]=0x00
    bare.select(BANK_L0)
    sc.mpu.memory = bare

    # MODEL ORDER
    sc._run(ENTRY_VIEW)
    bare.select(BANK_C); sc._run(ENTRY_SPAN_INIT)
    # clear FB
    for a in range(FB_LO, 0x6C00): bare[a]=0
    bare.select(BANK_L0)
    sc._run(ENTRY_INIT_FRAME)
    sc._run(ENTRY_RENDER, max_cycles=10_000_000)

    fb = bytes(bare[FB_LO:FB_HI]); nz = sum(1 for b in fb if b)
    print(f"reference {ref_nz} nz ; model-order bare {nz} nz ; "
          f"{'IDENTICAL' if fb==ref_fb else 'DIFFER'}")
    print(f"visited $0A80 = {' '.join('%02X'%bare[0xA80+i] for i in range(8))}")

if __name__=='__main__':
    main()
