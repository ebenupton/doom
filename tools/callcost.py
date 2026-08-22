#!/usr/bin/env python3
"""Per-callee cost distribution: which subroutines are mostly no-ops?

    python3 tools/callcost.py [--pos X,Y,ANG]

Twice this week a routine turned out to spend most of its calls
discovering it had nothing to do — tfs_flush_pending (57% no-op) and
dcl_close_if_open (97%) — and in both cases hoisting the test to the
call site was the win, because JSR+RTS is 12 cycles before the callee
even looks.  This finds the rest of that family mechanically: for every
executed JSR, time the call to its matching RTS, and report the routines
whose calls cluster at the cheap end.

`p10` is the 10th-percentile call cost.  A routine with a low p10 and
many calls is a guard-at-the-call-site candidate: the floor is what a
no-op costs, and 12 of it is the call itself.
"""
import os, sys, collections, bisect

ROOT = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), '..'))
sys.path.insert(0, ROOT)
os.environ.setdefault('SDL_VIDEODRIVER', 'dummy')
os.environ['PYGAME_HIDE_SUPPORT_PROMPT'] = '1'
import pygame; pygame.init(); pygame.display.set_mode((1, 1))
from symmap import sym, _load


def names():
    t = _load(0, 0)
    d = t[0] if isinstance(t, tuple) else t
    rev = sorted((v, k) for k, v in d.items())
    return rev


def run(px, py, ab):
    import doom_wireframe as dw, trace_compare as tc
    from bsp_render_6502 import poke_init_frame_state
    _ = dw.Instrumented6502Spans(); sc = dw._span_clip_6502
    tc.setup_wad(sc); tc.setup_view_zp(sc, px, py, ab)
    sc._run(tc.ENTRY_BR_VIEW_SETUP); sc.init(); sc.clear_screen()
    poke_init_frame_state(sc.mpu.memory)
    mpu = sc.mpu; mem = mpu.memory
    mpu.pc = sym('render_frame'); mpu.sp = 0xDD; mpu.p = 0x30
    mem[0x01DF] = 0xFE; mem[0x01DE] = 0xFF; mpu.processorCycles = 0
    costs = collections.defaultdict(list)
    stack = []                       # (target, sp_after_jsr, cycles_at_entry)
    while mpu.pc != 0xFF00:
        pc = mpu.pc; op = mem[pc]; sp = mpu.sp
        while stack and sp > stack[-1][1]:
            tgt, _, c0 = stack.pop()
            costs[tgt].append(mpu.processorCycles - c0)
        if op == 0x20:
            tgt = mem[(pc + 1) & 0xFFFF] | (mem[(pc + 2) & 0xFFFF] << 8)
            mpu.step()
            stack.append((tgt, mpu.sp, mpu.processorCycles))
            continue
        mpu.step()
    return costs


def main():
    pos = (1133, -3242, 0x90)
    for a in sys.argv[1:]:
        if a.startswith('--pos'):
            pos = tuple(int(x, 0) for x in a.split('=', 1)[1].split(','))
    costs = run(*pos)
    rev = names()
    def nm(a):
        i = bisect.bisect_right(rev, (a, '\xff')) - 1
        if i >= 0 and rev[i][0] == a:
            return rev[i][1]
        return f'${a:04X}'
    rows = []
    for tgt, cs in costs.items():
        if len(cs) < 8:
            continue
        cs.sort()
        p10 = cs[len(cs) // 10]
        rows.append((p10, len(cs), sum(cs), cs[len(cs) // 2], nm(tgt)))
    rows.sort(key=lambda r: (r[0], -r[1]))
    print(f'frame {pos}\n')
    print(f"{'callee':30}{'calls':>7}{'p10':>7}{'median':>8}{'total':>9}"
          f"{'  guard saves ~12 x calls-at-p10'}")
    for p10, n, tot, med, name in rows[:18]:
        cheap = sum(1 for _ in range(0))
        print(f'  {name:28}{n:7d}{p10:7d}{med:8d}{tot:9,}')


main()
