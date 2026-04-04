#!/usr/bin/env python3
"""Test the packed rendering path against the classic FP path.

Run:  SDL_VIDEODRIVER=dummy python3 test_packed.py

Verifies that packed_render_bsp produces identical draw calls to
render_bsp_fp at multiple positions and angles.
"""

import os
os.environ['SDL_VIDEODRIVER'] = 'dummy'
os.environ['PYGAME_HIDE_SUPPORT_PROMPT'] = '1'

import sys, math, random, struct
sys.setrecursionlimit(10000)

import pygame
pygame.init()
_screen = pygame.display.set_mode((1, 1))

# ── Pre-import checks: verify linedef deltas fit in s8 ──────────────────────

from doom_wireframe import (
    fp_vertexes, linedefs, fp_segs_vwh, fp_ssectors, nodes, vertexes,
    vwh_table, fp_sectors, segs, sectors, sidedefs,
    FPClipSpans, render_bsp_fp, fp_bbox_visible,
    packed_render_bsp, packed_render_seg, packed_render_subsector,
    _packed_ram_new, _p_layout, _p_rom_main, _p_rom_detail,
    player_x, player_y, player_floor, _prescale_height,
    FP_WIDTH, FP_HEIGHT, MAP_CENTER_X, MAP_CENTER_Y, PRESCALE,
    NF_SUBSECTOR, draw_stats, map_trace, hud_font,
    GREEN, use_subpixel, _real_drawline,
)
import fp as fp_module
from fp import fp_sincos, fp_view_context, RECIP_FRAC_BITS

print("=== Pre-check: linedef delta clamping ===")
clamped = 0
for i, svwh in enumerate(fp_segs_vwh):
    s = svwh[0]
    ld = linedefs[s[3]]
    lv1 = fp_vertexes[ld[0]]
    lv2 = fp_vertexes[ld[1]]
    dx = lv2[0] - lv1[0]
    dy = lv2[1] - lv1[1]
    if dx < -128 or dx > 127 or dy < -128 or dy > 127:
        clamped += 1
        print(f"  seg {i}: ld={s[3]} dx={dx} dy={dy}")
if clamped == 0:
    print("  All deltas fit in s8 -- no clamping issues.")
else:
    print(f"  WARNING: {clamped} segs have clamped deltas -- back-face test may differ!")
print()


# ── Verification ─────────────────────────────────────────────────────────────

def run_comparison(px, py, ab):
    """Run both renderers at a given position/angle and compare draw calls.

    Returns (match, classic_draws, packed_draws).
    """
    ang_rad = ab * 2 * math.pi / 256
    cos_f = math.cos(ang_rad)
    sin_f = math.sin(ang_rad)
    px_88 = int((px - MAP_CENTER_X) * 256 / PRESCALE)
    py_88 = int((py - MAP_CENTER_Y) * 256 / PRESCALE)
    vz_ps = _prescale_height(player_floor(px, py) + 41)
    sc = fp_sincos(ab)

    classic_draws = []
    packed_draws = []
    _current = [None]

    def _intercept(surface, color, p1, p2, w=1):
        if _current[0] is not None:
            _current[0].append(((int(p1[0]), int(p1[1])),
                                (int(p2[0]), int(p2[1]))))
        return _real_drawline(surface, color, p1, p2, w)

    tmp = pygame.Surface((FP_WIDTH, FP_HEIGHT))

    # Classic FP run
    _current[0] = classic_draws
    pygame.draw.line = _intercept
    fp_module.mul_reset()
    ctx_c = fp_view_context(px_88, py_88, sc)
    random.seed(42)
    for i in range(5): draw_stats[i] = 0
    for k in map_trace:
        map_trace[k] = {} if k == "vertex_muls" else ([] if k == "ss_order" else set())
    tmp.fill((0, 0, 0))
    render_bsp_fp(len(nodes)-1, FPClipSpans(), ctx_c, vz_ps,
                  int(px), int(py), cos_f, sin_f, tmp,
                  [None]*len(vertexes), [None]*len(vwh_table))
    classic_muls = dict(fp_module.mul_counts)

    # Packed run
    _current[0] = packed_draws
    fp_module.mul_reset()
    ctx_p = fp_view_context(px_88, py_88, sc)
    random.seed(42)
    for i in range(5): draw_stats[i] = 0
    for k in map_trace:
        map_trace[k] = {} if k == "vertex_muls" else ([] if k == "ss_order" else set())
    tmp.fill((0, 0, 0))
    p_ram = _packed_ram_new()
    packed_render_bsp(len(nodes)-1, FPClipSpans(), ctx_p, vz_ps,
                      int(px), int(py), cos_f, sin_f, tmp, p_ram)
    packed_muls = dict(fp_module.mul_counts)

    _current[0] = None
    pygame.draw.line = _real_drawline

    return classic_draws == packed_draws, classic_draws, packed_draws, classic_muls, packed_muls


# ── Main test ────────────────────────────────────────────────────────────────

print("=== Verification: classic FP vs packed FP ===")
print(f"Player start: ({player_x:.0f}, {player_y:.0f})")
print()

# Test at the player start first
px0, py0 = player_x, player_y
ab0 = 28  # roughly the starting angle

match, c_draws, p_draws, c_muls, p_muls = run_comparison(px0, py0, ab0)
print(f"Position ({px0:.0f},{py0:.0f}) angle={ab0}:")
print(f"  Classic: {len(c_draws)} draws, muls={c_muls}")
print(f"  Packed:  {len(p_draws)} draws, muls={p_muls}")
print(f"  Match: {match}")
if not match:
    for i in range(min(10, max(len(c_draws), len(p_draws)))):
        c = c_draws[i] if i < len(c_draws) else "---"
        p = p_draws[i] if i < len(p_draws) else "---"
        flag = " <-- DIFF" if c != p else ""
        print(f"    [{i}] classic={c}  packed={p}{flag}")
print()

# Run over a grid of positions and angles
n_tested = 0
n_passed = 0
n_failed = 0
fail_examples = []

test_positions = [(px0 + dx, py0 + dy)
                  for dx in range(-120, 121, 60)
                  for dy in range(-120, 121, 60)]
test_angles = list(range(0, 256, 8))  # 32 angles

for px, py in test_positions:
    for ab in test_angles:
        n_tested += 1
        try:
            match, c_draws, p_draws, _, _ = run_comparison(px, py, ab)
        except Exception as e:
            match = False
            c_draws, p_draws = [], []
            fail_examples.append(((px, py), ab, f"EXCEPTION: {e}"))
            n_failed += 1
            continue

        if match:
            n_passed += 1
        else:
            n_failed += 1
            if len(fail_examples) < 5:
                first_diff = None
                for i in range(max(len(c_draws), len(p_draws))):
                    c = c_draws[i] if i < len(c_draws) else None
                    p = p_draws[i] if i < len(p_draws) else None
                    if c != p:
                        first_diff = (i, c, p)
                        break
                fail_examples.append(((px, py), ab,
                    f"classic={len(c_draws)} packed={len(p_draws)} first_diff={first_diff}"))

        if n_tested % 100 == 0:
            print(f"  ... {n_tested} tested, {n_passed} passed, {n_failed} failed", flush=True)

print()
print(f"=== Results: {n_tested} tested, {n_passed} passed, {n_failed} failed ===")
if fail_examples:
    print("First few failures:")
    for (pos, ang, detail) in fail_examples:
        print(f"  pos={pos} angle={ang}: {detail}")
else:
    print("ALL TESTS PASSED!")
print()

pygame.quit()
