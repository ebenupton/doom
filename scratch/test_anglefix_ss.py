import os
os.environ.setdefault('SDL_VIDEODRIVER','dummy'); os.environ.setdefault('PYGAME_HIDE_SUPPORT_PROMPT','1')
import pygame; pygame.init()
import doom_wireframe as dw, fp
from wad_packed import spans_init_full
W,H=dw.FP_RENDER_W,dw.FP_RENDER_H
def ss_set(px,py,ab,angle):
    dw._USE_ANGLE_BBOX=angle; dw._VIEW_AB=ab
    seen=[]
    o=dw.packed_render_subsector
    def p(idx,*a,**k): seen.append(idx); return o(idx,*a,**k)
    dw.packed_render_subsector=p
    surf=pygame.Surface((W,H))
    px8=int((px-dw.MAP_CENTER_X)*256/dw.PRESCALE); py8=int((py-dw.MAP_CENTER_Y)*256/dw.PRESCALE)
    ctx=fp.fp_view_context(px8,py8,fp.fp_sincos(ab)); vz=dw._prescale_height(dw.player_floor(px,py)+41)
    cf=pygame.math.Vector2(1,0).rotate(ab*360/256).x; sf=pygame.math.Vector2(1,0).rotate(ab*360/256).y
    ram=bytearray(dw.packed_layout['ram_size']); spans_init_full(ram,dw.packed_layout['ram_spans'],W,H-1)
    dw.packed_render_bsp(len(dw.nodes)-1, dw.Instrumented6502Spans(), ctx, vz, px,py,cf,sf,surf,ram)
    dw.packed_render_subsector=o
    return set(seen)
bad=0; tot=0
for px in range(950,1250,50):
  for py in range(-3750,-3350,50):
    for ab in range(0,256,4):
        c=ss_set(px,py,ab,False)   # corner = truth
        a=ss_set(px,py,ab,True)    # angle (fixed)
        tot+=1
        if c!=a:
            bad+=1
            if bad<=8: print(f"  ({px},{py},{ab}): corner={sorted(c)} angle_extra={sorted(a-c)} angle_missing={sorted(c-a)}")
print(f"\nss-set mismatches: {bad}/{tot}")
# specific target
print("137:", "corner", sorted(ss_set(1056,-3616,137,False)), "angle", sorted(ss_set(1056,-3616,137,True)))
