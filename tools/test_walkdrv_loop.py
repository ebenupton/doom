"""The BANKED WALK DRIVER frame loop in py65, WALKING.

SHEILA stubs (cycle-accurate T1, vsync latch, keyboard with UP pressable),
real LOW/bank images.  After two settle frames UP is held; each frame's
DV pose is snapshotted at view_setup entry and the drawn frame must be
BIT-IDENTICAL to a model render at that exact pose.

History: the standing-only first cut of this gate let TWO driver bugs
hide: the plot-queue flip reset (drained stale garbage every frame) and
the missing fraction staging (zp_br_px/py moved absolute 2026-08-31,
the driver kept feeding the old zp cells = LC scratch, every walked
frame rendered with frac 0 -- the 8-world-unit camera snap Eben felt as
judder).  A vacuous-movement run FAILS."""
import os,sys
_ROOT=os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0,_ROOT); sys.path.insert(0,os.path.join(_ROOT,'tools'))
os.chdir(_ROOT)
os.environ.setdefault('SDL_VIDEODRIVER','dummy'); os.environ['PYGAME_HIDE_SUPPORT_PROMPT']='1'
import pygame; pygame.init(); pygame.display.set_mode((1,1))
import doom_wireframe as dw, abi, symmap
from banked_bsp import BankedBspRender, BANK_L0, BANK_C, BANK_L2
from banked_mem import BankedMemory
from span_clip_6502 import SpanClip6502

src=BankedBspRender(dw.packed_layout,dw.packed_rom_main,dw.packed_rom_detail,
                    dw.packed_bbox_table,dw.MAP_CENTER_X,dw.MAP_CENTER_Y,dw.PRESCALE)
L0=bytes(src.bm._banks[BANK_L0]); C=bytes(src.bm._banks[BANK_C]); L2=bytes(src.bm._banks[BANK_L2])
LOW=bytes(src.bm[abi.LOW_BASE:0x5800])

class HW(BankedMemory):
    def __init__(s,*a):
        super().__init__(*a); s.vs=0; s.mpu=None; s.key=0; s.up=False
    def _us(s):
        return s.mpu.processorCycles//2 if s.mpu else 0
    def _t1(s):
        return (19967-(s._us()%19968))&0xFFFF       # 19968us field clock
    def _t2(s):
        return (0x10000-(s._us()&0xFFFF))&0xFFFF    # free-running 1MHz
    def __setitem__(s,i,v):
        if isinstance(i,int) and i==0xFE4F: s.key=v
        super().__setitem__(i,v)
    def __getitem__(s,i):
        if isinstance(i,int):
            if i==0xFE4D:
                s.vs+=1
                return 2 if (s.vs%700)==0 else 0
            if i==0xFE44: return s._t1()&0xFF
            if i==0xFE45: return (s._t1()>>8)&0xFF
            if i==0xFE48: return s._t2()&0xFF
            if i==0xFE49: return (s._t2()>>8)&0xFF
            if i==0xFE4F: return 0x80 if (s.up and s.key==0x39) else 0
        return super().__getitem__(i)

sc=SpanClip6502()
m=HW([0]*65536)
m.define_bank(BANK_L0,L0); m.define_bank(BANK_C,C); m.define_bank(BANK_L2,L2)
for i,b in enumerate(LOW): m[abi.LOW_BASE+i]=b
m.select(BANK_L0)
sc.mpu.memory=m
mpu=sc.mpu; m.mpu=mpu
m[0xFFF4]=0xA2; m[0xFFF5]=0x01; m[0xFFF6]=0x60
VS=symmap.sym('view_setup',banked=1)
mpu.pc=abi.DRV_ORG; mpu.sp=0xDD; mpu.p=0x34
frames=0; steps=0; poses=[]; fbs=[]
while steps<80_000_000 and frames<8:
    if mpu.pc==VS:
        frames+=1
        if frames==3: m.up=True
        if frames>1:
            bh=m[0x0D11]                             # backhi = about-to-draw
            done=0x5800 if bh==0x6C else 0x6C00      # the completed frame
            fbs.append(bytes(m[done:done+0x1400]))
        poses.append((m[0x0D12]|m[0x0D13]<<8, m[0x0D15]|m[0x0D16]<<8))
    mpu.step(); steps+=1
print('poses:',[(hex(x),hex(y)) for x,y in poses])
if len(set(poses))<2:
    print('WALKDRV LOOP: FAIL (movement never engaged — vacuous gate)')
    sys.exit(1)
mdl=BankedBspRender(dw.packed_layout,dw.packed_rom_main,dw.packed_rom_detail,
                    dw.packed_bbox_table,dw.MAP_CENTER_X,dw.MAP_CENTER_Y,dw.PRESCALE)
PRE=8; ok=True
def s16(v): return v-0x10000 if v&0x8000 else v
for k,fb in enumerate(fbs):
    if k==0: continue
    px88,py88=poses[k]
    wx=(s16(px88)/256.0)*PRE+1200.0; wy=(s16(py88)/256.0)*PRE-3248.0
    mdl.render_frame(wx,wy,64,dw.player_floor(wx,wy))
    ref=bytes(mdl.bm[0x5800:0x6C00])
    d=sum(1 for i in range(5120) if fb[i]!=ref[i])
    print(f'driver frame {k+1} @({px88:04X},{py88:04X}) vs model: {d} diffs')
    if d: ok=False
print('WALKDRV LOOP: '+('PASS' if ok else 'FAIL'))
sys.exit(0 if ok else 1)
