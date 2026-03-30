"""Fixed-point arithmetic helpers for the DOOM wireframe renderer.

All values fit in 16 bits with case-by-case integer/fractional splits.
Most multiplies are 8×8 or 16×8.

Formats:
  16.0  — world coords, view-space positions, integers
  1.7   — sin/cos (8-bit signed, 7 fractional bits)
  8.8   — reciprocal scale (FOCAL/vy), general fixed-point
  10.6  — screen coordinates (X: 0..960, Y: 0..600)
  4.12  — clip function slopes (high precision for shallow angles)
  0.16  — parametric t (Cyrus-Beck, near-clip)
"""

import math

# ── Shift constants ──────────────────────────────────────────────────────────

FP7  = 7    # 1.7 (sin/cos)
FP8  = 8    # 8.8 (reciprocal, general)
FP6  = 6    # 10.6 (screen coords)
FP12 = 12   # 4.12 (slopes)
FP16 = 16   # 0.16 (parametric t)

# ── Core arithmetic ──────────────────────────────────────────────────────────

def fp_mul(a, b, shift):
    """Signed multiply, shift right.  a and b are Python ints."""
    return (a * b) >> shift

def fp_div(num, den, shift):
    """Signed divide: (num << shift) // den.  Returns 0 if den == 0."""
    if den == 0: return 0
    # Python's // truncates toward negative infinity; use int division
    # that truncates toward zero for consistency with C/hardware.
    r = (num << shift)
    if (r < 0) != (den < 0):
        return -(abs(r) // abs(den))
    return abs(r) // abs(den)

def fp_from_float(x, shift):
    """Float → fixed-point."""
    return int(x * (1 << shift))

def fp_to_float(x, shift):
    """Fixed-point → float."""
    return x / (1 << shift)

def s16(x):
    """Clamp/wrap to signed 16-bit range."""
    x = x & 0xFFFF
    return x - 0x10000 if x >= 0x8000 else x

# ── Sin/cos table (1.7 signed, 8-bit) ───────────────────────────────────────
#
# 256 entries covering 0..360°.  Each entry is int8: -128..+127.
# sin(0)=0, sin(64)=+127 (clamp from 128), sin(128)=0, sin(192)=-128.
# angle_byte: 0=0°, 64=90°, 128=180°, 192=270°.

_SIN_TABLE = []
for _i in range(256):
    _rad = _i * 2.0 * math.pi / 256.0
    _val = round(math.sin(_rad) * 128)
    _val = max(-128, min(127, _val))
    _SIN_TABLE.append(_val)

def fp_sin(angle_byte):
    """8-bit angle → 1.7 signed sin value."""
    return _SIN_TABLE[angle_byte & 0xFF]

def fp_cos(angle_byte):
    """8-bit angle → 1.7 signed cos value."""
    return _SIN_TABLE[(angle_byte + 64) & 0xFF]

# ── Reciprocal (perspective scale) ──────────────────────────────────────────
#
# Separate X and Y reciprocals for DOOM's 1.2:1 pixel aspect correction.
# FOCAL_X = 480, FOCAL_Y = 576 (= 480 * 1.2).

FOCAL_X_SCALED = 480 * 256   # = 122880
FOCAL_Y_SCALED = 576 * 256   # = 147456

def fp_recip_x(vy):
    """16.0 view depth → 8.8 horizontal reciprocal (FOCAL_X/vy * 256)."""
    if vy <= 0: return 0x7FFF
    r = FOCAL_X_SCALED // vy
    return min(r, 0x7FFF)

def fp_recip_y(vy):
    """16.0 view depth → 8.8 vertical reciprocal (FOCAL_Y/vy * 256)."""
    if vy <= 0: return 0x7FFF
    r = FOCAL_Y_SCALED // vy
    return min(r, 0x7FFF)

# ── Projection helpers ──────────────────────────────────────────────────────

HALF_W = 480    # WIDTH // 2, in 16.0
HALF_H = 300    # HEIGHT // 2, in 16.0
HALF_W_6 = 480 << FP6   # in 10.6
HALF_H_6 = 300 << FP6   # in 10.6

def fp_project_x(vx, recip_x):
    """Project view-space X to screen X (10.6).

    sx = half_w + vx * recip_x >> 8, then convert to 10.6.
    vx: 16.0, recip_x: 8.8 (FOCAL_X based).
    """
    sx_int = HALF_W + ((vx * recip_x) >> FP8)
    return sx_int << FP6  # 10.6

def fp_project_y(height_delta, recip_y):
    """Project height delta to screen Y (10.6).

    sy = half_h - height_delta * recip_y >> 8, in 10.6.
    height_delta: 16.0 (ceil - vz or floor - vz).  recip_y: 8.8 (FOCAL_Y based).
    """
    proj = (height_delta * recip_y) >> FP8  # 16.0
    return HALF_H_6 - (proj << FP6)

# ── Clip function helpers (4.12 slope, 10.6 intercept) ─────────────────────

def fp_linfn(y1_6, y2_6, sx1_6, sx2_6):
    """Two-point → (slope_12, intercept_6).

    y1_6, y2_6: screen Y in 10.6.
    sx1_6, sx2_6: screen X in 10.6.
    slope = (y2 - y1) / (sx2 - sx1) in 4.12 (high precision).
    intercept = y1 - slope * sx1 in 10.6.
    """
    dx = sx2_6 - sx1_6
    if abs(dx) < (1 << FP6):  # less than 1 pixel
        return (0, (y1_6 + y2_6) >> 1)
    dy = y2_6 - y1_6
    # slope in 4.12: (dy << 12) / dx, but dy is 10.6 and dx is 10.6
    # so dy/dx is dimensionless.  We want 4.12 result.
    # (dy << 12) / dx: dy is 10.6, <<12 makes it 10.18, /dx(10.6) → 0.12.
    # That gives 0.12 which is what we want for the slope in "per 10.6-unit" terms.
    # Actually: slope = dy_real / dx_real.  Both in 10.6.
    # dy_real = dy / 64, dx_real = dx / 64.  slope_real = dy/dx (unitless).
    # In 4.12: slope_12 = slope_real * 4096 = (dy * 4096) / dx = (dy << 12) / dx.
    # But dy and dx are in 10.6, so dy << 12 is 10.18.  Division by 10.6 gives 0.12.
    # We need 4.12, but the integer part comes from the actual slope magnitude.
    slope_12 = fp_div(dy, dx, FP12)  # (dy << 12) // dx
    # intercept in 10.6: y1 - slope * sx1
    # slope_12 * sx1_6: 4.12 * 10.6 = 14.18, >>12 → 10.6
    intercept_6 = y1_6 - fp_mul(slope_12, sx1_6, FP12)
    return (slope_12, intercept_6)

def fp_eval(fn, x_6):
    """Evaluate slope-intercept at screen X (10.6) → screen Y (10.6).

    fn = (slope_12, intercept_6).
    result = slope * x + intercept.
    slope_12 * x_6: 4.12 * 10.6 = 14.18, >>12 → 10.6.
    """
    return fp_mul(fn[0], x_6, FP12) + fn[1]

# ── View transform ──────────────────────────────────────────────────────────

def fp_to_view(wx, wy, vx, vy, sin_a, cos_a):
    """World to view space.  All 16.0 except sin/cos (1.7).

    view_x = dx * sin_a - dy * cos_a   (16.0 * 1.7 >> 7 → 16.0)
    view_y = dx * cos_a + dy * sin_a
    """
    dx = wx - vx
    dy = wy - vy
    evx = fp_mul(dx, sin_a, FP7) - fp_mul(dy, cos_a, FP7)
    evy = fp_mul(dx, cos_a, FP7) + fp_mul(dy, sin_a, FP7)
    return evx, evy

# ── Near clip ───────────────────────────────────────────────────────────────

NEAR_FP = 1  # 16.0

def fp_near_clip(vx1, vy1, vx2, vy2):
    """Clip to vy >= NEAR.  All 16.0.  Returns (vx1,vy1,vx2,vy2) or None."""
    if vy1 < NEAR_FP and vy2 < NEAR_FP: return None
    if vy1 >= NEAR_FP and vy2 >= NEAR_FP: return (vx1, vy1, vx2, vy2)
    # t = (NEAR - vy1) / (vy2 - vy1) in 0.16
    t = fp_div(NEAR_FP - vy1, vy2 - vy1, FP16)
    # cx = vx1 + t * (vx2 - vx1) >> 16
    cx = vx1 + fp_mul(t, vx2 - vx1, FP16)
    if vy1 < NEAR_FP:
        return (cx, NEAR_FP, vx2, vy2)
    return (vx1, vy1, cx, NEAR_FP)
