#!/usr/bin/env python3
"""Empirically measure operand ranges at each suspect wide-multiply site.

Renders the 5 baseline positions through the Python FP renderer and
records the actual min/max of each operand the s9-risk audit flagged.
Also walks a 360-degree sweep at the spawn point plus the fp_segs ×
fp_vertexes cross product that the back-face test iterates.
"""
import os, sys
os.environ['SDL_VIDEODRIVER'] = 'dummy'
os.environ['PYGAME_HIDE_SUPPORT_PROMPT'] = '1'
import pygame; pygame.init(); pygame.display.set_mode((1, 1))

import doom_wireframe as dw
import fp
from fp import _rot_int  # may not be needed

# ── Tracker ─────────────────────────────────────────────────────────────────
class Tracker:
    def __init__(self, name):
        self.name = name
        self.lo = None
        self.hi = None
        self.n = 0
        self.oob_lo = 0   # count of values < -128
        self.oob_hi = 0   # count of values > 127

    def add(self, v):
        self.n += 1
        if self.lo is None or v < self.lo:
            self.lo = v
        if self.hi is None or v > self.hi:
            self.hi = v
        if v < -128:
            self.oob_lo += 1
        elif v > 127:
            self.oob_hi += 1

    def report(self):
        if self.n == 0:
            return f"  {self.name:40s} (no samples)"
        oob = self.oob_lo + self.oob_hi
        pct = 100.0 * oob / self.n if self.n else 0
        status = "s8 ok  " if oob == 0 else f"OOB {oob}/{self.n} ({pct:.1f}%)"
        return (f"  {self.name:40s} range=[{self.lo:>6d}, {self.hi:>6d}] "
                f"n={self.n:>6d}  {status}")

# A. Back-face: ldy × (px_int - lv1_x) and ldx × (py_int - lv1_y)
bf_dx = Tracker("A1: px_int - lv1_x  (bf)")
bf_dy = Tracker("A2: py_int - lv1_y  (bf)")
bf_ldx = Tracker("A3: ldx             (bf)")
bf_ldy = Tracker("A4: ldy             (bf)")

# B. fp_to_view: d_hi = wx - px_int, dy_hi = wy - py_int
tv_dx_hi = Tracker("B1: wx - px_int    (to_view dx)")
tv_dy_hi = Tracker("B2: wy - py_int    (to_view dy)")

# C. fp_near_clip: dvx = vx2 - vx1 (when crossing near plane)
nc_dvx = Tracker("C1: vx2 - vx1       (near_clip)")
nc_t   = Tracker("C2: parametric t    (near_clip)")

# D. fp_project_x: vx input (after near-clip or from fp_to_view)
px_vx_round = Tracker("D1: vx input (rounded)")
px_vx_trunc = Tracker("D2: vx input (truncated/subpx)")
px_vx_after_nc = Tracker("D3: vx after near-clip")

# ── Monkey-patches ──────────────────────────────────────────────────────────

_orig_fp_to_view = fp.fp_to_view
def _tracked_fp_to_view(wx, wy, ctx):
    px_int, py_int, sc, frac_vx, frac_vy = ctx
    tv_dx_hi.add(wx - px_int)
    tv_dy_hi.add(wy - py_int)
    return _orig_fp_to_view(wx, wy, ctx)
fp.fp_to_view = _tracked_fp_to_view
dw.fp_to_view = _tracked_fp_to_view

_orig_fp_near_clip = fp.fp_near_clip
def _tracked_fp_near_clip(vx1, vy1, vx2, vy2):
    # Only the "crossing" case invokes the multiply
    NEAR = fp.NEAR_FP
    if not (vy1 < NEAR and vy2 < NEAR) and not (vy1 >= NEAR and vy2 >= NEAR):
        nc_dvx.add(vx2 - vx1)
        if (vy2 - vy1) != 0:
            t = fp.fp_div8(NEAR - vy1, vy2 - vy1)
            nc_t.add(t)
    result = _orig_fp_near_clip(vx1, vy1, vx2, vy2)
    if result is not None:
        # Record the vx that flows into fp_project_x
        px_vx_after_nc.add(result[0])
        px_vx_after_nc.add(result[2])
    return result
