#!/usr/bin/env python3
"""obj_lamp_xy: does the 6502 build the floor lamp's 10-x / 13-y ladder?

Poke obj_a / obj_h / obj_cx / obj_yt / obj_yb, run the routine, read the
slots back, and compare against the integer mirror -- whose fractions are
doc/billboard's lamp L1 VERBATIM.  Unit test, not an end-to-end one: the
ladder is the piece with the arithmetic in it.
"""
import os, sys
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, ROOT); sys.path.insert(0, os.path.join(ROOT, 'tools'))
os.environ.setdefault('SDL_VIDEODRIVER', 'dummy')
os.environ['PYGAME_HIDE_SUPPORT_PROMPT'] = '1'
import pygame; pygame.init()
import doom_wireframe as dw
from banked_bsp import BankedBspRender, BANK_C
from symmap import sym

GX = (167, 166, 122, 109)          # x magnitudes /256 of a (5th is a)
GY = (174, 176, 177, 178, 180,     # y_1..y_11 /256 of H below syt
      218, 221, 224, 226, 229, 252)
# x byte offsets from obj_X, ladder index 0..9 ascending: +-a keep
# obj_X+0/+10 (the obj_probe silhouette-edge contract), the inner +side
# values spill to obj_Y[13..16].
LXOFF = (0, 2, 4, 6, 8, 38, 40, 42, 44, 10)


def mirror(H, a, cx, syt):
    m = [a] + [(a * g + 128) >> 8 for g in GX]        # descending magnitude
    xs = [cx - v for v in m] + [cx + v for v in reversed(m)]
    ys = [syt] + [syt + ((H * g + 128) >> 8) for g in GY] + [syt + H]
    return xs, ys


def main():
    r = BankedBspRender(dw.packed_layout, dw.packed_rom_main, dw.packed_rom_detail,
                        dw.packed_bbox_table, dw.MAP_CENTER_X, dw.MAP_CENTER_Y,
                        dw.PRESCALE)
    sc = r.sc; mem = sc.mpu.memory
    E = sym('obj_lamp_xy', banked=1)
    OH = sym('obj_h', banked=1); OA = sym('obj_a', banked=1)
    OCX = sym('obj_cx_l', banked=1)
    OYT = sym('obj_yt_l', banked=1); OYB = sym('obj_yb_l', banked=1)
    OX = sym('obj_X', banked=1); OY = sym('obj_Y', banked=1)
    def s16(v): return v - 0x10000 if v >= 0x8000 else v
    bad = 0
    for H in (228, 190, 152, 114, 95, 76, 57, 45, 38, 28, 19, 12, 7, 3):
        a = (H * 15 + 32) >> 6                        # the lamp's k = 15
        for cx, syt in ((80, 40), (3, 0), (140, 150)):
            mem[OH] = H; mem[OA] = a
            mem[OCX] = cx & 0xFF; mem[OCX+1] = 0
            mem[OYT] = syt & 0xFF; mem[OYT+1] = (syt >> 8) & 0xFF
            yb = syt + H
            mem[OYB] = yb & 0xFF; mem[OYB+1] = (yb >> 8) & 0xFF
            mem[0xFE30] = BANK_C                      # tables live in bank C
            sc._run(E)
            gx = [s16(mem[OX+o] | (mem[OX+o+1] << 8)) for o in LXOFF]
            gy = [s16(mem[OY+2*i] | (mem[OY+2*i+1] << 8)) for i in range(13)]
            wx, wy = mirror(H, a, cx, syt)
            if gx != wx or gy != wy:
                bad += 1
                print(f'  H={H} a={a} cx={cx} syt={syt}')
                print(f'    got  x {gx}\n    want x {wx}')
                print(f'    got  y {gy}\n    want y {wy}')
                continue
            # extent: y_0 = syt and y_12 = syb EXACTLY -- the drawn figure
            # spans the whole projected height.
            if gy[0] != syt or gy[12] != syt + H:
                bad += 1
                print(f'  H={H} syt={syt}: extent {gy[0]}..{gy[12]} != {syt}..{syt+H}')
            # both ladders monotone (non-decreasing after rounding): a
            # crossing means some pair of art lines swaps sides.
            if any(gx[i] > gx[i+1] for i in range(9)) or \
               any(gy[i] > gy[i+1] for i in range(12)):
                bad += 1
                print(f'  H={H} a={a} cx={cx}: ladder not monotone\n    x {gx}\n    y {gy}')
    print('LAMPLADDER:', 'PASS' if not bad else f'FAIL ({bad})')
    return 1 if bad else 0

if __name__ == '__main__':
    sys.exit(main())
