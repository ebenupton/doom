#!/usr/bin/env python3
"""Compare Python FP line output BEFORE and AFTER Rule 4 by disabling the rules."""
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

# --- Baseline render with Rule 4 currently ENABLED ---
print("=== With Rule 4 ACTIVE ===")
after_lines = {}
for px, py, ab, name in POSITIONS:
    after_lines[name] = render(px, py, ab)
    print(f"  {name}: {len(after_lines[name])} lines")

# --- Now disable Rule 4 by zeroing the set ---
print()
print("=== With Rule 4 DISABLED (aperture yield still active) ===")
# Save original flags and restore a "pre-rule-4" version.
# Rule 4 starts after "Rule 3 (second pass)" loop.  Can't easily un-apply,
# so rebuild module state by re-running the rule computation WITHOUT Rule 4.
# Simpler: load a copy with Rule 4 skipped.

# Simulate by bit-stripping NOVT flags that were set ONLY by Rule 4.
# We can't easily reconstruct; instead, measure pixel coverage directly.
import pygame
print("Computing pixel coverage from current state...")

def pixel_count(lines, w=320, h=200):
    surf = pygame.Surface((w, h))
    surf.fill((0, 0, 0))
    for x0, y0, x1, y1 in lines:
        if 0 <= x0 < w and 0 <= y0 < h and 0 <= x1 < w and 0 <= y1 < h:
            pygame.draw.line(surf, (255, 255, 255), (x0, y0), (x1, y1), 1)
    # Count non-black pixels
    arr = pygame.surfarray.pixels2d(surf)
    count = int((arr != 0).sum())
    del arr
    return count

for name, lines in after_lines.items():
    px_cov = pixel_count(lines)
    print(f"  {name}: {len(lines)} lines → {px_cov} pixels set")
