"""Unit-test 6502 seg_project ($E955) vs angle_seg.seg_2b per endpoint.
Exercises the full per-seg flow: seg_c ($E952) once, then seg_project twice
(testing that c survives in $30 across both endpoints' point_to_angle)."""
import os, sys
os.environ['SDL_VIDEODRIVER']='dummy'; os.environ['PYGAME_HIDE_SUPPORT_PROMPT']='1'
import pygame; pygame.init(); pygame.display.set_mode((1,1))
from span_clip_6502 import SpanClip6502
import doom_wireframe as dw, angle_seg as S
A=S.A
sc=SpanClip6502(); m=sc.mpu
code=open('bsp_render_ang.bin','rb').read()
for i,b in enumerate(code): m.memory[0xE940+i]=b
for i in range(256): m.memory[0xFB00+i]=S._COSR[i]&0xFF
# tantoangle TA_LO $DC00 / TA_HI $F200, VATOX $F601 (mirror the bbox harness)
for k in range(1025):
    t=A._tantoangle[k] if k<len(A._tantoangle) else A._tantoangle[-1]
    m.memory[0xDC00+k]=t&0xFF; m.memory[0xF200+k]=(t>>8)&0xFF
for k in range(1025):
    c=(A._vatox_lo[k+512]+A._vatox_hi[k+512])//2
    m.memory[0xF601+k]=max(0,min(255,c))
def s16(v): return v-65536 if v>=32768 else v
def w16(a,v): m.memory[a]=v&0xFF; m.memory[a+1]=(v>>8)&0xFF
def call(addr):
    m.pc=addr; m.sp=0xFD; m.memory[0x1FF]=0xFF; m.memory[0x1FE]=0xFF
    n=0
    while m.pc!=0 and n<8000: m.step(); n+=1
def seg_c(dy1,dx1,ldx,ldy,L):
    w16(0x32,dy1); w16(0x34,dx1); m.memory[0x36]=ldx&0xFF; m.memory[0x37]=ldy&0xFF; m.memory[0x38]=L&0xFF
    call(0xE952)
def seg_project(wx,wy,px,py,afn,na):
    w16(0x9D,wx); w16(0x71,wy); w16(0x8D,px); w16(0x9B,py); w16(0x3B,afn); w16(0x4C,na)
    call(0xE955)
    cull=(m.p&1)!=0
    return m.memory[0x4E], (None if cull else (m.memory[0x46]|(m.memory[0x47]<<8)))
def exp_endpoint(wx,wy,px,py,afn,na,c):
    dx,dy=wx-px,wy-py
    phi=S._signed(afn-A.point_to_angle(dx,dy)); phi=max(-S.ANG45,min(S.ANG45,phi))
    sx=max(0,min(255,S._vatox_centre(phi)))
    cph=S._cos(phi); cden=S._cos(afn-phi-na)
    num,den=c*cph,cden
    if den<0: num,den=-num,-den
    if den==0: return sx,None
    depth=S._rdiv(num,den)
    if depth<=0: return sx,None
    return sx, min(65535,depth)
bad=n=0; exam=[]
for (px,py,ab) in [(1056,-3616,a) for a in range(0,256,8)]+[(1024,-3500,65),(800,-3400,96),(1500,-3700,1),(1200,-3000,129)]:
    pxi=int((px-dw.MAP_CENTER_X)/dw.PRESCALE);pyi=int((py-dw.MAP_CENTER_Y)/dw.PRESCALE)
    afn=(ab*16)&S.MASK
    for svwh in dw.fp_segs_vwh:
        sg=svwh[0];v1=dw.fp_vertexes[sg[0]];v2=dw.fp_vertexes[sg[1]]
        ldx,ldy=v2[0]-v1[0],v2[1]-v1[1]; na,L=S.seg_consts(ldx,ldy)
        if L==0: continue
        dy1=v1[1]-pyi; dx1=v1[0]-pxi
        cross=dy1*ldx-dx1*ldy; c=S._rdiv(cross<<4,L)
        if not (-32768<=c<=32767): continue
        seg_c(dy1,dx1,ldx,ldy,L)           # sets $30/$31 = c (once per seg)
        for (wx,wy) in ((v1[0],v1[1]),(v2[0],v2[1])):
            got=seg_project(wx,wy,pxi,pyi,afn,na)
            exp=exp_endpoint(wx,wy,pxi,pyi,afn,na,c)
            n+=1
            if got!=exp:
                bad+=1
                if len(exam)<8: exam.append((wx,wy,pxi,pyi,ab,na,c,got,exp))
for e in exam: print("  wx,wy,px,py,ab,na,c,got,exp =",e)
print(f"seg_project: checked {n}, {bad} mismatches", "PASS" if bad==0 else "FAIL")
sys.exit(1 if bad else 0)
