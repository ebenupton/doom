import os
os.environ.setdefault('SDL_VIDEODRIVER','dummy'); os.environ.setdefault('PYGAME_HIDE_SUPPORT_PROMPT','1')
import pygame; pygame.init()
import numpy as np
import doom_wireframe as dw, fp
from wad_packed import spans_init_full, NODE_SIZE, read_u16
from fp import fp_to_view, PRESCALE, MAP_CENTER_X as MCX, MAP_CENTER_Y as MCY
W,H=dw.FP_RENDER_W,dw.FP_RENDER_H; NF=dw.NF_SUBSECTOR; rom=dw._p_rom_main; lay=dw._p_layout
px,py,ab=973,-3367,239
def children(nid):
    off=lay['off_nodes']+nid*NODE_SIZE; return read_u16(rom,off+8), read_u16(rom,off+10)
def subtree_ss(nid):
    acc=set(); st=[nid]
    while st:
        n=st.pop()
        if n&NF: acc.add(0 if n==0xFFFF else n&0x7FFF)
        else: r,l=children(n); st+=[r,l]
    return acc
def setup():
    px8=int((px-MCX)*256/PRESCALE); py8=int((py-MCY)*256/PRESCALE)
    ctx=fp.fp_view_context(px8,py8,fp.fp_sincos(ab)); vz=dw._prescale_height(dw.player_floor(px,py)+41)
    cf=pygame.math.Vector2(1,0).rotate(ab*360/256).x; sf=pygame.math.Vector2(1,0).rotate(ab*360/256).y
    ram=bytearray(lay['ram_size']); spans_init_full(ram,lay['ram_spans'],W,H-1)
    return ctx,vz,cf,sf,ram
def traced(nid,clips,ctx,vz,cf,sf,surf,ram,prunes,vis):
    if clips.is_full(): return
    if nid&NF:
        ss=0 if nid==0xFFFF else nid&0x7FFF; vis.append(ss)
        dw.packed_render_subsector(ss,clips,ctx,vz,surf,ram); return
    r,l=children(nid); node=dw.nodes[nid]; side=dw.point_on_side(px,py,node); ch=(r,l)
    for s in (side,side^1):
        if clips.is_full(): return
        br=dw.fp_bbox_visible_fixed(node,s,ctx)
        if br is None: prunes.append((ch[s],'frustum'))
        elif not clips.has_gap(br[0],br[1]): prunes.append((ch[s],'occlusion'))
        else: traced(ch[s],clips,ctx,vz,cf,sf,surf,ram,prunes,vis)
def render(bbfn):
    dw.fp_bbox_visible_fixed=bbfn; dw._USE_ANGLE_BBOX=False; dw._VIEW_AB=ab
    ctx,vz,cf,sf,ram=setup(); surf=pygame.Surface((W,H))
    dw.packed_render_bsp(len(dw.nodes)-1,dw.Instrumented6502Spans(),ctx,vz,px,py,cf,sf,surf,ram)
    return pygame.surfarray.array3d(surf).sum(2)>0
def far(B,ref):
    n=0
    for x in range(W):
        ry=np.where(ref[x])[0]; bo=np.where(B[x]&~ref[x])[0]
        if len(bo): n+=int((np.full(len(bo),99) if len(ry)==0 else np.abs(ry[None,:]-bo[:,None]).min(axis=1)>2).sum())
    return n
_orig=dw.fp_bbox_visible_fixed
ref=render(_orig)
nocull=render(lambda n,s,c:(0,W-1))
print(f"973 no-cull vs corner-proj:  EXTRA={far(nocull,ref)}  MISSING={far(ref,nocull)}")
# categorize the prunes corner-proj makes
dw.fp_bbox_visible_fixed=_orig; ctx,vz,cf,sf,ram=setup(); surf=pygame.Surface((W,H))
prunes=[]; vis=[]
traced(len(dw.nodes)-1,dw.Instrumented6502Spans(),ctx,vz,cf,sf,surf,ram,prunes,vis)
# nocull visited set
dw.fp_bbox_visible_fixed=lambda n,s,c:(0,W-1)
seen=[]; op=dw.packed_render_subsector
def p(idx,*a,**k): seen.append(idx); return op(idx,*a,**k)
dw.packed_render_subsector=p; ctx,vz,cf,sf,ram=setup(); surf=pygame.Surface((W,H))
dw.packed_render_bsp(len(dw.nodes)-1,dw.Instrumented6502Spans(),ctx,vz,px,py,cf,sf,surf,ram)
dw.packed_render_subsector=op; dw.fp_bbox_visible_fixed=_orig
extra=set(seen)-set(vis)
fr=set(); oc=set()
for cnid,reason in prunes:
    sub=subtree_ss(cnid)
    if reason=='frustum': fr|=sub
    else: oc|=sub
print(f"corner visited={len(set(vis))} nocull visited={len(set(seen))} extra={len(extra)}")
print(f"prunes: {sum(1 for _,r in prunes if r=='frustum')} frustum, {sum(1 for _,r in prunes if r=='occlusion')} occlusion")
print(f"extra subsectors under FRUSTUM prunes={len(extra&fr)}  under OCCLUSION prunes={len(extra&oc)}  neither={len(extra-fr-oc)}")
