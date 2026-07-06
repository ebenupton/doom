#!/usr/bin/env python3
"""Pixel-exact Python reference frame.

Runs the full Python packed pipeline (packed_render_bsp: Python BSP traversal,
Python transform/projection, 6502-shadow span clipper with the pure-Python
EndpointClipSpans lockstep check) with angle-space bbox visibility, captures
every emitted raster segment from the clipper, and rasterises them in pure
Python with nj_raster (proven pixel-exact vs the 6502 NJ rasteriser over the
42,462-line corpus).

render_ref_fb(px, py, ab) -> (fb_bytes, clip_ok): a 5120-byte mode-4
framebuffer byte-comparable with the engine's $5800 FB, plus the
python-vs-6502 span-state lockstep verdict for the frame.

__main__: compares the reference FB against the all-6502 engine FB
(BspRender6502.render_frame) at the regression positions.
"""
import os, sys
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), '..'))
os.chdir(os.path.join(os.path.dirname(os.path.abspath(__file__)), '..'))
os.environ.setdefault('SDL_VIDEODRIVER', 'dummy')
os.environ.setdefault('PYGAME_HIDE_SUPPORT_PROMPT', '1')
import pygame
pygame.init()

import doom_wireframe as dw
import fp
import nj_raster
from wad_packed import spans_init_full

# The ENGINE has no aperture-skip: subsector.s gates ft/fb/bt/bb emission on
# seg flags + height compares only and lets DCL clip against the pool. The
# python ap-skip is a python-side speed hack that decides from the legacy
# span MODEL (which drifts ±1 from the pool) — with it on, the reference
# skips draws/tightens the engine performs and diverges. Keep it off here.
dw._AP_SKIP_ENABLE = False

_surf = None


def render_ref_fb(px, py, ab):
    """Full-Python-pipeline frame -> (5120-byte FB, clip_lockstep_ok)."""
    global _surf
    if _surf is None:
        _surf = pygame.Surface((dw.FP_RENDER_W, dw.FP_RENDER_H))
    clips = dw.Instrumented6502Spans()
    sc = dw._span_clip_6502
    sc.capture = []
    orig_use, orig_ab = dw._USE_ANGLE_BBOX, dw._VIEW_AB
    dw._USE_ANGLE_BBOX = True
    dw._VIEW_AB = ab
    try:
        px_88 = int((px - dw.MAP_CENTER_X) * 256 / dw.PRESCALE)
        py_88 = int((py - dw.MAP_CENTER_Y) * 256 / dw.PRESCALE)
        sc_t = fp.fp_sincos(ab)
        ctx = fp.fp_view_context(px_88, py_88, sc_t)
        vz = dw._prescale_height(dw.player_floor(px, py) + 41)
        cos_f = pygame.math.Vector2(1, 0).rotate(ab * 360 / 256).x
        sin_f = pygame.math.Vector2(1, 0).rotate(ab * 360 / 256).y
        p_ram = bytearray(dw.packed_layout['ram_size'])
        spans_init_full(p_ram, dw.packed_layout['ram_spans'],
                        dw.FP_RENDER_W, dw.FP_RENDER_H - 1)
        dw.packed_render_bsp(len(dw.nodes) - 1, clips, ctx, vz,
                             px, py, cos_f, sin_f, _surf, p_ram)
    finally:
        dw.packed_render_subsector = dw.packed_render_subsector
        dw._USE_ANGLE_BBOX, dw._VIEW_AB = orig_use, orig_ab
    fb = nj_raster.new_fb()
    for (x0, y0, x1, y1) in sc.capture:
        nj_raster.draw_line(fb, x0, y0, x1, y1)
    sc.capture = None
    return bytes(fb), dw._frame_clip_match[0]


def main():
    from bsp_render_6502 import BspRender6502
    positions = [(1056, -3616, 128), (1056, -3328, 14), (1308, -3289, 252),
                 (994, -3291, 237), (845, -3084, 215), (1056, -3291, 34),
                 (1056, -3616, 0), (1056, -3616, 64), (800, -3400, 96),
                 (-486, -3307, 243)]
    if len(sys.argv) == 4:
        positions = [(int(sys.argv[1]), int(sys.argv[2]), int(sys.argv[3]))]
    eng = BspRender6502(dw.packed_layout, dw.packed_rom_main, dw.packed_rom_detail,
                        dw.packed_bbox_table, dw.MAP_CENTER_X, dw.MAP_CENTER_Y,
                        dw.PRESCALE)
    allok = True
    for (px, py, ab) in positions:
        fz = dw.player_floor(px, py)
        eng.render_frame(px, py, ab, fz)
        eng_fb = bytes(eng.sc.mpu.memory[0x5800:0x5800 + 5120])
        ref_fb, clip_ok = render_ref_fb(px, py, ab)
        same = ref_fb == eng_fb
        ndiff = sum(1 for a, b in zip(ref_fb, eng_fb) if a != b)
        # clip_ok (python span MODEL vs 6502 lockstep) is informational:
        # the records-driven 6502 tighten and the legacy u8-interp python
        # tighten pick split anchors ±1 apart, a known pre-existing drift
        # that does not affect emissions. FB identity is the gate.
        print(f'({px},{py},{ab}): '
              f"{'IDENTICAL' if same else f'DIFFER {ndiff} bytes'}"
              f"{'' if clip_ok else ' (model-drift)'}")
        allok = allok and same
    print('PYREF:', 'PASS — python-NJ reference byte-identical to engine FB'
          if allok else 'FAIL')
    sys.exit(0 if allok else 1)


if __name__ == '__main__':
    main()
