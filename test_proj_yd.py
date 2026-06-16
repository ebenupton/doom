"""Unit-test 6502 proj_yd ($E94F) vs angle_seg.proj_y_delta (option-2b Y)."""
import os, sys
os.environ['SDL_VIDEODRIVER']='dummy'; os.environ['PYGAME_HIDE_SUPPORT_PROMPT']='1'
import pygame; pygame.init(); pygame.display.set_mode((1,1))
from span_clip_6502 import SpanClip6502
import doom_wireframe as dw, angle_seg as S
sc=SpanClip6502(); m=sc.mpu
code=open('bsp_render_ang.bin','rb').read()
for i,b in enumerate(code): m.memory[0xE940+i]=b
def s16(v): return v-65536 if v>=32768 else v
def proj_yd(hd, depth):
    m.memory[0x30]=hd&0xFF
    m.memory[0x46]=depth&0xFF; m.memory[0x47]=(depth>>8)&0xFF
    m.pc=0xE94F; m.sp=0xFD; m.memory[0x1FF]=0xFF; m.memory[0x1FE]=0xFF
    n=0
    while m.pc!=0 and n<3000: m.step(); n+=1
    return s16(m.memory[0x32]|(m.memory[0x33]<<8))
bad=n=0; exam=[]
# exhaustive over the real depth range and all hd in s8
for depth in list(range(11,300))+list(range(300,65536,257)):
    for hd in range(-128,128):
        got=proj_yd(hd, depth)
        exp=S.proj_y_delta(hd, depth)
        n+=1
        if got!=exp:
            bad+=1
            if len(exam)<8: exam.append((hd,depth,got,exp))
for e in exam: print("  hd,depth,got,exp =",e)
print(f"proj_yd: checked {n}, {bad} mismatches", "PASS" if bad==0 else "FAIL")
sys.exit(1 if bad else 0)
