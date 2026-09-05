#!/usr/bin/env python3
"""Would an identity table (ident[i] = i) pay?

The trick: `LDY ident+k,X` leaves Y = X+k in 4 cycles (5 across a page),
and `LDX ident+k,Y` the mirror, where the register file's own route is
TXA / CLC / ADC #k / TAY -- 8 cycles, 5 bytes, and it destroys A.  The
same table serves `LDA ident+k,X` for A = X+k at 4 against 6.

So the question is empirical: how much of the frame is spent moving an
index register with a constant added?  This censuses the EXECUTED stream
for the patterns a table would replace, weighted by how often each runs:

  T1  TXA/TYA  CLC  ADC #k  TAX/TAY       8 -> 4
  T2  TXA/TYA  CLC  ADC #k                6 -> 4              (A = reg+k)
  T3  INX/INY runs of n >= 3              2n -> 4

THE CLC IS REQUIRED, and that is the whole subtlety: an `ADC #k` with no
CLC before it is propagating a CARRY, not adding a constant, and a table
lookup cannot do that -- `LDY ident+k,X` ignores the flag.  The first cut
of this census allowed the CLC to be absent and duly reported the two
carry-propagation sites in rwp_o2h/rwp_o4h (22.7 execs a frame each) as
the biggest win on offer, which would have been 91 of a claimed 110
cycles a frame that do not exist.
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

TXA, TYA, TAX, TAY = 0x8A, 0x98, 0xAA, 0xA8
CLC, ADCI, SEC = 0x18, 0x69, 0x38
INX, INY, DEX, DEY = 0xE8, 0xC8, 0xCA, 0x88
SIZE = {CLC: 1, SEC: 1, TXA: 1, TYA: 1, TAX: 1, TAY: 1, INX: 1, INY: 1,
        DEX: 1, DEY: 1, ADCI: 2}


def main():
    r = BankedBspRender(dw.packed_layout, dw.packed_rom_main,
                        dw.packed_rom_detail, dw.packed_bbox_table,
                        dw.MAP_CENTER_X, dw.MAP_CENTER_Y, dw.PRESCALE)
    r.sc.mpu.memory[symmap.sym('ok_state', banked=1)] = 0
    sc = r.sc; mpu = sc.mpu; mem = mpu.memory
    exec_at = collections.Counter()
    frame = [0]

    def traced(entry, max_cycles=10_000_000):
        mpu.pc = entry; mpu.sp = 0xDD; mpu.p = 0x30
        mem[0x1DF] = 0xFE; mem[0x1DE] = 0xFF
        mpu.processorCycles = 0
        while mpu.pc != 0xFF00:
            exec_at[mpu.pc] += 1
            mpu.step()
        sc.last_cycles = mpu.processorCycles
        sc.total_cycles += mpu.processorCycles
        frame[0] += mpu.processorCycles
        return mpu.processorCycles

    sc._run = traced
    for (px, py, ab) in C.POSITIONS:
        r.render_frame(px, py, ab, dw.player_floor(px, py))
    nfr = len(C.POSITIONS)

    tbl, _ = symmap._load(banked=1, c02=0)
    items = sorted((v, k) for k, v in tbl.items() if isinstance(v, int))

    def near(a):
        lo, hi = 0, len(items)
        while lo < hi:
            m = (lo + hi) // 2
            if items[m][0] <= a: lo = m + 1
            else: hi = m
        return items[lo - 1] if lo else (0, '?')

    hits = []
    for pc, n in exec_at.items():
        op = mem[pc]
        if op in (TXA, TYA):
            i = pc + 1
            cyc = 2
            if mem[i] != CLC:          # no CLC => carry-live, not a constant add
                continue
            i += 1; cyc += 2
            if mem[i] != ADCI:
                continue
            k = mem[i + 1]; i += 2; cyc += 2
            kind = 'T2'
            if mem[i] in (TAX, TAY):
                i += 1; cyc += 2; kind = 'T1'
            hits.append((n, pc, kind, k, cyc, 4))
        elif op in (INX, INY):
            j = pc; cnt = 0
            while mem[j] == op:
                cnt += 1; j += 1
            if cnt >= 3 and exec_at.get(pc - 1, -1) != n:   # run head
                hits.append((n, pc, f'T3x{cnt}', cnt, 2 * cnt, 4))
    hits.sort(reverse=True)
    tot_now = sum(n * c for n, _, _, _, c, _ in hits)
    tot_tab = sum(n * t for n, _, _, _, _, t in hits)
    print(f'frame MEAN {frame[0] / nfr:,.0f} cyc\n')
    print(f'{"execs/fr":>9} {"kind":>6} {"+k":>4} {"now":>4} {"tbl":>4} '
          f'{"save/fr":>8}  site      symbol')
    for n, pc, kind, k, cyc, t in hits[:20]:
        v, s = near(pc)
        print(f'{n / nfr:9.1f} {kind:>6} {k:4} {cyc:4} {t:4} '
              f'{n * (cyc - t) / nfr:8.1f}  ${pc:04X}  {s}+{pc - v}')
    print(f'\n{len(hits)} sites: {tot_now / nfr:,.0f} cyc/frame today, '
          f'{tot_tab / nfr:,.0f} with the table -> saving '
          f'{(tot_now - tot_tab) / nfr:,.0f} cyc/frame '
          f'({(tot_now - tot_tab) / frame[0] * nfr / nfr:.3%} of the frame)'
          if hits else 'no sites')


if __name__ == '__main__':
    main()
