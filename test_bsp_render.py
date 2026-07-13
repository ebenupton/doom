"""Test bsp_render.asm primitives against fp.py reference.

Run with `python3 test_bsp_render.py` from the doom directory.

Each test sets up zp inputs, JSRs the routine, reads zp outputs,
and compares against the Python reference.
"""
import os
os.environ['SDL_VIDEODRIVER'] = 'dummy'
os.environ['PYGAME_HIDE_SUPPORT_PROMPT'] = '1'
import pygame; pygame.init(); pygame.display.set_mode((1, 1))

from span_clip_6502 import SpanClip6502
import fp
import abi

from symmap import sym as _sym
ENTRY_BR_UMUL8 = _sym('jt_br_umul8')
ENTRY_BR_SMUL8 = _sym('jt_br_smul8')
ENTRY_BR_RECIP = _sym('jt_br_recip')

ZP_A    = _sym('zp_br_a')
ZP_B    = _sym('zp_br_b')
ZP_RESL = _sym('zp_br_resl')
ZP_RESH = _sym('zp_br_resh')
ZP_T0   = _sym('zp_br_t0')
ZP_T1   = _sym('zp_br_t1')
ZP_RHI  = _sym('zp_br_rhi')
ZP_RLO  = _sym('zp_br_rlo')


def s8(v):
    """Interpret a signed 8-bit value."""
    return v - 256 if v >= 128 else v


def s16_from_zp(mem, lo_addr):
    lo = mem[lo_addr]
    hi = mem[lo_addr + 1]
    val = (hi << 8) | lo
    return val - 65536 if val >= 32768 else val


def test_umul8():
    """u8 × u8 → u16 — quarter-square table."""
    sc = SpanClip6502()
    mem = sc.mpu.memory
    cases = [(0, 0), (1, 1), (255, 255), (128, 2), (17, 23), (200, 100)]
    fail = 0
    for a, b in cases:
        mem[ZP_A] = a
        mem[ZP_B] = b
        sc._run(ENTRY_BR_UMUL8)
        got = mem[ZP_RESL] | (mem[ZP_RESH] << 8)
        want = a * b
        ok = got == want
        if not ok:
            fail += 1
            print(f"  FAIL umul8({a}, {b}): got={got}, want={want}")
        else:
            print(f"  OK   umul8({a}, {b}) = {got}")
    return fail


def test_smul8():
    """s8 × s8 → s16."""
    sc = SpanClip6502()
    mem = sc.mpu.memory
    cases = [(0, 0), (1, 1), (-1, 1), (1, -1), (-1, -1),
             (127, -128), (-128, -128), (50, -50), (100, 100), (-100, 100)]
    fail = 0
    for a, b in cases:
        mem[ZP_A] = a & 0xFF
        mem[ZP_B] = b & 0xFF
        sc._run(ENTRY_BR_SMUL8)
        got = s16_from_zp(mem, ZP_RESL)
        want = a * b
        ok = got == want
        if not ok:
            fail += 1
            print(f"  FAIL smul8({a}, {b}): got={got}, want={want}")
        else:
            print(f"  OK   smul8({a}, {b}) = {got}")
    return fail


def test_recip():
    """Floating-mantissa reciprocal: (M8, S) for the FULL 9.1 index domain
    (every idx 2..1023) plus the clamp corners."""
    sc = SpanClip6502()
    mem = sc.mpu.memory
    cases = list(range(2, 1024)) + [0, 1, 1024, 2048, 65535]
    fail = 0
    for vy_idx in cases:
        mem[ZP_T0] = vy_idx & 0xFF
        mem[ZP_T1] = (vy_idx >> 8) & 0xFF
        sc._run(ENTRY_BR_RECIP)
        got_hi = mem[ZP_RHI]
        got_lo = mem[ZP_RLO]
        want_hi, want_lo = fp.fp_recip(vy_idx)
        ok = got_hi == want_hi and got_lo == want_lo
        if not ok:
            fail += 1
            if fail <= 5:
                print(f"  FAIL recip({vy_idx}): got=({got_hi:02X}, {got_lo:02X}), "
                      f"want=({want_hi:02X}, {want_lo:02X})")
    if fail == 0:
        print(f"  OK   recip: {len(cases)} cases pass (full domain + clamps)")
    else:
        print(f"  ... {fail}/{len(cases)} failed")
    return fail


ENTRY_BR_VIEW_SETUP = _sym('jt_br_view_setup')
ENTRY_BR_TO_VIEW    = _sym('jt_br_to_view')

