import subprocess, sys
import angle_bbox as A
import asmbuild
if asmbuild.env_c02():
    from py65.devices.mpu65c02 import MPU
else:
    from py65.devices.mpu6502 import MPU
from engine_load import load_angle_module
from symmap import sym
mpu=MPU()
load_angle_module(mpu.memory)
BCA=sym('jt_bca_check'); BOX=sym('bca_top')
def w16(a,v): mpu.memory[a]=v&0xFF; mpu.memory[a+1]=(v>>8)&0xFF
def run(top,bot,left,right,px,py,ab):
    w16(sym('bca_top'),top);w16(sym('bca_bot'),bot)
    w16(sym('bca_left'),left);w16(sym('bca_right'),right)
    mpu.memory[sym('bca_px')]=px&0xFF;mpu.memory[sym('bca_py')]=py&0xFF
    mpu.memory[sym('bca_ab')]=ab&0xFF
    w16(sym('bca_afn'),(ab<<4)&0xFFFF)
    mpu.memory[sym('bca_pxs')]=px&0xFF;mpu.memory[sym('bca_pxs')+1]=0xFF if px<0 else 0
    mpu.memory[sym('bca_pys')]=py&0xFF;mpu.memory[sym('bca_pys')+1]=0xFF if py<0 else 0
    w16(sym('bca_boxp'),BOX)
    mpu.pc=BCA;mpu.sp=0xFD;mpu.memory[0x01FF]=0xFF;mpu.memory[0x01FE]=0xFF
    s=0
    while mpu.pc!=0x0000 and s<20000: mpu.step();s+=1
    return mpu.memory[sym('bca_straddle')]
def py_straddle(top,bot,left,right,px,py,ab):
    if left<=px<=right and bot<=py<=top: return 0
    bx=0 if px<=left else (1 if px<right else 2); by=0 if py>=top else (1 if py>bot else 2)
    cc=A._CHECKCOORD[(by<<2)+bx]
    if cc is None: return 0
    vt=(top,bot,left,right); af=(ab*(A.FINEANGLES//256))&A.ANGMASK
    p1=A._phi(vt[cc[0]],vt[cc[1]],px,py,af); p2=A._phi(vt[cc[2]],vt[cc[3]],px,py,af)
    return 1 if (abs(p1)>A.ANG90 or abs(p2)>A.ANG90) else 0
boxes=[(80,-80,-80,80),(40,10,-60,-20),(120,60,20,90),(-10,-50,30,70),(100,-100,-100,100),(20,5,5,40),(-50,-54,-22,-14)]
fails=checked=0; exam=[]
for (top,bot,left,right) in boxes:
    for px in range(-120,121,13):
        for py in range(-120,121,13):
            for ab in range(0,256,17):
                exp=py_straddle(top,bot,left,right,px,py,ab); got=run(top,bot,left,right,px,py,ab)
                checked+=1
                if exp!=(1 if got else 0):
                    fails+=1
                    if len(exam)<12: exam.append(((top,bot,left,right,px,py,ab),got,exp))
for e in exam: print("  ",e)
print(f"straddle flag: checked {checked}, {fails} mismatches")
print("PASS" if fails==0 else "FAIL"); sys.exit(1 if fails else 0)
