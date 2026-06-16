"""Unit-test 6502 seg_depth ($E94C) vs angle_seg depth (option-2b)."""
import os, sys
os.environ['SDL_VIDEODRIVER']='dummy'; os.environ['PYGAME_HIDE_SUPPORT_PROMPT']='1'
import pygame; pygame.init(); pygame.display.set_mode((1,1))
from span_clip_6502 import SpanClip6502
import doom_wireframe as dw, angle_seg as S
sc=SpanClip6502(); m=sc.mpu
code=open('bsp_render_ang.bin','rb').read()
for i,b in enumerate(code): m.memory[0xE940+i]=b
for i in range(256): m.memory[0xF800+i]=S._COSR[i]&0xFF
def s16(v): return v-65536 if v>=32768 else v
def seg_depth(c, phi, den):
    m.memory[0x30]=c&0xFF; m.memory[0x31]=(c>>8)&0xFF
    m.memory[0x32]=phi&0xFF; m.memory[0x33]=(phi>>8)&0xFF
    m.memory[0x44]=den&0xFF; m.memory[0x45]=(den>>8)&0xFF
    m.pc=0xE94C; m.sp=0xFD; m.memory[0x1FF]=0xFF; m.memory[0x1FE]=0xFF
    n=0
    while m.pc!=0 and n<3000: m.step(); n+=1
    cull = (m.p & 1) != 0      # carry set = cull
    depth = m.memory[0x46]|(m.memory[0x47]<<8)
    return None if cull else depth
def exp_depth(c, phi, den_ang):
    cph=S._cos(phi); cden=S._cos(den_ang)
    num,d=c*cph,cden
    if d<0: num,d=-num,-d
    if d==0: return None
    depth=S._rdiv(num,d)
    if depth<=0: return None
    return min(65535,depth)
bad=n=0; exam=[]
for (px,py,ab) in [(1056,-3616,a) for a in range(0,256,8)]+[(1024,-3500,65),(800,-3400,96),(1500,-3700,1),(1200,-3000,129)]:
    pxi=int((px-dw.MAP_CENTER_X)/dw.PRESCALE);pyi=int((py-dw.MAP_CENTER_Y)/dw.PRESCALE)
    a_fine=(ab*16)&S.MASK
    for svwh in dw.fp_segs_vwh:
        sg=svwh[0];v1=dw.fp_vertexes[sg[0]];v2=dw.fp_vertexes[sg[1]]
        ldx,ldy=v2[0]-v1[0],v2[1]-v1[1]; na,rlen=S.seg_consts(ldx,ldy)
        cross=(v1[1]-pyi)*ldx-(v1[0]-pxi)*ldy; c=(cross*rlen)>>12
        if not (-32768<=c<=32767): continue
        for (wx,wy) in ((v1[0],v1[1]),(v2[0],v2[1])):
            dx,dy=wx-pxi,wy-pyi
            phi=S._signed(a_fine-S.A.point_to_angle(dx,dy)); phi=max(-S.ANG45,min(S.ANG45,phi))
            den=(a_fine-phi-na)&S.MASK
            got=seg_depth(c&0xFFFF if c>=0 else (c+65536), phi&0xFFFF, den)
            exp=exp_depth(c,phi,den)
            n+=1
            if got!=exp:
                bad+=1
                if len(exam)<6: exam.append((c,phi,den,got,exp))
for e in exam: print("  ",e)
print(f"seg_depth: checked {n}, {bad} mismatches", "PASS" if bad==0 else "FAIL")
sys.exit(1 if bad else 0)
