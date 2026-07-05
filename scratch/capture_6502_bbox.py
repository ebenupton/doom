import os
os.environ.setdefault('SDL_VIDEODRIVER','dummy'); os.environ.setdefault('PYGAME_HIDE_SUPPORT_PROMPT','1')
import pygame; pygame.init()
import doom_wireframe as dw
from bsp_render_6502 import BspRender6502
px,py,ab=1056,-3616,137
r=BspRender6502(dw.packed_layout,dw.packed_rom_main,dw.packed_rom_detail,dw.packed_bbox_table,dw.MAP_CENTER_X,dw.MAP_CENTER_Y,dw.PRESCALE)
sc=r.sc; ev=[]
def prof_run(entry,max_cycles=10_000_000):
    m=sc.mpu; m.pc=entry; m.sp=0xFD; m.p=0x30; mem=m.memory; mem[0x01FF]=0xFE; mem[0x01FE]=0xFF; m.processorCycles=0
    for _ in range(max_cycles):
        pc=m.pc
        if pc==0xFF00: break
        if pc==0x509A:
            ev.append(('BBOX', (mem[0x58]|(mem[0x59]<<8))&0x7FFF, mem[0x34]))
        elif pc==0x2009:
            ev.append(('GAP', mem[0xC2], mem[0xC3]))
        m.step()
    return m.processorCycles
sc._run=prof_run
r.render_frame(px,py,ab,dw.player_floor(px,py))
# pair each BBOX with the immediately-following GAP (if any before next BBOX)
out=[]
i=0
while i<len(ev):
    if ev[i][0]=='BBOX':
        nid,side=ev[i][1],ev[i][2]
        res=None
        if i+1<len(ev) and ev[i+1][0]=='GAP': res=(ev[i+1][1],ev[i+1][2]); i+=1
        out.append((nid,side,res))
    i+=1
print("6502 br_bbox_visible results (nid, side, (ilo,ihi) or None=culled-before-gap):")
for j,o in enumerate(out[:16]): print(f"  {j:3d} nid={o[0]:4d} side={o[1]} -> {o[2]}")
