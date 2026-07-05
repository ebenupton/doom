import os
os.environ.setdefault('SDL_VIDEODRIVER','dummy'); os.environ.setdefault('PYGAME_HIDE_SUPPORT_PROMPT','1')
import pygame; pygame.init()
import numpy as np
import doom_wireframe as dw, fp, angle_bbox as A
from wad_packed import spans_init_full
W,H=dw.FP_RENDER_W,dw.FP_RENDER_H
ANG90=A.ANG90
# install guard by wrapping bbox_check_angle
_orig=A.bbox_check_angle
def guarded(top,bot,left,right,px,py,ab):
    if left<=px<=right and bot<=py<=top: return 0,A.VIS_W-1
    boxx=0 if px<=left else (1 if px<right else 2)
    boxy=0 if py>=top else (1 if py>bot else 2)
    cc=A._CHECKCOORD[(boxy<<2)+boxx]
    if cc is None: return 0,A.VIS_W-1
    val=(top,bot,left,right); a_fine=(ab*(A.FINEANGLES//256))&A.ANGMASK
    p1=A._phi(val[cc[0]],val[cc[1]],px,py,a_fine); p2=A._phi(val[cc[2]],val[cc[3]],px,py,a_fine)
    if abs(p1)>ANG90 or abs(p2)>ANG90:   # silhouette corner behind view plane -> straddle -> full
        return 0,A.VIS_W-1
    return _orig(top,bot,left,right,px,py,ab)
def render(px,py,ab,use_guard):
    A.bbox_check_angle = guarded if use_guard else _orig
    dw._USE_ANGLE_BBOX=True; dw._VIEW_AB=ab
    surf=pygame.Surface((W,H))
    px8=int((px-dw.MAP_CENTER_X)*256/dw.PRESCALE); py8=int((py-dw.MAP_CENTER_Y)*256/dw.PRESCALE)
    ctx=fp.fp_view_context(px8,py8,fp.fp_sincos(ab)); vz=dw._prescale_height(dw.player_floor(px,py)+41)
    cf=pygame.math.Vector2(1,0).rotate(ab*360/256).x; sf=pygame.math.Vector2(1,0).rotate(ab*360/256).y
    ram=bytearray(dw.packed_layout['ram_size']); spans_init_full(ram,dw.packed_layout['ram_spans'],W,H-1)
    dw.packed_render_bsp(len(dw.nodes)-1, dw.Instrumented6502Spans(), ctx, vz, px,py,cf,sf,surf,ram)
    return pygame.surfarray.array3d(surf).sum(2)>0
def corner(px,py,ab):
    A.bbox_check_angle=_orig; dw._USE_ANGLE_BBOX=False
    surf=pygame.Surface((W,H))
    px8=int((px-dw.MAP_CENTER_X)*256/dw.PRESCALE); py8=int((py-dw.MAP_CENTER_Y)*256/dw.PRESCALE)
    ctx=fp.fp_view_context(px8,py8,fp.fp_sincos(ab)); vz=dw._prescale_height(dw.player_floor(px,py)+41)
    cf=pygame.math.Vector2(1,0).rotate(ab*360/256).x; sf=pygame.math.Vector2(1,0).rotate(ab*360/256).y
    ram=bytearray(dw.packed_layout['ram_size']); spans_init_full(ram,dw.packed_layout['ram_spans'],W,H-1)
    dw.packed_render_bsp(len(dw.nodes)-1, dw.Instrumented6502Spans(), ctx, vz, px,py,cf,sf,surf,ram)
    return pygame.surfarray.array3d(surf).sum(2)>0
def disp(B,truth):  # B-only pixels far from any truth pixel in same column
    bad=0
    for x in range(W):
        ay=np.where(truth[x])[0]; bo=np.where(B[x]&~truth[x])[0]
        if len(bo)==0: continue
        d=np.full(len(bo),99) if len(ay)==0 else np.abs(ay[None,:]-bo[:,None]).min(axis=1)
        bad+=int((d>2).sum())
    return bad
POS=[(1056,-3616,137),(1056,-3616,128),(994,-3291,237),(1056,-3328,14),(845,-3084,215),(1308,-3289,252),(1500,-3700,1),(1024,-3500,65)]
for (px,py,ab) in POS:
    t=corner(px,py,ab); ng=render(px,py,ab,False); g=render(px,py,ab,True)
    print(f"({px},{py},{ab}): angle-noguard disp={disp(ng,t):4d}  angle+guard disp={disp(g,t):4d}")

# broad random sweep
import random
random.seed(1)
worst=0; nbad=0; N=40
for _ in range(N):
    px=random.randint(850,1450); py=random.randint(-3850,-3050); ab=random.randint(0,255)
    t=corner(px,py,ab); g=render(px,py,ab,True)
    d=disp(g,t)
    if d>2: nbad+=1; print(f"  REGRESSION ({px},{py},{ab}): disp={d}")
    worst=max(worst,d)
print(f"\nbroad sweep: {N} positions, worst disp={worst}, {nbad} with disp>2")
