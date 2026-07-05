import os
os.environ.setdefault('SDL_VIDEODRIVER','dummy'); os.environ.setdefault('PYGAME_HIDE_SUPPORT_PROMPT','1')
import pygame; pygame.init()
import doom_wireframe as dw
from bsp_render_6502 import BspRender6502
px,py,ab=1056,-3616,137
r=BspRender6502(dw.packed_layout,dw.packed_rom_main,dw.packed_rom_detail,dw.packed_bbox_table,dw.MAP_CENTER_X,dw.MAP_CENTER_Y,dw.PRESCALE)
sc=r.sc
def s16(lo,hi):
    v=lo|(hi<<8); return v-65536 if v>=32768 else v
def prof_run(entry,max_cycles=10_000_000):
    m=sc.mpu; m.pc=entry; m.sp=0xFD; m.p=0x30; mem=m.memory; mem[0x01FF]=0xFE; mem[0x01FE]=0xFF; m.processorCycles=0
    want=False; dumped=False
    for _ in range(max_cycles):
        pc=m.pc
        if pc==0xFF00: break
        if pc==0x509A:
            nid=(mem[0x58]|(mem[0x59]<<8))&0x7FFF
            want = (nid==100 and mem[0x34]==1)
        if want and pc==0x2009 and not dumped:
            dumped=True
            print("BBOX_FLAGS($0968)=%02X (bit0=any_behind,bit1=any_front)"%mem[0x0968])
            print("ILO/IHI=%d/%d"%(mem[0xC2],mem[0xC3]))
            for c in range(4):
                b=0x0A40+c*8
                vx=s16(mem[b],mem[b+1]); vy=s16(mem[b+2],mem[b+3]); front=mem[b+4]
                print(f"  corner{c}: vx16={vx} vy16={vy} front={front}")
            want=False
        m.step()
    return m.processorCycles
sc._run=prof_run
r.render_frame(px,py,ab,dw.player_floor(px,py))
print("\nPython truth: c0 evy=5 front=1 | c1 evy=-3 front=0 | c2 evy=-2 front=0 | c3 evy=5 front=1")
