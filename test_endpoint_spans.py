#!/usr/bin/env python3
"""Test EndpointClipSpans against FPClipSpans: compare line output."""
import os, sys, math
os.environ['SDL_VIDEODRIVER'] = 'dummy'
os.environ['PYGAME_HIDE_SUPPORT_PROMPT'] = '1'
import pygame; pygame.init(); pygame.display.set_mode((1, 1))

import doom_wireframe as dw
from endpoint_spans import EndpointClipSpans
import fp as fpmod

POSITIONS = [
    (1056, -3616, 64, "E (spawn)"),
    (1056, -3616, 0, "N"),
    (1031, -3447, 64, "corrupt1"),
    (1049, -3408, 16, "corrupt2"),
    (1200, -3300, 64, "moved"),
]

for PX, PY, ANGLE, name in POSITIONS:
    FZ = dw.player_floor(PX, PY)
    px_88 = int((PX - dw.MAP_CENTER_X) * 256 / dw.PRESCALE)
    py_88 = int((PY - dw.MAP_CENTER_Y) * 256 / dw.PRESCALE)
    vz_ps = dw._prescale_height(FZ + 41)
    sc = dw.fp_sincos(ANGLE)
    ctx = dw.fp_view_context(px_88, py_88, sc)
    ang_rad = dw.byte_to_radians(ANGLE)
    cos_f, sin_f = math.cos(ang_rad), math.sin(ang_rad)

    # Run with FPClipSpans (reference)
    fp_lines = []
    _real = pygame.draw.line
    def _cap_fp(surface, color, p1, p2, w=1):
        fp_lines.append((int(p1[0]), int(p1[1]), int(p2[0]), int(p2[1])))
        return _real(surface, color, p1, p2, w)
    pygame.draw.line = _cap_fp
    tmp = pygame.Surface((dw.FP_RENDER_W, dw.FP_RENDER_H))
    fpmod.mul_reset()
    fp_clips = dw.FPClipSpans()
    dw.render_bsp_fp(len(dw.nodes) - 1, fp_clips, ctx, vz_ps,
                     int(PX), int(PY), cos_f, sin_f, tmp,
                     [None] * len(dw.vertexes), [None] * len(dw.vwh_table))
    pygame.draw.line = _real
    fp_set = set(fp_lines)

    # Run with EndpointClipSpans
    ep_lines = []
    def _cap_ep(surface, color, p1, p2, w=1):
        ep_lines.append((int(p1[0]), int(p1[1]), int(p2[0]), int(p2[1])))
        return _real(surface, color, p1, p2, w)
    pygame.draw.line = _cap_ep
    tmp2 = pygame.Surface((dw.FP_RENDER_W, dw.FP_RENDER_H))
    fpmod.mul_reset()
    ep_clips = EndpointClipSpans()
    dw.render_bsp_fp(len(dw.nodes) - 1, ep_clips, ctx, vz_ps,
                     int(PX), int(PY), cos_f, sin_f, tmp2,
                     [None] * len(dw.vertexes), [None] * len(dw.vwh_table))
    pygame.draw.line = _real
    ep_set = set(ep_lines)

    only_fp = fp_set - ep_set
    only_ep = ep_set - fp_set
    status = "MATCH" if not only_fp and not only_ep else f"fp_only={len(only_fp)} ep_only={len(only_ep)}"
    print(f"  {name:15s}  FP={len(fp_set):>3}  EP={len(ep_set):>3}  {status}")
    if only_fp and len(only_fp) <= 5:
        for l in sorted(only_fp):
            print(f"    FP only: {l}")
    if only_ep and len(only_ep) <= 5:
        for l in sorted(only_ep):
            print(f"    EP only: {l}")
