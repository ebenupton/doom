#!/usr/bin/env python3
"""Measure tighten dispositions across the 9 reference scenes.
Bounds the achievable savings of asymmetric top/bot anchors:
  no_cx_top_only + no_cx_bot_only = spans where one side stays
  unchanged but the current code re-anchors and re-interps both.
"""
import os, sys, math
os.environ['SDL_VIDEODRIVER'] = 'dummy'
os.environ['PYGAME_HIDE_SUPPORT_PROMPT'] = '1'
import pygame; pygame.init(); pygame.display.set_mode((1, 1))

import doom_wireframe as dw
import fp as fpmod
from endpoint_spans import TIGHTEN_STATS

POSITIONS = [
    (1056, -3616, 64, "S1_E"),
    (1056, -3616, 0,  "N"),
    (1056, -3616, 32, "S2_NE"),
    (1056, -3616, 96, "SE"),
    (1200, -3300, 64, "T_moved"),
    (964,  -3441, 79, "doorway"),
    (1200, -3300, 0,  "T_N"),
    (1200, -3300, 32, "T_NE"),
    (800,  -3500, 32, "spawn-W"),
]

def render(px, py, ab):
    fz = dw.player_floor(px, py)
    real = pygame.draw.line
    pygame.draw.line = lambda *a, **k: None
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
    if dw._span_clip_6502 is not None:
        dw._span_clip_6502.clear_screen()
    dw.packed_render_bsp(len(dw.nodes) - 1, dw.Instrumented6502Spans(),
                         ctx, vz_ps, int(px), int(py), cos_f, sin_f,
                         tmp, p_ram)
    pygame.draw.line = real

# Reset and accumulate across all scenes
for k in TIGHTEN_STATS: TIGHTEN_STATS[k] = 0
for px, py, ab, name in POSITIONS:
    render(px, py, ab)

total_overlap = (
    TIGHTEN_STATS['full_dom']
    + TIGHTEN_STATS['no_cx_both_win']
    + TIGHTEN_STATS['no_cx_top_only']
    + TIGHTEN_STATS['no_cx_bot_only']
    + TIGHTEN_STATS['no_cx_both_narrow']
    + TIGHTEN_STATS['no_cx_killed']
    + TIGHTEN_STATS['crossover']
)
one_sided = TIGHTEN_STATS['no_cx_top_only'] + TIGHTEN_STATS['no_cx_bot_only']

print(f"tighten calls:       {TIGHTEN_STATS['tighten_calls']}")
print(f"spans visited:       {TIGHTEN_STATS['spans_visited']}")
print(f"  no_overlap:        {TIGHTEN_STATS['no_overlap']}")
print(f"  full_dom (skip):   {TIGHTEN_STATS['full_dom']}")
print(f"  no_cx both_win:    {TIGHTEN_STATS['no_cx_both_win']}")
print(f"  no_cx top_only:    {TIGHTEN_STATS['no_cx_top_only']}  ← saved by asym")
print(f"  no_cx bot_only:    {TIGHTEN_STATS['no_cx_bot_only']}  ← saved by asym")
print(f"  no_cx both_narrow: {TIGHTEN_STATS['no_cx_both_narrow']}")
print(f"  no_cx killed:      {TIGHTEN_STATS['no_cx_killed']}")
print(f"  crossover (split): {TIGHTEN_STATS['crossover']}")
print()
print(f"interp paths (per overlapping span: 4 for old + 4 for new):")
print(f"  old fast path:     {TIGHTEN_STATS['old_fast_path']}")
print(f"  old interp path:   {TIGHTEN_STATS['old_interp_path']}  → {4*TIGHTEN_STATS['old_interp_path']} interp_stores")
print(f"  new fast path:     {TIGHTEN_STATS['new_fast_path']}")
print(f"  new interp path:   {TIGHTEN_STATS['new_interp_path']}  → {4*TIGHTEN_STATS['new_interp_path']} interp_stores")
print()
print("cheap pre-check would fire (sufficient condition):")
print(f"  pre_top_dom (seg_top_max <= OT_span):  {TIGHTEN_STATS['pre_top_dom']}")
print(f"  pre_bot_dom (seg_bot_min >= OB_span):  {TIGHTEN_STATS['pre_bot_dom']}")
print()
print("interps saved by pre-check + asymmetric anchors (one-sided narrowings):")
print(f"  pre_save_top4 (bot_only AND pre_top_dom): {TIGHTEN_STATS['pre_save_top4']}  → save 4 top interps each")
print(f"  pre_save_bot4 (top_only AND pre_bot_dom): {TIGHTEN_STATS['pre_save_bot4']}  → save 4 bot interps each")
saved_interps = 4 * (TIGHTEN_STATS['pre_save_top4'] + TIGHTEN_STATS['pre_save_bot4'])
print(f"  total interps saved: {saved_interps}  → ~{saved_interps * 80} cyc across 9 scenes")
print()
print(f"overlapping spans:   {total_overlap}")
print(f"one-sided narrow:    {one_sided}  ({100*one_sided/max(1,total_overlap):.1f}% of overlap)")
print(f"                          ({100*one_sided/max(1,TIGHTEN_STATS['spans_visited']):.1f}% of all spans visited)")
