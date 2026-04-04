#!/usr/bin/env python3
"""Wide-range verification of packed vs classic FP rendering.

Tests at many more positions and angles to ensure robustness.
"""

import os
os.environ['SDL_VIDEODRIVER'] = 'dummy'
os.environ['PYGAME_HIDE_SUPPORT_PROMPT'] = '1'

import sys, math, random
sys.setrecursionlimit(10000)

import pygame
pygame.init()

from doom_wireframe import (
    fp_segs_vwh, nodes, vertexes, vwh_table,
    FPClipSpans, render_bsp_fp,
    packed_render_bsp, _packed_ram_new,
    player_x, player_y, player_floor, _prescale_height,
    FP_WIDTH, FP_HEIGHT, MAP_CENTER_X, MAP_CENTER_Y, PRESCALE,
    draw_stats, map_trace, _real_drawline,
)
import fp as fp_module
from fp import fp_sincos, fp_view_context


def run_one(px, py, ab):
    """Run both paths, return True if draws match."""
    ang_rad = ab * 2 * math.pi / 256
    cos_f, sin_f = math.cos(ang_rad), math.sin(ang_rad)
    px_88 = int((px - MAP_CENTER_X) * 256 / PRESCALE)
    py_88 = int((py - MAP_CENTER_Y) * 256 / PRESCALE)
    vz_ps = _prescale_height(player_floor(px, py) + 41)
    sc = fp_sincos(ab)

    classic, packed = [], []
    cur = [None]

    def intercept(surface, color, p1, p2, w=1):
        if cur[0] is not None:
            cur[0].append(((int(p1[0]), int(p1[1])), (int(p2[0]), int(p2[1]))))
        return _real_drawline(surface, color, p1, p2, w)

    tmp = pygame.Surface((FP_WIDTH, FP_HEIGHT))

    cur[0] = classic
    pygame.draw.line = intercept
    fp_module.mul_reset()
    ctx = fp_view_context(px_88, py_88, sc)
    random.seed(42)
    for i in range(5): draw_stats[i] = 0
    for k in map_trace:
        map_trace[k] = {} if k == "vertex_muls" else ([] if k == "ss_order" else set())
    tmp.fill(0)
    render_bsp_fp(len(nodes)-1, FPClipSpans(), ctx, vz_ps,
                  int(px), int(py), cos_f, sin_f, tmp,
                  [None]*len(vertexes), [None]*len(vwh_table))

    cur[0] = packed
    fp_module.mul_reset()
    ctx = fp_view_context(px_88, py_88, sc)
    random.seed(42)
    for i in range(5): draw_stats[i] = 0
    for k in map_trace:
        map_trace[k] = {} if k == "vertex_muls" else ([] if k == "ss_order" else set())
    tmp.fill(0)
    ram = _packed_ram_new()
    packed_render_bsp(len(nodes)-1, FPClipSpans(), ctx, vz_ps,
                      int(px), int(py), cos_f, sin_f, tmp, ram)

    cur[0] = None
    pygame.draw.line = _real_drawline
    return classic == packed


# ── Test grid: wider area + all 256 angles at selected positions ──
print("=== Wide verification ===")
n, ok, fail = 0, 0, 0
fail_list = []

# Phase 1: coarse grid, all angles
positions_coarse = [
    (player_x + dx, player_y + dy)
    for dx in range(-200, 201, 100)
    for dy in range(-200, 201, 100)
]
angles_coarse = list(range(0, 256, 4))  # 64 angles

for px, py in positions_coarse:
    for ab in angles_coarse:
        n += 1
        if run_one(px, py, ab):
            ok += 1
        else:
            fail += 1
            if len(fail_list) < 10:
                fail_list.append((px, py, ab))
    if n % 200 == 0:
        print(f"  {n} tested, {ok} passed, {fail} failed", flush=True)

# Phase 2: player start position, every single angle
for ab in range(256):
    n += 1
    if run_one(player_x, player_y, ab):
        ok += 1
    else:
        fail += 1
        if len(fail_list) < 10:
            fail_list.append((player_x, player_y, ab))

print(f"\n=== Results: {n} tested, {ok} passed, {fail} failed ===")
if fail_list:
    for px, py, ab in fail_list:
        print(f"  FAIL at ({px:.0f},{py:.0f}) angle={ab}")
else:
    print("ALL TESTS PASSED!")

pygame.quit()
