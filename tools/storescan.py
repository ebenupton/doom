#!/usr/bin/env python3
"""Find stores that always write the value already at the destination.

    python3 tools/storescan.py [--min N]

Twice on 2026-08-23 a store turned out to be writing a value the code
had already put there — the exit check's end_x (zp_ox1 already held xr)
and the per-span Y-bbox reset.  Both were invisible in the source
because producer and consumer sit hundreds of lines apart.  This finds
the rest mechanically.

Every executed store is checked against the byte already at its
effective address, over the 19-frame suite AND the heavy frame.  A site
that is redundant on 100% of its executions is a CANDIDATE — not a
proof: the corpus can simply never have exercised the differing case.
Each one still needs a static argument before removal.

Hardware ($FE00-$FEFF) and the framebuffer are excluded: a same-value
write there can still be load-bearing.
"""
import os, sys, collections, bisect
ROOT = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), '..'))
sys.path.insert(0, ROOT); sys.path.insert(0, os.path.join(ROOT, 'tools'))
os.environ.setdefault('SDL_VIDEODRIVER', 'dummy')
os.environ['PYGAME_HIDE_SUPPORT_PROMPT'] = '1'
import pygame; pygame.init(); pygame.display.set_mode((1, 1))
import re, py65.devices.mpu6502 as M
from symmap import sym

MODES = M.MPU().disassemble
STORES = {0x85:'A',0x95:'A',0x8D:'A',0x9D:'A',0x99:'A',0x81:'A',0x91:'A',
          0x86:'X',0x96:'X',0x8E:'X',
          0x84:'Y',0x94:'Y',0x8C:'Y',
          0x64:'Z',0x74:'Z',0x9C:'Z',0x9E:'Z'}
FB_LO, FB_HI = 0xEA00, 0xFDFF          # flat framebuffer + IO headroom


def ea(mpu, mem, pc, mode):
    o = mem[(pc + 1) & 0xFFFF]
    if mode == 'zpg': return o
    if mode == 'zpx': return (o + mpu.x) & 0xFF
    if mode == 'zpy': return (o + mpu.y) & 0xFF
    hi = mem[(pc + 2) & 0xFFFF]
    if mode == 'abs': return o | (hi << 8)
    if mode == 'abx': return (o | (hi << 8)) + mpu.x & 0xFFFF
    if mode == 'aby': return (o | (hi << 8)) + mpu.y & 0xFFFF
    if mode == 'inx':
        p = (o + mpu.x) & 0xFF
        return mem[p] | (mem[(p + 1) & 0xFF] << 8)
    if mode == 'iny':
        return ((mem[o] | (mem[(o + 1) & 0xFF] << 8)) + mpu.y) & 0xFFFF
    return None


def run(px, py, ab, tot, red):
    import doom_wireframe as dw, trace_compare as tc
    from bsp_render_6502 import poke_init_frame_state
    _ = dw.Instrumented6502Spans(); sc = dw._span_clip_6502
    tc.setup_wad(sc); tc.setup_view_zp(sc, px, py, ab)
    sc._run(tc.ENTRY_BR_VIEW_SETUP)
    mpu = sc.mpu; mem = mpu.memory
    # THREE consecutive frames from one state; only the last two are
    # counted.  A single frame from a cold start makes every per-frame
    # CLEAR look redundant (the VCACHE_VALID/VDONE wipe in walk.s is the
    # obvious one) because nothing has dirtied the bytes yet.  Frame 1
    # warms the state; frames 2-3 see it as the hardware would.
    # The viewpoint MOVES between the counted frames.  Re-rendering one
    # static view marks every view-dependent value that happens to
    # recompute to the same number as "redundant" -- the VC_SXL/SXH/RLO
    # vertex-cache write-backs are the obvious victims, since only the
    # VALID bits are wiped per frame while the data planes keep last
    # frame's bytes.  Stepping the view forward 8 units per frame (the
    # walkseq step) keeps the state warm without that artefact.
    import pygame as _pg
    for _frame in range(3):
        if _frame:
            v = _pg.math.Vector2(1, 0).rotate(ab * 360 / 256)
            px, py = px + v.x * 8.0, py + v.y * 8.0
            tc.setup_view_zp(sc, int(px), int(py), ab)
            sc._run(tc.ENTRY_BR_VIEW_SETUP)
        # FULL per-frame reset.  render_frame alone is NOT re-enterable:
        # the span pool still reads fully solid from the previous frame,
        # so the BSP walk bails after ~199 steps.  init/clear_screen
        # rebuild the pool; poke_init_frame_state mirrors the inline
        # records + vcache-valid ground state.  VWHC and VXC are
        # deliberately NOT touched -- they persist on hardware too.
        sc.init(); sc.clear_screen(); poke_init_frame_state(mem)
        mpu.pc = sym('render_frame'); mpu.sp = 0xDD; mpu.p = 0x30
        mem[0x01DF] = 0xFE; mem[0x01DE] = 0xFF
        _count = _frame > 0
        _scan(mpu, mem, tot, red, _count)


