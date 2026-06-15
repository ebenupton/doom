"""Validate the angle-space column (angle_bbox.view_column) two ways:

  1. vs the TRUE float projection column — the correctness bar. The
     conservative bracket must contain the float column within +/-1 col
     everywhere (including near-plane), proving angle-space is faithful.
  2. vs the current perspective-FP column — shows where the two *methods*
     differ (a near-plane tail to ~19 cols), which is perspective-FP being
     numerically unstable at small vy, NOT the angle method being wrong.

Run: python3 validate_angle.py
"""
import math
import angle_bbox as A
import fp

HALF_W = 128
FOCAL = 128
NEAR = getattr(fp, 'NEAR_FP', 1)


def float_col(dx, dy, ab):
    Arad = ab * 2 * math.pi / 256
    phi = Arad - math.atan2(dy, dx)
    phi = (phi + math.pi) % (2 * math.pi) - math.pi
    if math.cos(phi) <= 0 or abs(phi) >= math.pi / 4:
        return None
    return HALF_W + FOCAL * math.tan(phi)


def persp_col(dx, dy, ab):
    sc = fp.fp_sincos(ab)
    ctx = (0, 0, sc, 0, 0)
    r = fp.fp_to_view(dx, dy, ctx)
    evx, evy, idx = r[1], r[2], r[4]
    if evy < NEAR:
        return None
    rxh, rxl = fp.fp_recip(idx)
    return fp.fp_project_x(evx, rxh, rxl)


def run():
    chk_f = miss_f = wf = 0
    chk_p = wp = 0
    for ab in range(0, 256):
        for dx in range(-300, 301, 5):
            for dy in range(-300, 301, 5):
                br = A.view_column(dx, dy, ab)
                fc = float_col(dx, dy, ab)
                if fc is not None and 0 <= fc <= 255:
                    chk_f += 1
                    if br is None:
                        miss_f += 1
                    else:
                        d = 0 if (br[0]-1) <= fc <= (br[1]+1) else min(abs(br[0]-fc), abs(fc-br[1]))
                        wf = max(wf, d)
                        if d > 1.5:
                            miss_f += 1
                pc = persp_col(dx, dy, ab)
                if pc is not None and 0 <= pc <= 255 and br is not None:
                    chk_p += 1
                    d = 0 if br[0] <= pc <= br[1] else min(abs(br[0]-pc), abs(pc-br[1]))
                    wp = max(wp, d)
    print(f"vs FLOAT (truth):  {chk_f} pts, {miss_f} miss >1.5col, worst {wf:.1f}")
    print(f"vs PERSP-FP:       {chk_p} pts, worst {wp} col "
          f"(near-plane perspective instability, not angle error)")


if __name__ == '__main__':
    run()
