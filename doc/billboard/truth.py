"""GROUND TRUTH: the barrel art the engine really draws.

Read OBJ_ART's bytes out of the built image and obj_X / obj_Y out of a live
render at the moment a barrel is stamped, then decode exactly as the stamp
walker does.  No reconstruction from source.
"""
import os, sys, collections
ROOT='/Users/ebenupton/doom'; sys.path.insert(0,ROOT); sys.path.insert(0,os.path.join(ROOT,'tools'))
os.environ.setdefault('SDL_VIDEODRIVER','dummy'); os.environ['PYGAME_HIDE_SUPPORT_PROMPT']='1'
import pygame; pygame.init()
import doom_wireframe as dw, compare_renders as C
from banked_bsp import BankedBspRender, BANK_C
from symmap import sym
r=BankedBspRender(dw.packed_layout,dw.packed_rom_main,dw.packed_rom_detail,
                  dw.packed_bbox_table,dw.MAP_CENTER_X,dw.MAP_CENTER_Y,dw.PRESCALE)
mpu=r.sc.mpu; mem=mpu.memory
# there is no obj_art_hex label -- the hex path falls through into the
# dispatch, which stores the TEMPLATE OFFSET in obj_e.  Break at the stamp
# loop and read that instead.
E_STAMP=sym('obj_stamp',banked=1); OE=sym('obj_e',banked=1)
OX=sym('obj_X',banked=1); OY=sym('obj_Y',banked=1); OI=sym('obj_i',banked=1)
OA=sym('obj_a',banked=1); OB=sym('obj_b',banked=1); OASP=sym('obj_asp',banked=1)
ART=sym('OBJ_ART',banked=1)
def s16(a): 
    v=mem[a]|(mem[a+1]<<8); return v-0x10000 if v>=0x8000 else v
entry=sym('render_frame',banked=1)

def grab(px,py,ab):
    r.render_frame(px,py,ab,dw.player_floor(px,py))
    r.sc.init(); r.sc.clear_screen()
    mpu.pc=entry; mpu.sp=0xDD; mpu.p=0x30
    mem[0x01DF]=0xFE; mem[0x01DE]=0xFF; k=0; out=[]
    while mpu.pc!=0xFF00 and k<3_000_000:
        if mpu.pc==E_STAMP and mem[OE] in (0,76,100):
            e=mem[OE]; i=mem[OI]; asp=mem[OASP]
            X=[s16(OX+2*j) for j in range(6)]
            Y=[s16(OY+2*j) for j in range(12)]
            art=[]
            q=ART+e
            while True:
                b0=mem[q]
                if b0==0xFF: break
                art.append((b0,mem[q+1],mem[q+2],mem[q+3])); q+=4
            out.append(dict(off=e, idx=i, a=mem[OA], b=mem[OB], asp=asp,
                            X=X, Y=Y, art=art))
        mpu.step(); k+=1
    return out

hits=[]
for pose in C.POSITIONS:
    hits += grab(*pose)
    if len(hits)>=60: break
seen={}
for h in hits:
    seen.setdefault(h['off'],[]).append(h)
print(f'{len(hits)} stamps, template offsets seen: {sorted(seen)}')
import json
for off in sorted(seen):
    ex=max(seen[off], key=lambda h:h['a'])
    if off==100:
        json.dump(ex, open('/private/tmp/claude-501/-Users-ebenupton-doom/8cb45dec-e81d-4776-b295-d7274ede90ff/scratchpad/hexcap.json','w'))
    print(f'\n=== OBJ_ART offset {off}  ({len(seen[off])} stamps)  '
          f'best a={ex["a"]} b={ex["b"]} k={ex["asp"]&0x7F} '
          f'art_bit={(ex["asp"]>>7)&1}  {len(ex["art"])} entries')
    print('   X =', ex['X'])
    print('   Y =', ex['Y'])
    for (a1,b1,c1,d1) in ex['art']:
        if a1==0xFE: print('   -- ARM --'); continue
        print(f'   x{a1//2} y{b1//2} -> x{c1//2} y{d1//2}')
