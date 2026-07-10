#!/usr/bin/env python3
"""Lock-step the working model render against the bare (real-HW-faithful) render.
Both execute identical code (LOW + banks); they diverge only when a DATA read
yields a different value and drives a different branch. The first PC divergence
pinpoints the instruction reading stale/missing data on bare."""
import os
os.environ.setdefault('SDL_VIDEODRIVER', 'dummy')
os.environ.setdefault('PYGAME_HIDE_SUPPORT_PROMPT', '1')
import pygame; pygame.init()
import doom_wireframe as dw
from banked_mem import BankedMemory
from banked_bsp import BankedBspRender, BANK_L0, BANK_C, BANK_L2
from span_clip_6502 import SpanClip6502

ENTRY_VIEW, ENTRY_RENDER, ENTRY_INIT_FRAME = 0x2C09, 0x2C15, 0x2C1B
ENTRY_SPAN_INIT = 0x8000
ZP = {0x00:0x00,0x01:0xEE,0x02:0x40,0x03:0xD2,0x04:0x06,0x05:0,0x06:0,0x07:0,
      0x08:0,0x09:1,0x0A:1,0x90:0x70,0x91:0xFF,0x92:0x92,0x93:0xFE, 0x70:0x58,
      0x9D:0xFF,0x9E:0xFF}   # incl. s16 int-hi bytes (spawn negative both axes)
# (ROM-pointer pokes + $0BE8 block retired 2026-07-10: layout.inc constants)

def mk_model():
    r = BankedBspRender(dw.packed_layout, dw.packed_rom_main, dw.packed_rom_detail,
                        dw.packed_bbox_table, dw.MAP_CENTER_X, dw.MAP_CENTER_Y, dw.PRESCALE)
    # set the spawn ZP exactly as render_frame would, but DON'T run yet
    return r

def mk_bare():
    src = BankedBspRender(dw.packed_layout, dw.packed_rom_main, dw.packed_rom_detail,
                          dw.packed_bbox_table, dw.MAP_CENTER_X, dw.MAP_CENTER_Y, dw.PRESCALE)
    L0,C,L2 = (bytes(src.bm._banks[b]) for b in (BANK_L0,BANK_C,BANK_L2))
    import os as _os
    LOW = bytes(src.bm[0x1B40:0x2C00 + _os.path.getsize('bsp_render_bk.bin')])
    sc = SpanClip6502()
    bare = BankedMemory([0]*65536)
    for n,img in [(BANK_L0,L0),(BANK_C,C),(BANK_L2,L2)]: bare.define_bank(n,img)
    for i,b in enumerate(LOW): bare[0x1B40+i]=b
    for a,v in ZP.items(): bare[a]=v
    # RNS vectoring block: staged in L2 $A100, copied to the stack page by
    # the drivers' boot stkcpy — mirror that here (we enter entries directly).
    bare.select(BANK_L2)
    for i in range(0xC0): bare[0x0100+i]=bare[0xA100+i]
    bare[0x1B6F]=0x80; bare[0xFF00]=0x00
    bare.select(BANK_L0)
    sc.mpu.memory = bare
    return sc, bare

def run_entry(sc, entry, maxc=10_000_000):
    mpu=sc.mpu; mpu.pc=entry; mpu.sp=0xFD; mpu.p=0x34
    mem=mpu.memory; mem[0x01FF]=0xFE; mem[0x01FE]=0xFF
    for _ in range(maxc):
        if mpu.pc==0xFF00: return True
        mpu.step()
    return False

def setup_common(sc, bare_mode):
    # both: VIEW_SETUP, span_init(bank C), clear FB, INIT_FRAME
    run_entry(sc, ENTRY_VIEW)
    sc.mpu.memory.select(BANK_C); run_entry(sc, ENTRY_SPAN_INIT)
    for a in range(0x5800,0x6C00): sc.mpu.memory[a]=0
    sc.mpu.memory.select(BANK_L0)
    run_entry(sc, ENTRY_INIT_FRAME)

