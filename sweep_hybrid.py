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
def disp(B,t):
    bad=0
    for x in range(W):
        ay=np.where(t[x])[0]; bo=np.where(B[x]&~t[x])[0]
        if len(bo)==0: continue
        d=np.full(len(bo),99) if len(ay)==0 else np.abs(ay[None,:]-bo[:,None]).min(axis=1)
        bad+=int((d>2).sum())
    return bad
random.seed(7); N=60; worst=0; bad=[]
for _ in range(N):
    px=random.randint(850,1450); py=random.randint(-3850,-3050); ab=random.randint(0,255)
    t=render(px,py,ab,False); h=render(px,py,ab,True)
    d=disp(h,t)
    if d>2: bad.append((px,py,ab,d))
    worst=max(worst,d)
print(f"hybrid vs corner over {N} random positions: worst disp={worst}, {len(bad)} with disp>2")
for b in sorted(bad,key=lambda x:-x[3])[:10]: print("  ",b)
