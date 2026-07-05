import os
os.environ.setdefault('SDL_VIDEODRIVER','dummy'); os.environ.setdefault('PYGAME_HIDE_SUPPORT_PROMPT','1')
import pygame; pygame.init()
import doom_wireframe as dw, angle_bbox as A
from bsp_render_6502 import BspRender6502
px,py,ab=1056,-3616,137
r=BspRender6502(dw.packed_layout,dw.packed_rom_main,dw.packed_rom_detail,dw.packed_bbox_table,dw.MAP_CENTER_X,dw.MAP_CENTER_Y,dw.PRESCALE)
sc=r.sc
def s16(lo,hi):
    v=lo|(hi<<8); return v-65536 if v>=32768 else v
def prof_run(entry,max_cycles=10_000_000):
    m=sc.mpu; m.pc=entry; m.sp=0xFD; m.p=0x30; mem=m.memory; mem[0x01FF]=0xFE; mem[0x01FE]=0xFF; m.processorCycles=0
    want=False; done=False
    for _ in range(max_cycles):
        pc=m.pc
        if pc==0xFF00: break
        if pc==0x509A:
            want = ((mem[0x58]|(mem[0x59]<<8))&0x7FFF==100 and mem[0x34]==1)
        if want and pc==0xE943 and not done:  # BCA_CHECK entry
            done=True
            bp=mem[0x86]|(mem[0x87]<<8)
            top=s16(mem[bp],mem[bp+1]); bot=s16(mem[bp+2],mem[bp+3])
            left=s16(mem[bp+4],mem[bp+5]); right=s16(mem[bp+6],mem[bp+7])
            pxs=s16(mem[0x8D],mem[0x8E]); pys=s16(mem[0x9B],mem[0x9C])
            vab=mem[0xFA2F]; afine=mem[0x3B]|(mem[0x3C]<<8)
            print(f"6502 BCA inputs: top={top} bot={bot} left={left} right={right} px={pxs} py={pys} ab={vab} a_fine={afine}")
            pyr=A.bbox_check_angle(top,bot,left,right,pxs,pys,vab)
            print(f"angle_bbox.bbox_check_angle(same inputs) = {pyr}")
            # let it finish to read 6502 output
        m.step()
        if done and pc==0xFF00: break
    return m.processorCycles
sc._run=prof_run
r.render_frame(px,py,ab,dw.player_floor(px,py))
