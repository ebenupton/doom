#!/usr/bin/env python3
"""Diff Python line output with and without the aperture-yield extension,
to see what the yield changed."""
import os, sys, math
os.environ['SDL_VIDEODRIVER'] = 'dummy'
os.environ['PYGAME_HIDE_SUPPORT_PROMPT'] = '1'
import pygame; pygame.init(); pygame.display.set_mode((1, 1))

import doom_wireframe as dw
from endpoint_spans import EndpointClipSpans
import fp as fpmod

POSITIONS = [
    (1056, -3616, 64, "S1"),
    (1056, -3616, 32, "S2"),
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

# First render WITH aperture yield
yielded = {}
for px, py, ab, name in POSITIONS:
    yielded[name] = render(px, py, ab)

# Temporarily disable aperture yield by emptying the new set
orig_set = dw._vert_covered_by_solid_vert
dw._vert_covered_by_solid_vert = set()
try:
    nonyielded = {}
    for px, py, ab, name in POSITIONS:
        nonyielded[name] = render(px, py, ab)
finally:
    dw._vert_covered_by_solid_vert = orig_set

def norm(r):
    x1, y1, x2, y2 = r
    if (x1, y1) <= (x2, y2):
        return r
    return (x2, y2, x1, y1)

for name in yielded:
    ys = set(map(norm, yielded[name]))
    ns = set(map(norm, nonyielded[name]))
    only_y = ys - ns
    only_n = ns - ys
    print(f"=== {name} ===")
    print(f"  yielded: {len(yielded[name])} drawn, {len(ys)} unique")
    print(f"  not yielded: {len(nonyielded[name])} drawn, {len(ns)} unique")
    print(f"  lost by yielding: {len(only_n)}")
    for l in sorted(only_n):
        print(f"    LOST: {l}")
    for l in sorted(only_y):
        print(f"    GAINED: {l}")
