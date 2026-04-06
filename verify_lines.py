#!/usr/bin/env python3
"""Verify that the 6502 front-end + line peripheral produces exactly the same
clipped lines as the Python FP reference path.

The 6502 front-end now writes raw (unclipped) lines to the magic peripheral
at $FE20-$FE27.  The peripheral clips each line against the current span
state (same Cyrus-Beck as Python) and records the output.

The Python reference runs clip_and_draw_6502_lines() which processes the
command buffer through FPClipSpans.draw_clipped.

Both should produce the same set of clipped (x0,y0,x1,y1) line segments.
"""
import os, sys
os.environ['SDL_VIDEODRIVER'] = 'dummy'
os.environ['PYGAME_HIDE_SUPPORT_PROMPT'] = '1'
import pygame; pygame.init(); pygame.display.set_mode((1, 1))

import doom_wireframe as dw
from fe6502 import Frontend6502
import math

POSITIONS = [
    (1056, -3616, 64, "spawn East"),
    (1056, -3616, 0, "spawn North"),
    (1056, -3616, 32, "spawn NE"),
    (1056, -3616, 96, "spawn SE"),
    (1200, -3300, 64, "moved East"),
]

fe = Frontend6502(dw.packed_rom_banks, dw.packed_rom_recip,
                  dw.packed_bbox_table, dw.packed_layout)

print(f"=== Line verification (PRESCALE={dw.PRESCALE}) ===")
all_pass = True

for px, py, ab, name in POSITIONS:
    fz = dw.player_floor(px, py)

    # 6502 path: front-end writes to peripheral, peripheral clips
    hw_lines, hw_cyc = fe.render_frame(px, py, ab, fz)

    # Python reference path: render + clip_and_draw_6502_lines
    # (uses the old command-buffer approach for reference)
    # We need to compare against the Python FP renderer's clipped output.
    # Use the FP rendering path directly:
    from fp import fp_sincos, fp_view_context, PRESCALE, MAP_CENTER_X, MAP_CENTER_Y
    px_88 = int((px - MAP_CENTER_X) * 256 / PRESCALE)
    py_88 = int((py - MAP_CENTER_Y) * 256 / PRESCALE)
    sc = fp_sincos(ab)
    ctx = fp_view_context(px_88, py_88, sc)
    ang_rad = dw.byte_to_radians(ab)
    cos_f, sin_f = math.cos(ang_rad), math.sin(ang_rad)

    # Capture Python clipped lines
    py_lines = []
    saved_drawline = pygame.draw.line
    def _capture(surface, color, p1, p2, w=1):
        py_lines.append((int(p1[0]), int(p1[1]), int(p2[0]), int(p2[1])))
    pygame.draw.line = _capture
    tmp = pygame.Surface((dw.FP_RENDER_W, dw.FP_RENDER_H))
    for k in dw.map_trace:
        if hasattr(dw.map_trace[k], 'clear'):
            dw.map_trace[k].clear()
    dw.fp_module.mul_reset()
    dw.render_bsp_fp(len(dw.nodes) - 1, dw.FPClipSpans(), ctx, dw._prescale_height(fz + 41),
                     px, py, cos_f, sin_f, tmp,
                     [None] * len(dw.vertexes), [None] * len(dw.vwh_table))
    pygame.draw.line = saved_drawline

    # Compare (sorted — line order within each seg batch may differ)
    match = (sorted(hw_lines) == sorted(py_lines))
    status = "MATCH" if match else f"DIVERGE hw={len(hw_lines)} py={len(py_lines)}"
    if not match:
        all_pass = False
        # Find first difference
        for i in range(max(len(hw_lines), len(py_lines))):
            hw = hw_lines[i] if i < len(hw_lines) else None
            py_ = py_lines[i] if i < len(py_lines) else None
            if hw != py_:
                print(f"  {name:15s}  {status}  first diff at line {i}: hw={hw} py={py_}")
                break
    else:
        print(f"  {name:15s}  {len(hw_lines):3d} lines  {hw_cyc:>7d} cyc  {status}")

print()
print("ALL MATCH" if all_pass else "DIVERGENCE(S) DETECTED")
sys.exit(0 if all_pass else 1)
