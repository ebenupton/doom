import os
os.environ.setdefault('SDL_VIDEODRIVER','dummy'); os.environ.setdefault('PYGAME_HIDE_SUPPORT_PROMPT','1')
import pygame; pygame.init()
import numpy as np
import doom_wireframe as dw, fp
from wad_packed import spans_init_full
W,H=dw.FP_RENDER_W,dw.FP_RENDER_H
_orig=dw.fp_bbox_visible_fixed
def nocull(node,side,ctx): return 0, W-1     # never cull: rely purely on per-seg occlusion
def render(px,py,ab,mode):
    ss=[]
    o=dw.packed_render_subsector
    def p(idx,*a,**k): ss.append(idx); return o(idx,*a,**k)
    dw.packed_render_subsector=p
    dw.fp_bbox_visible_fixed = nocull if mode=='nocull' else _orig
    dw._USE_ANGLE_BBOX=False; dw._VIEW_AB=ab; surf=pygame.Surface((W,H))
    px8=int((px-dw.MAP_CENTER_X)*256/dw.PRESCALE); py8=int((py-dw.MAP_CENTER_Y)*256/dw.PRESCALE)
    ctx=fp.fp_view_context(px8,py8,fp.fp_sincos(ab)); vz=dw._prescale_height(dw.player_floor(px,py)+41)
    cf=pygame.math.Vector2(1,0).rotate(ab*360/256).x; sf=pygame.math.Vector2(1,0).rotate(ab*360/256).y
    ram=bytearray(dw.packed_layout['ram_size']); spans_init_full(ram,dw.packed_layout['ram_spans'],W,H-1)
    dw.packed_render_bsp(len(dw.nodes)-1, dw.Instrumented6502Spans(), ctx, vz, px,py,cf,sf,surf,ram)
    dw.fp_bbox_visible_fixed=_orig; dw.packed_render_subsector=o
    return pygame.surfarray.array3d(surf).sum(2)>0, len(set(ss))
def farpx(B,ref):
    n=0
    for x in range(W):
        ry=np.where(ref[x])[0]; bo=np.where(B[x]&~ref[x])[0]
        if len(bo): n+=int((np.full(len(bo),99) if len(ry)==0 else np.abs(ry[None,:]-bo[:,None]).min(axis=1)>2).sum())
    return n
for (px,py,ab) in [(1056,-3616,137),(955,-3735,222),(1056,-3616,128),(1500,-3700,1)]:
    t,tn=render(px,py,ab,'corner'); n,nn=render(px,py,ab,'nocull')
    print(f"({px},{py},{ab}): no-cull EXTRA over corner = {farpx(n,t)}px   MISSING = {farpx(t,n)}px   (ss corner={tn} nocull={nn})")
