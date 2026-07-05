import os
os.environ.setdefault('SDL_VIDEODRIVER','dummy'); os.environ.setdefault('PYGAME_HIDE_SUPPORT_PROMPT','1')
import pygame; pygame.init()
import doom_wireframe as dw, fp
from wad_packed import spans_init_full
px,py,ab=1056,-3616,137; W,H=dw.FP_RENDER_W,dw.FP_RENDER_H
nodes=dw.nodes
calls=[]
orig=dw.fp_bbox_visible_fixed
def patched(node, far_side, ctx):
    r=orig(node, far_side, ctx)
    try: nid=nodes.index(node)
    except: nid=-1
    base=4+far_side*4
    calls.append((nid,far_side,node[base],node[base+1],node[base+2],node[base+3],r))
    return r
dw.fp_bbox_visible_fixed=patched
spans=dw.Instrumented6502Spans(); surf=pygame.Surface((W,H))
px8=int((px-dw.MAP_CENTER_X)*256/dw.PRESCALE); py8=int((py-dw.MAP_CENTER_Y)*256/dw.PRESCALE)
ctx=fp.fp_view_context(px8,py8,fp.fp_sincos(ab)); vz=dw._prescale_height(dw.player_floor(px,py)+41)
cf=pygame.math.Vector2(1,0).rotate(ab*360/256).x; sf=pygame.math.Vector2(1,0).rotate(ab*360/256).y
ram=bytearray(dw.packed_layout['ram_size']); spans_init_full(ram,dw.packed_layout['ram_spans'],W,H-1)
dw.packed_render_bsp(len(dw.nodes)-1, spans, ctx, vz, px,py,cf,sf,surf,ram)
print("px_int,py_int =",ctx[0],ctx[1])
print("idx  nid side  rt   rb   rl   rr   -> br")
for i,c in enumerate(calls[:14]):
    print(f"{i:3d} {c[0]:4d} {c[1]:2d}  {c[2]:5d}{c[3]:5d}{c[4]:5d}{c[5]:5d}  -> {c[6]}")
