"""Measure repetition in bv_corner_products inputs across the suite.

Each call rotates 4 deltas: dxl=left-px, dxr=right-px, dyt=top-py, dyb=bot-py.
Each delta needs rot_int(d,sin) and rot_int(d,cos) = 2 muls. If d values
repeat across node-sides within a frame, a per-d product cache cuts the cost.
Reports distinct-d, repeat rate, and the bbox-test count.
"""
import os
os.environ['SDL_VIDEODRIVER'] = 'dummy'
os.environ['PYGAME_HIDE_SUPPORT_PROMPT'] = '1'
import pygame; pygame.init(); pygame.display.set_mode((1, 1))
import doom_wireframe as dw
import trace_compare as tc

CP = 0x4740          # bv_corner_products
SCR = 0x0960         # top,bot,left,right (s16 le)
PX_H, PY_H = 0x01, 0x03

POSITIONS = [(1056,-3616,65),(1500,-3700,1),(1024,-3500,65),
             (800,-3400,96),(1200,-3000,129),(1056,-3616,129)]

def s16(lo, hi):
    v = lo | (hi << 8)
    return v - 65536 if v >= 32768 else v

def s8(b):
    return b - 256 if b >= 128 else b

def capture(px, py, ab):
    _ = dw.Instrumented6502Spans()
    sc = dw._span_clip_6502
    tc.setup_wad(sc); tc.setup_view_zp(sc, px, py, ab)
    sc._run(tc.ENTRY_BR_VIEW_SETUP)
    sc.init(); sc.clear_screen(); sc._run(0x481B)
    mpu = sc.mpu; mem = mpu.memory
    mpu.pc = 0x4815; mpu.sp = 0xFD; mpu.p = 0x30
    mem[0x01FF] = 0xFE; mem[0x01FE] = 0xFF
    calls = []
    while mpu.pc != 0xFF00:
        if mpu.pc == CP:
            top = s16(mem[SCR+0], mem[SCR+1]); bot = s16(mem[SCR+2], mem[SCR+3])
            left = s16(mem[SCR+4], mem[SCR+5]); right = s16(mem[SCR+6], mem[SCR+7])
            px_i = s8(mem[PX_H]); py_i = s8(mem[PY_H])
            calls.append((left-px_i, right-px_i, top-py_i, bot-py_i))
        mpu.step()
    return calls

if __name__ == '__main__':
    per_frame_rates = []
    all_deltas_global = []
    total_calls = 0
    for p in POSITIONS:
        calls = capture(*p)
        total_calls += len(calls)
        deltas = []
        for dxl,dxr,dyt,dyb in calls:
            deltas += [dxl,dxr,dyt,dyb]
        distinct = len(set(deltas))
        # per-frame product cache: 2 muls per distinct d (sin+cos), vs 2 per
        # every d without cache.
        rate = 100*(1 - distinct/len(deltas)) if deltas else 0
        per_frame_rates.append((p, len(calls), len(deltas), distinct, rate))
        # also: distinct corner (x,y) pairs reused?
    print(f'{"position":22s} {"calls":>6s} {"deltas":>7s} {"distinct":>9s} {"repeat%":>8s}')
    for p,c,d,dd,r in per_frame_rates:
        print(f'{str(p):22s} {c:6d} {d:7d} {dd:9d} {r:7.1f}%')
    tot_d = sum(x[2] for x in per_frame_rates)
    tot_calls = sum(x[1] for x in per_frame_rates)
    print(f'\ntotal bv_corner_products calls: {tot_calls}')
    print(f'total deltas (=4*calls): {tot_d}')
    print(f'avg per-frame distinct deltas: {sum(x[3] for x in per_frame_rates)/len(per_frame_rates):.0f}')
    print(f'avg per-frame repeat rate: {sum(x[4] for x in per_frame_rates)/len(per_frame_rates):.1f}%')


def sim_hash(calls_per_frame, N, hashfn):
    """Direct-mapped cache, per-frame cleared. Returns hit rate over deltas."""
    hits = tot = 0
    for calls in calls_per_frame:
        tab = {}  # idx -> d (the stored key)
        for tup in calls:
            for d in tup:
                tot += 1
                idx = hashfn(d & 0xffff, N)
                if tab.get(idx) == d:
                    hits += 1
                else:
                    tab[idx] = d
    return 100*hits/tot if tot else 0
