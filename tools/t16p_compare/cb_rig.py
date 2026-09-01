import os,sys
sys.path.insert(0,'/Users/ebenupton/doom'); sys.path.insert(0,'/Users/ebenupton/doom/tools')
os.environ.setdefault('SDL_VIDEODRIVER','dummy'); os.environ['PYGAME_HIDE_SUPPORT_PROMPT']='1'
import pygame; pygame.init(); pygame.display.set_mode((1,1))
import doom_wireframe as dw, compare_renders as C
from banked_bsp import BankedBspRender
from symmap import sym
r=BankedBspRender(dw.packed_layout,dw.packed_rom_main,dw.packed_rom_detail,
                  dw.packed_bbox_table,dw.MAP_CENTER_X,dw.MAP_CENTER_Y,dw.PRESCALE)
sc=r.sc; mpu=sc.mpu; mem=mpu.memory
URD=sym('umul_round_div',banked=1); UDIV=sym('udiv16_8',banked=1); UM8=sym('umul8',banked=1)
E=sym('render_frame',banked=1)
cb=[]; um=[]
orig=sc._run
def wrap(entry,max_cycles=10_000_000):
    if entry!=E: return orig(entry,max_cycles)
    mpu.pc=entry; mpu.sp=0xDD; mpu.p=0x30
    mem[0x1DF]=0xFE; mem[0x1DE]=0xFF
    mpu.processorCycles=0
    while mpu.pc!=0xFF00:
        if mpu.pc==URD:
            dy=mpu.a; off=mem[0xD9]; den=mem[0xDC]; c0=mpu.processorCycles; n=0
            while not (mpu.pc==UDIV or mpu.pc<0x8300 or mpu.pc>=0x8500):
                mpu.step(); n+=1
                if n>400: raise RuntimeError('URD bracket runaway pc=%04x'%mpu.pc)
            cb.append((dy,off,den,mpu.processorCycles-c0,mem[0xDA]|mem[0xDB]<<8))
            continue
        if mpu.pc==UM8:
            sp=mpu.sp; ret=((mem[0x101+sp]|mem[0x102+sp]<<8)+1)&0xFFFF
            dy=mpu.a; off=mem[0xD9]; c0=mpu.processorCycles; n=0
            while mpu.pc!=ret:
                mpu.step(); n+=1
                if n>400: break
            if n<=400:
                um.append((ret,dy,off,mpu.processorCycles-c0,mem[0xDA]|mem[0xDB]<<8))
            continue
        mpu.step()
    return mpu.processorCycles
sc._run=wrap
import sys as _s
for _i,(px,py,ab) in enumerate(C.POSITIONS):
    print('frame',_i,file=_s.stderr)
    r.render_frame(px,py,ab,dw.player_floor(px,py))
N=len(C.POSITIONS)
print('umul_round_div: calls',len(cb),'cyc',sum(c[3] for c in cb),
      '(%.1f/call, %.0f/frame)'%(sum(c[3] for c in cb)/max(1,len(cb)),sum(c[3] for c in cb)/N))
badp=sum(1 for dy,off,den,cyc,p in cb if p!=((dy*off+den//2)&0xFFFF))
print('  prod check vs python:',badp,'bad;  dy histogram top:',
      sorted(__import__('collections').Counter(c[0] for c in cb).items(),key=lambda kv:-kv[1])[:6])
chg_dy=sum(1 for i in range(len(cb)) if i==0 or cb[i][0]!=cb[i-1][0])
chg_off=sum(1 for i in range(len(cb)) if i==0 or cb[i][1]!=cb[i-1][1])
print('  bakes if keyed on dy:',chg_dy,' on off:',chg_off)
from collections import Counter
print('umul8 by ret site:',{hex(k):(v,sum(x[3] for x in um if x[0]==k)) for k,v in Counter(u[0] for u in um).items()})

# ---- variant replay ----
from py65.devices.mpu6502 import MPU
lbl={}
for ln in open('/private/tmp/claude-501/-Users-ebenupton-doom/8cb45dec-e81d-4776-b295-d7274ede90ff/scratchpad/cb/cbvar.lbl'):
    p=ln.split()
    if len(p)>=3: lbl[p[2].lstrip('.')]=int(p[1],16)
bmem=[0]*65536
for u in range(512):
    v=(u*u)//4
    bmem[0x200+u]=v&0xFF; bmem[0x400+u]=v>>8
for i in range(1,511):
    v=(abs(i-256)**2)//4
    bmem[0x600+i]=v&0xFF; bmem[0x800+i]=v>>8
img=open('/private/tmp/claude-501/-Users-ebenupton-doom/8cb45dec-e81d-4776-b295-d7274ede90ff/scratchpad/cb/cbvar.bin','rb').read()
bmem[0x2000:0x2000+len(img)]=list(img)
b=MPU(memory=bmem)
def run(entry,stop):
    b.pc=entry; b.p=0x30; b.processorCycles=0; n=0
    while b.pc!=stop:
        b.step(); n+=1
        assert n<500
    return b.processorCycles
tot_body=0; tot_bake=0; bakes=0; bad=0; curM=None
for dy,off,den,cyc,p in cb:
    assert 1<=dy<=255
    if dy!=curM:
        b.a=dy; tot_bake+=run(lbl['cb_bake'],lbl['cb_bdone']); bakes+=1; curM=dy
    bmem[0xD9]=off; bmem[0xDC]=den
    tot_body+=run(lbl['cb_body'],lbl['cb_done'])
    if (bmem[0xDA]|bmem[0xDB]<<8)!=((dy*off+den//2)&0xFFFF): bad+=1
cur=sum(c[3] for c in cb)
var=tot_body+tot_bake
print('variant: mismatches',bad,' body',tot_body,' bake',tot_bake,'(%d bakes)'%bakes)
print('CB VERDICT: current %d -> variant %d  = %+d/frame (%.1f -> %.1f/call)'%(
      cur,var,(var-cur)//N,cur/len(cb),var/len(cb)))
