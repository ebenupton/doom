#!/usr/bin/env python3
"""The pickup ladder builders vs doc/billboard's integer mirrors, BOTH TIERS.

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

def m_box(kind, H, a, cx, syt, syb, lod=0):
    st = kind == 4
    lid = (H * (51 if st else 54) + 128) >> 8
    d = {('Y',0): syt, ('Y',2): syt+lid, ('Y',4): syb}
    if lod:
        rear = R(a * (183 if st else 201))
        cw, tx = R(a * (110 if st else 55)), R(a * (37 if st else 18))
        ch, tz = R(H * (51 if st else 40)), R(H * (17 if st else 13))
        yc = syt + ((lid + H) >> 1)
        d.update({('Y',26): cx-rear, ('Y',28): cx+rear,
                  ('X',2): cx-cw, ('X',8): cx+cw,
                  ('X',4): cx-tx, ('X',6): cx+tx,
                  ('Y',6): yc-ch, ('Y',12): yc+ch,
                  ('Y',8): yc-tz, ('Y',10): yc+tz})
    return d

def m_potion(kind, H, a, cx, syt, syb, lod=0):
    # SINGLE-TIER (2026-09-03): the builder is unconditionally the POTL0
    # dodecagon ladder (a3 stem + near y ladder) — the far arm died with
    # the (585,-3437,244) crash; obj_lod is ignored.
    qa, a3 = R(a*187), R(a*69)
    return {('X',2): cx-qa, ('X',8): cx+qa, ('Y',0): syt,
            ('X',4): cx-a3, ('X',6): cx+a3,
            ('Y',2): syb-2*a, ('Y',4): syb-(a+qa), ('Y',6): syb-(a+a3),
            ('Y',8): syb-(a-a3), ('Y',10): syb-(a-qa), ('Y',12): syb}

def m_helmet(kind, H, a, cx, syt, syb, lod=0):
    # 2026-09-02 hoplite: +fx (166 = temple-flare reach 5.2) and +dxf
    # (176 = diagonal foot 5.5); y grows the eyehole roof / wall top /
    # diagonal top; syb moved to Y+12.
    x6, x4, x3, x2, fx, dxf = (R(a*f) for f in (192, 128, 96, 64, 166, 176))
    d = {('X',2): cx-x6, ('X',44): cx+x6, ('X',4): cx-x4, ('X',42): cx+x4,
         ('X',6): cx-x3, ('X',40): cx+x3, ('X',8): cx-x2, ('X',38): cx+x2,
         ('X',46): cx-fx, ('X',48): cx+fx, ('X',50): cx-dxf, ('X',52): cx+dxf,
         ('Y',0): syt, ('Y',12): syb}
    for off, f in ((2,34),(4,85),(6,162),(8,196),(10,205)):
        d[('Y',off)] = syt + R(H*f)
    return d

def m_vest(kind, H, a, cx, syt, syb, lod=0):
    # 2026-09-02 re-tier: 6 mirrored x mags + the centre at X+62; 13 y
    # levels; syb at Y+28.
    w, sc, px, so, w1, cr, cc = (R(a*f) for f in (91, 50, 173, 223, 144, 136, 246))
    d = {('X',2): cx-w, ('X',8): cx+w, ('X',4): cx-sc, ('X',6): cx+sc,
         ('X',42): cx-px, ('X',44): cx+px, ('X',46): cx-so, ('X',48): cx+so,
         ('X',50): cx-w1, ('X',52): cx+w1, ('X',54): cx-cr, ('X',56): cx+cr,
         ('X',58): cx-cc, ('X',60): cx+cc, ('X',62): cx,
         ('Y',0): syt, ('Y',28): syb}
    for off, f in ((2,4),(4,5),(6,15),(8,30),(10,35),(12,45),(14,60),
                   (16,69),(18,75),(20,90),(22,105),(24,175),(26,244)):
        d[('Y',off)] = syt + R(H*f)
    return d

CASES = [(4, 'obj_box_y', m_box, (0, 1)), (5, 'obj_box_y', m_box, (0, 1)),
         (2, 'obj_potion_xy', m_potion, (0, 1)),
         (3, 'obj_helmet_xy', m_helmet, (0,)), (6, 'obj_vest_xy', m_vest, (0,))]
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
    OLOD = sym('obj_lod', banked=1)
    def s16(v): return v - 0x10000 if v >= 0x8000 else v
    bad = 0
    for kind, entry, mirror, lods in CASES:
        E = sym(entry, banked=1)
        for lod in lods:
          for H in (255, 200, 152, 101, 76, 50, 34, 21, 12, 5):
            a = (H * KTAB[kind] + 32) >> 6
            for cx, syt in ((80, 40), (3, 0), (140, 150)):
                syb = syt + H
                mem[OH] = H; mem[OA] = a; mem[OASP] = kind; mem[OLOD] = lod
                mem[OCX] = cx & 0xFF; mem[OCX+1] = 0
                mem[OYT] = syt & 0xFF; mem[OYT+1] = (syt >> 8) & 0xFF
                mem[OYB] = syb & 0xFF; mem[OYB+1] = (syb >> 8) & 0xFF
                mem[0xFE30] = BANK_C
                sc._run(E)
                want = mirror(kind, H, a, cx, syt, syb, lod)
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
