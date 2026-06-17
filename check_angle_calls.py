"""Verify 6502 angle bbox in-frame == Python angle reference, per call.
Arm at $E946; read inputs; read outputs when control returns to main
code (<$C000). Also run a fresh standalone module per call as a control."""
import os
os.environ['SDL_VIDEODRIVER']='dummy'; os.environ['PYGAME_HIDE_SUPPORT_PROMPT']='1'
import pygame; pygame.init(); pygame.display.set_mode((1,1))
from span_clip_6502 import SpanClip6502
from py65.devices.mpu6502 import MPU
import trace_compare as tc
import angle_bbox as A
def s16(v): return v-0x10000 if v>=0x8000 else v
def s8(v):  return v-0x100 if v>=0x80 else v

# fresh standalone module
_st=MPU()
_code=open('bsp_render_ang.bin','rb').read()
for i,b in enumerate(_code): _st.memory[0xE940+i]=b
for i in range(1024):
    v=A._tantoangle[i]; _st.memory[0xDC00+i]=v&0xFF; _st.memory[0xF200+i]=(v>>8)&0xFF
for k in range(1025):
    c=(A._vatox_lo[k+512]+A._vatox_hi[k+512])//2; _st.memory[0xF601+k]=max(0,min(255,c))
def standalone(top,bot,left,right,px,py,ab):
    m=_st.memory
    m[0xFA10]=top&0xFF;m[0xFA11]=(top>>8)&0xFF;m[0xFA12]=bot&0xFF;m[0xFA13]=(bot>>8)&0xFF
    m[0xFA14]=left&0xFF;m[0xFA15]=(left>>8)&0xFF;m[0xFA16]=right&0xFF;m[0xFA17]=(right>>8)&0xFF
    m[0x01]=px&0xFF;m[0x03]=py&0xFF;m[0xFA2F]=ab&0xFF
    _afn=(ab<<4)&0xFFFF; m[0x3B]=_afn&0xFF; m[0x3C]=(_afn>>8)&0xFF  # a_fine now caller-set
    m[0x8D]=px&0xFF; m[0x8E]=0xFF if px<0 else 0   # bca_pxs (caller-set)
    m[0x9B]=py&0xFF; m[0x9C]=0xFF if py<0 else 0   # bca_pys
    m[0x86]=0x10; m[0x87]=0xFA                      # bca_boxp -> box at $FA10
    _st.pc=0xE943;_st.sp=0xFD;m[0x1FF]=0xFF;m[0x1FE]=0xFF
    s=0
    while _st.pc!=0 and s<20000: _st.step();s+=1
    return (m[0xFA30],m[0xFA31]) if m[0xFA32] else None

def check(px,py,ab):
    sc=SpanClip6502(); tc.setup_wad(sc); tc.setup_view_zp(sc,px,py,ab)
    sc._run(tc.ENTRY_BR_VIEW_SETUP); sc.init(); sc.clear_screen(); sc._run(0x481B)
    mem=sc.mpu.memory; mpu=sc.mpu
    vs_py=[]; vs_st=[]; n=0
    armed=None
    def traced(entry,max_cycles=30_000_000):
        nonlocal n,armed
        mpu.pc=entry; mpu.sp=0xFD; mpu.p=0x30; mem[0x1FF]=0xFE; mem[0x1FE]=0xFF
        for _ in range(max_cycles):
            pc=mpu.pc
            if pc==0xFF00: break
            if pc==0xE943 and armed is None:
                bp=mem[0x86]|(mem[0x87]<<8)          # bca_boxp -> ROM box (top,bot,left,right)
                armed=(s16(mem[bp]|(mem[bp+1]<<8)),s16(mem[bp+2]|(mem[bp+3]<<8)),
                       s16(mem[bp+4]|(mem[bp+5]<<8)),s16(mem[bp+6]|(mem[bp+7]<<8)),
                       s8(mem[0x01]),s8(mem[0x03]),mem[0xFA2F])
            elif armed is not None and pc<0xC000:
                got=(mem[0xFA30],mem[0xFA31]) if mem[0xFA32] else None
                n+=1
                if got!=A.bbox_check_angle(*armed) and len(vs_py)<4: vs_py.append((armed,got,A.bbox_check_angle(*armed)))
                if got!=standalone(*armed) and len(vs_st)<4: vs_st.append((armed,got,standalone(*armed)))
                armed=None
            mpu.step()
    sc._run=traced; sc._run(0x4815)
    return n,vs_py,vs_st

tp=ts=nc=0
for (px,py,ab) in [(1056,-3616,128),(1024,-3500,65),(1500,-3700,1),(800,-3400,96),(1200,-3000,129)]:
    n,vp,vs=check(px,py,ab); tp+=len(vp); ts+=len(vs); nc+=n
    print(f"({px},{py},{ab}): {n} calls | vs_python={len(vp)} vs_standalone={len(vs)}")
    for e in vs[:3]: print("    [STATE-CORRUPT]",e)
    for e in vp[:3]: print("    [vs-py]",e)
print(f"TOTAL {nc} calls: {tp} differ vs python, {ts} differ vs standalone(=corruption)")
