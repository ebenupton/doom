"""Unit-test 6502 seg_c ($E952) vs angle_seg c = round((cross<<4)/L)."""
import os, sys
os.environ['SDL_VIDEODRIVER']='dummy'; os.environ['PYGAME_HIDE_SUPPORT_PROMPT']='1'
import pygame; pygame.init(); pygame.display.set_mode((1,1))
from span_clip_6502 import SpanClip6502
import doom_wireframe as dw, angle_seg as S
sc=SpanClip6502(); m=sc.mpu
code=open('bsp_render_ang.bin','rb').read()
for i,b in enumerate(code): m.memory[0xE940+i]=b
def s16(v): return v-65536 if v>=32768 else v
def w16(a,v): m.memory[a]=v&0xFF; m.memory[a+1]=(v>>8)&0xFF
def seg_c(dy1,dx1,ldx,ldy,L):
    w16(0x32,dy1); w16(0x34,dx1); m.memory[0x36]=ldx&0xFF; m.memory[0x37]=ldy&0xFF; m.memory[0x38]=L&0xFF
    m.pc=0xE952; m.sp=0xFD; m.memory[0x1FF]=0xFF; m.memory[0x1FE]=0xFF
    n=0
    while m.pc!=0 and n<5000: m.step(); n+=1
    return s16(m.memory[0x30]|(m.memory[0x31]<<8))
bad=n=0; exam=[]
for (px,py,ab) in [(1056,-3616,a) for a in range(0,256,8)]+[(1024,-3500,65),(800,-3400,96),(1500,-3700,1),(1200,-3000,129)]:
    pxi=int((px-dw.MAP_CENTER_X)/dw.PRESCALE);pyi=int((py-dw.MAP_CENTER_Y)/dw.PRESCALE)
    for svwh in dw.fp_segs_vwh:
        sg=svwh[0];v1=dw.fp_vertexes[sg[0]];v2=dw.fp_vertexes[sg[1]]
        ldx,ldy=v2[0]-v1[0],v2[1]-v1[1]; na,L=S.seg_consts(ldx,ldy)
        if L==0: continue
        dy1=v1[1]-pyi; dx1=v1[0]-pxi
        cross=dy1*ldx-dx1*ldy; exp=S._rdiv(cross<<4,L)
        if not (-32768<=exp<=32767): continue
        got=seg_c(dy1,dx1,ldx,ldy,L)
        n+=1
        if got!=exp:
            bad+=1
            if len(exam)<8: exam.append((dy1,dx1,ldx,ldy,L,got,exp))
for e in exam: print("  dy1,dx1,ldx,ldy,L,got,exp =",e)
print(f"seg_c: checked {n}, {bad} mismatches", "PASS" if bad==0 else "FAIL")
sys.exit(1 if bad else 0)
