#!/usr/bin/env python3
"""Compare the full 6502 renderer output against the Python reference.

This fills the gap the regression never covered: run_regression / sweep_verify
compare the 6502 against ITSELF (trace_asm vs trace_hybrid, both 6502 clip), so
they verify self-consistency, not agreement with the Python ground truth. And
they only test integer positions (the harness does `px & 0xFF`), missing
sub-unit divergences.

Here we render BspRender6502 (the real chip pipeline) and render_bsp_fp (the
pure-Python fixed-point reference) at the same (px, py, ab) and compare their
framebuffers. The two use different rasterisers (6502 Hamiltonian vs
pygame.draw.line), so identical geometry still differs by ~1px aliasing. We
therefore measure the *vertical displacement* of each 6502-lit pixel to the
nearest Python-lit pixel in the same column: <=2px = aliasing, more = a real
geometry/occlusion divergence.

Usage:
    python3 verify_6502_vs_python.py            # default broad sweep
    python3 verify_6502_vs_python.py 1056 -3328 14   # single position
"""
import os, sys, math, random
os.environ.setdefault('SDL_VIDEODRIVER', 'dummy')
os.environ.setdefault('PYGAME_HIDE_SUPPORT_PROMPT', '1')
import pygame
import numpy as np
import doom_wireframe as dw
from bsp_render_6502 import BspRender6502
from endpoint_spans import EndpointClipSpans

W, H = dw.FP_RENDER_W, dw.FP_RENDER_H
ALIAS_PX = 2          # <= this vertical displacement is rasteriser aliasing


class _FFS(EndpointClipSpans):
    def draw_clipped(self, l, c, s, stats=None, roles=None):
        super().draw_clipped(l, c, s, stats)


def _reset_trace():
    for k in dw.map_trace:
        dw.map_trace[k] = {} if k == "vertex_muls" else (
            [] if k == "ss_order" else set())


def _py_mask(px, py, ab):
    random.seed(42)
    dw.fp_module.mul_reset()
    p8 = int((px - dw.MAP_CENTER_X) * 256 / dw.PRESCALE)
    q8 = int((py - dw.MAP_CENTER_Y) * 256 / dw.PRESCALE)
    vz = dw._prescale_height(dw.player_floor(px, py) + 41)
    ctx = dw.fp_view_context(p8, q8, dw.fp_sincos(ab))
    ar = ab * 2 * math.pi / 256
    _reset_trace()
    s = pygame.Surface((W, H)); s.fill((0, 0, 0))
    dw.render_bsp_fp(len(dw.nodes) - 1, _FFS(), ctx, vz, int(px), int(py),
                     math.cos(ar), math.sin(ar), s,
                     [None] * len(dw.vertexes), [None] * len(dw.vwh_table))
    return pygame.surfarray.array3d(s).sum(2) > 0


_r6502 = None
_fb = None


def _six_mask(px, py, ab):
    global _r6502, _fb
    if _r6502 is None:
        _r6502 = BspRender6502(dw.packed_layout, dw.packed_rom_main,
                               dw.packed_rom_detail, dw.packed_bbox_table,
                               dw.MAP_CENTER_X, dw.MAP_CENTER_Y, dw.PRESCALE)
        _fb = pygame.Surface((W, H))
    cyc = _r6502.render_frame(px, py, ab, dw.player_floor(px, py))
    done = _r6502.sc.mpu.pc == 0xFF00
    _r6502.blit_framebuffer_to(_fb)
    mask = pygame.surfarray.array3d(_fb).sum(2) > 0
    if not done:
        # A frame that hit the cap leaves the emulator mid-routine; reusing it
        # would contaminate later positions. Drop it so the next call is fresh.
        _r6502 = None
    return mask, cyc, done


def _col_disp(only, ref):
    """Per-column displacement of `only`-lit pixels to the nearest `ref`-lit
    pixel in the same column. Returns (max_disp_beyond_alias, n_beyond_alias)."""
    maxd = 0; ndiv = 0
    for x in range(W):
        oy = np.where(only[x])[0]
        if len(oy) == 0:
            continue
        ry = np.where(ref[x])[0]
        if len(ry) == 0:
            d = np.full(len(oy), 99)
        else:
            d = np.abs(ry[None, :] - oy[:, None]).min(axis=1)
        far = d[d > ALIAS_PX]
        ndiv += len(far)
        if len(far):
            maxd = max(maxd, int(far.max()))
    return maxd, ndiv


def compare(px, py, ab):
    """Two-sided comparison. Returns (max_over, n_over, max_miss, n_miss,
    cyc, completed).

    over  = pixels the 6502 lit that Python didn't (over-draw / over-emission)
    miss  = pixels Python lit that the 6502 didn't (missing lines — these are
            BUGS per the project rules, never 'BSP divergence')
    Displacement > ALIAS_PX in either direction is a real divergence.
    """
    A = _py_mask(px, py, ab)
    B, cyc, done = _six_mask(px, py, ab)
    max_over, n_over = _col_disp(B & ~A, A)
    max_miss, n_miss = _col_disp(A & ~B, B)
    return max_over, n_over, max_miss, n_miss, cyc, done


def main():
    pygame.init()
    if len(sys.argv) == 4:
        px, py, ab = int(sys.argv[1]), int(sys.argv[2]), int(sys.argv[3])
        mo, no, mm, nm, cyc, done = compare(px, py, ab)
        verdict = ("CLEAN" if (mo <= ALIAS_PX and mm <= ALIAS_PX)
                   else f"DIVERGENT (over {mo}px / miss {mm}px)")
        print(f"({px},{py},{ab}): {verdict}  over_px={no} miss_px={nm}  "
              f"6502={cyc} cyc {'ok' if done else 'TRUNCATED'}")
        return

    # Broad sweep: walk forward + fan + sub-unit jitter, random angles.
    random.seed(7)
    positions = []
    sx, sy = 1056.0, -3616.0
    for hd in range(0, 360, 30):
        hx, hy = math.cos(math.radians(hd)), math.sin(math.radians(hd))
        for step in range(6):
            bx, by = sx + hx * step * 96, sy + hy * step * 96
            for _ in range(2):
                jx = bx + random.uniform(-1, 1)
                jy = by + random.uniform(-1, 1)
                positions.append((int(round(jx)), int(round(jy)),
                                  random.randint(0, 255)))
    # include the known cases
    positions += [(1056, -3328, 14), (1200, -3000, 129), (1308, -3289, 252)]

    divergent = []
    for i, (px, py, ab) in enumerate(positions):
        mo, no, mm, nm, cyc, done = compare(px, py, ab)
        flag = (mo > ALIAS_PX) or (mm > ALIAS_PX) or (not done)
        if flag:
            divergent.append((px, py, ab, mo, no, mm, nm, done))
            print(f"  DIVERGENT ({px},{py},{ab}): over={mo}px({no}) "
                  f"miss={mm}px({nm}) {'' if done else 'TRUNCATED'}")
        if (i + 1) % 20 == 0:
            print(f"  ...{i+1}/{len(positions)} checked, "
                  f"{len(divergent)} divergent so far")
    print(f"\nSWEEP: {len(positions)} positions, {len(divergent)} divergent "
          f"(>{ALIAS_PX}px displacement, either direction)")
    for d in sorted(divergent, key=lambda r: -max(r[3], r[5])):
        print(f"   ({d[0]},{d[1]},{d[2]})  over={d[3]}px({d[4]})  "
              f"miss={d[5]}px({d[6]})  {'TRUNCATED' if not d[7] else ''}")


if __name__ == '__main__':
    main()
