#!/usr/bin/env python3
"""Enumerate ALL stale flat-address reads in the banked render in one pass.
On bare (real-HW) memory, the only regions that hold data are: low RAM (LOW
file), the bank window $8000-$BFFF, and zero everywhere else. The model keeps
flat table copies at $6C00-$7FFF and $C000-$FFFF. Any banked-code read into
those flat ranges is a bug (works in model, reads zero on real HW). Log each
such read with the PC so we can fix them all at once."""
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
ZP = {0x00:0x00,0x01:0xEE,0x02:0x40,0x03:0xD2,0x04:0x06,0x05:0,0x06:0,0x07:0,
      0x08:0,0x09:1,0x0A:1,0x90:0x70,0x91:0xFF,0x92:0x92,0x93:0xFE, 0x70:0x58}
PTRS = {0x42:0x4C,0x43:0x87, 0x4C:0xEB,0x4D:0x00}
BLK = [0x00,0x24,0x00,0x8E,0x00,0x80,0x00,0x00,0x0C,0x96,0xC0,0x99,0x00,0xA2,0x00,0x24]

# flat ranges that are ZERO on bare but data in the model (banking-relocated)
def suspicious(a):
    # $57CB-$8000 and $C000+ : genuinely missing flat tables on bare.
    # $0900-$0BE7 : flat bsp_d/bsp_b blobs the model has but bare lacks — if the
    #   banked build calls/reads these (vs the relocated $3A40/$3BC0), it's a bug.
    return (0x57CB <= a < 0x8000) or (0xC000 <= a < 0xFE00) or (0x0900 <= a < 0x0BE8)

class LogMem(BankedMemory):
    def __init__(self, *a):
        super().__init__(*a); self.mpu=None; self.hits={}
    def __getitem__(self, i):
        if self.mpu is not None and isinstance(i,int) and suspicious(i):
            pc=self.mpu.pc
            self.hits.setdefault(pc, [0,i]); self.hits[pc][0]+=1
        return super().__getitem__(i)

def main():
    src = BankedBspRender(dw.packed_layout, dw.packed_rom_main, dw.packed_rom_detail,
                          dw.packed_bbox_table, dw.MAP_CENTER_X, dw.MAP_CENTER_Y, dw.PRESCALE)
    L0,C,L2 = (bytes(src.bm._banks[b]) for b in (BANK_L0,BANK_C,BANK_L2))
    LOW = bytes(src.bm[0x1B40:0x4800+os.path.getsize('bsp_render_bk.bin')])
    sc = SpanClip6502()
    bare = LogMem([0]*65536)
    for n,img in [(BANK_L0,L0),(BANK_C,C),(BANK_L2,L2)]: bare.define_bank(n,img)
    for i,b in enumerate(LOW): bare[0x1B40+i]=b
    for a,v in ZP.items(): bare[a]=v
    for a,v in PTRS.items(): bare[a]=v
    for i,v in enumerate(BLK): bare[0xBE8+i]=v
    bare[0x3A2F]=0x80; bare[0xFF00]=0x00
    bare.select(BANK_L0)
    sc.mpu.memory = bare; bare.mpu = sc.mpu

    def run(entry):
        mpu=sc.mpu; mpu.pc=entry; mpu.sp=0xFD; mpu.p=0x34
        bare[0x01FF]=0xFE; bare[0x01FE]=0xFF
        for _ in range(20_000_000):
            if mpu.pc==0xFF00: return
            mpu.step()
    run(ENTRY_VIEW)
    bare.select(BANK_C); run(ENTRY_SPAN_INIT)
    for a in range(0x5800,0x6C00): bare[a]=0
    bare.select(BANK_L0)
    bare.hits.clear()              # only log during INIT_FRAME + RENDER
    run(ENTRY_INIT_FRAME)
    run(ENTRY_RENDER)

    if not bare.hits:
        print("NO stale flat reads — banked code is fully bank-relocated"); return
    print(f"{len(bare.hits)} distinct PCs read flat (zero-on-bare) addresses:")
    for pc in sorted(bare.hits):
        cnt,addr = bare.hits[pc]
        print(f"  PC ${pc:04X}  reads ~${addr:04X}  ({cnt}x)")

if __name__=='__main__':
    main()
