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
    asmbuild.build_all(banked=1, c02=c02)
    # walk_drv is a ca65 link unit since 749ba62: the driver bytes come from
    # the link, not a beebasm pass against a generated engine_syms.inc.
    DRV=open('engine_drv.bin','rb').read()
    src=BankedBspRender(dw.packed_layout, dw.packed_rom_main, dw.packed_rom_detail,
                        dw.packed_bbox_table, dw.MAP_CENTER_X, dw.MAP_CENTER_Y, dw.PRESCALE)
    L0=bytes(src.bm._banks[BANK_L0]); C=bytes(src.bm._banks[BANK_C]); L2=bytes(src.bm._banks[BANK_L2])
    LOW=bytes(src.bm[abi.LOW_BASE:0x5800])   # THE FB WALL — the old
                                             # MAIN_BASE+getsize proxy
                                             # drifted with the bin and
                                             # mangled the boot image
    sc=SpanClip6502()
    if c02:
        from py65.devices.mpu65c02 import MPU as M; sc.mpu=M()
    bare=BankedMemory([0]*65536)
    bare.define_bank(BANK_L0,L0); bare.define_bank(BANK_C,C); bare.define_bank(BANK_L2,L2)
    for i,b in enumerate(LOW): bare[abi.LOW_BASE+i]=b
    for i,b in enumerate(DRV): bare[abi.DRV_ORG+i]=b
    bare.select(BANK_L0)
    bare[0xFFF4]=0xA2; bare[0xFFF5]=osver; bare[0xFFF6]=0x60      # OSBYTE stub
    # Model B: font in the MOS ROM at $C000. Master: the font is in ANDY
    # ($8900-$8FFF), paged over $8000-$8FFF by ROMSEL bit 7 — so the
    # Master glyphs go in the ANDY image, NOT in main memory, and the
    # $AA bytes can ONLY reach the framebuffer if hud_draw really pages
    # ANDY in. The same offsets in bank C hold $99, so a HUD that forgot
    # to page would show those instead and the count would give it away.
    for i in range(96*8):
        blank = i < 8
        bare[0xC000+i]=0x00 if blank else 0xFF                     # Model B font
    andy=bytearray(0x1000)
    for i in range(96*8):
        andy[0x900+i]=0x00 if i < 8 else 0xAA                      # Master font
    bare.define_andy(andy)
    for i in range(96*8):
        bare[0x8900+i]=0x99                        # bank C decoy at the same
                                                   # addresses, ANDY paged out
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
            scan.count(0xAA), scan.count(0xFF), scan.count(0x99))

# SUBPROCESS ISOLATION (2026-09-02): each (cpu,osver) case runs in a
# FRESH interpreter.  The NMOS run leaves py65/module state that
# corrupts a later C02 free-run in the SAME process (25M steps amplify
# it) -- every case passes standalone but the in-process loop reported
# base=$0000.  Isolation is the honest fix: the gate measures what a
# real boot does, not the residue of the previous boot.  The child sets
# E2E_CHILD, which gates the driver block below so only run() executes.
def _run_isolated(osver, c02):
    import json, runpy
    env = dict(os.environ, E2E_CHILD='1', E2E_OSVER=str(osver), E2E_C02=str(c02))
    out = subprocess.run([sys.executable, os.path.abspath(__file__)],
                         cwd=_ROOT, capture_output=True, text=True, env=env)
    for ln in out.stdout.splitlines():
        if ln.startswith('RESULT '):
            return tuple(json.loads(ln[7:]))
    raise RuntimeError('isolated run produced no RESULT:\n'
                       + out.stdout[-800:] + out.stderr[-800:])


if os.environ.get('E2E_CHILD'):
    import json
    _r = run(int(os.environ['E2E_OSVER']), int(os.environ['E2E_C02']))
    print('RESULT', json.dumps(list(_r)))
    sys.exit(0)


if True:
    res=[]
    for c02 in (0,1):
        tag='C02 host (Master)' if c02 else 'NMOS host (Model B)'
        # measured OSBYTE-129 answers (622ad83): jsbeeb B = $FF, Master = $FD
        for osver,want in ((0xFF,abi.HUD_FONT_B),(0xFD,abi.HUD_FONT_MASTER)):
            base,n_aa,n_ff,n_99=_run_isolated(osver,c02)
            res.append((tag,osver,want,base,n_aa,n_ff,n_99))
            print('%-20s OSver $%02X -> base $%04X, ANDY-glyphs=%d ROM-glyphs=%d decoy=%d'
                  %(tag,osver,base,n_aa,n_ff,n_99))

    print()
    bad=0
    for i in (0,2):
        tag=res[i][0]; b_aa=res[i][4]; m_aa=res[i+1][4]; b_ff=res[i][5]; m_ff=res[i+1][5]
        base_ok = res[i][3]==res[i][2] and res[i+1][3]==res[i+1][2]
        # the Master run must blit its ANDY glyphs, NOT the bank-C decoy
        # at the same addresses with ANDY paged out.  $99 occurs naturally
        # in engine code, so compare the two runs.
        b_99, m_99 = res[i][6], res[i+1][6]
        src_ok = m_aa > b_aa + 50 and b_ff > m_ff and m_99 <= b_99
        print('%-20s base select %s ; Master glyphs came from ANDY %s  '
              '(ANDY %d->%d, ROM %d->%d, decoy %d->%d)'
              %(tag,'ok' if base_ok else 'FAIL','ok' if src_ok else 'FAIL',
                b_aa,m_aa,b_ff,m_ff,b_99,m_99))
        if not (base_ok and src_ok): bad+=1
    print('HUDFONT-E2E:', 'PASS' if not bad else 'FAIL')
    sys.exit(1 if bad else 0)
