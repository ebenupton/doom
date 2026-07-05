import os
os.environ.setdefault('SDL_VIDEODRIVER','dummy'); os.environ.setdefault('PYGAME_HIDE_SUPPORT_PROMPT','1')
import pygame; pygame.init()
import numpy as np
import doom_wireframe as dw, fp
from fp import (PRESCALE,MAP_CENTER_X as MCX,MAP_CENTER_Y as MCY,NEAR_FP,
                fp_to_view,fp_recip,fp_project_x)
from wad_packed import spans_init_full
W,H=dw.FP_RENDER_W,dw.FP_RENDER_H
def lean_straddle(top,bot,left,right,ctx):
    corners=((left,top),(right,top),(right,bot),(left,bot))
    cols=[]
    for wx,wy in corners:
        _,evx,evy,_,eyi=fp_to_view(wx,wy,ctx)
        if evy>=NEAR_FP:
            rxh,rxl=fp_recip(eyi); cols.append(fp_project_x(evx,rxh,rxl))
        else:
            cols.append(0 if evx<0 else W-1)
    lo=max(0,min(cols)); hi=min(W-1,max(cols))
    return (lo,hi) if lo<=hi else None
# patch fp_bbox_visible_fixed straddle path to use lean rule
import doom_wireframe as dwmod
_orig=dwmod.fp_bbox_visible_fixed
import angle_bbox as A
def patched(node,side,ctx):
    base=4+side*4; rt,rb,rl,rr=node[base],node[base+1],node[base+2],node[base+3]
    top=(rt-MCY)//PRESCALE; bot=(rb-MCY)//PRESCALE; left=(rl-MCX)//PRESCALE; right=(rr-MCX)//PRESCALE
    px,py=ctx[0],ctx[1]
    if not dwmod._USE_ANGLE_BBOX: return _orig(node,side,ctx)
    if left<=px<=right and bot<=py<=top: return 0,W-1
    bx=0 if px<=left else (1 if px<right else 2); by=0 if py>=top else (1 if py>bot else 2)
    cc=A._CHECKCOORD[(by<<2)+bx]
    if cc is None: return 0,W-1
    vt=(top,bot,left,right); af=(dwmod._VIEW_AB*(A.FINEANGLES//256))&A.ANGMASK
    q1=A._phi(vt[cc[0]],vt[cc[1]],px,py,af); q2=A._phi(vt[cc[2]],vt[cc[3]],px,py,af)
    if abs(q1)>A.ANG90 or abs(q2)>A.ANG90:
        return lean_straddle(top,bot,left,right,ctx)   # LEAN fallback
    return A.bbox_check_angle(top,bot,left,right,px,py,dwmod._VIEW_AB)
def render(px,py,ab,mode):
    dwmod.fp_bbox_visible_fixed = patched if mode=='lean' else _orig
    dwmod._USE_ANGLE_BBOX=(mode=='lean'); dwmod._VIEW_AB=ab
    surf=pygame.Surface((W,H))
    px8=int((px-MCX)*256/PRESCALE); py8=int((py-MCY)*256/PRESCALE)
    ctx=fp.fp_view_context(px8,py8,fp.fp_sincos(ab)); vz=dw._prescale_height(dw.player_floor(px,py)+41)
    cf=pygame.math.Vector2(1,0).rotate(ab*360/256).x; sf=pygame.math.Vector2(1,0).rotate(ab*360/256).y
    ram=bytearray(dw.packed_layout['ram_size']); spans_init_full(ram,dw.packed_layout['ram_spans'],W,H-1)
    dw.packed_render_bsp(len(dw.nodes)-1, dw.Instrumented6502Spans(), ctx, vz, px,py,cf,sf,surf,ram)
    dwmod.fp_bbox_visible_fixed=_orig
    return pygame.surfarray.array3d(surf).sum(2)>0
def disp(B,t):
    bad=0
    for x in range(W):
        ay=np.where(t[x])[0]; bo=np.where(B[x]&~t[x])[0]
        if len(bo)==0: continue
        d=np.full(len(bo),99) if len(ay)==0 else np.abs(ay[None,:]-bo[:,None]).min(axis=1)
        bad+=int((d>2).sum())
    return bad
for (px,py,ab) in [(1056,-3616,137),(1056,-3328,14),(955,-3735,222),(1056,-3616,128)]:
    t=render(px,py,ab,'corner'); l=render(px,py,ab,'lean')
    print(f"({px},{py},{ab}): lean vs corner disp={disp(l,t)}")

import random
random.seed(11); worst=0; bad=[]
for _ in range(50):
    px=random.randint(850,1450); py=random.randint(-3850,-3050); ab=random.randint(0,255)
    t=render(px,py,ab,'corner'); l=render(px,py,ab,'lean'); d=disp(l,t)
    if d>2: bad.append((px,py,ab,d))
    worst=max(worst,d)
print(f"\nLEAN broad sweep (50 pos): worst={worst}, {len(bad)} disp>2: {bad[:8]}")
