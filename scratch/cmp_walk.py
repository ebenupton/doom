import os
os.environ.setdefault('SDL_VIDEODRIVER','dummy'); os.environ.setdefault('PYGAME_HIDE_SUPPORT_PROMPT','1')
import pygame; pygame.init()
import doom_wireframe as dw, fp
from bsp_render_6502 import BspRender6502
from wad_packed import spans_init_full
px,py,ab=1056,-3616,137; W,H=dw.FP_RENDER_W,dw.FP_RENDER_H
nodes=dw.nodes
# --- angle-Python br stream ---
dw._USE_ANGLE_BBOX=True
ap=[]
of=dw.fp_bbox_visible_fixed
def pf(node,side,ctx):
    r=of(node,side,ctx)
    try: nid=nodes.index(node)
    except: nid=-1
    ap.append((nid,side,r)); return r
dw.fp_bbox_visible_fixed=pf
surf=pygame.Surface((W,H))
px8=int((px-dw.MAP_CENTER_X)*256/dw.PRESCALE); py8=int((py-dw.MAP_CENTER_Y)*256/dw.PRESCALE)
ctx=fp.fp_view_context(px8,py8,fp.fp_sincos(ab)); vz=dw._prescale_height(dw.player_floor(px,py)+41)
cf=pygame.math.Vector2(1,0).rotate(ab*360/256).x; sf=pygame.math.Vector2(1,0).rotate(ab*360/256).y
ram=bytearray(dw.packed_layout['ram_size']); spans_init_full(ram,dw.packed_layout['ram_spans'],W,H-1)
dw.packed_render_bsp(len(dw.nodes)-1, dw.Instrumented6502Spans(), ctx, vz, px,py,cf,sf,surf,ram)
dw.fp_bbox_visible_fixed=of; dw._USE_ANGLE_BBOX=False
# --- 6502 br stream ($509A bbox entry, $2009 has_gap) ---
r=BspRender6502(dw.packed_layout,dw.packed_rom_main,dw.packed_rom_detail,dw.packed_bbox_table,dw.MAP_CENTER_X,dw.MAP_CENTER_Y,dw.PRESCALE)
sc=r.sc; ev=[]
def prof_run(entry,max_cycles=10_000_000):
    m=sc.mpu; m.pc=entry; m.sp=0xFD; m.p=0x30; mem=m.memory; mem[0x01FF]=0xFE; mem[0x01FE]=0xFF; m.processorCycles=0
    for _ in range(max_cycles):
        pc=m.pc
        if pc==0xFF00: break
        if pc==0x509A: ev.append(('B',(mem[0x58]|(mem[0x59]<<8))&0x7FFF,mem[0x34]))
        elif pc==0x2009: ev.append(('G',mem[0xC2],mem[0xC3]))
        m.step()
    return m.processorCycles
sc._run=prof_run
r.render_frame(px,py,ab,dw.player_floor(px,py))
sp=[]; i=0
while i<len(ev):
    if ev[i][0]=='B':
        nid,side=ev[i][1],ev[i][2]; res=None
        if i+1<len(ev) and ev[i+1][0]=='G': res=(ev[i+1][1],ev[i+1][2]); i+=1
        sp.append((nid,side,res))
    i+=1
print("idx  angle-Python      6502")
n=min(len(ap),len(sp))
for i in range(n):
    mark = '   <<< DIFF' if ap[i]!=sp[i] else ''
    print(f"{i:3d}  {str(ap[i]):22s} {str(sp[i]):22s}{mark}")
    if ap[i]!=sp[i] and i>0: 
        if i+2<n and ap[i+1]==sp[i+1]: continue
        break
