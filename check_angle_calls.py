"""Verify 6502 angle bbox in-frame == Python angle reference, per call.
Arm at $E946; read inputs; read outputs when control returns to main
code (<$C000). Also run a fresh standalone module per call as a control."""
import os
os.environ['SDL_VIDEODRIVER']='dummy'; os.environ['PYGAME_HIDE_SUPPORT_PROMPT']='1'
import pygame; pygame.init(); pygame.display.set_mode((1,1))
import doom_wireframe as dw
from py65.devices.mpu6502 import MPU
import trace_compare as tc
import angle_bbox as A
from engine_load import load_angle_module
# Symbols resolve for the build the shared rig IS (banked since 2026-08-29;
# DOOM_FLAT_RIG=1 restores flat).  zp/pool names are identical in both maps
# by rule, so only CODE entries actually move -- but a stale flat entry in a
# banked rig is a silent jump into the wrong build, so resolve it all here.
import functools as _ft, os as _os
_BANKED = 0 if dw.FLAT_RIG else 1     # dw is the single switch
from symmap import sym as _raw_sym
sym = _ft.partial(_raw_sym, banked=_BANKED)
def s16(v): return v-0x10000 if v>=0x8000 else v
def s8(v):  return v-0x100 if v>=0x80 else v

BCA=sym('box_classify')  # pristine check (moving path); BCA_WS/bca_top retired 2026-07-26
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

# Fresh standalone module -- FLAT, deliberately.  It is a bare MPU with no
# bank window, and it exists to check box_classify's ARITHMETIC against the
# in-frame run, not the banked layout; the angle core is the same source in
# both builds.  So it keeps flat symbols while everything above resolves for
# the (banked) shared rig.  Mixing the two is what produced 20 phantom
# "STATE-CORRUPT" divergences: the banked PC jumped into a flat image.
_symf = _ft.partial(_raw_sym, banked=0)
_st=MPU()
load_angle_module(_st.memory)
F_BCA = _symf('box_classify')
F_PX, F_PY, F_AB = _symf('bca_px'), _symf('bca_py'), _symf('bca_ab')
F_AFN, F_PXS, F_PYS = _symf('bca_afn'), _symf('bca_pxs'), _symf('bca_pys')
F_ILO, F_IHI = _symf('bca_ilo'), _symf('bca_ihi')
F_BBP=[_symf(n) for n in ('BBP_T_LO','BBP_T_HI','BBP_B_LO','BBP_B_HI',
                          'BBP_L_LO','BBP_L_HI','BBP_R_LO','BBP_R_HI')]
F_ZNODE, F_ZSIDE = _symf('zp_node_ch_l'), _symf('zp_bbox_side')
def standalone(top,bot,left,right,px,py,ab):
    m=_st.memory
    m[F_PX]=px&0xFF;m[F_PY]=py&0xFF;m[F_AB]=ab&0xFF
    _afn=((ab<<4)+512+12)&0x0FFF; m[F_AFN]=_afn&0xFF; m[F_AFN+1]=(_afn>>8)&0xFF  # pre-biased +512+EPS (view.s hoist)
    m[F_PXS]=px&0xFF; m[F_PXS+1]=(0xFF if px<0 else 0)^0x80  # offset-binned (view.s)
    m[F_PYS]=py&0xFF; m[F_PYS+1]=(0xFF if py<0 else 0)^0x80
    m[F_ZNODE]=0; m[F_ZSIDE]=0                 # box -> planes at node 0, side 0
    _pr=_symf('bca_tail_postrc')             # moving contract: tail vector
    # (tail vector gone 2026-09-04: the arms jump direct)
    for f,val in enumerate((top,bot,left,right)):
        m[F_BBP[2*f]]=val&0xFF; m[F_BBP[2*f+1]]=((val>>8)^0x80)&0xFF  # offset-binned hi
    _st.pc=F_BCA;_st.sp=0xDD;m[0x1DF]=0xFF;m[0x1DE]=0xFF
    s=0
    while _st.pc!=0 and s<20000: _st.step();s+=1
    _vis = (_st.p & 0x40) == 0   # C/V signature (2026-07-26): V=1 = angle
                                 # cull; V=0 = extent valid (gap or no-gap).
                                 # V is defined here because standalone runs
                                 # are always the uncached classify path.
    return (m[F_ILO],m[F_IHI]) if _vis else None

def check(px,py,ab):
    sc=dw.make_span_rig(); tc.setup_wad(sc); tc.setup_view_zp(sc,px,py,ab)
    sc._run(tc.ENTRY_BR_VIEW_SETUP); sc.init(); sc.clear_screen()
    from bsp_render_6502 import poke_init_frame_state; poke_init_frame_state(sc.mpu.memory)
    mem=sc.mpu.memory; mpu=sc.mpu
    vs_py=[]; vs_st=[]; n=0
    armed=None
    def traced(entry,max_cycles=30_000_000):
        nonlocal n,armed
        mpu.pc=entry; mpu.sp=0xDD; mpu.p=0x30; mem[0x1DF]=0xFE; mem[0x1DE]=0xFF
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
                got=(mem[B_ILO],mem[B_IHI]) if (mpu.p & 0x40) == 0 else None  # V=0: extent (cold frame => always classify path, V defined)
                n+=1
                if got!=A.bbox_check_angle(*armed) and len(vs_py)<4: vs_py.append((armed,got,A.bbox_check_angle(*armed)))
                if got!=standalone(*armed) and len(vs_st)<4: vs_st.append((armed,got,standalone(*armed)))
                armed=None
            mpu.step()
    sc._run=traced; sc._run(sym('render_frame'))
    return n,vs_py,vs_st

tp=ts=nc=0
for (px,py,ab) in [(1056,-3616,128),(1024,-3500,65),(1500,-3700,1),(800,-3400,96),(1200,-3000,129)]:
    n,vp,vs=check(px,py,ab); tp+=len(vp); ts+=len(vs); nc+=n
    print(f"({px},{py},{ab}): {n} calls | vs_python={len(vp)} vs_standalone={len(vs)}")
    for e in vs[:3]: print("    [STATE-CORRUPT]",e)
    for e in vp[:3]: print("    [vs-py]",e)
print(f"TOTAL {nc} calls: {tp} differ vs python, {ts} differ vs standalone(=corruption)")
