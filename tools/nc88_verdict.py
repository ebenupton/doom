#!/usr/bin/env python3
"""EV16 decision gate: is the 8.8 crossing (_NC88) closer to float truth?

Float arbiter = dw.render_bsp (float pipeline) with pygame.draw.line
intercepted by dw._cycle_drawline, captured lines rasterized via nj_raster
into the SAME 5120-byte mode-4 FB space as the pyref reference.

Scores, per position:
  changed  = pixels where pyref(OFF) != pyref(ON)   (the crossing shift set)
  d_off    = changed pixels where OFF disagrees with float
  d_on     = changed pixels where ON  disagrees with float
Verdict: ON is toward-float when d_on < d_off.
"""
import os, sys, math, random
os.environ.setdefault('SDL_VIDEODRIVER', 'dummy')
os.environ.setdefault('PYGAME_HIDE_SUPPORT_PROMPT', '1')
sys.path.insert(0, '/Users/ebenupton/doom')
sys.path.insert(0, '/Users/ebenupton/doom/tools')
os.chdir('/Users/ebenupton/doom')
import pygame
pygame.init()

import doom_wireframe as dw
import nj_raster
import pyref_render
import compare_renders as C

W, H = dw.FP_RENDER_W, dw.FP_RENDER_H


def _clip_line(x0, y0, x1, y1):
    """Liang-Barsky clip to [0,W-1]x[0,H-1]; returns int coords or None."""
    dx, dy = x1 - x0, y1 - y0
    t0, t1 = 0.0, 1.0
    for p, q in ((-dx, x0 - 0), (dx, (W - 1) - x0),
                 (-dy, y0 - 0), (dy, (H - 1) - y0)):
        if p == 0:
            if q < 0:
                return None
        else:
            r = q / p
            if p < 0:
                if r > t1: return None
                if r > t0: t0 = r
            else:
                if r < t0: return None
                if r < t1: t1 = r
    return (round(x0 + t0 * dx), round(y0 + t0 * dy),
            round(x0 + t1 * dx), round(y0 + t1 * dy))


def float_fb(px, py, ab):
    ar = ab * 2 * math.pi / 256
    vz = dw.player_floor(px, py) + 41.0
    surf = pygame.Surface((W, H))
    random.seed(42)
    for k in dw.map_trace:
        dw.map_trace[k] = {} if k == "vertex_muls" else (
            [] if k == "ss_order" else set())
    dw._frame_nj_lines.clear()
    old = pygame.draw.line
    pygame.draw.line = dw._cycle_drawline
    try:
        dw.render_bsp(len(dw.nodes) - 1, dw.ClipSpans(),
                      math.cos(ar), math.sin(ar), px, py, vz, surf)
    finally:
        pygame.draw.line = old
    fb = nj_raster.new_fb()
    for (x0, y0, x1, y1) in dw._frame_nj_lines:
        c = _clip_line(x0, y0, x1, y1)
        if c is not None:
            nj_raster.draw_line(fb, *c)
    return int.from_bytes(bytes(fb), 'big')


def pyref_fb(px, py, ab, nc88):
    dw._NC88 = nc88
    try:
        fb, _ok = pyref_render.render_ref_fb(px, py, ab)
    finally:
        dw._NC88 = False
    return int.from_bytes(fb, 'big')


def main():
    positions = list(C.POSITIONS)
    tot_off = tot_on = tot_changed = 0
    print(f"{'position':>22}  {'chg':>5} {'d_off':>5} {'d_on':>5}  "
          f"{'full_off':>8} {'full_on':>8}  verdict")
    for (px, py, ab) in positions:
        flt = float_fb(px, py, ab)
        off = pyref_fb(px, py, ab, False)
        on = pyref_fb(px, py, ab, True)
        changed = off ^ on
        d_off = ((off ^ flt) & changed).bit_count()
        d_on = ((on ^ flt) & changed).bit_count()
        full_off = (off ^ flt).bit_count()
        full_on = (on ^ flt).bit_count()
        nch = changed.bit_count()
        tot_off += d_off; tot_on += d_on; tot_changed += nch
        verdict = '-' if nch == 0 else (
            'TOWARD' if d_on < d_off else
            ('AWAY' if d_on > d_off else 'tie'))
        print(f"{str((px, py, ab)):>22}  {nch:>5} {d_off:>5} {d_on:>5}  "
              f"{full_off:>8} {full_on:>8}  {verdict}")
    print(f"\nTOTAL changed {tot_changed}  d_off {tot_off}  d_on {tot_on}  "
          f"=> {'TOWARD-FLOAT' if tot_on < tot_off else 'NOT toward'}")


if __name__ == '__main__':
    main()
