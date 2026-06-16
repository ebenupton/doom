#!/usr/bin/env python3
"""Option-2 (angle-space SEG pipeline) de-risk, in Python, vs the reference.

DOOM's R_AddLine derives each seg endpoint's screen column from the WORLD angle
of the endpoint minus the view angle, via viewangletox -- no rotation, no
perspective divide for X (and back-face culling falls out of angle1-angle2).
The current engine instead rotates each vertex to view space (4 muls) and
perspective-projects it (project_x).

This compares both against TRUE float geometry over every vertex across many
views. Result (E1M1): world-angle is dramatically more faithful AND cheaper:

  PERSPECTIVE: mean 1.37 col err, 42.6% within +/-1, 3.9% off by >3
  WORLD-ANGLE: mean 0.42 col err, 99.4% within +/-1, 0.0% off by >3

Y is unchanged by option 2: it still needs the forward depth vy = dx*cos+dy*sin
(2 muls) + project_y -- identical to today. So option 2 removes the sideways
rotation (2 muls) + project_x (1-3 muls) per vertex and makes X more accurate.
Remaining piece to prototype: near-plane / FOV-edge handling switches from the
parametric view-space near-clip to DOOM's angle clamp (as the bbox already does).
"""
import os, math
os.environ['SDL_VIDEODRIVER'] = 'dummy'
os.environ['PYGAME_HIDE_SUPPORT_PROMPT'] = '1'
import pygame; pygame.init(); pygame.display.set_mode((1, 1))
import doom_wireframe as dw, fp, angle_bbox as A
RFB = getattr(fp, 'RECIP_FRAC_BITS', 0)


def persp_col(wx, wy, ctx):
    r = fp.fp_to_view(wx, wy, ctx); ex, ey = r[0], r[2]
    if ey < 1: return None
    rxh, rxl = fp.fp_recip((ey << RFB) if RFB else ey)
    return fp.fp_project_x(ex, rxh, rxl)


def true_col(dx, dy, ab):
    th = ab / 256 * 2 * math.pi; c, s = math.cos(th), math.sin(th)
    vy = dx * c + dy * s; vx = dx * s - dy * c
    if vy <= 0: return None
    return 128 + 128 * vx / vy


def main():
    views = ([(1056, -3616, a) for a in range(0, 256, 4)]
             + [(1024, -3500, 65), (1500, -3700, 1), (800, -3400, 96),
                (1200, -3000, 129), (1300, -3200, 40), (950, -3450, 200)])
    pe = ae = 0; pc1 = ac1 = n = 0; ptail = atail = 0
    for (px, py, ab) in views:
        px88 = int((px - dw.MAP_CENTER_X) * 256 / dw.PRESCALE)
        py88 = int((py - dw.MAP_CENTER_Y) * 256 / dw.PRESCALE)
        ctx = fp.fp_view_context(px88, py88, fp.fp_sincos(ab)); pxi, pyi = ctx[0], ctx[1]
        for v in dw.fp_vertexes:
            pc = persp_col(v[0], v[1], ctx)
            if pc is None or not (0 <= pc <= 255): continue
            tc = true_col(v[0] - pxi, v[1] - pyi, ab)
            if tc is None or not (0 <= tc <= 255): continue
            vcw = A.view_column(v[0] - pxi, v[1] - pyi, ab)
            if vcw is None: continue
            acol = (vcw[0] + vcw[1]) // 2
            n += 1
            pe += abs(pc - tc); ae += abs(acol - tc)
            pc1 += abs(pc - tc) <= 1; ac1 += abs(acol - tc) <= 1
            ptail += abs(pc - tc) > 3; atail += abs(acol - tc) > 3
    print(f"{n} on-screen endpoints vs TRUE geometry:")
    print(f"  PERSPECTIVE: mean {pe/n:.2f} col, within +/-1: {100*pc1/n:.1f}%, >3 off: {100*ptail/n:.1f}%")
    print(f"  WORLD-ANGLE: mean {ae/n:.2f} col, within +/-1: {100*ac1/n:.1f}%, >3 off: {100*atail/n:.1f}%")


if __name__ == '__main__':
    main()
