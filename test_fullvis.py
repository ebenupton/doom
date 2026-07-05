import os
os.environ.setdefault('SDL_VIDEODRIVER','dummy'); os.environ.setdefault('PYGAME_HIDE_SUPPORT_PROMPT','1')
import pygame; pygame.init()
import numpy as np, random
import doom_wireframe as dw, fp
from wad_packed import spans_init_full
W,H=dw.FP_RENDER_W,dw.FP_RENDER_H
def render(px,py,ab,angle):
    dw._USE_ANGLE_BBOX=angle; dw._VIEW_AB=ab; surf=pygame.Surface((W,H))
    px8=int((px-dw.MAP_CENTER_X)*256/dw.PRESCALE); py8=int((py-dw.MAP_CENTER_Y)*256/dw.PRESCALE)
    ctx=fp.fp_view_context(px8,py8,fp.fp_sincos(ab)); vz=dw._prescale_height(dw.player_floor(px,py)+41)
    cf=pygame.math.Vector2(1,0).rotate(ab*360/256).x; sf=pygame.math.Vector2(1,0).rotate(ab*360/256).y
    ram=bytearray(dw.packed_layout['ram_size']); spans_init_full(ram,dw.packed_layout['ram_spans'],W,H-1)
    dw.packed_render_bsp(len(dw.nodes)-1, dw.Instrumented6502Spans(), ctx, vz, px,py,cf,sf,surf,ram)
    return pygame.surfarray.array3d(surf).sum(2)>0
def far(B,ref):
    n=0
    for x in range(W):
        ry=np.where(ref[x])[0]; bo=np.where(B[x]&~ref[x])[0]
        if len(bo): n+=int((np.full(len(bo),99) if len(ry)==0 else np.abs(ry[None,:]-bo[:,None]).min(axis=1)>2).sum())
    return n
for (px,py,ab) in [(1056,-3616,137),(1056,-3328,14),(955,-3735,222),(1354,-3748,95),(893,-3218,123),(973,-3367,239),(1056,-3616,128),(1500,-3700,1)]:
    t=render(px,py,ab,False); a=render(px,py,ab,True)
    print(f"({px},{py},{ab}): full-vis EXTRA={far(a,t)} MISSING={far(t,a)}")
random.seed(5); worst=0; bad=0
for _ in range(40):
    px=random.randint(850,1450); py=random.randint(-3850,-3050); ab=random.randint(0,255)
    t=render(px,py,ab,False); a=render(px,py,ab,True); d=max(far(a,t),far(t,a))
    if d>2: bad+=1
    worst=max(worst,d)
print(f"sweep(40): worst={worst}, {bad} bad")
