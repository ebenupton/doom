#!/usr/bin/env python3
"""Compare 6502 vs Python FP line output across all test positions, focus on
dup-suppression regression risk: confirm Python line sets haven't lost coverage.
"""
import os, sys, math
os.environ['SDL_VIDEODRIVER'] = 'dummy'
os.environ['PYGAME_HIDE_SUPPORT_PROMPT'] = '1'
import pygame; pygame.init(); pygame.display.set_mode((1, 1))

import doom_wireframe as dw
from fe6502 import Frontend6502
from endpoint_spans import EndpointClipSpans
import fp as fpmod

POSITIONS = [
    (1056, -3616, 64, "S1 E"),
    (1056, -3616, 0, "N"),
    (1056, -3616, 32, "S2 NE"),
    (1056, -3616, 96, "SE"),
    (1200, -3300, 64, "T moved"),
]

fe = Frontend6502(dw.packed_rom_banks, dw.packed_rom_recip,
                  dw.packed_bbox_table, dw.packed_layout)

for PX, PY, ANGLE, name in POSITIONS:
    FZ = dw.player_floor(PX, PY)

    # 6502
    asm_lines, cyc = fe.render_frame(PX, PY, ANGLE, FZ, capture_lines=True)
    asm_set = set(asm_lines)

    # Python FP
    captured = []
    _real = pygame.draw.line
    def _cap(surface, color, p1, p2, w=1):
        captured.append((int(p1[0]), int(p1[1]), int(p2[0]), int(p2[1])))
        return _real(surface, color, p1, p2, w)
    pygame.draw.line = _cap

    px_88 = int((PX - dw.MAP_CENTER_X) * 256 / dw.PRESCALE)
    py_88 = int((PY - dw.MAP_CENTER_Y) * 256 / dw.PRESCALE)
    vz_ps = dw._prescale_height(FZ + 41)
    sc = dw.fp_sincos(ANGLE)
    ctx = dw.fp_view_context(px_88, py_88, sc)
    ang_rad = dw.byte_to_radians(ANGLE)
    cos_f, sin_f = math.cos(ang_rad), math.sin(ang_rad)
    tmp = pygame.Surface((dw.FP_RENDER_W, dw.FP_RENDER_H))
    for k in dw.map_trace:
        if hasattr(dw.map_trace[k], 'clear'):
            dw.map_trace[k].clear()
    fpmod.mul_reset()
    dw.render_bsp_fp(len(dw.nodes) - 1, EndpointClipSpans(), ctx, vz_ps,
                     int(PX), int(PY), cos_f, sin_f, tmp,
                     [None] * len(dw.vertexes), [None] * len(dw.vwh_table))
    pygame.draw.line = _real

    py_set = set(captured)
    only_asm = asm_set - py_set
    only_py = py_set - asm_set
    status = "MATCH" if not only_asm and not only_py else f"asm_only={len(only_asm)} py_only={len(only_py)}"
    print(f"  {name:10s}  6502={len(asm_set):>3}  py={len(py_set):>3}  cyc={cyc:>8}  {status}")
    if only_py:
        for l in sorted(only_py)[:5]:
            print(f"         MISSING:  ({l[0]},{l[1]},{l[2]},{l[3]})")
    if only_asm:
        for l in sorted(only_asm)[:5]:
            print(f"         EXTRA:    ({l[0]},{l[1]},{l[2]},{l[3]})")
