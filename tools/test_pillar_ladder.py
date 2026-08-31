#!/usr/bin/env python3
"""obj_pillar_y: does the 6502 build the techno pillar's 18-slot y ladder?

Poke obj_h / obj_yt / obj_yb, run the routine, read obj_Y back, and compare
against the integer mirror -- which is itself checked against the geometry in
doc/billboard.  Unit test, not an end-to-end one: the ladder is the piece
with the arithmetic in it.
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

RIMS_M = (46, 43, 19, 22)          # 65536*|z-41| / (h*K/k*64), z = 128,122.83,4.9,0

def mirror(H, syt):
    P = H * H
    Ph, Pl = P >> 8, P & 0xFF
    b = [(Ph * M + ((Pl * M) >> 8) + 128) >> 8 for M in RIMS_M]
    cyA = syt + b[0]
    cyD = syt + H - b[3]
    S = cyD - cyA
    cy = [cyA,
          cyA + ((S * 10 + 128) >> 8),
          cyA + ((S * 246 + 128) >> 8),
          cyD]
    mag = []
    for bb in b:
        b2 = (bb * 47 + 32) >> 6
        mag += [bb, b2, bb - b2, 0]
    TAB = [0x00,0x01,0x02, 0x04,0x05,0x06,0x07, 0x86,0x85,
           0x09,0x0A,0x0B, 0x8A,0x89,0x88, 0x8E,0x8D,0x8C]
    out = []
    for d in TAB:
        m = mag[d & 0x0F]
        c = cy[(d & 0x0C) >> 2]
        out.append(c + m if d & 0x80 else c - m)
    return out


def main():
    r = BankedBspRender(dw.packed_layout, dw.packed_rom_main, dw.packed_rom_detail,
                        dw.packed_bbox_table, dw.MAP_CENTER_X, dw.MAP_CENTER_Y,
                        dw.PRESCALE)
    sc = r.sc; mem = sc.mpu.memory
    E = sym('obj_pillar_y', banked=1)
    OH = sym('obj_h', banked=1); OYT = sym('obj_yt_l', banked=1)
    OYB = sym('obj_yb_l', banked=1); OY = sym('obj_Y', banked=1)
    def s16(v): return v - 0x10000 if v >= 0x8000 else v
    bad = 0
    for H in (202, 180, 152, 128, 101, 88, 76, 60, 50, 38, 30, 25, 19, 12, 6, 3):
        for syt in (0, 40, 200):
            mem[OH] = H
            mem[OYT] = syt & 0xFF; mem[OYT+1] = (syt >> 8) & 0xFF
            yb = syt + H
            mem[OYB] = yb & 0xFF; mem[OYB+1] = (yb >> 8) & 0xFF
            # obj_pM / opy_frac / obj_pytab live with the art in BANK C, and
            # the object prologue has already paged it by the time the real
            # caller gets here.  Page it for the unit test too.
            mem[0xFE30] = BANK_C
            sc._run(E)
            got = [s16(mem[OY+2*i] | (mem[OY+2*i+1] << 8)) for i in range(18)]
            want = mirror(H, syt)
            if got != want:
                bad += 1
                print(f'  H={H} syt={syt}')
                print(f'    got  {got}')
                print(f'    want {want}')
                continue
            # the invariant that matters: the ladder spans exactly H
            if got[17] - got[0] != H:
                bad += 1
                print(f'  H={H} syt={syt}: extent {got[17]-got[0]} != {H}')
            # Monotonic WITHIN each rim's group -- b >= b2 >= b3, or that
            # rim's arc edges cross (the trap obj_s7 documents).  NOT across
            # the whole ladder: different rims' arcs legitimately interleave,
            # the cap's top arc reaching below its own lower rim's apex.
            for lo, hi in ((0, 3), (3, 9), (9, 15), (15, 18)):
                g = got[lo:hi]
                if any(g[i] > g[i+1] for i in range(len(g)-1)):
                    bad += 1
                    print(f'  H={H} syt={syt}: rim group {lo}:{hi} not ordered {g}')
    print('PILLARLADDER:', 'PASS' if not bad else f'FAIL ({bad})')
    return 1 if bad else 0

if __name__ == '__main__':
    sys.exit(main())
