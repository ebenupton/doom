#!/usr/bin/env python3
"""Rotation-cache exactness gate: warm cached frames must be byte-identical
to the original (uncached) routine at the same (position, angle).

The cache (RCACHE_ENABLE, src/slope_div.s) only changes cycles, never pixels;
this check keeps that contract enforced. Runs a rotate-in-place sequence with
big angle jumps (the historical failure mode: psi stored after the tail had
clipped p1/p2, corrupting warm results at other angles) plus a moved-frame
mix (cache epoch resets).
"""
import os, sys
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), '..'))
os.chdir(os.path.join(os.path.dirname(os.path.abspath(__file__)), '..'))
os.environ.setdefault('SDL_VIDEODRIVER', 'dummy')
os.environ.setdefault('PYGAME_HIDE_SUPPORT_PROMPT', '1')
import pygame; pygame.init()
import doom_wireframe as dw
from bsp_render_6502 import BspRender6502
from symmap import sym

EN = sym('RCACHE_ENABLE')


def mk(enable):
    r = BspRender6502(dw.packed_layout, dw.packed_rom_main, dw.packed_rom_detail,
                      dw.packed_bbox_table, dw.MAP_CENTER_X, dw.MAP_CENTER_Y,
                      dw.PRESCALE)
    r.sc.mpu.memory[EN] = enable
    return r


def fb(r):
    return bytes(r.sc.mpu.memory[r.sc.SCREEN_START:r.sc.SCREEN_START + r.sc.SCREEN_SIZE])


def main():
    rc, ro = mk(1), mk(0)
    bad = 0
    # rotate-in-place with big jumps (incl. the historical killer 1,32,65,129),
    # then a moved frame (epoch reset), then more rotation at the new spot.
    seq = [(1056, -3616, a) for a in (1, 32, 65, 129, 193, 65)] + \
          [(800, -3400, 96), (800, -3400, 40), (800, -3400, 200)]
    for (px, py, ab) in seq:
        fl = dw.player_floor(px, py)
        rc.render_frame(px, py, ab, fl)
        ro.render_frame(px, py, ab, fl)
        if fb(rc) != fb(ro):
            bad += 1
            print(f'ROTCACHE MISMATCH at ({px},{py},{ab})')
    print(f'ROTCACHE: {len(seq)} frames, {bad} mismatches — '
          + ('PASS' if bad == 0 else 'FAIL'))
    sys.exit(1 if bad else 0)


if __name__ == '__main__':
    main()
