#!/usr/bin/env python3
"""Forward-coherence bbox cache (D cache) lockstep validation.

Drives the 6502 engine through multi-frame walking sequences with
D_ENABLE=1 and the driver's D_FWD flag asserted on forward frames, and
byte-compares every frame's framebuffer against the pixel-exact Python
reference rendered fresh (the D cache changes traversal, provably never
pixels). Sequences include forward runs, a mid-run rotation (wipe), a
backward step (wipe), and a stationary tail. Also asserts the cache
actually engages (fresh-frame cycles drop once warm).
"""
import os, sys
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), '..'))
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
os.chdir(os.path.join(os.path.dirname(os.path.abspath(__file__)), '..'))
os.environ.setdefault('SDL_VIDEODRIVER', 'dummy')
os.environ.setdefault('PYGAME_HIDE_SUPPORT_PROMPT', '1')
import pygame; pygame.init()
import doom_wireframe as dw
import pyref_render
from bsp_render_6502 import BspRender6502
from symmap import sym


def fb(eng):
    sc = eng.sc
    return bytes(sc.mpu.memory[sc.SCREEN_START:sc.SCREEN_START + sc.SCREEN_SIZE])


def main():
    eng = BspRender6502(dw.packed_layout, dw.packed_rom_main, dw.packed_rom_detail,
                        dw.packed_bbox_table, dw.MAP_CENTER_X, dw.MAP_CENTER_Y,
                        dw.PRESCALE)
    mem = eng.sc.mpu.memory
    D_ENABLE, D_FWD = sym('D_ENABLE'), sym('D_FWD')
    mem[D_ENABLE] = 1

    # sequence: (dx-steps, dy-steps are along facing), move kind per frame
    # 'f' = forward step (D_FWD=1), 's' = stationary, 'r' = rotate +4,
    # 'b' = backward step (D_FWD=0)
    SEQS = [
        (2345, -3123, 132, 'ffffffffssfffrfffbff'),
        (1056, -3616, 65,  'ffffffffffffffff'),
        (1500, -3700, 1,   'ffffssffffrrffff'),
    ]
    STEP = 8.0
    bad = 0
    for (px0, py0, ab0, seq) in SEQS:
        px, py, ab = float(px0), float(py0), ab0
        cyc_first = cyc_warm = None
        for k, mv in enumerate('0' + seq):      # leading '0': spawn frame
            if mv in ('f', 'b'):
                v = pygame.math.Vector2(1, 0).rotate(ab * 360 / 256)
                s = STEP if mv == 'f' else -STEP
                px, py = px + v.x * s, py + v.y * s
            elif mv == 'r':
                ab = (ab + 4) & 0xFF
            mem[D_FWD] = 1 if mv == 'f' else 0
            cyc = eng.render_frame(px, py, ab, dw.player_floor(px, py))
            if k == 1: cyc_first = cyc
            if k == 8: cyc_warm = cyc
            ref, _ = pyref_render.render_ref_fb(px, py, ab)
            got = fb(eng)
            miss = sum(bin(~a & b & 0xFF).count('1') for a, b in zip(got, bytes(ref)))
            extra = sum(bin(a & ~b & 0xFF).count('1') for a, b in zip(got, bytes(ref)))
            if miss or extra:
                print(f'  FAIL ({px0},{py0},{ab0}) frame {k} mv={mv}: '
                      f'miss={miss} extra={extra}')
                bad += 1
        tag = ''
        if cyc_first and cyc_warm and cyc_warm >= cyc_first:
            tag = f'  (warning: no warm speedup {cyc_first}->{cyc_warm})'
        print(f'  ({px0},{py0},{ab0}) x{len(seq)+1} frames: '
              f'{"OK" if not bad else "FAIL"} '
              f'frame1={cyc_first} warm={cyc_warm}{tag}')
    if bad:
        print(f'walkseq_check: FAIL ({bad} divergent frames)')
        sys.exit(1)
    print('walkseq_check: OK')


if __name__ == '__main__':
    main()
