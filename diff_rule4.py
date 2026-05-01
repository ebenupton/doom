#!/usr/bin/env python3
"""Compare Python line sets with and without Rule 4 applied by stubbing _novt_rule4."""
import os, sys, math
os.environ['SDL_VIDEODRIVER'] = 'dummy'
os.environ['PYGAME_HIDE_SUPPORT_PROMPT'] = '1'
import pygame; pygame.init(); pygame.display.set_mode((1, 1))

import doom_wireframe as dw
from endpoint_spans import EndpointClipSpans
import fp as fpmod

POSITIONS = [
    (1056, -3616, 64, "S1 E"),
    (1056, -3616, 0, "N"),
    (1056, -3616, 32, "S2 NE"),
    (1056, -3616, 96, "SE"),
    (1200, -3300, 64, "T"),
]

def render(px, py, ab):
    captured = []
    _real = pygame.draw.line
    def _cap(surface, color, p1, p2, w=1):
        captured.append((int(p1[0]), int(p1[1]), int(p2[0]), int(p2[1])))
        return _real(surface, color, p1, p2, w)
    pygame.draw.line = _cap

    fz = dw.player_floor(px, py)
    px_88 = int((px - dw.MAP_CENTER_X) * 256 / dw.PRESCALE)
    py_88 = int((py - dw.MAP_CENTER_Y) * 256 / dw.PRESCALE)
    vz_ps = dw._prescale_height(fz + 41)
    sc = dw.fp_sincos(ab)
    ctx = dw.fp_view_context(px_88, py_88, sc)
    ang_rad = dw.byte_to_radians(ab)
    cos_f, sin_f = math.cos(ang_rad), math.sin(ang_rad)
    tmp = pygame.Surface((dw.FP_RENDER_W, dw.FP_RENDER_H))
    for k in dw.map_trace:
        if hasattr(dw.map_trace[k], 'clear'):
            dw.map_trace[k].clear()
    fpmod.mul_reset()
    dw.render_bsp_fp(len(dw.nodes) - 1, EndpointClipSpans(), ctx, vz_ps,
                     int(px), int(py), cos_f, sin_f, tmp,
                     [None] * len(dw.vertexes), [None] * len(dw.vwh_table))
    pygame.draw.line = _real
    return captured

# Render WITH Rule 4
after = {}
for px, py, ab, name in POSITIONS:
    after[name] = render(px, py, ab)

# Render WITHOUT Rule 4 (clear the flags Rule 4 added)
orig_flags = list(dw._seg_novt_flags)
orig_rule4 = dw._novt_rule4.copy()
# Undo Rule 4: clear the NOVT bits it added (those in _novt_rule4)
for si, side in orig_rule4:
    bit = dw._SF_NOVT1 if side == 1 else dw._SF_NOVT2
    dw._seg_novt_flags[si] &= ~bit
dw._novt_rule4 = set()

try:
    before = {}
    for px, py, ab, name in POSITIONS:
        before[name] = render(px, py, ab)
finally:
    dw._seg_novt_flags[:] = orig_flags
    dw._novt_rule4 = orig_rule4

def norm(r):
    x1, y1, x2, y2 = r
    if (x1, y1) <= (x2, y2):
        return r
    return (x2, y2, x1, y1)

for name in after:
    ys = set(map(norm, after[name]))
    ns = set(map(norm, before[name]))
    only_y = ys - ns
    only_n = ns - ys
    print(f"=== {name} ===")
    print(f"  after:  {len(after[name])} drawn, {len(ys)} unique")
    print(f"  before: {len(before[name])} drawn, {len(ns)} unique")
    print(f"  lost by Rule 4: {len(only_n)}")
    for l in sorted(only_n):
        print(f"    LOST: {l}")
    print(f"  gained by Rule 4: {len(only_y)}")
    for l in sorted(only_y):
        print(f"    GAINED: {l}")
