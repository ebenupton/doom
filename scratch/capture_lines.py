import os,sys
os.environ.setdefault('SDL_VIDEODRIVER','dummy'); os.environ.setdefault('PYGAME_HIDE_SUPPORT_PROMPT','1')
import pygame; pygame.init()
import doom_wireframe as dw, fp
from bsp_render_6502 import BspRender6502
from wad_packed import spans_init_full
px,py,ab=1056,-3616,137
W,H=dw.FP_RENDER_W,dw.FP_RENDER_H

# --- Python capture ---
pylines=[]
class Rec(dw.Instrumented6502Spans):
    def draw_clipped(self, lines, color, surface, stats=None, roles=None):
        for seg in lines:
            pylines.append(tuple(int(round(v)) for v in (seg[0],seg[1],seg[2],seg[3])))
        return super().draw_clipped(lines,color,surface,stats,roles)
surf=pygame.Surface((W,H))
px8=int((px-dw.MAP_CENTER_X)*256/dw.PRESCALE); py8=int((py-dw.MAP_CENTER_Y)*256/dw.PRESCALE)
ctx=fp.fp_view_context(px8,py8,fp.fp_sincos(ab)); vz=dw._prescale_height(dw.player_floor(px,py)+41)
cf=pygame.math.Vector2(1,0).rotate(ab*360/256).x; sf=pygame.math.Vector2(1,0).rotate(ab*360/256).y
ram=bytearray(dw.packed_layout['ram_size']); spans_init_full(ram,dw.packed_layout['ram_spans'],W,H-1)
dw.packed_render_bsp(len(dw.nodes)-1, Rec(), ctx, vz, px, py, cf, sf, surf, ram)

# --- 6502 capture (hook rasteriser entry $A900) ---
r=BspRender6502(dw.packed_layout,dw.packed_rom_main,dw.packed_rom_detail,dw.packed_bbox_table,dw.MAP_CENTER_X,dw.MAP_CENTER_Y,dw.PRESCALE)
sc=r.sc; sixlines=[]
def prof_run(entry,max_cycles=10_000_000):
    m=sc.mpu; m.pc=entry; m.sp=0xFD; m.p=0x30; mem=m.memory; mem[0x01FF]=0xFE; mem[0x01FE]=0xFF; m.processorCycles=0
    for _ in range(max_cycles):
        if m.pc==0xFF00: break
        if m.pc==0xA900:
            sixlines.append((mem[0x82],mem[0x83],mem[0x84],mem[0x85]))
        m.step()
    return m.processorCycles
sc._run=prof_run
r.render_frame(px,py,ab,dw.player_floor(px,py))

def norm(l):  # canonical: order endpoints
    a=(l[0],l[1]); b=(l[2],l[3]); return (a,b) if a<=b else (b,a)
ps=set(map(norm,pylines)); ss=set(map(norm,sixlines))
print(f"python lines={len(pylines)} (uniq {len(ps)})  6502 lines={len(sixlines)} (uniq {len(ss)})")
extra=sorted(ss-ps); missing=sorted(ps-ss)
print(f"\n6502-ONLY (extra, over-drawn) {len(extra)}:")
for l in extra[:40]: print("  ",l)
print(f"\nPYTHON-ONLY (missing in 6502) {len(missing)}:")
for l in missing[:20]: print("  ",l)