# zp slots (linked equates; hi bytes are lo+1)
ZP_PX    = _sym('zp_br_px');    ZP_PXH  = ZP_PX + 1
ZP_PY    = _sym('zp_br_py');    ZP_PYH  = ZP_PY + 1
ZP_SMAG  = _sym('zp_br_smag');  ZP_SNEG = _sym('zp_br_sneg'); ZP_SONE = _sym('zp_br_sone')
ZP_CMAG  = _sym('zp_br_cmag');  ZP_CNEG = _sym('zp_br_cneg'); ZP_CONE = _sym('zp_br_cone')
ZP_FVXLO = _sym('zp_br_fvxlo'); ZP_FVXHI = ZP_FVXLO + 1
ZP_FVYLO = _sym('zp_br_fvylo'); ZP_FVYHI = ZP_FVYLO + 1
ZP_DX    = _sym('zp_br_dx');    ZP_DY    = _sym('zp_br_dy')
ZP_VXLO  = _sym('zp_br_vxlo');  ZP_VXHI  = _sym('zp_br_vxhi')
ZP_VYLO  = _sym('zp_br_vylo');  ZP_VYHI  = _sym('zp_br_vyhi')


def write_view_state(mem, vx_88, vy_88, sc_tuple):
    """Write player view state into ZP."""
    s_mag, s_neg, s_one, c_mag, c_neg, c_one = sc_tuple
    mem[ZP_PX]  = vx_88 & 0xFF
    mem[ZP_PXH] = (vx_88 >> 8) & 0xFF
    mem[ZP_PY]  = vy_88 & 0xFF
    mem[ZP_PYH] = (vy_88 >> 8) & 0xFF
    mem[_sym('zp_br_px_e')] = (vx_88 >> 16) & 0xFF
    mem[_sym('zp_br_py_e')] = (vy_88 >> 16) & 0xFF
    mem[ZP_SMAG] = s_mag
    mem[ZP_SNEG] = 1 if s_neg else 0
    mem[ZP_SONE] = 1 if s_one else 0
    mem[ZP_CMAG] = c_mag
    mem[ZP_CNEG] = 1 if c_neg else 0
    mem[ZP_CONE] = 1 if c_one else 0


def test_view_setup():
    """Compare 6502 frac_vx/vy against fp_view_context."""
    sc = SpanClip6502()
    mem = sc.mpu.memory
    cases = [
        (0x0100, 0x0200, 0),    # angle 0 (cos=1, sin=0)
        (0x1234, -0x0500, 64),  # 90°
        (-0x0080, 0x0080, 32),  # 45°-ish
        (0x07FF, 0x07FF, 128),  # 180°
        (-0x07FF, -0x07FF, 200),
    ]
    fail = 0
    for vx88, vy88, ab in cases:
        sc_tuple = fp.fp_sincos(ab)
        write_view_state(mem, vx88, vy88, sc_tuple)
        sc._run(ENTRY_BR_VIEW_SETUP)
        got_fvx = s16_from_zp(mem, ZP_FVXLO)
        got_fvy = s16_from_zp(mem, ZP_FVYLO)
        ctx = fp.fp_view_context(vx88, vy88, sc_tuple)
        want_fvx = ctx[3] & 0xFFFF
        want_fvy = ctx[4] & 0xFFFF
        # ctx[3] / ctx[4] are signed Python ints; convert to s16 wraparound.
        if want_fvx >= 0x8000: want_fvx -= 0x10000
        if want_fvy >= 0x8000: want_fvy -= 0x10000
        ok = got_fvx == want_fvx and got_fvy == want_fvy
        if not ok:
            fail += 1
            print(f"  FAIL view_setup(vx={vx88:5X} vy={vy88:5X} a={ab}): "
                  f"got=(fvx={got_fvx} fvy={got_fvy}), "
                  f"want=(fvx={want_fvx} fvy={want_fvy})")
        else:
            print(f"  OK   view_setup(a={ab:3d}) fvx={got_fvx:+5d} fvy={got_fvy:+5d}")
    return fail


