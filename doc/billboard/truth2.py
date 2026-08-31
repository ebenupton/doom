"""Walk up to a barrel until it leaves LOD, and capture the OCT template."""
import os, sys
ROOT='/Users/ebenupton/doom'; sys.path.insert(0,ROOT); sys.path.insert(0,os.path.join(ROOT,'tools'))
os.environ.setdefault('SDL_VIDEODRIVER','dummy'); os.environ['PYGAME_HIDE_SUPPORT_PROMPT']='1'
import pygame; pygame.init()
import doom_wireframe as dw
from banked_bsp import BankedBspRender
from symmap import sym
r=BankedBspRender(dw.packed_layout,dw.packed_rom_main,dw.packed_rom_detail,
                  dw.packed_bbox_table,dw.MAP_CENTER_X,dw.MAP_CENTER_Y,dw.PRESCALE)
mpu=r.sc.mpu; mem=mpu.memory
E=sym('obj_stamp',banked=1); OE=sym('obj_e',banked=1); OI=sym('obj_i',banked=1)
OX=sym('obj_X',banked=1); OY=sym('obj_Y',banked=1)
OA=sym('obj_a',banked=1); OB=sym('obj_b',banked=1); OASP=sym('obj_asp',banked=1)
OCX=sym('obj_cx_l',banked=1); OYT=sym('obj_yt_l',banked=1); OYB=sym('obj_yb_l',banked=1)
ART=sym('OBJ_ART',banked=1); ENT=sym('render_frame',banked=1)
def s16(a):
    v=mem[a]|(mem[a+1]<<8); return v-0x10000 if v>=0x8000 else v
BX,BY=1312,-3264
best=None
for dist in (96,104,112,120,128,136,144,152,160,176,192,208,224,256,288):
    vx,vy = BX+dist, BY
    try: fl=dw.player_floor(vx,vy)
    except Exception: continue
    r.render_frame(vx,vy,128,fl); r.sc.init(); r.sc.clear_screen()
    mpu.pc=ENT; mpu.sp=0xDD; mpu.p=0x30
    mem[0x01DF]=0xFE; mem[0x01DE]=0xFF; k=0
    while mpu.pc!=0xFF00 and k<3_000_000:
        if mpu.pc==E and mem[OE] in (0,100) and (mem[OASP]&0x7F)==23:
            e=mem[OE]; a=mem[OA]
            art=[]; q=ART+e
            while mem[q]!=0xFF:
                art.append((mem[q],mem[q+1],mem[q+2],mem[q+3])); q+=4
            rec=dict(d=dist,off=e,a=a,b=mem[OB],
                     X=[s16(OX+2*j) for j in range(6)],
                     Y=[s16(OY+2*j) for j in range(12)],
                     cx=s16(OCX), yt=s16(OYT), yb=s16(OYB), art=art)
            print(f'  d={dist:4d}  tmpl={"OCT" if e==0 else "HEX"}  a={a:3d} b={rec["b"]:2d}'
                  f'  H={rec["yb"]-rec["yt"]:4d}')
            if e==100 and (best is None or a>best['a']): best=rec
            break
        mpu.step(); k+=1
if best:
    print(f'\nHEX captured at d={best["d"]}, a={best["a"]}, b={best["b"]}, '
          f'H={best["yb"]-best["yt"]}, {len(best["art"])} entries')
    print('  X =',best['X']); print('  Y =',best['Y'])
    import json
    json.dump(best, open('/private/tmp/claude-501/-Users-ebenupton-doom/8cb45dec-e81d-4776-b295-d7274ede90ff/scratchpad/hex.json','w'))
    for (a1,b1,c1,d1) in best['art']:
        if a1==0xFE: print('   -- ARM --'); continue
        print(f'   x{a1//2:<2d} y{b1//2:<2d} -> x{c1//2:<2d} y{d1//2:<2d}')
else:
    print('\nno HEX stamp captured')
