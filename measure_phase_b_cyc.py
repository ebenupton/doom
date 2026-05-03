#!/usr/bin/env python3
"""Measure DCL+tighten cycles with Phase B records (DCL hooks) on vs off."""
import os, math
os.environ['SDL_VIDEODRIVER'] = 'dummy'
os.environ['PYGAME_HIDE_SUPPORT_PROMPT'] = '1'
import pygame; pygame.init(); pygame.display.set_mode((1, 1))

import doom_wireframe as dw
import fp as fpmod
import span_clip_6502 as sc6mod

POSITIONS = [
    (1056, -3616, 64, "S1"),
    (505, -3268, 125, "S2"),
    (1056, -3616, 0, "N"),
    (1056, -3616, 32, "S2_NE"),
    (1056, -3616, 96, "SE"),
    (1200, -3300, 64, "T_moved"),
    (964, -3441, 79, "doorway"),
    (1200, -3300, 0, "T_N"),
    (1200, -3300, 32, "T_NE"),
    (800, -3500, 32, "spawn-W"),
]


def render(px, py, ab):
    fz = dw.player_floor(px, py)
    real = pygame.draw.line; pygame.draw.line = lambda *a, **k: None
    px_88 = int((px - dw.MAP_CENTER_X) * 256 / dw.PRESCALE)
    py_88 = int((py - dw.MAP_CENTER_Y) * 256 / dw.PRESCALE)
    vz_ps = dw._prescale_height(fz + 41)
    sc = dw.fp_sincos(ab); ctx = dw.fp_view_context(px_88, py_88, sc)
    ang_rad = dw.byte_to_radians(ab)
    cos_f, sin_f = math.cos(ang_rad), math.sin(ang_rad)
    tmp = pygame.Surface((dw.FP_RENDER_W, dw.FP_RENDER_H))
    fpmod.mul_reset()
    from wad_packed import spans_init_full
    p_ram = dw._packed_ram_new()
    spans_base = dw.packed_layout['ram_spans']
    spans_init_full(p_ram, spans_base, dw.FP_RENDER_W, dw.FP_RENDER_H - 1)
    if dw._span_clip_6502 is not None:
        dw._span_clip_6502.init()
        dw._span_clip_6502.total_cycles = 0
    dw.packed_render_bsp(len(dw.nodes) - 1, dw.Instrumented6502Spans(),
                         ctx, vz_ps, int(px), int(py), cos_f, sin_f,
                         tmp, p_ram)
    pygame.draw.line = real
    return dw._span_clip_6502.total_cycles


print(f"{'scene':<10s} {'PhB on':>10s} {'PhB off':>10s} {'delta':>8s} {'pct':>6s}")
total_on = 0
total_off = 0
for px, py, ab, name in POSITIONS:
    sc6mod._USE_6502_RECORDS_TIGHTEN = True
    sc6mod._USE_DCL_RECORDS_HOOK = True
    on = render(px, py, ab)
    sc6mod._USE_6502_RECORDS_TIGHTEN = False
    sc6mod._USE_DCL_RECORDS_HOOK = False
    off = render(px, py, ab)
    delta = off - on
    pct = 100 * delta / off if off else 0
    total_on += on
    total_off += off
    print(f"{name:<10s} {on:>10d} {off:>10d} {delta:>8d} {pct:>5.1f}%")

print()
print(f"{'TOTAL':<10s} {total_on:>10d} {total_off:>10d} "
      f"{total_off - total_on:>8d} {100*(total_off-total_on)/total_off:>5.1f}%")
