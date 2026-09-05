#!/usr/bin/env python3
"""Which quarter-square sites could drop their overflow arm?

a*b = f(a+b) - f(|a-b|) needs f over 0..510, so the sum index is NINE bits
and every site carries two arms: sqr_l/h when a+b fits a byte, sqr2_l/h
when it carries.  If BOTH operands are bounded by 127 the sum cannot carry
— a+b <= 254, |a-b| <= 127 — the branch and the sqr2 arm both go, and the
site reads one table pair.  (Noted for the Z80 in doom-z80's
umul8x8-z80.md, where the same bound removes 9-bit pointer synthesis; on
the 6502 what it removes is the branch.)

The operands are recovered exactly from the indices the site uses: the
first read of every site is `LDA sqr_l,X` or `LDA sqr2_l,X` with X = a+b
(the table choice supplying the ninth bit) and Y = |a-b|, so
a = (s+d)/2, b = (s-d)/2.

A corpus can only ever show a site is NOT 7-bit-safe.  Sites it never
falsifies are candidates whose bound then has to be argued from the
pipeline, not from the census.
"""
import os, sys, collections

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, ROOT)
os.chdir(ROOT)
os.environ.setdefault('SDL_VIDEODRIVER', 'dummy')
os.environ.setdefault('PYGAME_HIDE_SUPPORT_PROMPT', '1')
import pygame; pygame.init(); pygame.display.set_mode((1, 1))
import doom_wireframe as dw
from banked_bsp import BankedBspRender
import compare_renders as C
import symmap

LDA_ABX = 0xBD


def main():
    sqr_l = symmap.sym('sqr_l', banked=1)
    sqr2_l = symmap.sym('sqr2_l', banked=1)
    first = {sqr_l: 0, sqr2_l: 256}          # base -> the sum's ninth bit
    r = BankedBspRender(dw.packed_layout, dw.packed_rom_main,
                        dw.packed_rom_detail, dw.packed_bbox_table,
                        dw.MAP_CENTER_X, dw.MAP_CENTER_Y, dw.PRESCALE)
    sc = r.sc; mpu = sc.mpu; mem = mpu.memory
    site = collections.defaultdict(
        lambda: dict(n=0, mx=0, msum=0, ovf=0, pairs=collections.Counter()))
    frame = [0]

    def traced(entry, max_cycles=10_000_000):
        mpu.pc = entry; mpu.sp = 0xDD; mpu.p = 0x30
        mem[0x1DF] = 0xFE; mem[0x1DE] = 0xFF
        mpu.processorCycles = 0
        while mpu.pc != 0xFF00:
            pc = mpu.pc
            if mem[pc] == LDA_ABX:
                base = mem[pc + 1] | (mem[pc + 2] << 8)
                hi = first.get(base)
                if hi is not None:
                    s = mpu.x + hi
                    d = mpu.y
                    a, b = (s + d) >> 1, (s - d) >> 1
                    assert a + b == s and abs(a - b) == d, (pc, s, d)
                    st = site[pc]
                    st['n'] += 1
                    st['mx'] = max(st['mx'], a, b)
                    st['msum'] = max(st['msum'], s)
                    st['ovf'] += (s > 255)
            mpu.step()
        sc.last_cycles = mpu.processorCycles
        sc.total_cycles += mpu.processorCycles
        frame[0] += mpu.processorCycles
        return mpu.processorCycles

    sc._run = traced
    for (px, py, ab) in C.POSITIONS:
        r.render_frame(px, py, ab, dw.player_floor(px, py))
    nfr = len(C.POSITIONS)

    # a site is the PAIR of arms; group them by the arm that is not sqr2
    tbl, _ = symmap._load(banked=1, c02=0)
    names = sorted(((v, k) for k, v in tbl.items() if isinstance(v, int)))

    def near(a):
        lo, hi = 0, len(names)
        while lo < hi:
            mid = (lo + hi) // 2
            if names[mid][0] <= a:
                lo = mid + 1
            else:
                hi = mid
        return names[lo - 1] if lo else (0, '?')

    tot = sum(s['n'] for s in site.values())
    print(f'frame MEAN {frame[0] / nfr:,.0f} cyc; {tot:,} quarter-square '
          f'multiplies over {nfr} frames = {tot / nfr:,.0f}/frame\n')
    print(f'{"site":>6} {"execs/fr":>9} {"max a,b":>8} {"max a+b":>8} '
          f'{"carries":>9} {"7-bit?":>7}  enclosing')
    cands = 0
    for pc, s in sorted(site.items(), key=lambda kv: -kv[1]['n']):
        v, k = near(pc)
        ok = s['mx'] <= 127
        cands += s['n'] if ok else 0
        print(f'${pc:04X} {s["n"] / nfr:9.1f} {s["mx"]:8} {s["msum"]:8} '
              f'{s["ovf"] / s["n"]:8.0%} {"YES" if ok else "no":>7}  '
              f'{k}+{pc - v}')
    print(f'\n{cands / nfr:,.1f} of {tot / nfr:,.1f} multiplies a frame are at '
          f'sites the corpus never falsifies ({cands / max(1, tot):.0%})')


if __name__ == '__main__':
    main()
