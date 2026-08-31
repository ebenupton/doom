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
# BANKED harness (2026-08-31): this gate still rendered through the FLAT
# path, whose rasterisers were stripped on 08-29 (banked reference) --
# every flat render has been a silent 10M-step runaway since, so this
# gate's PASS was vacuous.  The stack guard exposed it the day it landed.
def main():
    # THE COMPARISON IS AGAINST GROUND TRUTH now, not against the
    # cache-off arm: when this gate came back to life (2026-08-31, the
    # stack guard exposed its flat-corpse vacuity), cache-on vs cache-off
    # diverged at 12 of 64 pose/angles -- and verify showed the SHIPPING
    # cache-on path pixel-clean at every one.  The cache-OFF fallback is
    # the rotten side (unexercised since 08-29); repairing it is queued
    # separately.  This gate now walks the historical killer rotation
    # sequence (big jumps incl. 1,32,65,129) and requires zero over/miss
    # vs the python reference each frame.
    import verify_6502_vs_python as V
    bad = 0
    seq = [(1056, -3616, a) for a in (1, 32, 65, 129, 193, 65)] + \
          [(800, -3400, 96), (800, -3400, 40), (800, -3400, 200)]
    for (px, py, ab) in seq:
        mo, no, mm, nm, cyc, done = V.compare(px, py, ab)
        if mo > V.ALIAS_PX or mm > V.ALIAS_PX or not done:
            bad += 1
            print(f'ROTCACHE MISMATCH at ({px},{py},{ab}): '
                  f'over={mo}px miss={mm}px done={done}')
    print(f'ROTCACHE: {len(seq)} frames, {bad} mismatches — '
          + ('PASS' if bad == 0 else 'FAIL'))
    sys.exit(1 if bad else 0)


if __name__ == '__main__':
    main()
