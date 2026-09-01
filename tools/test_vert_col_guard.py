#!/usr/bin/env python3
"""dv_emit Y-band safety clip — the Model B KIL of 2026-09-01.

The tighten's apertures extend off-screen, so the vertical fastpath's
cy1/cy2 arrive biased outside [Y_BIAS, VIS_YMAX] (state-file autopsy:
column 164, Y0 = $FA = biased 42 unbias-wrapped).  vplot indexes vptab
by the raw row, read past the table, and the PHA/PHA/RTS dispatch
executed table bytes until a KIL jammed the CPU.  dcl_emit_segment has
carried the equivalent clip all along; dv_emit_band is its vertical
twin.  This gate drives dv_emit_band directly through every band case.
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

Y_BIAS, VIS_YMAX = 48, 207


def main():
    r = banked_bsp.BankedBspRender(dw.packed_layout, dw.packed_rom_main,
                                   dw.packed_rom_detail, dw.packed_bbox_table,
                                   dw.MAP_CENTER_X, dw.MAP_CENTER_Y, dw.PRESCALE)
    mpu = r.sc.mpu; mem = mpu.memory
    band = sym('dv_emit_band', banked=1)
    op = sym('dv_emit_op', banked=1)
    cy1 = sym('zp_cb_cy1', banked=1); cy2 = sym('zp_cb_cy2', banked=1)
    xl = sym('zp_line_xl_l', banked=1)
    X0, Y0, X1, Y1 = (sym(f'RASTER_ZP_{n}', banked=1) for n in ('X0', 'Y0', 'X1', 'Y1'))
    # park the SMC dispatch on a sentinel RTS so a staged emit "returns"
    mem[0x1200] = 0x60
    mem[op + 1] = 0x00
    mem[op + 2] = 0x12
    # (case, biased cy1, biased cy2, expect) — expect None = rejected,
    # else (screen y0, screen y1)
    CASES = [
        ('crash twin (top above)',  42, 84,   (0, 36)),
        ('in-band',                 60, 100,  (12, 52)),
        ('bottom below',            60, 240,  (12, 159)),
        ('both above',              10, 40,   None),
        ('both below',              210, 250, None),
        ('crosses whole band',      2, 250,   (0, 159)),
        ('exact band edges',        48, 207,  (0, 159)),
    ]
    ok = True
    for name, c1, c2, want in CASES:
        mem[cy1] = c1; mem[cy2] = c2; mem[xl] = 164
        for z in (X0, Y0, X1, Y1): mem[z] = 0xEE          # poison
        mpu.pc = band; mpu.sp = 0xF0; mpu.p = 0x30
        mem[0x01F1] = 0xFE; mem[0x01F2] = 0x12            # RTS -> $12FF
        steps = 0
        while steps < 4000 and mpu.pc != 0x12FF:
            mpu.step(); steps += 1
        staged = mem[X0] != 0xEE
        if want is None:
            good = not staged
            print(f'  {name}: {"rejected" if not staged else "STAGED?!"}')
        else:
            good = staged and (mem[Y0], mem[Y1]) == want and mem[X0] == mem[X1] == 164
            print(f'  {name}: staged y=[{mem[Y0]},{mem[Y1]}] x={mem[X0]} '
                  f'(want {want})')
        ok &= good and mpu.pc == 0x12FF
    print('VERTCOLGUARD:', 'PASS' if ok else 'FAIL')
    return 0 if ok else 1


if __name__ == '__main__':
    sys.exit(main())
