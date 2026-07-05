import os
os.environ.setdefault('SDL_VIDEODRIVER','dummy'); os.environ.setdefault('PYGAME_HIDE_SUPPORT_PROMPT','1')
import pygame; pygame.init()
import doom_wireframe as dw, fp
from wad_packed import spans_init_full, NODE_SIZE, read_u16
W,H=dw.FP_RENDER_W,dw.FP_RENDER_H
NF=dw.NF_SUBSECTOR; rom=dw._p_rom_main; lay=dw._p_layout
def children(nid):
    off=lay['off_nodes']+nid*NODE_SIZE
    return read_u16(rom,off+8), read_u16(rom,off+10)   # (right,left)
def subtree_ss(nid):
    acc=set(); st=[nid]
    while st:
        n=st.pop()
        if n & NF: acc.add(0 if n==0xFFFF else n&0x7FFF)
        else:
            r,l=children(n); st.append(r); st.append(l)
    return acc
def setup(px,py,ab):
    px8=int((px-dw.MAP_CENTER_X)*256/dw.PRESCALE); py8=int((py-dw.MAP_CENTER_Y)*256/dw.PRESCALE)
    ctx=fp.fp_view_context(px8,py8,fp.fp_sincos(ab)); vz=dw._prescale_height(dw.player_floor(px,py)+41)
    cf=pygame.math.Vector2(1,0).rotate(ab*360/256).x; sf=pygame.math.Vector2(1,0).rotate(ab*360/256).y
    ram=bytearray(lay['ram_size']); spans_init_full(ram,lay['ram_spans'],W,H-1)
    return ctx,vz,cf,sf,ram
def traced_walk(nid, clips, ctx, vz, wx,wy, cf,sf, surf, ram, prunes, visited):
    if clips.is_full(): return
    if nid & NF:
        ss=0 if nid==0xFFFF else nid&0x7FFF; visited.append(ss)
        dw.packed_render_subsector(ss, clips, ctx, vz, surf, ram); return
    r,l=children(nid); node=dw.nodes[nid]; side=dw.point_on_side(wx,wy,node); ch=(r,l)
    for s in (side, side^1):
        if clips.is_full(): return
        br=dw.fp_bbox_visible_fixed(node, s, ctx)
        if br is None: prunes.append((ch[s],'frustum'))
        elif not clips.has_gap(br[0],br[1]): prunes.append((ch[s],'occlusion'))
        else: traced_walk(ch[s], clips, ctx, vz, wx,wy, cf,sf, surf, ram, prunes, visited)
def nocull_visit(px,py,ab):
    ctx,vz,cf,sf,ram=setup(px,py,ab); dw._USE_ANGLE_BBOX=False; dw._VIEW_AB=ab
    seen=[]
    o=dw.fp_bbox_visible_fixed; dw.fp_bbox_visible_fixed=lambda n,s,c:(0,W-1)
    op=dw.packed_render_subsector
    def p(idx,*a,**k): seen.append(idx); return op(idx,*a,**k)
    dw.packed_render_subsector=p
    surf=pygame.Surface((W,H))
    dw.packed_render_bsp(len(dw.nodes)-1, dw.Instrumented6502Spans(), ctx, vz, px,py,cf,sf,surf,ram)
    dw.fp_bbox_visible_fixed=o; dw.packed_render_subsector=op
    return set(seen)
for (px,py,ab) in [(955,-3735,222),(1500,-3700,1)]:
    ctx,vz,cf,sf,ram=setup(px,py,ab); dw._USE_ANGLE_BBOX=False; dw._VIEW_AB=ab
    surf=pygame.Surface((W,H)); prunes=[]; vis=[]
    traced_walk(len(dw.nodes)-1, dw.Instrumented6502Spans(), ctx,vz, px,py, cf,sf, surf, ram, prunes, vis)
    cornerss=set(vis); nocss=nocull_visit(px,py,ab)
    extra=nocss-cornerss
    # map each prune subtree
    fr=set(); oc=set()
    for (cnid,reason) in prunes:
        sub=subtree_ss(cnid)
        if reason=='frustum': fr|=sub
        else: oc|=sub
    extra_frustum=extra & fr; extra_occ=extra & oc
    print(f"({px},{py},{ab}): corner ss={len(cornerss)} nocull ss={len(nocss)} extra={len(extra)}")
    print(f"   prunes: {sum(1 for _,r in prunes if r=='frustum')} frustum, {sum(1 for _,r in prunes if r=='occlusion')} occlusion")
    print(f"   extra subsectors under FRUSTUM prunes: {len(extra_frustum)}   under OCCLUSION prunes: {len(extra_occ)}   neither: {len(extra-extra_frustum-extra_occ)}")
