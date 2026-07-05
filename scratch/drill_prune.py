#!/usr/bin/env python3
"""Find the corner-walk prune decision that wrongly excludes ss=105 at
(973,-3367,239), and dump fp_bbox_visible_fixed's internals for it."""
import os
os.environ.setdefault('SDL_VIDEODRIVER', 'dummy')
os.environ.setdefault('PYGAME_HIDE_SUPPORT_PROMPT', '1')
import pygame; pygame.init()
import math
import doom_wireframe as dw
import fp
from fp import (PRESCALE, MAP_CENTER_X as MCX, MAP_CENTER_Y as MCY, NEAR_FP,
                fp_to_view, fp_recip, fp_project_x, m8, fp_mul8)
from overtraversal_probe import setup

PX, PY, AB, SS = 973, -3367, 239, 105
NF = dw.NF_SUBSECTOR


def subtree_ss(nid):
    acc = set(); st = [nid]
    while st:
        n = st.pop()
        if n & NF:
            acc.add(0 if n == 0xFFFF else n & 0x7FFF)
        else:
            node = dw.nodes[n]
            st.append(node[12]); st.append(node[13])
    return acc


ctx, vz, cf, sf, ram = setup(PX, PY, AB)
orig = dw.fp_bbox_visible_fixed
prunes = []

def spy(node, side, c):
    r = orig(node, side, c)
    prunes.append((node, side, r))
    return r

dw.fp_bbox_visible_fixed = spy
clips = dw.Instrumented6502Spans()
surf = pygame.Surface((dw.FP_RENDER_W, dw.FP_RENDER_H))
dw.packed_render_bsp(len(dw.nodes) - 1, clips, ctx, vz, PX, PY, cf, sf, surf, ram)
dw.fp_bbox_visible_fixed = orig

nid_of = {id(n): i for i, n in enumerate(dw.nodes)}
for (node, side, r) in prunes:
    nid = nid_of[id(node)]
    ch = (node[12], node[13])[side]
    sub = subtree_ss(ch) if not (ch & NF) else \
        {0 if ch == 0xFFFF else ch & 0x7FFF}
    if SS not in sub:
        continue
    # the walk may have pruned via has_gap on r, or r None
    print(f"bbox check: node {nid} side {side} child {ch & 0x7FFF}"
          f"{'(ss)' if ch & NF else ''} -> {r}   [subtree holds ss{SS}]")
    if r is not None:
        print(f"   has_gap({r[0]},{r[1]}) = {clips_gap: = 0}" if False else "")
# Now dump internals for the FAILING check (the deepest one that pruned).
# Re-run the corner internals by hand for each holding node:
print("\n--- internals for holding checks ---")
for (node, side, r) in prunes:
    nid = nid_of[id(node)]
    ch = (node[12], node[13])[side]
    sub = subtree_ss(ch) if not (ch & NF) else {0 if ch == 0xFFFF else ch & 0x7FFF}
    if SS not in sub:
        continue
    base = 4 + side * 4
    rt, rb, rl, rr = node[base], node[base+1], node[base+2], node[base+3]
    top = (rt - MCY) // PRESCALE; bot = (rb - MCY) // PRESCALE
    left = (rl - MCX) // PRESCALE; right = (rr - MCX) // PRESCALE
    print(f"node {nid} side {side}: box top={top} bot={bot} left={left} right={right} "
          f"viewer=({ctx[0]},{ctx[1]}) -> {r}")
    corners = ((left, top), (right, top), (right, bot), (left, bot))
    pts = []
    for wx, wy in corners:
        _, evx, evy, _, eyi = fp_to_view(wx, wy, ctx)
        pts.append((evx, evy, eyi))
        print(f"   corner ({wx},{wy}): evx={evx} evy={evy}")
    sxs = []
    for i in range(4):
        vx0, vy0, ey0 = pts[i]
        vx1, vy1, _ = pts[(i + 1) % 4]
        if vy0 >= NEAR_FP:
            rh, rl_ = fp_recip(ey0)
            sxs.append(('corner', fp_project_x(vx0, rh, rl_)))
        if (vy0 < NEAR_FP) != (vy1 < NEAR_FP):
            dvy = vy1 - vy0
            if dvy != 0:
                t = ((NEAR_FP - vy0) << 8) // dvy
                dvx = vx1 - vx0
                cx_raw = vx0 + m8(t, dvx)          # what the code does
                cx_shift = vx0 + fp_mul8(t, dvx)   # what 0.8 t semantics need
                rh, rl_ = fp_recip(NEAR_FP << 1)
                sxs.append(('crossing', fp_project_x(cx_raw, rh, rl_),
                            f't={t} dvx={dvx} cx_raw={cx_raw} cx_shift={cx_shift}'))
    print(f"   sxs: {sxs}")