fp.fp_near_clip = _tracked_fp_near_clip
dw.fp_near_clip = _tracked_fp_near_clip

_orig_fp_project_x = fp.fp_project_x
def _tracked_fp_project_x(vx, recip_hi, recip_lo):
    px_vx_round.add(vx)
    return _orig_fp_project_x(vx, recip_hi, recip_lo)
fp.fp_project_x = _tracked_fp_project_x
dw.fp_project_x = _tracked_fp_project_x

_orig_fp_project_x_subpx = fp.fp_project_x_subpx
def _tracked_fp_project_x_subpx(vx, vx_frac, recip_hi, recip_lo):
    px_vx_trunc.add(vx)
    return _orig_fp_project_x_subpx(vx, vx_frac, recip_hi, recip_lo)
fp.fp_project_x_subpx = _tracked_fp_project_x_subpx
dw.fp_project_x_subpx = _tracked_fp_project_x_subpx

# Back-face test: patch fp_render_seg's inputs by intercepting the seg-level
# loop.  Cleanest is to wrap fp_render_seg and pre-compute the operands from
# the seg/linedef data.
_orig_fp_render_seg = dw.fp_render_seg
def _tracked_fp_render_seg(si, clips, ctx, vz, surface, vcache, vwh_cache, deferred=None):
    svwh = dw.fp_segs_vwh[si]
    s = svwh[0]
    ld = dw.linedefs[s[3]]
    lv1, lv2 = dw.fp_vertexes[ld[0]], dw.fp_vertexes[ld[1]]
    ldx = lv2[0] - lv1[0]
    ldy = lv2[1] - lv1[1]
    px_int, py_int = ctx[0], ctx[1]
    bf_dx.add(px_int - lv1[0])
    bf_dy.add(py_int - lv1[1])
    bf_ldx.add(ldx)
    bf_ldy.add(ldy)
    return _orig_fp_render_seg(si, clips, ctx, vz, surface, vcache, vwh_cache, deferred)
dw.fp_render_seg = _tracked_fp_render_seg

# ── Run the test positions ──────────────────────────────────────────────────

POSITIONS = [
    (1056, -3616, 64, "E1M1 start East"),
    (1056, -3616, 0,  "E1M1 start North"),
    (1056, -3616, 32, "E1M1 start NE"),
    (1056, -3616, 96, "E1M1 start SE"),
    (1200, -3300, 64, "moved East"),
]

import math
def render_at(px, py, ab):
    fp.mul_reset()
    px_88 = int((px - dw.MAP_CENTER_X) * 256 / dw.PRESCALE)
    py_88 = int((py - dw.MAP_CENTER_Y) * 256 / dw.PRESCALE)
    vz_ps = dw._prescale_height(dw.player_floor(px, py) + 41)
    sc = dw.fp_sincos(ab)
    ctx = dw.fp_view_context(px_88, py_88, sc)
    ang_rad = dw.byte_to_radians(ab)
    cos_f, sin_f = math.cos(ang_rad), math.sin(ang_rad)
    tmp = pygame.Surface((dw.FP_RENDER_W, dw.FP_RENDER_H))
    dw.render_bsp_fp(len(dw.nodes) - 1, dw.FPClipSpans(), ctx, vz_ps,
                     int(px), int(py), cos_f, sin_f, tmp,
                     [None] * len(dw.vertexes), [None] * len(dw.vwh_table))

print("=== Rendering 5 baseline positions ===")
for px, py, ab, name in POSITIONS:
    render_at(px, py, ab)
    print(f"  rendered {name}")

# Also sweep angles at spawn for broader coverage
print("\n=== 360° sweep at spawn ===")
for ab in range(0, 256, 8):
    render_at(1056, -3616, ab)
print(f"  32 angles sampled")

# ── Report ──────────────────────────────────────────────────────────────────
print("\n" + "=" * 75)
print(f"{'Operand':42s} {'range':>18s}  {'samples':>10s}  status")
print("=" * 75)
for t in [bf_dx, bf_dy, bf_ldx, bf_ldy,
          tv_dx_hi, tv_dy_hi,
          nc_dvx, nc_t,
          px_vx_round, px_vx_trunc, px_vx_after_nc]:
    print(t.report())
print("=" * 75)
