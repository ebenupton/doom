#!/usr/bin/env python3
"""Census (Eben, 2026-07-25): how many EXPLICIT-table vertices could be
served by a single static maximum-y-extent line, leaning on the span
clipper for the appearance?

The full line can only OVER-draw, so per serve the predicate is:
    the exact spans' clipped union covers the WHOLE aperture at that
    column (first-match span, _span_top_ceil/_span_bot — the landed
    dcl_vertical semantics, no TFIX).
Instrumented at the mirror's emission point (clip state = serve time,
transform-serve). The frame then draws the EXACT spans as normal, so
later serves see canonical state.

Corpus: the 18 regression poses + the 4 cachebench locations + 16-step
rotations at three spots. Per vertex: serves seen, serves where the
full line is pixel-identical, and the worst uncovered aperture length
(rows) when it is not.
"""
import os, sys, math
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), '..'))
os.chdir(os.path.join(os.path.dirname(os.path.abspath(__file__)), '..'))
os.environ.setdefault('SDL_VIDEODRIVER', 'dummy')
os.environ.setdefault('PYGAME_HIDE_SUPPORT_PROMPT', '1')
import pygame; pygame.init()
import doom_wireframe as dw
import endpoint_spans as es
import fp

SUITE = [(1056,-3616,0),(1056,-3616,32),(1056,-3616,64),(1056,-3616,128),
         (1056,-3616,192),(1056,-3616,224),(1024,-3500,64),(1500,-3700,0),
         (800,-3400,96),(1200,-3000,128),(2112,-2368,35),(192,-2368,99),
         (1984,-2496,67),(1856,-2368,3),(3648,-2368,35),(2500,-2600,67),
         (3648,-4800,131),(-486,-3307,243)]
def world(v24, center):
    s = v24 - 0x1000000 if v24 & 0x800000 else v24
    return center + (s / 256.0) * dw.PRESCALE
BENCH = [(0xFFEE72,0xFFDCBA,0x3C),(0x002E29,0x005EEB,0x04),
         (0x00DF9A,0x003CC8,0xCC),(0x00B636,0x0002E9,0x88)]
POSES = list(SUITE)
for x24,y24,ab in BENCH:
    POSES.append((world(x24, dw.MAP_CENTER_X), world(y24, dw.MAP_CENTER_Y), ab))
for (px,py) in [(1056,-3616),(1500,-3700),(2345,-3123)]:
    for k in range(16):
        POSES.append((px, py, (k*16+1) & 0xFF))

# per-vertex tallies: [serves, drawn-serves, equal, near(<1 row), diff, worst_rows]
T = {}

# EMIT-SERVE hook (post-revert 0b62b47): emit_vertex_spans owns the
# done-set + on_screen gates — census only the call that actually
# serves and draws, at the DRAW-SITE clip state.
_orig = dw.emit_vertex_spans
def census(vidx, sx, proj, H, clips, surface, draw_stats, on_screen):
    d = dw.vspan_desc[vidx]
    if (d & 0x80) and vidx not in dw._vspan_done and on_screen:
        t = T.setdefault(vidx, [0,0,0,0,0,0.0])
        t[0] += 1
        ix = sx
        ap = None
        for s in clips.spans:
            if s[0] <= ix <= s[1]:
                ty = es._span_top_ceil(s, ix); by = es._span_bot(s, ix)
                if ty < by: ap = (ty, by)
                break
        if ap is not None:
            top, bot = ap
            # exact spans, clamped + projected + clipped (mirror the emitter)
            i = d & 0x7F
            ivs = []
            while True:
                h_lo, h_hi, cont = dw.vspan_expl[i]
                c_lo, c_hi = max(h_lo, H['fh']), min(h_hi, H['ch'])
                if c_hi > c_lo:
                    y1, y2 = proj(c_hi), proj(c_lo)     # top, bottom
                    a, b = max(y1, top), min(y2, bot)
                    if a <= b: ivs.append((a, b))
                if not cont: break
                i += 1
            # union coverage of [top, bot]
            ivs.sort()
            covered = 0.0; cur = top
            for a, b in ivs:
                if b <= cur: continue
                covered += b - max(a, cur)
                cur = max(cur, b)
            uncovered = (bot - top) - covered
            t[1] += 1
            if uncovered <= 1e-9: t[2] += 1
            elif uncovered < 1.0: t[3] += 1
            else: t[4] += 1
            t[5] = max(t[5], uncovered)
    return _orig(vidx, sx, proj, H, clips, surface, draw_stats, on_screen)
dw.emit_vertex_spans = census

def render(px, py, ab):
    p8 = int((px - dw.MAP_CENTER_X) * 256 / dw.PRESCALE)
    q8 = int((py - dw.MAP_CENTER_Y) * 256 / dw.PRESCALE)
    vz = dw._prescale_height(dw.player_floor(px, py) + 41)
    ctx = fp.fp_view_context(p8, q8, fp.fp_sincos(ab))
    ar = ab * 2 * math.pi / 256
    surf = pygame.Surface((256, 160))
    dw.render_bsp_fp(len(dw.nodes) - 1, es.EndpointClipSpans(), ctx, vz,
                     int(px), int(py), math.cos(ar), math.sin(ar), surf,
                     [None] * len(dw.vertexes), [None] * len(dw.vwh_table))

for (px, py, ab) in POSES:
    render(px, py, ab)

nvert = sum(1 for d in dw.vspan_desc if d & 0x80)
served = {v: t for v, t in T.items()}
always = [v for v, t in served.items() if t[1] > 0 and t[2] == t[1]]
near   = [v for v, t in served.items() if t[4] == 0 and t[3] > 0]
diff   = [v for v, t in served.items() if t[4] > 0]
unseen = nvert - len(served)
nspans = {v: bin(0)[0] for v in ()}
def spancount(v):
    i = dw.vspan_desc[v] & 0x7F
    n = 1
    while dw.vspan_expl[i][2]:
        n += 1; i += 1
    return n

print(f'\nexplicit vertices: {nvert} total; served in corpus: {len(served)}; never served: {unseen}')
print(f'  ALWAYS full-line-identical: {len(always)}')
print(f'  only sub-row deviations (<1 row): {len(near)}')
print(f'  materially different somewhere: {len(diff)}')
print(f'\nper-vertex detail (materially different):')
print(f'  {"v":>5} {"spans":>5} {"serves":>6} {"drawn":>5} {"equal":>5} {"<1row":>5} {"diff":>4} {"worst rows":>10}')
for v in sorted(diff, key=lambda v: -served[v][5]):
    t = served[v]
    print(f'  {v:>5} {spancount(v):>5} {t[0]:>6} {t[1]:>5} {t[2]:>5} {t[3]:>5} {t[4]:>4} {t[5]:>10.1f}')
sing = [v for v in always if spancount(v) == 1]
dbl  = [v for v in always if spancount(v) > 1]
print(f'\nALWAYS-identical split: {len(sing)} single-span + {len(dbl)} multi-span vertices')
entries_now = len(dw.vspan_expl)
entries_kept = sum(spancount(v) for v in served if v in diff or v in near) + \
               sum(spancount(v) for v in dw.__dict__.get("_never",[]))
print(f'table entries today: {entries_now}; retired if always-identical (+unseen kept): '
      f'{sum(spancount(v) for v in always)}')
