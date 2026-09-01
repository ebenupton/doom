"""The BANKED WALK DRIVER frame loop in py65 — SHEILA stubs (vsync latch,
timers, keyboard), real LOW/bank images, frames must be BIT-IDENTICAL to
the model render.  THE GATE the 2026-09-01 plot-queue flip-reset bug
demanded: the flip's stale LDA#0/STA $A0 made every frame's first
enqueue wrap the count-down queue to FULL and the pump drain 63 slots
of stale garbage — visible here as a persistent 1-byte FB diff (pixel
0,0) that jsbeeb rendered as DFS-junk line spray."""
import os,sys
import os as _o
_ROOT=_o.path.dirname(_o.path.dirname(_o.path.abspath(__file__)))
sys.path.insert(0,_ROOT); sys.path.insert(0,_o.path.join(_ROOT,'tools'))
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
    """SHEILA stubs: vsync latch $FE4D bit1 fires every read-count window;
    timers count down; keyboard reads = not pressed; ROMSEL via base class."""
    def __init__(s,*a):
        super().__init__(*a); s.vs_ctr=0; s.t1=0x3000
    def __getitem__(s,i):
        if isinstance(i,int):
            if i==0xFE4D:
                s.vs_ctr+=1
                return 2 if (s.vs_ctr % 50000)==0 else 0   # latch fires periodically
            if i==0xFE44: s.t1=(s.t1-7)&0xFFFF; return s.t1&0xFF
            if i==0xFE45: return (s.t1>>8)&0xFF
            if i==0xFE48: return 0x00
            if i==0xFE49: return 0x40
            if i==0xFE4F: return 0x00                    # no key (bit7 clear)
        return super().__getitem__(i)

sc=SpanClip6502()
m=HW([0]*65536)
m.define_bank(BANK_L0,L0); m.define_bank(BANK_C,C); m.define_bank(BANK_L2,L2)
for i,b in enumerate(LOW): m[abi.LOW_BASE+i]=b
m.select(BANK_L0)
sc.mpu.memory=m
mpu=sc.mpu

# stub the one OS call (OSBYTE read-version at $FFF4): LDX #1 / RTS
m[0xFFF4]=0xA2; m[0xFFF5]=0x01; m[0xFFF6]=0x60

DRV=abi.DRV_ORG
mpu.pc=DRV; mpu.sp=0xDD; mpu.p=0x34
frames=0; steps=0
VS=symmap.sym('view_setup',banked=1)
fbs=[]
while steps<40_000_000 and frames<4:
    pc=mpu.pc
    if pc==VS:
        frames+=1
        if frames>1: fbs.append(bytes(m[0x5800:0x6C00]))  # previous frame's draw
    mpu.step(); steps+=1
print('frames rendered:',frames,'steps',steps)
q=bytes(m[0x800:0x900])
bad=[(i,(q[i],q[64+i],q[128+i],q[192+i])) for i in range(64)
     if q[64+i]>159 or q[192+i]>159]
print('bad queue slots:',bad[:6])
# compare last full frame vs model ab=64
mdl=BankedBspRender(dw.packed_layout,dw.packed_rom_main,dw.packed_rom_detail,
                    dw.packed_bbox_table,dw.MAP_CENTER_X,dw.MAP_CENTER_Y,dw.PRESCALE)
mdl.render_frame(1056,-3616,64,dw.player_floor(1056,-3616))
model=bytes(mdl.bm[0x5800:0x6C00])
ok=True
for k,fb in enumerate(fbs):
    d=sum(1 for i in range(5120) if fb[i]!=model[i])
    print(f'driver frame {k+1} vs model: {d} diffs')
    if k>0 and d: ok=False        # frame 1 is the warmup snapshot
print('WALKDRV LOOP: ' + ('PASS' if ok else 'FAIL'))
sys.exit(0 if ok else 1)