def main():
    # model: drive the BankedBspRender's own sc with the spawn ZP set
    mr = mk_model(); msc = mr.sc
    for a,v in ZP.items(): msc.mpu.memory[a]=v
    msc.mpu.memory[0x1B6F]=0x80
    bsc, bare = mk_bare()

    setup_common(msc, False)
    setup_common(bsc, True)

    # before RENDER: diff persistent low-RAM state ($00-$1B40). Both ran the same
    # VIEW+init+INIT_FRAME, so any difference here is initial state bare lacks.
    # exclude dead flat code blobs the banked build never calls: bsp_d $0900-$09FF,
    # bsp_b $0A00-$0BE7 (BSP_STACK/visited live here too but are per-frame), focus
    # on ZP and the ROM-pointer/data region.
    def dead(a): return 0x0900 <= a < 0x0BE8
    diffs=[]
    for a in range(0x00, 0x1B40):
        if a < 0x100 or (0x0BE8 <= a < 0x1B40 and not dead(a)):
            if msc.mpu.memory[a] != bare[a]:
                diffs.append((a, msc.mpu.memory[a], bare[a]))
    print(f"ZP + data diffs (excl dead flat blobs): {len(diffs)}")
    for a,mv,bv in diffs:
        print(f"  ${a:04X}: model {mv:02X} bare {bv:02X}")

    # lockstep RENDER
    m=msc.mpu; b=bsc.mpu
    m.pc=ENTRY_RENDER; m.sp=0xFD; m.p=0x34; m.memory[0x01FF]=0xFE; m.memory[0x01FE]=0xFF
    b.pc=ENTRY_RENDER; b.sp=0xFD; b.p=0x34; b.memory[0x01FF]=0xFE; b.memory[0x01FE]=0xFF
    prev_m=prev_b=ENTRY_RENDER
    for i in range(10_000_000):
        if m.pc==0xFF00 or b.pc==0xFF00:
            mnz=sum(1 for k in range(0x5800,0x8000) if m.memory[k])
            bnz=sum(1 for k in range(0x5800,0x8000) if bare[k])
            print(f"both finished at step {i}; model FB nz={mnz} bare FB nz={bnz}"); break
        if m.pc != b.pc:
            mm=m.memory; bm=bare
            print(f"DIVERGE at step {i}: model PC=${m.pc:04X} bare PC=${b.pc:04X}")
            print(f"  prev instr at ${prev_b:04X}")
            def dz(mem,a,n): return ' '.join('%02X'%mem[a+k] for k in range(n))
            print(f"  $42/43 (nodes ptr): model {dz(mm,0x42,2)}  bare {dz(bm,0x42,2)}")
            print(f"  $1C/1D (zp_br_p):   model {dz(mm,0x1C,2)}  bare {dz(bm,0x1C,2)}")
            print(f"  $50-57 (node flds): model {dz(mm,0x50,8)}  bare {dz(bm,0x50,8)}")
            print(f"  current bank: model {mm.current_bank()}  bare {bm.current_bank()}")
            # node addr = zp_br_p; dump 8 bytes there in both windows
            pa = mm[0x1C] | (mm[0x1D]<<8)
            print(f"  node@${pa:04X}: model {dz(mm,pa,8)}  bare {dz(bm,pa,8)}")
            # compare full windows
            wd = sum(1 for k in range(0x8000,0xC000) if mm[k]!=bm[k])
            print(f"  window $8000-BFFF bytes differing model vs bare: {wd}")
            # compare below-window flat region that bare lacks
            fd = sum(1 for k in range(0x6C00,0x8000) if mm[k]!=bm[k])
            print(f"  flat $6C00-7FFF bytes differing: {fd}")
            break
        # detect first DATA divergence in the rasteriser write pointer / coords
        if (m.memory[0x74]!=bare[0x74] or m.memory[0x75]!=bare[0x75] or
            any(m.memory[0x82+k]!=bare[0x82+k] for k in range(4))):
            def dz(mem,a,n): return ' '.join('%02X'%mem[a+k] for k in range(n))
            print(f"SCR/COORD diverge at step {i}, PC=${m.pc:04X} (prev ${prev_b:04X})")
            print(f"  scr$74/75: model {dz(m.memory,0x74,2)} bare {dz(bare,0x74,2)}")
            print(f"  x0y0x1y1 $82-85: model {dz(m.memory,0x82,4)} bare {dz(bare,0x82,4)}")
            break
        prev_m, prev_b = m.pc, b.pc
        m.step(); b.step()
    else:
        print("no divergence in budget")

if __name__=='__main__':
    main()
