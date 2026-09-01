#!/usr/bin/env python3
"""Do the billboards actually get drawn?

THE HOLE THIS CLOSES: on 2026-08-31 a routine landed in the middle of the
object builder's fall-through, so every object overwrote its own y ladder and
returned early -- billboards stopped drawing ALTOGETHER -- and the whole
suite stayed green.  The pixel comparisons do not cover billboards, so
nothing else in the gate can see this class of failure.

Count the art stamps over the render corpus and check the total and the
per-template split.
"""
import os, sys, collections
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, ROOT); sys.path.insert(0, os.path.join(ROOT, 'tools'))
os.environ.setdefault('SDL_VIDEODRIVER', 'dummy')
os.environ['PYGAME_HIDE_SUPPORT_PROMPT'] = '1'
import pygame; pygame.init()
import doom_wireframe as dw, compare_renders as C
from banked_bsp import BankedBspRender
from symmap import sym

# Counted per template start, named by the KIND byte.  The pickup landing
# (2026-08-31) put 44 more billboards in the map; EXPECT is the measured
# corpus census -- any drop is a lost draw.  LAMP fell 11 -> 8 when the
# candelabras were removed outright (they had borrowed the template and
# accounted for three of the corpus's stamps).
EXPECT = {'HEX': 9, 'LAMP': 8,
          'POTION': 7, 'HELMET': 23, 'BOXS': 1, 'BOXM': 2, 'VEST': 1}
# (POTION 9 -> 7, 2026-09-01: the armour-room strip removed the only two
#  zigzag-room potions the corpus ever had in view; the room's helmets
#  never stamped from the corpus positions, so HELMET holds at 23.)

def main():
    r = BankedBspRender(dw.packed_layout, dw.packed_rom_main, dw.packed_rom_detail,
                        dw.packed_bbox_table, dw.MAP_CENTER_X, dw.MAP_CENTER_Y,
                        dw.PRESCALE)
    mpu = r.sc.mpu; mem = mpu.memory
    entry = sym('render_frame', banked=1)
    STAMP = sym('obj_stamp', banked=1)
    OE = sym('obj_e', banked=1)
    OASP = sym('obj_asp', banked=1)
    KINDS = ('HEX','LAMP','POTION','HELMET','BOXS','BOXM','VEST')
    TPL_OFF = ({0}, {52}, {28, 160}, {88}, {0, 76}, {0, 76}, {160})
    n = collections.Counter(); last = [None]
    for (px, py, ab) in C.POSITIONS:
        r.render_frame(px, py, ab, dw.player_floor(px, py))
        r.sc.init(); r.sc.clear_screen()
        mpu.pc = entry; mpu.sp = 0xDD; mpu.p = 0x30
        mem[0x01DF] = 0xFE; mem[0x01DE] = 0xFF
        k = 0
        while mpu.pc != 0xFF00 and k < 3_000_000:
            # obj_e ADVANCES through the template, so only count the first
            # entry of each object -- and only when it is a template start.
            if mpu.pc == STAMP:
                e = mem[OE]; kind = mem[OASP]
                key = (kind, e)
                if e in TPL_OFF[kind] and key != last[0]:
                    n[KINDS[kind]] += 1
                last[0] = key
            mpu.step(); k += 1
    got = dict(n)
    print(f'  stamps: {got}  (expect {EXPECT})')
    ok = got == EXPECT
    print('OBJDRAWS:', 'PASS' if ok else f'FAIL (got {got}, expect {EXPECT})')
    return 0 if ok else 1

if __name__ == '__main__':
    sys.exit(main())
