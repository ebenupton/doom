"""Unit-test 6502 cos_fine ($E949) vs angle_seg._cos (s8 cos*127)."""
import subprocess, sys
from py65.devices.mpu6502 import MPU
import angle_seg as S
subprocess.run(['./beebasm','-i','slope_div.asm'], check=True, capture_output=True)
m=MPU(); code=open('bsp_render_ang.bin','rb').read()
for i,b in enumerate(code): m.memory[0xE940+i]=b
for i in range(256): m.memory[0xFB00+i]=S._COSR[i]&0xFF     # signed byte
def cos_fine(ang):
    m.memory[0x9B]=ang&0xFF; m.memory[0x9C]=(ang>>8)&0xFF
    m.pc=0xE949; m.sp=0xFD; m.memory[0x1FF]=0xFF; m.memory[0x1FE]=0xFF
    s=0
    while m.pc!=0 and s<100: m.step(); s+=1
    v=m.memory[0x9D]; return v-256 if v>=128 else v
bad=0; n=0
for ang in range(0,4096):
    n+=1
    if cos_fine(ang)!=S._cos(ang): bad+=1
print(f"cos_fine: checked {n}, {bad} mismatches", "PASS" if bad==0 else "FAIL")
sys.exit(1 if bad else 0)
