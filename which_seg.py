#!/usr/bin/env python3
"""Trace which Python seg would draw a specific line, and show its NOVT state."""
import os, sys, math
os.environ['SDL_VIDEODRIVER'] = 'dummy'
os.environ['PYGAME_HIDE_SUPPORT_PROMPT'] = '1'
import pygame; pygame.init(); pygame.display.set_mode((1, 1))

import doom_wireframe as dw
from endpoint_spans import EndpointClipSpans
import fp as fpmod

# (px, py, ab, target_x, "label")
CASES = [
    (1200, -3300, 64, 186, "T H4 = (186,57,220,45)"),
    (1200, -3300, 64, 220, "T H5 = (220,45,220,91)"),
]

def norm(r):
    x1, y1, x2, y2 = r
    return r if (x1, y1) <= (x2, y2) else (x2, y2, x1, y1)

for PX, PY, ANGLE, tx, label in CASES:
    FZ = dw.player_floor(PX, PY)
    seg_lines = {}
    current = [None]
    real = pygame.draw.line
    def cap(surf, col, p1, p2, w=1):
        si = current[0]
        if si is not None:
            seg_lines.setdefault(si, []).append(
                (int(p1[0]), int(p1[1]), int(p2[0]), int(p2[1])))
        return real(surf, col, p1, p2, w)
    pygame.draw.line = cap
    orig = dw.fp_render_seg
    def wrap(si, *a, **kw):
        current[0] = si
        r = orig(si, *a, **kw)
        current[0] = None
        return r
    dw.fp_render_seg = wrap

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
    dw.fp_render_seg = orig

    print(f"=== {label} ===")
    # Find all Python segs that touch x=tx near the target
    for si, lines in seg_lines.items():
        for x1, y1, x2, y2 in lines:
            if x1 == tx or x2 == tx:
                sv = dw.fp_segs_vwh[si]
                s = sv[0]
                v1, v2 = s[0], s[1]
                bi = sv[2]
                fi = sv[1]
                solid = bi is None
                novt = dw._seg_novt_flags[si]
                n1 = bool(novt & dw._SF_NOVT1)
                n2 = bool(novt & dw._SF_NOVT2)
                r4 = []
                if (si, 1) in dw._novt_rule4: r4.append("V1")
                if (si, 2) in dw._novt_rule4: r4.append("V2")
                role = 'solid' if solid else ('portal-steps' if (dw.fp_sectors[bi][1] < sv[4] or dw.fp_sectors[bi][0] > sv[3]) else 'portal-plain')
                print(f"  seg {si} v=({v1},{v2}) front={fi} back={bi} {role} "
                      f"novt={'V1' if n1 else ''}{'V2' if n2 else ''} "
                      f"rule4={r4 or '-'}  draws: ({x1},{y1})→({x2},{y2})")
    print()
