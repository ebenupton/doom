"""Isolate one billboard's own pixels, with the tier and geometry it used."""
import os, sys, json
sys.path.insert(0, os.getcwd()); sys.path.insert(0, os.path.join(os.getcwd(),'tools')); sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
os.environ.setdefault('SDL_VIDEODRIVER','dummy'); os.environ['PYGAME_HIDE_SUPPORT_PROMPT']='1'
import pygame; pygame.init(); pygame.display.set_mode((1,1))
import doom_wireframe as dw
from banked_bsp import BankedBspRender
from symmap import sym
from fbdec import decode
S = lambda n: sym(n, banked=1)
OBJSLOT = S('obj_draw_slot')
OH, OA, OLOD, OASP = S('obj_h'), S('obj_a'), S('obj_lod'), S('obj_asp')
FB, FBLEN = 0x5800, 0x1400
r = BankedBspRender(dw.packed_layout, dw.packed_rom_main, dw.packed_rom_detail,
                    dw.packed_bbox_table, dw.MAP_CENTER_X, dw.MAP_CENTER_Y, dw.PRESCALE)
sc = r.sc; mpu = sc.mpu; mem = mpu.memory
KINDS = ('barrel','lamp','potion','helmet','stimpack','medikit','armour')
def grab(px, py, ab, want_index=0, kind=None):
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
                cur.update(H=mem[OH], a=mem[OA], lod=mem[OLOD],
                           kind=KINDS[mem[OASP]] if mem[OASP] < 7 else '?')
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
        b, a = o['before'], o['after']
        pxs=[]
        for cy in range(20):
            for col in range(32):
                base=cy*32*8+col*8
                for pr in range(8):
                    y=cy*8+pr
                    if y>=160: break
                    diff=a[base+pr] & ~b[base+pr]
                    for bit in range(8):
                        if diff & (0x80>>bit): pxs.append((col*8+bit, y))
        if not pxs: continue
        o['px']=pxs
        xs=[p[0] for p in pxs]; ys=[p[1] for p in pxs]
        o['box']=(min(xs), min(ys), max(xs), max(ys))
        if kind is not None and o['kind'] != kind: continue
        if best is None or len(pxs) > len(best['px']): best=o
    return best

for spec in json.load(open(sys.argv[1])):
    g = grab(spec['x'], spec['y'], spec['ab'], spec.get('i', 0), spec.get('kind'))
    if not g: print(f"MISS {spec['name']}"); continue
    x0,y0,x1,y1 = g['box']
    print(f"SPR {spec['name']:16s} kind={g['kind']:9s} tier={'NEAR' if g['lod'] else 'far '} "
          f"H={g['H']:3d} a={g['a']:3d} box={x1-x0+1}x{y1-y0+1} px={len(g['px'])}")
    json.dump(dict(name=spec['name'], kind=g['kind'], lod=g['lod'], H=g['H'], a=g['a'],
                   box=g['box'], px=g['px']), open(f"{sys.argv[2]}/spr_{spec['name']}.json", 'w'))
