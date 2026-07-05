import os
os.environ.setdefault('SDL_VIDEODRIVER','dummy'); os.environ.setdefault('PYGAME_HIDE_SUPPORT_PROMPT','1')
import pygame; pygame.init()
import numpy as np
import doom_wireframe as dw, fp, angle_bbox as A
from wad_packed import spans_init_full
W,H=dw.FP_RENDER_W,dw.FP_RENDER_H
_orig=dw.fp_bbox_visible_fixed
def full_straddle(node,side,ctx):
    from fp import PRESCALE,MAP_CENTER_X as MCX,MAP_CENTER_Y as MCY
    base=4+side*4; rt,rb,rl,rr=node[base],node[base+1],node[base+2],node[base+3]
    top=(rt-MCY)//PRESCALE; bot=(rb-MCY)//PRESCALE; left=(rl-MCX)//PRESCALE; right=(rr-MCX)//PRESCALE
    px,py=ctx[0],ctx[1]
    if left<=px<=right and bot<=py<=top: return 0,W-1
    bx=0 if px<=left else (1 if px<right else 2); by=0 if py>=top else (1 if py>bot else 2)
    cc=A._CHECKCOORD[(by<<2)+bx]
    if cc is None: return 0,W-1
    vt=(top,bot,left,right); af=(dw._VIEW_AB*(A.FINEANGLES//256))&A.ANGMASK
    q1=A._phi(vt[cc[0]],vt[cc[1]],px,py,af); q2=A._phi(vt[cc[2]],vt[cc[3]],px,py,af)
    if abs(q1)>A.ANG90 or abs(q2)>A.ANG90: return 0,W-1     # straddle -> FULL (most conservative)
    return A.bbox_check_angle(top,bot,left,right,px,py,dw._VIEW_AB)
def render(px,py,ab,mode):
    ss=[]
    o=dw.packed_render_subsector
    def p(idx,*a,**k): ss.append(idx); return o(idx,*a,**k)
    dw.packed_render_subsector=p
    if mode=='full': dw.fp_bbox_visible_fixed=full_straddle; dw._USE_ANGLE_BBOX=True
    else: dw.fp_bbox_visible_fixed=_orig; dw._USE_ANGLE_BBOX=False
    dw._VIEW_AB=ab; surf=pygame.Surface((W,H))
    px8=int((px-dw.MAP_CENTER_X)*256/dw.PRESCALE); py8=int((py-dw.MAP_CENTER_Y)*256/dw.PRESCALE)
    ctx=fp.fp_view_context(px8,py8,fp.fp_sincos(ab)); vz=dw._prescale_height(dw.player_floor(px,py)+41)
    cf=pygame.math.Vector2(1,0).rotate(ab*360/256).x; sf=pygame.math.Vector2(1,0).rotate(ab*360/256).y
    ram=bytearray(dw.packed_layout['ram_size']); spans_init_full(ram,dw.packed_layout['ram_spans'],W,H-1)
    dw.packed_render_bsp(len(dw.nodes)-1, dw.Instrumented6502Spans(), ctx, vz, px,py,cf,sf,surf,ram)
    dw.fp_bbox_visible_fixed=_orig; dw.packed_render_subsector=o
    return pygame.surfarray.array3d(surf).sum(2)>0, set(ss)
px,py,ab=955,-3735,222
t,tss=render(px,py,ab,'corner'); f,fss=render(px,py,ab,'full')
def farpx(B,ref):
    n=0
    for x in range(W):
        ry=np.where(ref[x])[0]; bo=np.where(B[x]&~ref[x])[0]
        if len(bo): n+=int((np.full(len(bo),99) if len(ry)==0 else np.abs(ry[None,:]-bo[:,None]).min(axis=1)>2).sum())
    return n
print(f"222 full-straddle: EXTRA(over-draw)={farpx(f,t)}px  MISSING(under)={farpx(t,f)}px")
print(f"subsectors: corner={len(tss)}  full={len(fss)}  full-only(extra descents)={sorted(fss-tss)}  corner-only={sorted(tss-fss)}")
