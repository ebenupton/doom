#!/usr/bin/env python3
"""Span band invariant — no safety clips, by Eben's ruling (2026-09-02).

Every span is inside the visible band by induction from the initial
span, so every emitted primitive is in-band with NO emit-time clamps.
The one producer of off-band spans was dcl_boundary_ix's ceiling arm:
`ADC #$FF` assumed C=0 but umul8/SBC run in between and leave C=1, so
the numerator got +den instead of +den-1 — a line GRAZING a boundary at
its far column divided to 256, wrapped the u8 quotient to 0, and the
whole overlap flipped visible (the Model B KIL's true root; span top
re-opened above the screen).

Two arms:
  1. dcl_boundary_ix unit matrix, C poisoned both ways, including the
     graze (d2=0) in both directions.
  2. Full renders at the witness poses; every plot the harness traps
     must stage Y0/Y1 in [0,159].
"""
import os, sys
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, ROOT); sys.path.insert(0, os.path.join(ROOT, 'tools'))
os.environ.setdefault('SDL_VIDEODRIVER', 'dummy')
os.environ['PYGAME_HIDE_SUPPORT_PROMPT'] = '1'
import pygame; pygame.init()
import doom_wireframe as dw
import banked_bsp
from symmap import sym


def bix_case(mpu, mem, entry, d1, d2, cx1, cx2, clip_p1, carry):
    mem[sym('zp_tmp0', banked=1)] = d1 & 0xFF
    mem[sym('zp_tmp1', banked=1)] = d2 & 0xFF
    mem[sym('zp_cb_cx1', banked=1)] = cx1
    mem[sym('zp_cb_cx2', banked=1)] = cx2
    mpu.pc = entry; mpu.a = clip_p1; mpu.sp = 0xF0
    mpu.p = 0x30 | (1 if carry else 0)
    mem[0x01F1] = 0xFE; mem[0x01F2] = 0x12
    steps = 0
    while steps < 20000 and mpu.pc != 0x12FF:
        mpu.step(); steps += 1
    return mpu.a


def main():
    r = banked_bsp.BankedBspRender(dw.packed_layout, dw.packed_rom_main,
                                   dw.packed_rom_detail, dw.packed_bbox_table,
                                   dw.MAP_CENTER_X, dw.MAP_CENTER_Y, dw.PRESCALE)
    mpu = r.sc.mpu; mem = mpu.memory
    import abi
    mem[0xFE30] = abi.BANK_C
    entry = sym('dcl_boundary_ix', banked=1)
    ok = True
    # magnitude contract: (|d1|, |d2|, cx1, cx2, clip_p1, lo, hi) —
    # exact when lo == hi; wide-denom cases allow the one inward column.
    CASES = [
        (17, 0, 0, 255, 1, 255, 255),    # THE GRAZE: ceil = 255 exactly, no wrap
        (17, 17, 0, 254, 1, 127, 127),   # symmetric exact, ceil
        (17, 17, 0, 254, 0, 127, 127),   # symmetric, floor
        (1, 254, 0, 255, 1, 1, 1),       # exact at 1, ceil
        (1, 254, 0, 255, 0, 1, 1),       # floor
        (254, 1, 0, 255, 1, 254, 254),   # exact at 254, ceil (|d| > 127!)
        (254, 1, 0, 255, 0, 254, 254),   # floor (|d| > 127!)
        (207, 150, 0, 255, 1, 148, 149), # WIDE denom (357): inward-safe ceil
        (207, 150, 0, 255, 0, 147, 148), # WIDE denom: inward-safe floor
        (0, 17, 0, 255, 1, 0, 0),        # |d1| = 0: crossing AT cx1
        (10, 5, 100, 100, 1, 100, 100),  # dx = 0
    ]
    for d1, d2, cx1, cx2, p1, lo, hi in CASES:
        true_ceil = None
        for carry in (0, 1):
            got = bix_case(mpu, mem, entry, d1, d2, cx1, cx2, p1, carry)
            good = lo <= got <= hi
            ok &= good
            if not good:
                print(f'  bix |d1|={d1} |d2|={d2} cx=[{cx1},{cx2}] p1={p1} '
                      f'Cin={carry}: got {got} want [{lo},{hi}]  FAIL')
    print(f'  bix matrix: {len(CASES)*2} cases')
    # arm 2: witness renders — every trapped plot in-band
    mem[0xFE30] = 0
    POSES = [(1604.46875, -2487.15625, 252),   # the Model B KIL pose
             (1000, -3160, 156),               # the BL=241 witness
             (1792.34375, -3351.375, 108),
             (-486, -3307, 243)]
    nlines = 0
    for (px, py, ab) in POSES:
        r.render_frame(px, py, ab, dw.player_floor(px, py))
        for (x0, y0, x1, y1) in r.sc.last_lines:
            nlines += 1
            if y0 > 159 or y1 > 159:
                ok = False
                print(f'  OFF-BAND plot at ({px},{py},{ab}): '
                      f'({x0},{y0})-({x1},{y1})')
    print(f'  plot stream: {nlines} lines, all in-band' if ok else '  (violations above)')
    print('SPANBAND:', 'PASS' if ok else 'FAIL')
    return 0 if ok else 1


if __name__ == '__main__':
    sys.exit(main())
