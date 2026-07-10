#!/usr/bin/env python3
"""Trace who draws specific lines with Rule 4 disabled."""
import os, sys, math
os.environ['SDL_VIDEODRIVER'] = 'dummy'
os.environ['PYGAME_HIDE_SUPPORT_PROMPT'] = '1'
import pygame; pygame.init(); pygame.display.set_mode((1, 1))

import doom_wireframe as dw
from endpoint_spans import EndpointClipSpans
import fp as fpmod

# Clear Rule 4
orig_flags = list(dw._seg_novt_flags)
orig_rule4 = dw._novt_rule4.copy()
for si, side in orig_rule4:
    bit = dw._SF_NOVT1 if side == 1 else dw._SF_NOVT2
    dw._seg_novt_flags[si] &= ~bit
dw._novt_rule4 = set()

TARGETS = {
    "S1": [(38, 63, 38, 107), (243, 64, 243, 95)],
    "S2": [(120, 69, 120, 91), (196, 60, 196, 111)],
    "T":  [(220, 0, 220, 45), (220, 96, 220, 111), (240, 0, 240, 91)],
}

POSITIONS = [
    (1056, -3616, 64, "S1"),
    (1056, -3616, 32, "S2"),
    (1200, -3300, 64, "T"),
]

_real = pygame.draw.line
def norm(r):
    x1, y1, x2, y2 = r
    if (x1, y1) <= (x2, y2): return r
    return (x2, y2, x1, y1)

for px, py, ab, name in POSITIONS:
    current = [None]
    seg_lines = {}
    def _cap(surface, color, p1, p2, w=1):
        rec = (int(p1[0]), int(p1[1]), int(p2[0]), int(p2[1]))
        si = current[0]
        if si is not None:
            seg_lines.setdefault(si, []).append(rec)
        return _real(surface, color, p1, p2, w)
    pygame.draw.line = _cap

    _orig = dw.fp_render_seg
    def _wrap(si, *a, **k):
        current[0] = si
        r = _orig(si, *a, **k)
        current[0] = None
        return r
    dw.fp_render_seg = _wrap

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
    dw.fp_render_seg = _orig

    print(f"=== {name} ===")
    for target in TARGETS[name]:
        tn = norm(target)
        print(f"  looking for {target}:")
        for si, lines in seg_lines.items():
            for r in lines:
                if norm(r) == tn:
                    sv = dw.fp_segs_vwh[si]
                    s = sv[0]
                    v1, v2 = s[0], s[1]
                    bi = sv[2]
                    fi = sv[1]
                    solid = (bi is None)
                    novt = dw._seg_novt_flags[si]
                    n1 = bool(novt & dw._SF_NOVT1)
                    n2 = bool(novt & dw._SF_NOVT2)
                    rule4 = [s for s, sd in orig_rule4 if s == si]
                    print(f"    s{si} v=({v1},{v2}) front={fi} {'solid' if solid else 'portal'} "
                          f"novt={'V1' if n1 else ''}{'V2' if n2 else ''} "
                          f"rule4={[sd for s, sd in orig_rule4 if s == si]}")
                    break
