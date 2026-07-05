import os
os.environ.setdefault('SDL_VIDEODRIVER','dummy'); os.environ.setdefault('PYGAME_HIDE_SUPPORT_PROMPT','1')
import pygame; pygame.init()
import doom_wireframe as dw, fp
from bsp_render_6502 import BspRender6502
from wad_packed import spans_init_full
px,py,ab=1056,-3616,137; W,H=dw.FP_RENDER_W,dw.FP_RENDER_H
# Python ss order
pyss=[]
orig=dw.packed_render_subsector
def patched(idx,*a,**k): pyss.append(idx); return orig(idx,*a,**k)
dw.packed_render_subsector=patched
surf=pygame.Surface((W,H))
px8=int((px-dw.MAP_CENTER_X)*256/dw.PRESCALE); py8=int((py-dw.MAP_CENTER_Y)*256/dw.PRESCALE)
ctx=fp.fp_view_context(px8,py8,fp.fp_sincos(ab)); vz=dw._prescale_height(dw.player_floor(px,py)+41)
cf=pygame.math.Vector2(1,0).rotate(ab*360/256).x; sf=pygame.math.Vector2(1,0).rotate(ab*360/256).y
ram=bytearray(dw.packed_layout['ram_size']); spans_init_full(ram,dw.packed_layout['ram_spans'],W,H-1)
dw.packed_render_bsp(len(dw.nodes)-1, dw.Instrumented6502Spans(), ctx, vz, px,py,cf,sf,surf,ram)
dw.packed_render_subsector=orig
# 6502 ss order (hook $50F2)
r=BspRender6502(dw.packed_layout,dw.packed_rom_main,dw.packed_rom_detail,dw.packed_bbox_table,dw.MAP_CENTER_X,dw.MAP_CENTER_Y,dw.PRESCALE)
sc=r.sc; sixss=[]
def prof_run(entry,max_cycles=10_000_000):
    m=sc.mpu; m.pc=entry; m.sp=0xFD; m.p=0x30; mem=m.memory; mem[0x01FF]=0xFE; mem[0x01FE]=0xFF; m.processorCycles=0
    for _ in range(max_cycles):
        if m.pc==0xFF00: break
        if m.pc==0x50F2:
            sixss.append(mem[0x58] | ((mem[0x59]&0x7F)<<8))
        m.step()
    return m.processorCycles
sc._run=prof_run
r.render_frame(px,py,ab,dw.player_floor(px,py))
print("python ss order:", pyss)
print("6502   ss order:", sixss)
print("6502-only ss:", sorted(set(sixss)-set(pyss)))
print("python-only ss:", sorted(set(pyss)-set(sixss)))
