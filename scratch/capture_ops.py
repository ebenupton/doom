import os
os.environ.setdefault('SDL_VIDEODRIVER','dummy'); os.environ.setdefault('PYGAME_HIDE_SUPPORT_PROMPT','1')
import pygame; pygame.init()
import doom_wireframe as dw, fp
from bsp_render_6502 import BspRender6502
from wad_packed import spans_init_full
px,py,ab=1056,-3616,137; W,H=dw.FP_RENDER_W,dw.FP_RENDER_H
# Python ops
pyops=[]
spans=dw.Instrumented6502Spans()
oms,otg,ohg=spans.mark_solid,spans.tighten,spans.has_gap
def ms(lo,hi,**k): pyops.append(('SOLID',int(lo),int(hi))); return oms(lo,hi,**k)
def tg(lo,hi,*a,**k): pyops.append(('TIGHT',int(lo),int(hi))); return otg(lo,hi,*a,**k)
def hg(lo,hi):
    r=ohg(lo,hi); pyops.append(('GAP?',int(lo),int(hi),int(bool(r)))); return r
spans.mark_solid=ms; spans.tighten=tg; spans.has_gap=hg
surf=pygame.Surface((W,H))
px8=int((px-dw.MAP_CENTER_X)*256/dw.PRESCALE); py8=int((py-dw.MAP_CENTER_Y)*256/dw.PRESCALE)
ctx=fp.fp_view_context(px8,py8,fp.fp_sincos(ab)); vz=dw._prescale_height(dw.player_floor(px,py)+41)
cf=pygame.math.Vector2(1,0).rotate(ab*360/256).x; sf=pygame.math.Vector2(1,0).rotate(ab*360/256).y
ram=bytearray(dw.packed_layout['ram_size']); spans_init_full(ram,dw.packed_layout['ram_spans'],W,H-1)
dw.packed_render_bsp(len(dw.nodes)-1, spans, ctx, vz, px,py,cf,sf,surf,ram)
# 6502 ops
r=BspRender6502(dw.packed_layout,dw.packed_rom_main,dw.packed_rom_detail,dw.packed_bbox_table,dw.MAP_CENTER_X,dw.MAP_CENTER_Y,dw.PRESCALE)
sc=r.sc; sixops=[]; ENTRY={0x2003:'SOLID',0x2006:'TIGHT',0x201B:'TIGHT',0x2009:'GAP?'}
pend=[]
def prof_run(entry,max_cycles=10_000_000):
    m=sc.mpu; m.pc=entry; m.sp=0xFD; m.p=0x30; mem=m.memory; mem[0x01FF]=0xFE; mem[0x01FE]=0xFF; m.processorCycles=0
    for _ in range(max_cycles):
        pc=m.pc
        if pc==0xFF00: break
        if pc in ENTRY:
            t=ENTRY[pc]
            if t=='GAP?': pend.append((len(sixops), m.sp)); sixops.append(['GAP?',mem[0xC2],mem[0xC3],None])
            else: sixops.append([t,mem[0xC2],mem[0xC3]])
        # resolve has_gap result when its RTS returns (sp back above entry sp)
        for idx,esp in pend[:]:
            if m.sp>esp and sixops[idx][3] is None and m.pc!=ENTRY: pass
        m.step()
        for idx,esp in pend[:]:
            if m.sp>esp+1:
                sixops[idx][3]=int(m.a!=0); pend.remove((idx,esp))
    return m.processorCycles
sc._run=prof_run
r.render_frame(px,py,ab,dw.player_floor(px,py))
sixops=[tuple(o) for o in sixops]
# diff: first index where they differ
print(f"python ops={len(pyops)}  6502 ops={len(sixops)}")
n=min(len(pyops),len(sixops))
for i in range(n):
    if pyops[i]!=sixops[i]:
        print(f"FIRST DIVERGENCE at op #{i}:")
        for j in range(max(0,i-4),min(n,i+3)):
            mark='  <<<' if j==i else ''
            print(f"  [{j}] py={pyops[j]}  6502={sixops[j]}{mark}")
        break
else:
    print("common prefix identical; tails:")
    print("  py tail:", pyops[n:n+6]); print("  6502 tail:", sixops[n:n+6])
