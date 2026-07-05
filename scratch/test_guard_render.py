import os
os.environ.setdefault('SDL_VIDEODRIVER','dummy'); os.environ.setdefault('PYGAME_HIDE_SUPPORT_PROMPT','1')
import pygame; pygame.init()
import doom_wireframe as dw, fp, angle_bbox as A
from wad_packed import spans_init_full
import pygame.surfarray as sa
W,H=dw.FP_RENDER_W,dw.FP_RENDER_H
def render(px,py,ab):
    surf=pygame.Surface((W,H))
    px8=int((px-dw.MAP_CENTER_X)*256/dw.PRESCALE); py8=int((py-dw.MAP_CENTER_Y)*256/dw.PRESCALE)
    ctx=fp.fp_view_context(px8,py8,fp.fp_sincos(ab)); vz=dw._prescale_height(dw.player_floor(px,py)+41)
    cf=pygame.math.Vector2(1,0).rotate(ab*360/256).x; sf=pygame.math.Vector2(1,0).rotate(ab*360/256).y
    ram=bytearray(dw.packed_layout['ram_size']); spans_init_full(ram,dw.packed_layout['ram_spans'],W,H-1)
    dw.packed_render_bsp(len(dw.nodes)-1, dw.Instrumented6502Spans(), ctx, vz, px,py,cf,sf,surf,ram)
    return sa.array3d(surf).sum(2)>0
def diff(a,b): return int((a!=b).sum())
POS=[(1056,-3616,137),(1056,-3616,128),(994,-3291,237),(1056,-3328,14),(845,-3084,215),(1308,-3289,252),(1500,-3700,1)]
for (px,py,ab) in POS:
    dw._USE_ANGLE_BBOX=False; A._STRADDLE_FULL=False; truth=render(px,py,ab)   # corner-proj GT
    dw._USE_ANGLE_BBOX=True;  A._STRADDLE_FULL=False; ang0=render(px,py,ab)    # angle, no guard
    dw._USE_ANGLE_BBOX=True;  A._STRADDLE_FULL=True;  ang1=render(px,py,ab)    # angle + guard
    print(f"({px},{py},{ab}): angle-noguard vs truth={diff(ang0,truth):5d}px   angle-guard vs truth={diff(ang1,truth):5d}px")
