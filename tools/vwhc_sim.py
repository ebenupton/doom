#!/usr/bin/env python3
"""VWHC (project_y memo) capacity study -- would a bigger cache help?

Captures the (rhi, rlo, h) key stream at every project_y entry and
replays it through alternative cache organisations, in the THREE
regimes that behave completely differently:

  CORPUS  the 19-position suite exactly as run_regression drives it --
          ONE renderer instance, one frame per position, VWHC never
          cleared (it is a pure function of its key, so it is warm but
          maximally incoherent: scattered positions share few keys).
  HEAVY   the heavy frame, entered with the cache warm from the suite.
  WALK    the walkseq sequences, 8 units/frame plus rotations.  This is
          the regime real hardware runs in and the only one with
          meaningful headroom.

Do NOT model a regime by clearing the cache per position: the shipped
cache is never cleared, and a fresh-per-frame model reports compulsory
misses that hardware would not take.  Equally, render_frame is not
re-enterable on its own -- the span pool still reads solid and the walk
bails in ~199 steps -- so each frame gets init/clear_screen/
poke_init_frame_state, which leave VWHC and VXC alone.
"""
import os, sys, statistics
ROOT = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), '..'))
sys.path.insert(0, ROOT); sys.path.insert(0, os.path.join(ROOT, 'tools'))
os.environ.setdefault('SDL_VIDEODRIVER', 'dummy')
os.environ['PYGAME_HIDE_SUPPORT_PROMPT'] = '1'
import pygame; pygame.init(); pygame.display.set_mode((1, 1))
# Symbols resolve for the build the shared rig IS (banked since 2026-08-29;
# DOOM_FLAT_RIG=1 restores flat).  zp/pool names are identical in both maps
# by rule, so only CODE entries actually move -- but a stale flat entry in a
# banked rig is a silent jump into the wrong build, so resolve it all here.
import functools as _ft, os as _os
_BANKED = 1 if _os.environ.get('DOOM_BANKED_RIG') == '1' else 0
from symmap import sym as _raw_sym
sym = _ft.partial(_raw_sym, banked=_BANKED)

PY = sym('project_y'); RM8 = sym('zp_br_r_m8'); RS = sym('zp_br_r_s')
IDX = lambda k: (k[2] ^ k[0]) & 0xFF            # the shipped probe index
SEQS = [(2345, -3123, 132, 'ffffffffssfffrfffbff'),
        (1056, -3616, 65,  'ffffffffffffffff'),
        (1500, -3700, 1,   'ffffssffffrrffff')]
STEP = 8.0


def frame(sc, tc, poke, px, py, ab, timings=None):
    mpu = sc.mpu; mem = mpu.memory
    tc.setup_view_zp(sc, int(px), int(py), ab); sc._run(tc.ENTRY_BR_VIEW_SETUP)
    sc.init(); sc.clear_screen(); poke(mem)
    mpu.pc = sym('render_frame'); mpu.sp = 0xDD; mpu.p = 0x30
    mem[0x01DF] = 0xFE; mem[0x01DE] = 0xFF
    ks = []; live = False; c0 = d0 = 0
    while mpu.pc != 0xFF00:
        if mpu.pc == PY:
            ks.append((mem[RM8], mem[RS], mpu.a))
            live = True; c0 = mpu.processorCycles; d0 = mpu.sp
        elif live and mpu.sp > d0:
            if timings is not None: timings.append(mpu.processorCycles - c0)
            live = False
        mpu.step()
    return ks


def sim(frames, idxfn, ways=1, skip=0):
    st = {}; H = R = 0
    for i, ks in enumerate(frames):
        for k in ks:
            w = st.setdefault(idxfn(k), [])
            if k in w: w.remove(k); w.insert(0, k); h = 1
            else: w.insert(0, k); del w[ways:]; h = 0
            if i >= skip: H += h; R += 1
    return H / R * 100, R / max(1, len(frames) - skip)


def main():
    import doom_wireframe as dw, trace_compare as tc, compare_renders as C
    from bsp_render_6502 import poke_init_frame_state as poke
    _ = dw.Instrumented6502Spans(); sc = dw._span_clip_6502
    tc.setup_wad(sc)

    tim = []
    suite = [frame(sc, tc, poke, *q, timings=tim) for q in C.POSITIONS]
    suite.append(frame(sc, tc, poke, 1133, -3242, 0x90, timings=tim))

    walk = []
    for px0, py0, ab0, seq in SEQS:
        px, py, ab = float(px0), float(py0), ab0
        for mv in '0' + seq:
            if mv in 'fb':
                v = pygame.math.Vector2(1, 0).rotate(ab * 360 / 256)
                s = STEP if mv == 'f' else -STEP
                px, py = px + v.x * s, py + v.y * s
            elif mv == 'r': ab = (ab + 4) & 0xFF
            walk.append(frame(sc, tc, poke, px, py, ab))

    # cost of a hit: classify each timed call by replaying the shipped cache
    st = {}; hit = []; miss = []; i = 0
    for ks in suite:
        for k in ks:
            s = IDX(k); (hit if st.get(s) == k else miss).append(tim[i])
            st[s] = k; i += 1
    VAL = statistics.mean(miss) - statistics.mean(hit)
    print(f'project_y  hit {statistics.mean(hit):.1f} cyc / '
          f'miss {statistics.mean(miss):.1f} cyc  ->  a hit is worth {VAL:.0f} cycles')

    # bank-select bit must have its load already paid to be cheap; the
    # tax figures are the extra cycles per PROBE (hit and miss alike).
    VAR = [('512, 2 banks by h.3', lambda k: IDX(k) | (((k[2] >> 3) & 1) << 8), 1, 7.5),
           ('512, 2 banks by h.7', lambda k: IDX(k) | (((k[2] >> 7) & 1) << 8), 1, 2.5),
           ('512 = 2-way x 256',   IDX,                                        2, 12.0),
           ('infinite (ceiling)',  lambda k: 0,                            1 << 30, 0.0)]
    for name, frames, skip in (('CORPUS (19-pos suite)', suite[:19], 0),
                               ('HEAVY  (warm from suite)', suite, 19),
                               ('WALK   (55 frames)', walk, 3)):
        base, n = sim(frames, IDX, 1, skip)
        print(f'\n{name}: {n:.0f} calls/frame, shipped {base:.1f}%')
        for nm, f, w, tax in VAR:
            v, _ = sim(frames, f, w, skip)
            g = (v - base) / 100 * n * VAL
            print(f'   {nm:22s} {v:5.1f}% {v-base:+5.1f}pp   '
                  f'gain {g:+7.0f}  tax {-tax*n:+7.0f}  NET {g-tax*n:+7.0f} cyc/frame')


main()
