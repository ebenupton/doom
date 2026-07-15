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
from engine_load import load_angle_module
from symmap import sym
def s16(v): return v-0x10000 if v>=0x8000 else v
def s8(v):  return v-0x100 if v>=0x80 else v

BCA=sym('jt_bca_check'); BOX=sym('bca_top')
B_PX,B_PY,B_AB=sym('bca_px'),sym('bca_py'),sym('bca_ab')
B_AFN,B_PXS,B_PYS=sym('bca_afn'),sym('bca_pxs'),sym('bca_pys')
B_BOXP,B_ILO,B_IHI,B_VIS=sym('bca_boxp'),sym('bca_ilo'),sym('bca_ihi'),sym('bca_vis')

# fresh standalone module
_st=MPU()
load_angle_module(_st.memory)
def standalone(top,bot,left,right,px,py,ab):
    m=_st.memory
    for off,val in enumerate((top,bot,left,right)):
        m[BOX+2*off]=val&0xFF; m[BOX+2*off+1]=(val>>8)&0xFF
    m[B_PX]=px&0xFF;m[B_PY]=py&0xFF;m[B_AB]=ab&0xFF
    _afn=(ab<<4)&0xFFFF; m[B_AFN]=_afn&0xFF; m[B_AFN+1]=(_afn>>8)&0xFF
    m[B_PXS]=px&0xFF; m[B_PXS+1]=0xFF if px<0 else 0
    m[B_PYS]=py&0xFF; m[B_PYS+1]=0xFF if py<0 else 0
    m[B_BOXP]=BOX&0xFF; m[B_BOXP+1]=BOX>>8
    _st.pc=BCA;_st.sp=0xFD;m[0x1FF]=0xFF;m[0x1FE]=0xFF
    s=0
    while _st.pc!=0 and s<20000: _st.step();s+=1
    return (m[B_ILO],m[B_IHI]) if m[B_VIS] else None

def check(px,py,ab):
    sc=SpanClip6502(); tc.setup_wad(sc); tc.setup_view_zp(sc,px,py,ab)
    sc._run(tc.ENTRY_BR_VIEW_SETUP); sc.init(); sc.clear_screen()
    from bsp_render_6502 import poke_init_frame_state; poke_init_frame_state(sc.mpu.memory)
    mem=sc.mpu.memory; mpu=sc.mpu
    vs_py=[]; vs_st=[]; n=0
    armed=None
    def traced(entry,max_cycles=30_000_000):
        nonlocal n,armed
        mpu.pc=entry; mpu.sp=0xFD; mpu.p=0x30; mem[0x1FF]=0xFE; mem[0x1FE]=0xFF
        for _ in range(max_cycles):
            pc=mpu.pc
            if pc==0xFF00: break
            if pc==BCA and armed is None:
                bp=mem[B_BOXP]|(mem[B_BOXP+1]<<8)    # bca_boxp -> ROM box (top,bot,left,right)
                armed=(s16(mem[bp]|(mem[bp+1]<<8)),s16(mem[bp+2]|(mem[bp+3]<<8)),
                       s16(mem[bp+4]|(mem[bp+5]<<8)),s16(mem[bp+6]|(mem[bp+7]<<8)),
                       s8(mem[B_PX]),s8(mem[B_PY]),mem[B_AB])
            elif armed is not None and pc<0xC000:
                got=(mem[B_ILO],mem[B_IHI]) if mem[B_VIS] else None
                n+=1
                if got!=A.bbox_check_angle(*armed) and len(vs_py)<4: vs_py.append((armed,got,A.bbox_check_angle(*armed)))
                if got!=standalone(*armed) and len(vs_st)<4: vs_st.append((armed,got,standalone(*armed)))
                armed=None
            mpu.step()
    sc._run=traced; sc._run(sym('jt_br_render_frame'))
    return n,vs_py,vs_st

tp=ts=nc=0
for (px,py,ab) in [(1056,-3616,128),(1024,-3500,65),(1500,-3700,1),(800,-3400,96),(1200,-3000,129)]:
    n,vp,vs=check(px,py,ab); tp+=len(vp); ts+=len(vs); nc+=n
    print(f"({px},{py},{ab}): {n} calls | vs_python={len(vp)} vs_standalone={len(vs)}")
    for e in vs[:3]: print("    [STATE-CORRUPT]",e)
    for e in vp[:3]: print("    [vs-py]",e)
print(f"TOTAL {nc} calls: {tp} differ vs python, {ts} differ vs standalone(=corruption)")
