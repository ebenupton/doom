#!/usr/bin/env python3
"""Enumerate py-only and hw-only lines with labels, across test positions.

py-only labels use the Python draw index (same as /diff_overlay in-game).
hw-only labels are H0..HN in sorted order (same as in-game).
"""
import os, sys, math
os.environ['SDL_VIDEODRIVER'] = 'dummy'
os.environ['PYGAME_HIDE_SUPPORT_PROMPT'] = '1'
import pygame; pygame.init(); pygame.display.set_mode((1, 1))

import doom_wireframe as dw
from fe6502 import Frontend6502
from endpoint_spans import EndpointClipSpans
import endpoint_spans as _es
import fp as fpmod

POSITIONS = [
    (1056, -3616, 64, "S1 E"),
    (1056, -3616, 0, "N"),
    (1056, -3616, 32, "S2 NE"),
    (1056, -3616, 96, "SE"),
    (1200, -3300, 64, "T"),
]

fe = Frontend6502(dw.packed_rom_banks, dw.packed_rom_recip,
                  dw.packed_bbox_table, dw.packed_layout)

def nrm(r):
    x1, y1, x2, y2 = r
    return r if (x1, y1) <= (x2, y2) else (x2, y2, x1, y1)

for PX, PY, ANGLE, name in POSITIONS:
    FZ = dw.player_floor(PX, PY)

    # 6502
    hw_lines, _ = fe.render_frame(PX, PY, ANGLE, FZ, capture_lines=True)

    # Python (with indexed line collection)
    _es._drawn_lines = []
    real = pygame.draw.line
    pygame.draw.line = lambda *a, **kw: None  # prevent surface side-effect
    px_88 = int((PX - dw.MAP_CENTER_X) * 256 / dw.PRESCALE)
    py_88 = int((PY - dw.MAP_CENTER_Y) * 256 / dw.PRESCALE)
    vz_ps = dw._prescale_height(FZ + 41)
    sc = dw.fp_sincos(ANGLE)
    ctx = dw.fp_view_context(px_88, py_88, sc)
    ang_rad = dw.byte_to_radians(ANGLE)
    cos_f, sin_f = math.cos(ang_rad), math.sin(ang_rad)
    tmp = pygame.Surface((dw.FP_RENDER_W, dw.FP_RENDER_H))
    for k in dw.map_trace:
        if hasattr(dw.map_trace[k], 'clear'):
            dw.map_trace[k].clear()
    fpmod.mul_reset()
    dw.render_bsp_fp(len(dw.nodes) - 1, EndpointClipSpans(), ctx, vz_ps,
                     int(PX), int(PY), cos_f, sin_f, tmp,
                     [None] * len(dw.vertexes), [None] * len(dw.vwh_table))
    pygame.draw.line = real

    py_by_norm = {}
    for (_i, lx1, ly1, lx2, ly2) in _es._drawn_lines:
        py_by_norm.setdefault(nrm((lx1, ly1, lx2, ly2)), _i)
    hw_set = set(nrm(l) for l in hw_lines)
    py_only = sorted((py_by_norm[n], n) for n in py_by_norm if n not in hw_set)
    hw_only = sorted(n for n in hw_set if n not in py_by_norm)

    print(f"=== {name} ({PX},{PY},ab={ANGLE}) ===")
    for _idx, (x1, y1, x2, y2) in py_only:
        print(f"  PY-ONLY [{_idx}]:  ({x1},{y1})→({x2},{y2})")
    for _j, (x1, y1, x2, y2) in enumerate(hw_only):
        print(f"  HW-ONLY [H{_j}]: ({x1},{y1})→({x2},{y2})")
    print()