def test_to_view():
    """Compare 6502 (vx, vy) for sample vertices against fp_to_view."""
    sc = SpanClip6502()
    mem = sc.mpu.memory
    # Pick a player state and a few sample vertices.
    vx88, vy88, ab = 0x0500, -0x0300, 32
    sc_tuple = fp.fp_sincos(ab)
    ctx = fp.fp_view_context(vx88, vy88, sc_tuple)

    # Apply view setup.
    write_view_state(mem, vx88, vy88, sc_tuple)
    sc._run(ENTRY_BR_VIEW_SETUP)

    cases = [(10, 10), (-30, 50), (100, -100), (0, 0), (5, -5)]
    fail = 0
    for wx, wy in cases:
        # New s16 ZP layout: dxlo=$0F, dxhi=$35, dylo=$10, dyhi=$36
        mem[0x0F] = wx & 0xFF
        mem[0x35] = (wx >> 8) & 0xFF
        mem[0x10] = wy & 0xFF
        mem[0x36] = (wy >> 8) & 0xFF
        sc._run(ENTRY_BR_TO_VIEW)
        got_vx = s16_from_zp(mem, ZP_VXLO)
        got_vy = s16_from_zp(mem, ZP_VYLO)
        evx_t, evx_r, evy, evx_frac, evy_idx = fp.fp_to_view(wx, wy, ctx)
        # fp_to_view returns truncated/rounded; we want the FULL s16 total_vx/vy.
        # Re-derive: total_vx = (evx_t << 8) | evx_frac (truncated),
        # but Python computes (rounded vy = (total_vy + 128) >> 8).
        # Cleanest: recompute total directly.
        px_int, py_int, _, frac_vx, frac_vy = ctx
        dx = (wx - px_int) & 0xFF
        dy = (wy - py_int) & 0xFF
        # Use the Python helpers that compute integer parts.
        from fp import _rot_int
        s_mag, s_neg, s_one, c_mag, c_neg, c_one = sc_tuple
        d_dx = wx - px_int
        d_dy = wy - py_int
        t_dx_sin = _rot_int(d_dx, s_mag, s_neg, s_one)
        t_dy_cos = _rot_int(d_dy, c_mag, c_neg, c_one)
        t_dx_cos = _rot_int(d_dx, c_mag, c_neg, c_one)
        t_dy_sin = _rot_int(d_dy, s_mag, s_neg, s_one)
        int_vx = t_dx_sin - t_dy_cos
        int_vy = t_dx_cos + t_dy_sin
        want_vx = (int_vx + frac_vx) & 0xFFFF
        want_vy = (int_vy + frac_vy) & 0xFFFF
        if want_vx >= 0x8000: want_vx -= 0x10000
        if want_vy >= 0x8000: want_vy -= 0x10000
        ok = got_vx == want_vx and got_vy == want_vy
        if not ok:
            fail += 1
            print(f"  FAIL to_view(wx={wx:+4d} wy={wy:+4d}): "
                  f"got=(vx={got_vx:+6d} vy={got_vy:+6d}), "
                  f"want=(vx={want_vx:+6d} vy={want_vy:+6d})")
        else:
            print(f"  OK   to_view(wx={wx:+4d} wy={wy:+4d}) vx={got_vx:+6d} vy={got_vy:+6d}")
    return fail


ENTRY_BR_PROJECT_X = abi.ENGINE_JT_FLAT + 0x0F   # jt slots (were hardcoded $480F/
ENTRY_BR_PROJECT_Y = abi.ENGINE_JT_FLAT + 0x12   # $4812 pre one-region merge)


# One recip sample per shift value S=1..10 (idx chosen mid-range for each
# bit-length band) plus the S-band edges, so every rns24/rns32 branch and
# half constant is exercised.
_IDX_SWEEP = [2, 3, 4, 5, 8, 9, 12, 16, 17, 24, 32, 33, 48, 64, 65, 100,
              128, 129, 200, 256, 257, 400, 512, 513, 800, 1023]


def test_project_x():
    """fp_project_x (narrow): vx, vx_frac, (M8, S) → sx. Dense sweep:
    every S band × full-range vx (s8) × frac corners."""
    sc = SpanClip6502()
    mem = sc.mpu.memory
    cases = []
    for vy_idx in _IDX_SWEEP:
        rh, rl = fp.fp_recip(vy_idx)
        for vx in range(-128, 128, 7):
            for vx_frac in [0, 1, 127, 128, 255]:
                cases.append((vx, vx_frac, rh, rl))
    fail = 0
    ZP_XINT, ZP_XEXT, ZP_XFRAC = _sym('zp_v_xint'), _sym('zp_v_xext'), _sym('zp_v_xfrac')
    for vx, vx_frac, rh, rl in cases:
        mem[ZP_XINT] = vx & 0xFF
        mem[ZP_XEXT] = 0xFF if vx < 0 else 0   # narrow: ext = sign extension
        mem[ZP_XFRAC] = vx_frac
        mem[0x1A] = rh               # zp_br_rhi (M8)
        mem[0x1B] = rl               # zp_br_rlo (S)
        sc._run(_sym('rns_select'))  # refresh the per-vertex shifter vector
        sc._run(ENTRY_BR_PROJECT_X)
        got = s16_from_zp(mem, 0x17)
        want = fp.fp_project_x(vx, vx_frac, rh, rl)
        ok = got == want
        if not ok:
            fail += 1
            if fail <= 5:
                print(f"  FAIL project_x(vx={vx}, frac={vx_frac}, M8={rh:02X}, S={rl}): "
                      f"got={got}, want={want}")
    if fail == 0:
        print(f"  OK   project_x: {len(cases)} cases pass")
    else:
        print(f"  ... {fail}/{len(cases)} failed")
    return fail


