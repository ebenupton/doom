#!/usr/bin/env python3
"""Verify the aperture-clip skip optimisation preserves pixel coverage:
render each test scene with and without _AP_SKIP_ENABLE, compare line sets.
"""
import os, sys, math
os.environ['SDL_VIDEODRIVER'] = 'dummy'
os.environ['PYGAME_HIDE_SUPPORT_PROMPT'] = '1'
import pygame; pygame.init(); pygame.display.set_mode((1, 1))

import doom_wireframe as dw
import fp as fpmod

POSITIONS = [
    (1056, -3616, 64, "S1 E"),
    (1056, -3616, 0, "N"),
    (1056, -3616, 32, "S2 NE"),
    (1056, -3616, 96, "SE"),
    (1200, -3300, 64, "T moved"),
    (964, -3441, 79, "doorway"),
    (1200, -3300, 0, "T N"),
    (1200, -3300, 32, "T NE"),
    (800, -3500, 32, "spawn-W"),
]


def render(px, py, ab):
    fz = dw.player_floor(px, py)
    captured = []
    real = pygame.draw.line
    def cap(s, c, p1, p2, w=1):
        captured.append((int(p1[0]), int(p1[1]), int(p2[0]), int(p2[1])))
        return real(s, c, p1, p2, w)
    pygame.draw.line = cap
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
    from wad_packed import spans_init_full
    p_ram = dw._packed_ram_new()
    spans_base = dw.packed_layout['ram_spans']
    spans_init_full(p_ram, spans_base, dw.FP_RENDER_W, dw.FP_RENDER_H - 1)
    dw.packed_render_bsp(len(dw.nodes) - 1, dw.Instrumented6502Spans(),
                         ctx, vz_ps, int(px), int(py), cos_f, sin_f,
                         tmp, p_ram)
    pygame.draw.line = real
    return captured


def norm(r):
    x1, y1, x2, y2 = r
    return r if (x1, y1) <= (x2, y2) else (x2, y2, x1, y1)


bad = 0
print(f"{'scene':<10s}  {'on':>4s}  {'off':>4s}  {'lost':>4s}  {'gained':>6s}")
for px, py, ab, name in POSITIONS:
    dw._AP_SKIP_ENABLE = True
    on_set = set(map(norm, render(px, py, ab)))
    dw._AP_SKIP_ENABLE = False
    off_set = set(map(norm, render(px, py, ab)))
    lost = off_set - on_set
    gained = on_set - off_set
    bad += len(lost) + len(gained)
    print(f"{name:<10s}  {len(on_set):>4d}  {len(off_set):>4d}  {len(lost):>4d}  {len(gained):>6d}")
    for l in sorted(lost):
        print(f"   LOST: {l}")
    for l in sorted(gained):
        print(f"   GAIN: {l}")

print()
print(f"Total {bad} divergences" if bad else "All scenes match — coverage preserved.")
dw._AP_SKIP_ENABLE = True
