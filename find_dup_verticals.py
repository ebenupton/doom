#!/usr/bin/env python3
"""Find step-vertical duplicates emitted by adjacent portal segs at shared vertex.

Hooks pygame.draw.line to capture every line drawn, identifying pairs that
are identical or overlap.  Reports by seg-vertex to show pattern.
"""
import os, sys
os.environ['SDL_VIDEODRIVER'] = 'dummy'
os.environ['PYGAME_HIDE_SUPPORT_PROMPT'] = '1'
import pygame; pygame.init(); pygame.display.set_mode((1, 1))

import doom_wireframe as dw
import math

SCENES = [
    ("S1 E", (1056, -3616, 64)),
    ("N",    (1056, -3616, 0)),
    ("S2 NE",(1056, -3616, 32)),
    ("SE",   (1056, -3616, 96)),
    ("T",    (1200, -3300, 64)),
]

_real_draw = pygame.draw.line

def run(name, px, py, ab):
    # Hook draw
    drawn = []  # (x1,y1,x2,y2)
    current_seg = [None]
    seg_lines = {}  # si → [(x1,y1,x2,y2), ...]

    def _hook(surf, col, p1, p2, w=1):
        rec = (p1[0], p1[1], p2[0], p2[1])
        drawn.append(rec)
        si = current_seg[0]
        if si is not None:
            seg_lines.setdefault(si, []).append(rec)
        return _real_draw(surf, col, p1, p2, w)
    pygame.draw.line = _hook

    _orig = dw.fp_render_seg
    def _wrapped(si, *args, **kw):
        current_seg[0] = si
        r = _orig(si, *args, **kw)
        current_seg[0] = None
        return r
    dw.fp_render_seg = _wrapped

    try:
        fz = dw.player_floor(px, py)
        for k in dw.map_trace:
            if hasattr(dw.map_trace[k], 'clear'):
                dw.map_trace[k].clear()
        dw.fp_module.mul_reset()
        px_88 = int((px - dw.MAP_CENTER_X) * 256 / dw.PRESCALE)
        py_88 = int((py - dw.MAP_CENTER_Y) * 256 / dw.PRESCALE)
        vz_ps = dw._prescale_height(fz + 41)
        sc = dw.fp_sincos(ab)
        ctx = dw.fp_view_context(px_88, py_88, sc)
        ang_rad = dw.byte_to_radians(ab)
        cos_f, sin_f = math.cos(ang_rad), math.sin(ang_rad)
        tmp = pygame.Surface((dw.FP_RENDER_W, dw.FP_RENDER_H))
        from endpoint_spans import EndpointClipSpans
        dw.render_bsp_fp(len(dw.nodes) - 1, EndpointClipSpans(), ctx, vz_ps,
                         px, py, cos_f, sin_f, tmp,
                         [None] * len(dw.vertexes), [None] * len(dw.vwh_table))
    finally:
        pygame.draw.line = _real_draw
        dw.fp_render_seg = _orig

    # Normalize each line so (smaller endpoint) comes first
    def norm(r):
        x1, y1, x2, y2 = r
        if (x1, y1) <= (x2, y2):
            return r
        return (x2, y2, x1, y1)

    # Find duplicates (same normalized line drawn by 2+ segs)
    from collections import defaultdict
    line_to_segs = defaultdict(list)
    for si, lines in seg_lines.items():
        seen = set()
        for r in lines:
            n = norm(r)
            if n in seen:
                continue  # skip self-dup within seg
            seen.add(n)
            line_to_segs[n].append(si)

    dups = [(n, segs) for n, segs in line_to_segs.items() if len(segs) > 1]
    print(f"=== {name} {(px,py,ab)} ===")
    print(f"  total lines drawn: {len(drawn)}, unique segs: {len(seg_lines)}")
    print(f"  duplicate lines: {len(dups)}")
    for line, segs in sorted(dups):
        print(f"  DUP {line}:")
        for si in segs:
            sv = dw.fp_segs_vwh[si]
            s = sv[0]
            v1, v2 = s[0], s[1]
            bi = sv[2]
            fi = sv[1]
            solid = (bi is None)
            novt = dw._seg_novt_flags[si]
            n1 = bool(novt & dw._SF_NOVT1)
            n2 = bool(novt & dw._SF_NOVT2)
            role = 'solid' if solid else 'portal'
            # Is this seg a portal-with-steps?
            if not solid:
                bs = dw.fp_sectors[bi]
                fs = dw.fp_sectors[fi]
                if bs[1] < fs[1] or bs[0] > fs[0]:
                    role = 'portal-steps'
                else:
                    role = 'portal-plain'
            all_lines = [norm(r) for r in seg_lines[si]]
            shared_vert = set([v1, v2])
            other_segs = [sj for sj in segs if sj != si]
            for sj in other_segs:
                sjv = dw.fp_segs_vwh[sj][0]
                shared_vert &= set([sjv[0], sjv[1]])
            print(f"    s{si} v=({v1},{v2}) front={fi} {role} novt={'V1' if n1 else ''}{'V2' if n2 else ''} "
                  f"shared_v={shared_vert}")
            print(f"      all {len(all_lines)} lines: {all_lines}")

if __name__ == '__main__':
    for name, (px, py, ab) in SCENES:
        run(name, px, py, ab)
        print()
