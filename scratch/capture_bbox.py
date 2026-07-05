import os
os.environ.setdefault('SDL_VIDEODRIVER','dummy'); os.environ.setdefault('PYGAME_HIDE_SUPPORT_PROMPT','1')
import pygame; pygame.init()
import doom_wireframe as dw, fp, angle_bbox
from wad_packed import spans_init_full
px,py,ab=1056,-3616,137; W,H=dw.FP_RENDER_W,dw.FP_RENDER_H
calls=[]
orig=angle_bbox.bbox_check_angle
def patched(top,bot,left,right,pxi,pyi,view_ab):
    r=orig(top,bot,left,right,pxi,pyi,view_ab)
    calls.append((top,bot,left,right,pxi,pyi,view_ab,r))
    return r
angle_bbox.bbox_check_angle=patched
spans=dw.Instrumented6502Spans()
surf=pygame.Surface((W,H))
px8=int((px-dw.MAP_CENTER_X)*256/dw.PRESCALE); py8=int((py-dw.MAP_CENTER_Y)*256/dw.PRESCALE)
ctx=fp.fp_view_context(px8,py8,fp.fp_sincos(ab)); vz=dw._prescale_height(dw.player_floor(px,py)+41)
cf=pygame.math.Vector2(1,0).rotate(ab*360/256).x; sf=pygame.math.Vector2(1,0).rotate(ab*360/256).y
ram=bytearray(dw.packed_layout['ram_size']); spans_init_full(ram,dw.packed_layout['ram_spans'],W,H-1)
dw.packed_render_bsp(len(dw.nodes)-1, spans, ctx, vz, px,py,cf,sf,surf,ram)
print(f"VIEW_AB={calls[0][6] if calls else '?'}  total bbox checks={len(calls)}")
print("idx  top  bot left right  px   py  -> br")
for i,c in enumerate(calls[:16]):
    print(f"{i:3d} {c[0]:5d}{c[1]:5d}{c[2]:5d}{c[3]:5d}  {c[4]:4d} {c[5]:4d}  -> {c[7]}")
