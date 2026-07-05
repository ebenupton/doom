import os
os.environ.setdefault('SDL_VIDEODRIVER','dummy'); os.environ.setdefault('PYGAME_HIDE_SUPPORT_PROMPT','1')
import pygame; pygame.init()
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
    if all(evx+evy<0 for (evx,evy) in pts): return None
    if all(evx>evy for (evx,evy) in pts): return None
    return 0, W-1
px,py,ab=973,-3367,239
seg_subsec={}  # si -> subsector
op=dw.packed_render_subsector
def wrap_ss(idx,*a,**k):
    before=set(dw._seg2b_debug.keys()) if dw._seg2b_debug is not None else set()
    r=op(idx,*a,**k)
    if dw._seg2b_debug is not None:
        for si in set(dw._seg2b_debug.keys())-before: seg_subsec[si]=idx
    return r
def run(mode):
    global seg_subsec
    seg_subsec={}
    dw._seg2b_debug={}
    dw.packed_render_subsector=wrap_ss
    dw.fp_bbox_visible_fixed = halfplane if mode=='hp' else _orig
    dw._USE_ANGLE_BBOX=False; dw._VIEW_AB=ab; surf=pygame.Surface((W,H))
    px8=int((px-MCX)*256/PRESCALE); py8=int((py-MCY)*256/PRESCALE)
    ctx=fp.fp_view_context(px8,py8,fp.fp_sincos(ab)); vz=dw._prescale_height(dw.player_floor(px,py)+41)
    cf=pygame.math.Vector2(1,0).rotate(ab*360/256).x; sf=pygame.math.Vector2(1,0).rotate(ab*360/256).y
    ram=bytearray(dw.packed_layout['ram_size']); spans_init_full(ram,dw.packed_layout['ram_spans'],W,H-1)
    dw.packed_render_bsp(len(dw.nodes)-1, dw.Instrumented6502Spans(), ctx, vz, px,py,cf,sf,surf,ram)
    dw.packed_render_subsector=op; dw.fp_bbox_visible_fixed=_orig
    d=dict(dw._seg2b_debug); ss=dict(seg_subsec); dw._seg2b_debug=None
    return d, ss
hp,hpss=run('hp'); cp,cpss=run('corner')
hpsub=set(hpss.values()); cpsub=set(cpss.values())
print(f"half-plane visited {len(hpsub)} subsectors, corner {len(cpsub)}, extra={len(hpsub-cpsub)}")
# segs with extreme projected columns (over-extension), in half-plane render
ext=[(si,d[0],d[1],hpss.get(si)) for si,d in hp.items() if (abs(d[0])>400 or abs(d[1])>400)]
ext.sort(key=lambda t:-max(abs(t[1]),abs(t[2])))
print(f"\nsegs projecting to extreme columns (|sx|>400) in half-plane render: {len(ext)}")
for si,sx1,sx2,ssid in ext[:12]:
    pruned = "PRUNED by corner-proj" if ssid not in cpsub else "(also in corner)"
    print(f"  si={si} subsec={ssid} sx1={sx1} sx2={sx2}   {pruned}")

# of the EXTRA (over-traversed) subsectors, which segs mark ON-SCREEN columns?
extra_sub = hpsub - cpsub
print(f"\nON-SCREEN marking segs in the {len(extra_sub)} over-traversed subsectors:")
onscreen=[]
for si,(sx1,sx2) in hp.items():
    ss=hpss.get(si)
    if ss in extra_sub:
        lo=max(0,min(sx1,sx2)); hi=min(255,max(sx1,sx2))
        if lo<=hi: onscreen.append((si,ss,lo,hi,sx1,sx2))
onscreen.sort(key=lambda t:-(t[3]-t[2]))
for si,ss,lo,hi,sx1,sx2 in onscreen[:15]:
    print(f"  si={si} subsec={ss} on-screen cols [{lo},{hi}] (raw sx {sx1},{sx2})")
print(f"  total on-screen-marking segs in over-traversed subsectors: {len(onscreen)}")
# how does corner-proj's box extent for those subsectors compare? show a couple parents

# ---- no-cull run: visit everything ----
def run_nocull():
    global seg_subsec
    seg_subsec={}; dw._seg2b_debug={}
    dw.packed_render_subsector=wrap_ss
    dw.fp_bbox_visible_fixed=lambda n,s,c:(0,W-1)
    dw._USE_ANGLE_BBOX=False; dw._VIEW_AB=ab; surf=pygame.Surface((W,H))
    px8=int((px-MCX)*256/PRESCALE); py8=int((py-MCY)*256/PRESCALE)
    ctx=fp.fp_view_context(px8,py8,fp.fp_sincos(ab)); vz=dw._prescale_height(dw.player_floor(px,py)+41)
    cf=pygame.math.Vector2(1,0).rotate(ab*360/256).x; sf=pygame.math.Vector2(1,0).rotate(ab*360/256).y
    ram=bytearray(dw.packed_layout['ram_size']); spans_init_full(ram,dw.packed_layout['ram_spans'],W,H-1)
    dw.packed_render_bsp(len(dw.nodes)-1, dw.Instrumented6502Spans(), ctx, vz, px,py,cf,sf,surf,ram)
    dw.packed_render_subsector=op; dw.fp_bbox_visible_fixed=_orig
    d=dict(dw._seg2b_debug); ss=dict(seg_subsec); dw._seg2b_debug=None
    return d,ss
nc,ncss=run_nocull()
ncsub=set(ncss.values())
rejected = ncsub - hpsub      # subsectors no-cull visits but HALF-PLANE rejects
print(f"\nno-cull visited {len(ncsub)}; half-plane rejected {len(rejected)} of them")
print("ON-SCREEN occluders inside HALF-PLANE-REJECTED subsectors (the lost occluders):")
lost=[]
for si,(sx1,sx2) in nc.items():
    ss=ncss.get(si)
    if ss in rejected:
        lo=max(0,min(sx1,sx2)); hi=min(255,max(sx1,sx2))
        straddle = (abs(sx1)>300) != (abs(sx2)>300)   # one endpoint near-clipped to extreme
        if lo<=hi: lost.append((si,ss,lo,hi,sx1,sx2,straddle))
lost.sort(key=lambda t:-(t[3]-t[2]))
for si,ss,lo,hi,sx1,sx2,st in lost[:12]:
    tag=" <-- NEAR-STRADDLE SWING" if st else ""
    print(f"  si={si} rejected-subsec={ss} marks on-screen [{lo},{hi}] (raw {sx1},{sx2}){tag}")
print(f"  total on-screen occluders lost to half-plane reject: {len(lost)}  ({sum(1 for x in lost if x[6])} near-straddle)")
