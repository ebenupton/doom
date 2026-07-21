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

BCA=sym('box_classify'); BOX=sym('bca_top')  # pristine check (moving path)
B_PX,B_PY,B_AB=sym('bca_px'),sym('bca_py'),sym('bca_ab')
B_AFN,B_PXS,B_PYS=sym('bca_afn'),sym('bca_pxs'),sym('bca_pys')
B_ILO,B_IHI=sym('bca_ilo'),sym('bca_ihi')  # bca_vis retired: A/C signature
# corner planes (the boxp pointer is gone, 2026-07-15): field f at
# BBP_*, side at +$100, node = the Y index
BBP=[sym(n) for n in ('BBP_T_LO','BBP_T_HI','BBP_B_LO','BBP_B_HI',
                      'BBP_L_LO','BBP_L_HI','BBP_R_LO','BBP_R_HI')]
ZNODE,ZSIDE=sym('zp_node_ch_l'),sym('zp_bbox_side')
# the ZC corner arms run BELOW $C000 mid-check — exclude them from the
# 'returned to main code' probe (mid-check A/C aren't the verdict yet)
ZC_LO=sym('zc_corners'); ZC_HI=sym('zc_end')
HG_LO=sym('span_has_gap'); HG_HI=HG_LO+0x60  # the fused exit runs INSIDE the probe window (B segment); A/C aren't the verdict until it returns

# fresh standalone module
_st=MPU()
load_angle_module(_st.memory)
def standalone(top,bot,left,right,px,py,ab):
    m=_st.memory
    for off,val in enumerate((top,bot,left,right)):
        m[BOX+2*off]=val&0xFF; m[BOX+2*off+1]=(val>>8)&0xFF
    m[B_PX]=px&0xFF;m[B_PY]=py&0xFF;m[B_AB]=ab&0xFF
    _afn=((ab<<4)+512+12)&0x0FFF; m[B_AFN]=_afn&0xFF; m[B_AFN+1]=(_afn>>8)&0xFF  # pre-biased +512+EPS (view.s hoist)
    m[B_PXS]=px&0xFF; m[B_PXS+1]=(0xFF if px<0 else 0)^0x80  # offset-binned (view.s)
    m[B_PYS]=py&0xFF; m[B_PYS+1]=(0xFF if py<0 else 0)^0x80
    m[ZNODE]=0; m[ZSIDE]=0                 # box -> planes at node 0, side 0
    _pr=sym('bca_tail_postrc')             # moving contract: tail vector
    m[sym('zp_tail_vec')]=_pr&0xFF; m[sym('zp_tail_vec')+1]=_pr>>8
    for f,val in enumerate((top,bot,left,right)):
        m[BBP[2*f]]=val&0xFF; m[BBP[2*f+1]]=((val>>8)^0x80)&0xFF  # offset-binned hi
    _st.pc=BCA;_st.sp=0xFD;m[0x1FF]=0xFF;m[0x1FE]=0xFF
    s=0
    while _st.pc!=0 and s<20000: _st.step();s+=1
    _vis = _st.a == 1 or (_st.p & 1) == 0   # A/C signature (bca_vis retired)
    return (m[B_ILO],m[B_IHI]) if _vis else None

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
                nd,sd=mem[ZNODE],mem[ZSIDE]          # planes: field + side*$100 + node
                def _f(k): return s16(mem[BBP[2*k]+sd*0x100+nd]|((mem[BBP[2*k+1]+sd*0x100+nd]^0x80)<<8))  # un-bias the offset-binned hi (wad_packed)
                armed=(_f(0),_f(1),_f(2),_f(3),
                       s8(mem[B_PX]),s8(mem[B_PY]),mem[B_AB])
                ret=((mem[0x100+((mpu.sp+1)&0xFF)]|(mem[0x100+((mpu.sp+2)&0xFF)]<<8))+1)&0xFFFF  # the walk's JSR return: the check is JMP-threaded, so THIS pc is the one true exit (the 2026-07-21 one-blob map retired the window heuristic)
            elif armed is not None and pc==ret:
                got=(mem[B_ILO],mem[B_IHI]) if (mpu.a == 1 or (mpu.p & 1) == 0) else None
                n+=1
                if got!=A.bbox_check_angle(*armed) and len(vs_py)<4: vs_py.append((armed,got,A.bbox_check_angle(*armed)))
                if got!=standalone(*armed) and len(vs_st)<4: vs_st.append((armed,got,standalone(*armed)))
                armed=None
            mpu.step()
    sc._run=traced; sc._run(sym('br_render_frame'))
    return n,vs_py,vs_st

tp=ts=nc=0
for (px,py,ab) in [(1056,-3616,128),(1024,-3500,65),(1500,-3700,1),(800,-3400,96),(1200,-3000,129)]:
    n,vp,vs=check(px,py,ab); tp+=len(vp); ts+=len(vs); nc+=n
    print(f"({px},{py},{ab}): {n} calls | vs_python={len(vp)} vs_standalone={len(vs)}")
    for e in vs[:3]: print("    [STATE-CORRUPT]",e)
    for e in vp[:3]: print("    [vs-py]",e)
print(f"TOTAL {nc} calls: {tp} differ vs python, {ts} differ vs standalone(=corruption)")
