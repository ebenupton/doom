#!/usr/bin/env python3
"""Render door/lift animation phase strips through the pixel-exact python
reference (packed pipeline + 6502-shadow clipper + nj_raster), alongside
the float ground-truth render, into build/anim_proto/*.png.

Also self-checks: (a) patch reversibility — after a full open/close cycle
the packed tables must be byte-identical to their pristine state; (b) the
t=0 frame before and after the cycle must match.

Usage: DOOM_ANIM=1 python3 tools/anim_demo.py [sector ...]
"""
import math, os, sys
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), '..'))
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
os.chdir(os.path.join(os.path.dirname(os.path.abspath(__file__)), '..'))
os.environ['DOOM_ANIM'] = '1'
os.environ.setdefault('SDL_VIDEODRIVER', 'dummy')
os.environ.setdefault('PYGAME_HIDE_SUPPORT_PROMPT', '1')
import pygame; pygame.init()
import doom_wireframe as dw
import anim_sectors as an
import pyref_render
from endpoint_spans import EndpointClipSpans

OUT = 'build/anim_proto'
PHASES = [0.0, 0.25, 0.5, 0.75, 1.0]


def float_truth(px, py, ab):
    surf = pygame.Surface((dw.FP_RENDER_W, dw.FP_RENDER_H))
    surf.fill((0, 0, 0))
    ang = ab * 2 * math.pi / 256
    clips = EndpointClipSpans()
    vz = dw.player_floor(px, py) + 41
    dw.render_bsp(len(dw.nodes) - 1, clips, math.cos(ang), math.sin(ang),
                  px, py, vz, surf)
    return surf


def main():
    os.makedirs(OUT, exist_ok=True)
    want = [int(a) for a in sys.argv[1:]] or sorted(dw.ANIM_SECTORS)
    pristine_main = bytes(dw.packed_rom_main)
    pristine_detail = bytes(dw.packed_rom_detail)
    ok = True
    for sec in want:
        m = an.MOVERS[sec]
        px, py, ab = an.camera_for(m)
        base_fb, _ = pyref_render.render_ref_fb(px, py, ab)
        for t in PHASES:
            m.phase(t)
            fb, _ = pyref_render.render_ref_fb(px, py, ab)
            surf = an.fb_to_surface(fb)
            pygame.image.save(surf, f'{OUT}/s{sec}_{m.kind}_t{int(t*100):03d}_ref.png')
            pygame.image.save(float_truth(px, py, ab),
                              f'{OUT}/s{sec}_{m.kind}_t{int(t*100):03d}_float.png')
            print(f'sector {sec} ({m.kind}) t={t:.2f}: '
                  f'{sum(1 for b in fb if b)} nz bytes  cam=({px},{py},{ab})')
        m.phase(0.0)
        end_fb, _ = pyref_render.render_ref_fb(px, py, ab)
        if end_fb != base_fb:
            ok = False
            print(f'sector {sec}: REVERSIBILITY FAIL (t=0 frame differs after cycle)')
    if (bytes(dw.packed_rom_main) != pristine_main
            or bytes(dw.packed_rom_detail) != pristine_detail):
        ok = False
        print('TABLE RESTORE FAIL: packed bytes differ from pristine after cycles')
    print('ANIM DEMO:', 'PASS' if ok else 'FAIL', f'— frames in {OUT}/')
    sys.exit(0 if ok else 1)


if __name__ == '__main__':
    main()
