#!/usr/bin/env python3
"""Translation-coherence vertex cache exactness gate: with VXC_ENABLE=1,
every frame must be byte-identical to the cache-off engine at the same
(position, angle) — across forward/backward walks, strafes, diagonal and
fractional-direction steps, interleaved rotations (cold-frame wipes), and
A->B->A revisits (the telescoping base+CACC identity for stale entries).
Also reports the cycle saving on warm frames.
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

EN = sym('VXC_ENABLE')


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
    seq = []
    # forward walk at an odd angle (16-unit steps), then back up
    for i in range(6):
        seq.append((1056 + 3 * i, -3616 - 15 * i, 37))
    for i in range(3):
        seq.append((1056 + 3 * (5 - i), -3616 - 15 * (5 - i), 37))
    # strafe (perpendicular), diagonal drift, tiny 1-unit creeps
    seq += [(1071 + 15 * i, -3691 + 3 * i, 37) for i in range(4)]
    seq += [(1100, -3650, 37), (1101, -3650, 37), (1101, -3649, 37)]
    # rotation interleaved (cold frames), then translation resumes warm
    seq += [(1101, -3649, 45), (1101, -3649, 53), (1090, -3660, 53),
            (1080, -3670, 53), (1080, -3670, 200), (1080, -3690, 200)]
    # A -> B -> A revisit at fixed angle (stale-entry telescoping)
    seq += [(800, -3400, 96), (900, -3400, 96), (800, -3400, 96)]
    bad = 0
    warm_c = warm_o = nwarm = 0
    prev_ab = None
    for (px, py, ab) in seq:
        fz = dw.player_floor(px, py)
        cc = rc.render_frame(px, py, ab, fz)
        co = ro.render_frame(px, py, ab, fz)
        if fb(rc) != fb(ro):
            bad += 1
            print(f'VXCACHE MISMATCH at ({px},{py},{ab})')
        if ab == prev_ab:
            warm_c += cc; warm_o += co; nwarm += 1
        prev_ab = ab
    if nwarm:
        print(f'warm frames: {nwarm}, cycles {warm_c:,} vs {warm_o:,} '
              f'({100*(warm_c-warm_o)/warm_o:+.1f}%)')
    print(f'VXCACHE: {len(seq)} frames, {bad} mismatches — '
          + ('PASS' if bad == 0 else 'FAIL'))
    sys.exit(1 if bad else 0)


if __name__ == '__main__':
    main()
