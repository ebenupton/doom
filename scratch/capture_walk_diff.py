import os
os.environ.setdefault('SDL_VIDEODRIVER','dummy'); os.environ.setdefault('PYGAME_HIDE_SUPPORT_PROMPT','1')
import pygame; pygame.init()
import doom_wireframe as dw, fp
from wad_packed import spans_init_full
px,py,ab=1056,-3616,137; W,H=dw.FP_RENDER_W,dw.FP_RENDER_H
nodes=dw.nodes
def run():
    dec=[]; ss=[]
    of=dw.fp_bbox_visible_fixed
    def pf(node,side,ctx):
        r=of(node,side,ctx)
        try: nid=nodes.index(node)
        except: nid=-1
        dec.append([nid,side,r,None]); return r
    dw.fp_bbox_visible_fixed=pf
    osub=dw.packed_render_subsector
    def ps(idx,*a,**k): ss.append(idx); return osub(idx,*a,**k)
    dw.packed_render_subsector=ps
    surf=pygame.Surface((W,H))
    px8=int((px-dw.MAP_CENTER_X)*256/dw.PRESCALE); py8=int((py-dw.MAP_CENTER_Y)*256/dw.PRESCALE)
    ctx=fp.fp_view_context(px8,py8,fp.fp_sincos(ab)); vz=dw._prescale_height(dw.player_floor(px,py)+41)
    cf=pygame.math.Vector2(1,0).rotate(ab*360/256).x; sf=pygame.math.Vector2(1,0).rotate(ab*360/256).y
    ram=bytearray(dw.packed_layout['ram_size']); spans_init_full(ram,dw.packed_layout['ram_spans'],W,H-1)
    dw.packed_render_bsp(len(dw.nodes)-1, dw.Instrumented6502Spans(), ctx, vz, px,py,cf,sf,surf,ram)
    dw.fp_bbox_visible_fixed=of; dw.packed_render_subsector=osub
    return dec,ss
import angle_bbox
dw._USE_ANGLE_BBOX=False; cdec,css=run()      # corner = truth
dw._USE_ANGLE_BBOX=True;  adec,ass=run()       # angle = 6502 behavior
print("corner ss:",css)
print("angle  ss:",ass[:25],"..." if len(ass)>25 else "")
print("angle-only ss (leaked):", sorted(set(ass)-set(css)))
# diff the bbox-decision streams (nid,side,br) -> first where has_gap-relevant differs
print("\nbbox-decision divergences (nid,side, corner_br, angle_br):")
n=min(len(cdec),len(adec)); shown=0
for i in range(n):
    c=cdec[i]; a=adec[i]
    if c[0]!=a[0] or c[1]!=a[1]:
        print(f"  STREAM SPLIT at {i}: corner=({c[0]},{c[1]}) angle=({a[0]},{a[1]})"); break
    cg=c[2] is not None; ag=a[2] is not None
    # descend decision hinges on has_gap(br); approximate: None=cull, else maybe-descend
    if (c[2] is None)!=(a[2] is None):
        print(f"  #{i} nid={c[0]} side={c[1]}: corner={c[2]} angle={a[2]}  <-- cull/visible DIFFERS"); shown+=1
        if shown>=10: break
