#!/usr/bin/env python3
"""Generate the fine-grained 'inside' position corpus (Eben, 2026-08-20).

Grid step 4 (+2 offset to dodge wall-aligned lattice points) over the
map's vertex bounds; a position qualifies if
  1. it is inside the map outline — ODD crossing parity against the
     one-sided linedefs (the previous in-map costings' screen), done
     scanline-wise per grid row, and
  2. its subsector's sector is walkable volume: ceiling - floor >= 56
     at the static baked heights (drops void pillars and shut doors).

Writes build/inside_corpus.txt ('x y' per line, '#' meta header).
"""
import os, sys, time
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
os.chdir(os.path.join(os.path.dirname(os.path.abspath(__file__)), '..'))
os.environ.setdefault('SDL_VIDEODRIVER', 'dummy')
os.environ.setdefault('PYGAME_HIDE_SUPPORT_PROMPT', '1')
import pygame; pygame.init()
import doom_wireframe as dw

STEP, OFF = 4, 2
PLAYER_HEIGHT = 56
OUT = 'build/inside_corpus.txt'

def log(*a):
    print(*a, file=sys.stderr, flush=True)

# ---- one-sided outline segments -----------------------------------------
one_sided = []
for ld in dw.linedefs:
    r, l = ld[5], ld[6]
    if l == 0xFFFF or r == 0xFFFF:
        v1, v2 = dw.vertexes[ld[0]], dw.vertexes[ld[1]]
        if v1[1] != v2[1]:                       # horizontals never cross a row
            one_sided.append((v1[0], v1[1], v2[0], v2[1]))
log(f'{len(one_sided)} one-sided outline lines (non-horizontal)')

xs = [v[0] for v in dw.vertexes]; ys = [v[1] for v in dw.vertexes]
x0, x1 = min(xs), max(xs); y0, y1 = min(ys), max(ys)
gx = [x for x in range(x0 + OFF, x1, STEP)]
gy = [y for y in range(y0 + OFF, y1, STEP)]
log(f'bounds x [{x0},{x1}] y [{y0},{y1}]; grid {len(gx)} x {len(gy)} '
    f'= {len(gx)*len(gy):,} candidates')

# ---- per-subsector walkable verdict (cached) ----------------------------
_ss_ok = {}
def walkable(x, y):
    ss = dw.find_subsector(x, y)
    ok = _ss_ok.get(ss)
    if ok is None:
        s = dw.segs[dw.ssectors[ss][1]]
        ld = dw.linedefs[s[3]]
        sd = ld[5] if s[4] == 0 else ld[6]
        if sd == 0xFFFF:
            sd = ld[5]
        sec = dw.sectors[dw.sidedefs[sd][5]]
        ok = _ss_ok[ss] = (sec[1] - sec[0]) >= PLAYER_HEIGHT
    return ok

# ---- scanline parity + walkable screen ----------------------------------
t0 = time.time()
inside = walk_fail = 0
os.makedirs('build', exist_ok=True)
with open(OUT, 'w') as f:
    f.write(f'# inside_corpus step={STEP} off={OFF} '
            f'bounds={x0},{y0},{x1},{y1} height>={PLAYER_HEIGHT}\n')
    for ri, y in enumerate(gy):
        xcross = []
        for (ax, ay, bx, by) in one_sided:
            lo, hi = (ay, by) if ay < by else (by, ay)
            if lo <= y < hi:                     # half-open: shared verts once
                xcross.append(ax + (y - ay) * (bx - ax) / (by - ay))
        xcross.sort()
        # walk the row: parity flips at each crossing
        import bisect
        for x in gx:
            if bisect.bisect_left(xcross, x) & 1:    # odd = inside outline
                if walkable(x, y):
                    f.write(f'{x} {y}\n')
                    inside += 1
                else:
                    walk_fail += 1
        if (ri + 1) % 100 == 0 or ri + 1 == len(gy):
            log(f'  row {ri+1}/{len(gy)}: {inside:,} inside so far '
                f'({time.time()-t0:.0f}s)')

log(f'DONE: {inside:,} walkable inside positions '
    f'({walk_fail:,} parity-inside but unwalkable) -> {OUT}')
print(inside)