def test_project_x_wide():
    """br_project_x shrink dispatch: s16 view-x beyond s8, bit-exact vs
    the fp_project_x mirror (X88 >>= 1 with S-- until s8; S floors at 1)."""
    sc = SpanClip6502()
    mem = sc.mpu.memory
    ZP_XINT = _sym('zp_v_xint')
    ZP_XEXT = _sym('zp_v_xext')
    ZP_XFRAC = _sym('zp_v_xfrac')
    ENTRY_AUTO = ENTRY_BR_PROJECT_X          # unified entry dispatches itself
    cases = []
    for vy_idx in [1, 2, 5, 17, 65, 200, 513, 1023]:   # 1 -> S=1: deficit arm
        rh, rl = fp.fp_recip(vy_idx)
        for vx in [-32768, -3000, -300, -129, -128, 127, 128, 300, 3000, 32767]:
            for vx_frac in [0, 128, 255]:
                cases.append((vx, vx_frac, rh, rl))
    fail = 0
    for vx, vx_frac, rh, rl in cases:
        mem[ZP_XINT] = vx & 0xFF
        mem[ZP_XEXT] = (vx >> 8) & 0xFF
        mem[ZP_XFRAC] = vx_frac
        mem[0x1A] = rh
        mem[0x1B] = rl
        sc._run(_sym('rns_select'))  # refresh the per-vertex shifter vector
        sc._run(ENTRY_AUTO)
        got = mem[0x17] | (mem[0x18] << 8)
        want = fp.fp_project_x(vx, vx_frac, rh, rl) & 0xFFFF
        ok = got == want
        if not ok:
            fail += 1
            if fail <= 5:
                print(f"  FAIL project_x_wide(vx={vx}, frac={vx_frac}, M8={rh:02X}, S={rl}): "
                      f"got={got:04X}, want={want:04X}")
    if fail == 0:
        print(f"  OK   project_x_wide: {len(cases)} cases pass")
    else:
        print(f"  ... {fail}/{len(cases)} failed")
    return fail


def _has_sym(name):
    try:
        _sym(name)
        return True
    except Exception:
        return False


def test_project_y():
    """fp_project_y over the CONTRACT domain |h| <= 64 x every S band.

    2026-07-12: br_project_y_raw's ext byte is pure sign, valid only under
    the pack-time projection bound fence (doom_wireframe.py: every consumed
    |height - vz| <= 64, E1M1 worst is 54). h outside the fence is a packer
    bug by definition, so the sweep covers the fenced domain inclusive of
    both boundary values."""
    sc = SpanClip6502()
    mem = sc.mpu.memory
    cases = []
    for vy_idx in _IDX_SWEEP:
        rh, rl = fp.fp_recip(vy_idx)
        for h in range(-64, 65):
            cases.append((h, rh, rl))
    fail = 0
    for h, rh, rl in cases:
        mem[0x20] = h & 0xFF
        mem[0x1A] = rh
        mem[0x1B] = rl
        sc._run(_sym('rns_select'))  # refresh the per-vertex shifter vector
        sc._run(ENTRY_BR_PROJECT_Y)
        got = s16_from_zp(mem, 0x17)
        # br_project_y outputs HALF_H + Y_BIAS based values (the bias the
        # emission paths used to add per store is folded into the constant).
        want = fp.fp_project_y(h, rh, rl) + 48
        ok = got == want
        if not ok:
            fail += 1
            if fail <= 5:
                print(f"  FAIL project_y(h={h}, M8={rh:02X}, S={rl}): "
                      f"got={got}, want={want}")
    if fail == 0:
        print(f"  OK   project_y: {len(cases)} cases pass")
    else:
        print(f"  ... {fail}/{len(cases)} failed")
    return fail


if __name__ == '__main__':
    print("== br_umul8 ==")
    f1 = test_umul8()
    print("== br_smul8 ==")
    f2 = test_smul8()
    print("== br_recip ==")
    f3 = test_recip()
    print("== br_view_setup ==")
    f4 = test_view_setup()
    print("== br_to_view ==")
    f5 = test_to_view()
    print("== br_project_x ==")
    f6 = test_project_x()
    print("== br_project_y ==")
    f7 = test_project_y()
    print("== br_project_x (wide) ==")
    f8 = test_project_x_wide()
    total = f1 + f2 + f3 + f4 + f5 + f6 + f7 + f8
    print()
    if total == 0:
        print(f"All tests passed.")
    else:
        print(f"{total} failures.")
