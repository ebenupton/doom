#!/usr/bin/env python3
"""END-TO-END HUD font test: boot the REAL walk_drv, let it probe a stubbed
OSBYTE, enable the HUD, and check the glyphs the engine blits came from the
base the probe chose. Distinguishable fonts at $C000 ($FF rows) and $F900
($AA rows) make the source unambiguous."""
import os, sys, subprocess
_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, _ROOT); os.chdir(_ROOT)
os.environ['SDL_VIDEODRIVER']='dummy'; os.environ['PYGAME_HIDE_SUPPORT_PROMPT']='1'
import pygame; pygame.init()
import doom_wireframe as dw, abi, asmbuild
from banked_bsp import BankedBspRender, BankedMemory, BANK_L0, BANK_C, BANK_L2
from span_clip_6502 import SpanClip6502

def run(osver, c02):
    if c02: os.environ['DOOM_CPU']='65c02'
    else: os.environ.pop('DOOM_CPU', None)
    asmbuild.build_all(banked=1, c02=c02); asmbuild.gen_engine_syms()
    subprocess.run(['./beebasm','-i','walk_drv.asm','-D','BANKED=1'],check=True,capture_output=True)
    DRV=open('WALKDRV','rb').read()
    src=BankedBspRender(dw.packed_layout, dw.packed_rom_main, dw.packed_rom_detail,
                        dw.packed_bbox_table, dw.MAP_CENTER_X, dw.MAP_CENTER_Y, dw.PRESCALE)
    L0=bytes(src.bm._banks[BANK_L0]); C=bytes(src.bm._banks[BANK_C]); L2=bytes(src.bm._banks[BANK_L2])
    LOW=bytes(src.bm[abi.LOW_BASE:abi.MAIN_BASE+os.path.getsize('bsp_render_bk.bin')])
    sc=SpanClip6502()
    if c02:
        from py65.devices.mpu65c02 import MPU as M; sc.mpu=M()
    bare=BankedMemory([0]*65536)
    bare.define_bank(BANK_L0,L0); bare.define_bank(BANK_C,C); bare.define_bank(BANK_L2,L2)
    for i,b in enumerate(LOW): bare[abi.LOW_BASE+i]=b
    for i,b in enumerate(DRV): bare[abi.DRV_ORG+i]=b
    bare.select(BANK_L0)
    bare[0xFFF4]=0xA2; bare[0xFFF5]=osver; bare[0xFFF6]=0x60      # OSBYTE stub
    for i in range(96*8):
        bare[0xC000+i]=0xFF                                        # Model B font
        bare[0xF900+i]=0xAA                                        # Master font
    sc.mpu.memory=bare; mpu=sc.mpu
    mpu.pc=abi.DRV_ORG; mpu.sp=0xDD; mpu.p=0x34
    # boot + a few frames with the HUD forced on (H-key edge needs live HW)
    steps=0; enabled=False
    while steps<25_000_000:
        mpu.step(); steps+=1
        if not enabled and steps>2_000_000:
            bare[abi.DV_HUD_EN]=1; enabled=True                    # H pressed
    # scan BOTH display buffers (the driver double-buffers; the HUD lands
    # in whichever one the frame rendered into)
    scan=[bare[a] for a in range(0x3000,0x8000)]
    return (bare[abi.DV_HUD_FONT]|(bare[abi.DV_HUD_FONT+1]<<8),
            scan.count(0xAA), scan.count(0xFF))

res=[]
for c02 in (0,1):
    tag='C02 host (Master)' if c02 else 'NMOS host (Model B)'
    for osver,want in ((0x01,0xC000),(0x03,0xF900)):
        base,n_aa,n_ff=run(osver,c02)
        res.append((tag,osver,want,base,n_aa,n_ff))
        print('%-20s OSver $%02X -> base $%04X, AA=%d FF=%d'%(tag,osver,base,n_aa,n_ff))

print()
bad=0
for i in (0,2):
    tag=res[i][0]; b_aa=res[i][4]; m_aa=res[i+1][4]; b_ff=res[i][5]; m_ff=res[i+1][5]
    base_ok = res[i][3]==res[i][2] and res[i+1][3]==res[i+1][2]
    # the Master run must blit MORE $AA (its font) than the Model B run
    src_ok = m_aa > b_aa + 50 and b_ff > m_ff
    print('%-20s base select %s ; glyphs came from the SELECTED font %s  (AA %d->%d, FF %d->%d)'
          %(tag,'ok' if base_ok else 'FAIL','ok' if src_ok else 'FAIL',b_aa,m_aa,b_ff,m_ff))
    if not (base_ok and src_ok): bad+=1
print('HUDFONT-E2E:', 'PASS' if not bad else 'FAIL')
sys.exit(1 if bad else 0)
