#!/usr/bin/env python3
"""The pickup ladder builders vs doc/billboard's integer mirrors.

Pokes obj_asp/obj_h/obj_a/obj_cx/obj_yt/obj_yb, runs each builder, reads
the slots back.  The fractions here are the memo's L1 geometry -- if
objects.s and doc/billboard drift, this trips."""
import os, sys
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, ROOT); sys.path.insert(0, os.path.join(ROOT, 'tools'))
os.environ.setdefault('SDL_VIDEODRIVER', 'dummy')
os.environ['PYGAME_HIDE_SUPPORT_PROMPT'] = '1'
import pygame; pygame.init()
import doom_wireframe as dw
from banked_bsp import BankedBspRender, BANK_C
from symmap import sym

R = lambda p: (p + 128) >> 8

def m_box(kind, H, a, cx, syt, syb):
    lid = (H * (51 if kind == 4 else 54) + 128) >> 8
    return {('Y',0): syt, ('Y',2): syt+lid, ('Y',4): syb}

def m_potion(kind, H, a, cx, syt, syb):
    qa, wn, a3 = R(a*187), R(a*73), R(a*69)
    return {('X',2): cx-qa, ('X',8): cx+qa, ('X',4): cx-wn, ('X',6): cx+wn,
            ('Y',0): syt, ('Y',2): syb-2*qa, ('Y',4): syb-(qa+a3),
            ('Y',6): syb-(qa-a3), ('Y',8): syb}

def m_helmet(kind, H, a, cx, syt, syb):
    x6, x4, x3, x2 = R(a*192), R(a*128), R(a*96), R(a*64)
    d = {('X',2): cx-x6, ('X',44): cx+x6, ('X',4): cx-x4, ('X',42): cx+x4,
         ('X',6): cx-x3, ('X',40): cx+x3, ('X',8): cx-x2, ('X',38): cx+x2,
         ('Y',0): syt, ('Y',8): syb}
    for off, f in ((2,34),(4,85),(6,222)): d[('Y',off)] = syt + R(H*f)
    return d

def m_vest(kind, H, a, cx, syt, syb):
    w, sc = R(a*91), R(a*50)
    d = {('X',2): cx-w, ('X',8): cx+w, ('X',4): cx-sc, ('X',6): cx+sc,
         ('Y',0): syt, ('Y',10): syb}
    for off, f in ((2,20),(4,89),(6,75),(8,52)): d[('Y',off)] = syt + R(H*f)
    return d

CASES = [(4, 'obj_box_y', m_box), (5, 'obj_box_y', m_box),
         (2, 'obj_potion_xy', m_potion), (3, 'obj_helmet_xy', m_helmet),
         (6, 'obj_vest_xy', m_vest)]
KTAB = [23, 15, 25, 34, 30, 47, 58]

def main():
    r = BankedBspRender(dw.packed_layout, dw.packed_rom_main, dw.packed_rom_detail,
                        dw.packed_bbox_table, dw.MAP_CENTER_X, dw.MAP_CENTER_Y,
                        dw.PRESCALE)
    sc = r.sc; mem = sc.mpu.memory
    OH = sym('obj_h', banked=1); OA = sym('obj_a', banked=1)
    OASP = sym('obj_asp', banked=1); OCX = sym('obj_cx_l', banked=1)
    OYT = sym('obj_yt_l', banked=1); OYB = sym('obj_yb_l', banked=1)
    OX = sym('obj_X', banked=1); OY = sym('obj_Y', banked=1)
    def s16(v): return v - 0x10000 if v >= 0x8000 else v
    bad = 0
    for kind, entry, mirror in CASES:
        E = sym(entry, banked=1)
        for H in (255, 200, 152, 101, 76, 50, 34, 21, 12, 5):
            a = (H * KTAB[kind] + 32) >> 6
            for cx, syt in ((80, 40), (3, 0), (140, 150)):
                syb = syt + H
                mem[OH] = H; mem[OA] = a; mem[OASP] = kind
                mem[OCX] = cx & 0xFF; mem[OCX+1] = 0
                mem[OYT] = syt & 0xFF; mem[OYT+1] = (syt >> 8) & 0xFF
                mem[OYB] = syb & 0xFF; mem[OYB+1] = (syb >> 8) & 0xFF
                mem[0xFE30] = BANK_C
                sc._run(E)
                want = mirror(kind, H, a, cx, syt, syb)
                for (arr, off), wv in want.items():
                    base = OX if arr == 'X' else OY
                    gv = s16(mem[base+off] | (mem[base+off+1] << 8))
                    if gv != wv:
                        bad += 1
                        print(f'  kind{kind} H={H} cx={cx} syt={syt} '
                              f'{arr}+{off}: got {gv} want {wv}')
    print('PICKUPLADDERS:', 'PASS' if not bad else f'FAIL ({bad})')
    return 1 if bad else 0

if __name__ == '__main__':
    sys.exit(main())
