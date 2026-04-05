#!/usr/bin/env python3
"""Compare 6502 S/P draw commands against Python FP reference at current prescale."""
import os, sys
os.environ['SDL_VIDEODRIVER'] = 'dummy'
os.environ['PYGAME_HIDE_SUPPORT_PROMPT'] = '1'
import pygame; pygame.init(); pygame.display.set_mode((1,1))

import doom_wireframe as dw
from fe6502 import Frontend6502
import math

fe = Frontend6502(dw.packed_rom_main, dw.packed_rom_detail,
                  dw.packed_rom_recip, dw.packed_layout)

POSITIONS = [
    (1056, -3616, 64, "spawn East"),
    (1056, -3616, 0, "spawn North"),
    (1056, -3616, 32, "spawn NE"),
    (1056, -3616, 96, "spawn SE"),
    (1200, -3300, 64, "moved East"),
]

print(f"=== PRESCALE={dw.PRESCALE} ===")
print(f"{'position':20s} {'6502 S/P':>10s} {'python drawn':>14s}")

for px, py, ab, name in POSITIONS:
    # 6502
    fz = dw.player_floor(px, py)
    cmds, cyc = fe.render_frame(px, py, ab, fz)
    hw_draws = sum(1 for c in cmds if c[0] in 'SP')

    # Python FP
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
    dw.render_bsp_fp(len(dw.nodes) - 1, dw.FPClipSpans(), ctx, vz_ps,
                     px, py, cos_f, sin_f, tmp,
                     [None] * len(dw.vertexes), [None] * len(dw.vwh_table))
    py_draws = len(dw.map_trace['segs_drawn'])

    marker = "" if hw_draws == py_draws else "  <-- DIVERGENCE"
    print(f"  {name:18s}  {hw_draws:>8d}    {py_draws:>10d}      {marker}")
