import os
os.environ.setdefault('SDL_VIDEODRIVER','dummy'); os.environ.setdefault('PYGAME_HIDE_SUPPORT_PROMPT','1')
import pygame; pygame.init()
import numpy as np, random
import doom_wireframe as dw, fp
from fp import fp_to_view, PRESCALE, MAP_CENTER_X as MCX, MAP_CENTER_Y as MCY
from wad_packed import spans_init_full
W,H=dw.FP_RENDER_W,dw.FP_RENDER_H
_orig=dw.fp_bbox_visible_fixed
def halfplane(node,side,ctx):
    base=4+side*4; rt,rb,rl,rr=node[base],node[base+1],node[base+2],node[base+3]
    top=(rt-MCY)//PRESCALE; bot=(rb-MCY)//PRESCALE; left=(rl-MCX)//PRESCALE; right=(rr-MCX)//PRESCALE
    px,py=ctx[0],ctx[1]
    if left<=px<=right and bot<=py<=top: return 0,W-1
    pts=[fp_to_view(wx,wy,ctx)[1:3] for (wx,wy) in ((left,top),(right,top),(right,bot),(left,bot))]
    if all(evx+evy<0 for (evx,evy) in pts): return None    # all outside LEFT edge plane
    if all(evx>evy  for (evx,evy) in pts): return None    # all outside RIGHT edge plane
    return 0, W-1                                           # otherwise: full (no near-plane reject)
def render(px,py,ab,mode):
    dw.fp_bbox_visible_fixed = halfplane if mode=='hp' else _orig
    dw._USE_ANGLE_BBOX=False; dw._VIEW_AB=ab; surf=pygame.Surface((W,H))
    px8=int((px-MCX)*256/PRESCALE); py8=int((py-MCY)*256/PRESCALE)
    ctx=fp.fp_view_context(px8,py8,fp.fp_sincos(ab)); vz=dw._prescale_height(dw.player_floor(px,py)+41)
    cf=pygame.math.Vector2(1,0).rotate(ab*360/256).x; sf=pygame.math.Vector2(1,0).rotate(ab*360/256).y
    ram=bytearray(dw.packed_layout['ram_size']); spans_init_full(ram,dw.packed_layout['ram_spans'],W,H-1)
    dw.packed_render_bsp(len(dw.nodes)-1, dw.Instrumented6502Spans(), ctx, vz, px,py,cf,sf,surf,ram)
    dw.fp_bbox_visible_fixed=_orig
    return pygame.surfarray.array3d(surf).sum(2)>0
def far(B,ref):
    n=0
    for x in range(W):
        ry=np.where(ref[x])[0]; bo=np.where(B[x]&~ref[x])[0]
        if len(bo): n+=int((np.full(len(bo),99) if len(ry)==0 else np.abs(ry[None,:]-bo[:,None]).min(axis=1)>2).sum())
    return n
for (px,py,ab) in [(1056,-3616,137),(1056,-3328,14),(955,-3735,222),(1354,-3748,95),(893,-3218,123),(973,-3367,239),(1056,-3616,128),(1500,-3700,1)]:
    ref=render(px,py,ab,'corner'); hp=render(px,py,ab,'hp')
    print(f"({px},{py},{ab}): halfplane-reject+FULL vs corner  EXTRA={far(hp,ref)} MISSING={far(ref,hp)}")
random.seed(7); worst=0; bad=0
for _ in range(40):
    px=random.randint(850,1450); py=random.randint(-3850,-3050); ab=random.randint(0,255)
    ref=render(px,py,ab,'corner'); hp=render(px,py,ab,'hp'); d=max(far(hp,ref),far(ref,hp))
    if d>2: bad+=1
    worst=max(worst,d)
print(f"sweep(40): worst={worst}, {bad} bad")
