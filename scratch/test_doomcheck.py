import os
os.environ.setdefault('SDL_VIDEODRIVER','dummy'); os.environ.setdefault('PYGAME_HIDE_SUPPORT_PROMPT','1')
import pygame; pygame.init()
import numpy as np, random
import doom_wireframe as dw, fp
from wad_packed import spans_init_full
W,H=dw.FP_RENDER_W,dw.FP_RENDER_H
def render(px,py,ab,angle):
    dw._USE_ANGLE_BBOX=angle; dw._VIEW_AB=ab
    surf=pygame.Surface((W,H))
    px8=int((px-dw.MAP_CENTER_X)*256/dw.PRESCALE); py8=int((py-dw.MAP_CENTER_Y)*256/dw.PRESCALE)
    ctx=fp.fp_view_context(px8,py8,fp.fp_sincos(ab)); vz=dw._prescale_height(dw.player_floor(px,py)+41)
    cf=pygame.math.Vector2(1,0).rotate(ab*360/256).x; sf=pygame.math.Vector2(1,0).rotate(ab*360/256).y
    ram=bytearray(dw.packed_layout['ram_size']); spans_init_full(ram,dw.packed_layout['ram_spans'],W,H-1)
    dw.packed_render_bsp(len(dw.nodes)-1, dw.Instrumented6502Spans(), ctx, vz, px,py,cf,sf,surf,ram)
    return pygame.surfarray.array3d(surf).sum(2)>0
def disp(B,t):  # both-direction displacement >2px
    bad=0
    for x in range(W):
        ay=np.where(t[x])[0]
        for B2,t2 in ((B,t),):
            bo=np.where(B[x]&~t[x])[0]
            if len(bo): bad+=int((np.full(len(bo),99) if len(ay)==0 else np.abs(ay[None,:]-bo[:,None]).min(axis=1))[lambda d:d>2].__len__() if False else (np.full(len(bo),99) if len(ay)==0 else np.abs(ay[None,:]-bo[:,None]).min(axis=1)>2).sum())
        # also truth-only far from B (missing lines)
        by=np.where(B[x])[0]; to=np.where(t[x]&~B[x])[0]
        if len(to): bad+=int((np.full(len(to),99) if len(by)==0 else np.abs(by[None,:]-to[:,None]).min(axis=1)>2).sum())
    return bad
known=[(1056,-3616,137),(1056,-3328,14),(955,-3735,222),(1354,-3748,95),(893,-3218,123),(973,-3367,239),(1056,-3616,128),(1500,-3700,1)]
for (px,py,ab) in known:
    t=render(px,py,ab,False); a=render(px,py,ab,True)
    print(f"({px},{py},{ab}): DOOM-angle vs corner disp={disp(a,t)}")
random.seed(3); worst=0; bad=[]
for _ in range(40):
    px=random.randint(850,1450); py=random.randint(-3850,-3050); ab=random.randint(0,255)
    t=render(px,py,ab,False); a=render(px,py,ab,True); d=disp(a,t)
    if d>2: bad.append((px,py,ab,d))
    worst=max(worst,d)
print(f"\nsweep(40): worst={worst}, bad={bad[:6]}")
