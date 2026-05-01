#!/usr/bin/env python3
"""Measure aperture-clip-skip optimisation: how often does need_bt/need_bb
get fully clipped above/below the visible spans, letting us skip the
horizontal + step verticals + (optional) front-ceil/floor line?

Reports per-scene fire rate, lines saved, and verifies pixel coverage
is unchanged vs the unoptimised path.
"""
import os, sys, math
os.environ['SDL_VIDEODRIVER'] = 'dummy'
os.environ['PYGAME_HIDE_SUPPORT_PROMPT'] = '1'
import pygame; pygame.init(); pygame.display.set_mode((1, 1))

import doom_wireframe as dw
from endpoint_spans import EndpointClipSpans
from fe6502 import Frontend6502
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

fe = Frontend6502(dw.packed_rom_banks, dw.packed_rom_recip,
                  dw.packed_bbox_table, dw.packed_layout)


def render_python(px, py, ab):
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
    # Reset stats
    for k in dw._ap_skip_stats: dw._ap_skip_stats[k] = 0
    from wad_packed import spans_init_full
    p_ram = dw._packed_ram_new()
    spans_base = dw.packed_layout['ram_spans']
    spans_init_full(p_ram, spans_base, dw.FP_RENDER_W, dw.FP_RENDER_H - 1)
    dw.packed_render_bsp(len(dw.nodes) - 1, dw.Instrumented6502Spans(),
                         ctx, vz_ps, int(px), int(py), cos_f, sin_f,
                         tmp, p_ram)
    pygame.draw.line = real
    return captured, dict(dw._ap_skip_stats)


hdr = (f"{'scene':<10s}  {'bt_s':>4s}  {'bb_s':>4s}  "
       f"{'sol_t':>5s}  {'sol_b':>5s}  {'pp_t':>4s}  {'pp_b':>4s}")
print(hdr)
totals = dict.fromkeys(['bt_skipped', 'bb_skipped', 'solid_top_skipped',
                         'solid_bot_skipped', 'pp_top_skipped',
                         'pp_bot_skipped'], 0)
for px, py, ab, name in POSITIONS:
    py_lines, stats = render_python(px, py, ab)
    for k in totals:
        if k in stats:
            totals[k] += stats[k]
    print(f"{name:<10s}  {stats['bt_skipped']:>4d}  {stats['bb_skipped']:>4d}  "
          f"{stats['solid_top_skipped']:>5d}  {stats['solid_bot_skipped']:>5d}  "
          f"{stats['pp_top_skipped']:>4d}  {stats['pp_bot_skipped']:>4d}")

print()
print(f"TOTAL       {totals['bt_skipped']:>4d}  {totals['bb_skipped']:>4d}  "
      f"{totals['solid_top_skipped']:>5d}  {totals['solid_bot_skipped']:>5d}  "
      f"{totals['pp_top_skipped']:>4d}  {totals['pp_bot_skipped']:>4d}")
total_lines_saved = sum(totals.values())
print(f"Total skipped emissions: {total_lines_saved}, avg per scene: {total_lines_saved/len(POSITIONS):.1f}")
