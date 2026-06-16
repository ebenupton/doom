#!/usr/bin/env python3
"""Option 2b de-risk: seg Y with NO per-vertex rotation.

DOOM's R_StoreWallRange gets a column's depth from the WALL, not the vertex:
the seg has a (signed) perpendicular distance c and a normal angle na (both
per-seg constants), and for any screen column the forward depth is

    depth(x) = c * cos(phi) / cos(va - phi - na)        phi = xtoviewangle(x)

This is exact (validated to 0.0 px below) and -- crucially -- is well-defined at
a CLAMPED/behind-player column, where the per-vertex rotation depth (vy) is
undefined. So option 2b removes the rotation: X from the world angle, depth/Y
from c + the column angle.

Validation (float, E1M1, many views):
  (T) vs ray-cast TRUE depth at the drawn (clamped) column.
  (P) vs project_y at unclamped endpoints (the current path) -- must agree.
"""
import os, math
os.environ['SDL_VIDEODRIVER'] = 'dummy'
os.environ['PYGAME_HIDE_SUPPORT_PROMPT'] = '1'
import pygame; pygame.init(); pygame.display.set_mode((1, 1))
import doom_wireframe as dw
FOCAL = 128.0; HALF_W = 128.0; HALF_H = 80.0; VZ = 10


def xtoviewangle(x):
    return math.atan((x - HALF_W) / FOCAL)


def seg_const(v1, v2, px, py):
    """Per-seg constants: signed perp distance c (in the player-delta frame)
    and normal angle na. (6502: c = cross(v1-p, dir)/len; na precomputed.)"""
    ex, ey = v2[0] - v1[0], v2[1] - v1[1]
    L = math.hypot(ex, ey)
    if L == 0: return None
    nx, ny = -ey / L, ex / L
    c = (v1[0] - px) * nx + (v1[1] - py) * ny
    return c, math.atan2(ny, nx)


def depth_at(x, c, na, va):
    phi = xtoviewangle(x)
    den = math.cos(va - phi - na)
    if abs(den) < 1e-9: return None
    return c * math.cos(phi) / den


def true_depth(x, v1, v2, px, py, va):
    phi = xtoviewangle(x); wa = va - phi
    ux, uy = math.cos(wa), math.sin(wa)
    ex, ey = v2[0] - v1[0], v2[1] - v1[1]
    den = ux * (-ey) - uy * (-ex)
    if den == 0: return None
    r = ((v1[0] - px) * (-ey) - (v1[1] - py) * (-ex)) / den
    if r <= 0: return None
    wx, wy = px + r * ux, py + r * uy
    return (wx - px) * math.cos(va) + (wy - py) * math.sin(va)


def main():
    views = ([(1056, -3616, a) for a in range(0, 256, 8)]
             + [(1024, -3500, 65), (800, -3400, 96), (1500, -3700, 1), (1200, -3000, 129)])
    nT = eT = w1T = 0
    ncl = clok = 0
    nP = eP = w1P = 0
    for (px, py, ab) in views:
        pxi = int((px - dw.MAP_CENTER_X) / dw.PRESCALE)
        pyi = int((py - dw.MAP_CENTER_Y) / dw.PRESCALE)
        va = ab / 256 * 2 * math.pi; ca, sa = math.cos(va), math.sin(va)
        for svwh in dw.fp_segs_vwh:
            s = svwh[0]; v1 = dw.fp_vertexes[s[0]]; v2 = dw.fp_vertexes[s[1]]
            ch = svwh[4]; hd = ch - VZ
            g = seg_const(v1, v2, pxi, pyi)
            if g is None: continue
            c, na = g
            for v in (v1, v2):
                dx, dy = v[0] - pxi, v[1] - pyi
                vy = dx * ca + dy * sa; vx = dx * sa - dy * ca
                col = HALF_W + FOCAL * vx / vy if vy > 0 else None
                onscreen = col is not None and 0 <= col <= 255
                xc = (min(255, max(0, col)) if col is not None
                      else (0 if vx < 0 else 255))           # drawn (clamped) column
                d = depth_at(xc, c, na, va)
                td = true_depth(xc, v1, v2, pxi, pyi, va)
                if d is None or td is None or d <= 0 or td <= 0: continue
                ys = HALF_H - hd * FOCAL / d          # scale-Y (no rotation)
                yt = HALF_H - hd * FOCAL / td         # true-Y at that column
                nT += 1; e = abs(ys - yt); eT += e; w1T += (e <= 1)
                if not onscreen:
                    ncl += 1; clok += (e <= 1.5)
                if onscreen and vy > 0.5:             # vs project_y (rotation depth)
                    yp = HALF_H - hd * FOCAL / vy
                    nP += 1; ep = abs(ys - yp); eP += ep; w1P += (ep <= 1)
    print(f"scale-Y vs ray-cast TRUE: {nT} samples, mean {eT/nT:.3f} px, within 1px {100*w1T/nT:.1f}%")
    print(f"  clamped/off-screen endpoints: {ncl}, within 1.5px of true: {100*clok/max(1,ncl):.1f}%")
    print(f"scale-Y vs project_y (unclamped front): {nP} samples, mean {eP/max(1,nP):.3f} px, within 1px {100*w1P/max(1,nP):.1f}%")


if __name__ == '__main__':
    main()
