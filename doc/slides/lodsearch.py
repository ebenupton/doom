"""Find one pose per (kind, tier) at which the billboard is drawn whole:
the pixel box must be exactly (2a+1) x (H+1), so nothing was clipped away.
Writes lod_specs.json for sprite.py, which does the canonical capture."""
import os, sys, json, math
sys.path.insert(0, os.getcwd()); sys.path.insert(0, os.path.join(os.getcwd(),'tools')); sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
os.environ.setdefault('SDL_VIDEODRIVER','dummy'); os.environ['PYGAME_HIDE_SUPPORT_PROMPT']='1'
import pygame; pygame.init(); pygame.display.set_mode((1,1))
import doom_wireframe as dw
from banked_bsp import BankedBspRender
from symmap import sym
S = lambda n: sym(n, banked=1)
OBJSLOT = S('obj_draw_slot'); OH, OA, OLOD, OASP = S('obj_h'), S('obj_a'), S('obj_lod'), S('obj_asp')
FB, FBLEN = 0x5800, 0x1400
r = BankedBspRender(dw.packed_layout, dw.packed_rom_main, dw.packed_rom_detail,
                    dw.packed_bbox_table, dw.MAP_CENTER_X, dw.MAP_CENTER_Y, dw.PRESCALE)
sc = r.sc; mpu = sc.mpu; mem = mpu.memory
KINDS = ('barrel','lamp','potion','helmet','stimpack','medikit','armour')
def grab(px, py, ab, kind):
    objs=[]
    def prof(entry, max_cycles=900000):
        mpu.pc=entry; mpu.sp=0xDD; mpu.p=0x30; mem[0x01DF]=0xFE; mem[0x01DE]=0xFF
        mpu.processorCycles=0; sc.last_lines=[]; plot=sc.PLOT_PCS
        sp=None; cur=None
        for _ in range(max_cycles):
            pc=mpu.pc
            if pc==0xFF00: break
            if pc in plot: sc.last_lines.append((0,0,0,0))
            if sp is not None and mpu.sp >= sp+2:
                cur['after']=bytes(mem[FB:FB+FBLEN])
                cur.update(H=mem[OH], a=mem[OA], lod=mem[OLOD], kind=KINDS[mem[OASP]] if mem[OASP]<7 else '?')
                objs.append(cur); sp=None; cur=None
            if pc == OBJSLOT and sp is None:
                sp=mpu.sp; cur=dict(before=bytes(mem[FB:FB+FBLEN]))
            mpu.step()
        sc.last_cycles=mpu.processorCycles; sc.total_cycles+=mpu.processorCycles
        return mpu.processorCycles
    sc._run=prof
    r.render_frame(px, py, ab, dw.player_floor(px, py))
    best=None
    for o in objs:
        if o['kind']!=kind: continue
        b,a=o['before'],o['after']; n=0; xs=[]; ys=[]
        for cy in range(20):
            for col in range(32):
                base=cy*32*8+col*8
                for pr in range(8):
                    y=cy*8+pr
                    if y>=160: break
                    diff=a[base+pr] & ~b[base+pr]
                    if diff:
                        for bit in range(8):
                            if diff & (0x80>>bit): xs.append(col*8+bit); ys.append(y)
        if not xs: continue
        o['n']=len(xs); o['box']=(min(xs),min(ys),max(xs),max(ys))
        if best is None or o['n']>best['n']: best=o
    return best
names={0:'barrel',1:'lamp',2:'potion',3:'helmet',4:'stimpack',5:'medikit',6:'armour'}
objs=[]
for th in list(dw.things)+dw._ADDED_THINGS:
    tx,ty,ta,tt,fl=th
    if tt not in dw._OBJ_KINDS or (fl&0x10) or (tt,tx,ty) in dw._ARMOUR_ROOM_DROP: continue
    objs.append((names[dw._OBJ_KINDS[tt][2]],tx,ty))
# tiers wanted per kind (lamp and potion are single-tier), and the distances to try
# far-tier distances ascend from just outside the switch, so the far art is
# caught at its LARGEST size: same height as the near art, different shape
WANT={'barrel':{0:(130,136,142,150),1:(120,110,100)}, 'helmet':{0:(430,445,460,480),1:(200,160,140)},
      'stimpack':{0:(160,168,176,190),1:(110,100,90)}, 'medikit':{0:(330,340,352,370),1:(200,170,150)},
      'armour':{0:(152,158,165,175),1:(120,110,100)}, 'lamp':{0:(300,260,360)}, 'potion':{0:(150,180,120)}}
DIRS=[(0,-1,64),(0,1,192),(-1,0,0),(1,0,128)]   # stand S/N/W/E of it, face it (0=E, 64=N)
specs=[]; log=open(sys.argv[1]+'.log','w')
for kind,tiers in WANT.items():
    for tier,dists in tiers.items():
        found=None
        for (kk,tx,ty) in objs:
            if kk!=kind or found: continue
            for d in dists:
                if found: break
                for (ux,uy,ab) in DIRS:
                    px,py=tx+ux*d,ty+uy*d
                    try: g=grab(px,py,ab,kind)
                    except Exception as e: g=None
                    ok = g and g['lod']==tier and g['box'][2]-g['box'][0]+1==2*g['a']+1 and g['box'][3]-g['box'][1]+1==g['H']+1
                    msg=f"{kind} tier{tier} thing({tx},{ty}) d={d} ab={ab} -> " + (f"H={g['H']} a={g['a']} lod={g['lod']} box={g['box']} n={g['n']}" if g else 'none') + (' OK' if ok else '')
                    print(msg); log.write(msg+'\n'); log.flush()
                    if ok:
                        found=dict(name=f"{kind}_{'near' if tier else 'far'}", x=px, y=py, ab=ab, kind=kind); break
        if found: specs.append(found)
        else: print('MISSING', kind, tier); log.write(f'MISSING {kind} {tier}\n')
json.dump(specs, open(sys.argv[1],'w'), indent=1); print('wrote', len(specs))
