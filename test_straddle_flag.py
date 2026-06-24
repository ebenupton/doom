import subprocess, sys
from py65.devices.mpu6502 import MPU
import angle_bbox as A
subprocess.run(['./beebasm','-D','BANKED=0','-D','C02=0','-i','slope_div.asm','-o','slope_div.bin'],check=True,capture_output=True)
BCA=0xE943; code=open('bsp_render_ang.bin','rb').read()
mpu=MPU()
for i,b in enumerate(code): mpu.memory[0xE940+i]=b
for i in range(1024):
    v=A._tantoangle[i]; mpu.memory[0xDC00+i]=v&0xFF; mpu.memory[0xF200+i]=(v>>8)&0xFF
for k in range(1025):
    c=(A._vatox_lo[k+512]+A._vatox_hi[k+512])//2; mpu.memory[0xF601+k]=max(0,min(255,c))
def w16(a,v): mpu.memory[a]=v&0xFF; mpu.memory[a+1]=(v>>8)&0xFF
def run(top,bot,left,right,px,py,ab):
    w16(0xFA10,top);w16(0xFA12,bot);w16(0xFA14,left);w16(0xFA16,right)
    mpu.memory[0x01]=px&0xFF;mpu.memory[0x03]=py&0xFF;mpu.memory[0xFA2F]=ab&0xFF
    afn=(ab<<4)&0xFFFF;mpu.memory[0x3B]=afn&0xFF;mpu.memory[0x3C]=(afn>>8)&0xFF
    mpu.memory[0x8D]=px&0xFF;mpu.memory[0x8E]=0xFF if px<0 else 0
    mpu.memory[0x9B]=py&0xFF;mpu.memory[0x9C]=0xFF if py<0 else 0
    mpu.memory[0x86]=0x10;mpu.memory[0x87]=0xFA
    mpu.pc=BCA;mpu.sp=0xFD;mpu.memory[0x01FF]=0xFF;mpu.memory[0x01FE]=0xFF
    s=0
    while mpu.pc!=0x0000 and s<20000: mpu.step();s+=1
    return mpu.memory[0xFA33]   # bca_straddle
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