def _scan(mpu, mem, tot, red, count):
    while mpu.pc != 0xFF00:
        pc = mpu.pc; op = mem[pc]
        r = STORES.get(op)
        if r:
            a = ea(mpu, mem, pc, MODES[op][1])
            if (count and a is not None and not (FB_LO <= a <= FB_HI)
                    and not (0xFE00 <= a <= 0xFEFF)):
                v = 0 if r == 'Z' else (mpu.a if r == 'A' else mpu.x if r == 'X' else mpu.y)
                tot[pc] += 1
                if mem[a] == (v & 0xFF):
                    red[pc] += 1
        mpu.step()


def linemap():
    """addr -> file:line, from the linked debug file."""
    dbg = os.path.join(ROOT, 'build', 'engine_b0c0.dbg')
    raw = open(dbg).readlines()
    def f(rest): return dict(re.findall(r'(\w+)=("?[^,"]*"?)', rest))
    segs, spans, files = {}, {}, {}
    for ln in raw:
        k, _, rest = ln.partition('\t')
        if k == 'file': d = f(rest); files[d['id']] = d['name'].strip('"')
        elif k == 'seg': d = f(rest); segs[d['id']] = int(d['start'], 0)
        elif k == 'span': d = f(rest); spans[d['id']] = (d['seg'], int(d['start']), int(d['size']))
    out = {}
    for ln in raw:
        k, _, rest = ln.partition('\t')
        if k != 'line': continue
        d = f(rest); fn = files.get(d.get('file'))
        if not fn: continue
        for sid in re.findall(r'span=([\d+]+)', rest):
            for sp in sid.split('+'):
                if sp not in spans: continue
                sg, st, sz = spans[sp]; base = segs.get(sg)
                if base is None: continue
                for a in range(base + st, base + st + sz):
                    out[a] = (os.path.relpath(fn, ROOT), int(d['line']))
    return out


def main():
    mn = 20
    for a in sys.argv[1:]:
        if a.startswith('--min'): mn = int(a.split('=', 1)[1])
    import compare_renders as C
    tot, red = collections.Counter(), collections.Counter()
    for q in list(C.POSITIONS) + [(1133, -3242, 0x90)]:
        run(q[0], q[1], q[2], tot, red)
    lm = linemap()
    srcs = {}
    rows = []
    for pc, n in tot.items():
        if n < mn or red[pc] != n:
            continue
        loc = lm.get(pc)
        if not loc:
            continue
        fn, line = loc
        if fn not in srcs:
            srcs[fn] = open(os.path.join(ROOT, fn), errors='ignore').readlines()
        txt = srcs[fn][line - 1].split(';')[0].strip()
        rows.append((n, fn, line, txt, pc))
    rows.sort(reverse=True)
    print(f'{len(tot)} store sites executed; '
          f'{sum(1 for pc in tot if red[pc] == tot[pc])} always-redundant\n')
    print(f'ALWAYS wrote the value already present (>= {mn} executions):\n')
    for n, fn, line, txt, pc in rows:
        print(f'  {n:6d}x  ${pc:04X}  {fn}:{line}  {txt}')


main()
