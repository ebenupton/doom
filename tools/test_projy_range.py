#!/usr/bin/env python3
"""project_y raw-body domain sweep: every distinct recip (M8, S) the
table can produce, PLUS the half-unit tier's bumped (M8, S+1) pairs
(which reach S=11, the 2026-08-25 kernel), against fp_project_y for
every h in [-127, 127].

This is the certificate behind the projection-bound fence's |h| <= 127
domain (doom_wireframe._projection_bound_fence): the raw body's
constant ext bytes ($00 / $FF) and mod-256 mid arithmetic are exact for
the whole s8 range, not just the old |h| <= 64 claim. If someone
re-tightens the body in a way that reintroduces the narrow bound, this
sweep goes red before the fence's map arithmetic ever could.
"""
import os, sys
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, ROOT)
os.chdir(ROOT)
os.environ.setdefault('SDL_VIDEODRIVER', 'dummy')
os.environ.setdefault('PYGAME_HIDE_SUPPORT_PROMPT', '1')
import pygame; pygame.init()
import doom_wireframe as dw
from bsp_render_6502 import BspRender6502
import symmap, fp


def main():
    r = BspRender6502(dw.packed_layout, dw.packed_rom_main,
                      dw.packed_rom_detail, dw.packed_bbox_table,
                      dw.MAP_CENTER_X, dw.MAP_CENTER_Y, dw.PRESCALE)
    sc = r.sc
    m = sc.mpu.memory
    S_ = symmap.sym
    pe = S_('project_y')
    M8, RS, T0 = S_('zp_br_r_m8'), S_('zp_br_r_s'), S_('zp_br_t0')
    vycache_rs = S_('VYCACHE_R_S')
    go_op, vec = S_('rns_go_op'), S_('rns_vec_l')
    mpu = sc.mpu

    recs = {fp.fp_recip(i) for i in range(1, 1024)}
    pairs = set()
    for (m8v, sv) in recs:
        pairs.add((m8v, sv))
        pairs.add((m8v, sv + 1))       # the half-unit tier's S bump
    pairs = sorted(p for p in pairs if 1 <= p[1] <= 11)

    bad = n = 0
    for (m8v, sv) in pairs:
        for h in range(-127, 128):
            m[vycache_rs + ((h & 0xFF) ^ m8v)] = 0    # force the raw body
            m[M8], m[RS], m[T0] = m8v, sv, h & 0xFF
            m[go_op] = m[vec - 1 + sv]     # caller contract: the kernel is
                                           # SMC-selected (RNS_SELECT)
            mpu.pc = pe
            mpu.sp = 0xDD
            mpu.a = h & 0xFF
            m[0x1DE] = 0xFF; m[0x1DF] = 0xFE
            k = 0
            while mpu.pc != 0xFF00 and k < 4000:
                mpu.step(); k += 1
            assert mpu.pc == 0xFF00, f'wedge h={h} m8={m8v} s={sv}'
            got = (mpu.a << 8) | mpu.y
            if got >= 0x8000:
                got -= 0x10000
            # project_y's output is PRE-BIASED (Y_BIAS folded into the
            # 128 constant); fp_project_y is the unbiased reference
            want = fp.fp_project_y(h, m8v, sv) + 48   # endpoint_spans.Y_BIAS
            n += 1
            if got != want:
                bad += 1
                if bad <= 10:
                    print(f'MISMATCH h={h} m8={m8v} S={sv}: '
                          f'6502={got} py={want}')
    print(f'{n} cases ({len(pairs)} recip/S pairs), {bad} mismatches')
    print('PROJY-RANGE: ' + ('PASS' if bad == 0 else 'FAIL'))
    return 1 if bad else 0


if __name__ == '__main__':
    sys.exit(main())
