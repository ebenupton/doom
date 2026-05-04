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

ENTRY_BR_UMUL8 = 0x4800
ENTRY_BR_SMUL8 = 0x4803
ENTRY_BR_RECIP = 0x4806

ZP_A    = 0x15
ZP_B    = 0x16
ZP_RESL = 0x17
ZP_RESH = 0x18
ZP_T0   = 0x20
ZP_T1   = 0x21
ZP_RHI  = 0x1A
ZP_RLO  = 0x1B


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
    """Reciprocal lookup with 1-bit fractional averaging."""
    sc = SpanClip6502()
    mem = sc.mpu.memory
    # Sample vy_idx values (9.1 format). Range [2, 1023].
    cases = [2, 3, 4, 100, 101, 256, 511, 512, 513, 1023]
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
            print(f"  FAIL recip({vy_idx}): got=({got_hi:02X}, {got_lo:02X}), "
                  f"want=({want_hi:02X}, {want_lo:02X})")
        else:
            print(f"  OK   recip({vy_idx}) = ({got_hi:02X}, {got_lo:02X})")
    return fail


ENTRY_BR_VIEW_SETUP = 0x4809
ENTRY_BR_TO_VIEW    = 0x480C

# zp slots
ZP_PX    = 0x00; ZP_PXH  = 0x01
ZP_PY    = 0x02; ZP_PYH  = 0x03
ZP_SMAG  = 0x05; ZP_SNEG = 0x06; ZP_SONE = 0x07
ZP_CMAG  = 0x08; ZP_CNEG = 0x09; ZP_CONE = 0x0A
ZP_FVXLO = 0x0B; ZP_FVXHI = 0x0C
ZP_FVYLO = 0x0D; ZP_FVYHI = 0x0E
ZP_DX    = 0x0F; ZP_DY    = 0x10
ZP_VXLO  = 0x11; ZP_VXHI  = 0x12
ZP_VYLO  = 0x13; ZP_VYHI  = 0x14


def write_view_state(mem, vx_88, vy_88, sc_tuple):
    """Write player view state into ZP."""
    s_mag, s_neg, s_one, c_mag, c_neg, c_one = sc_tuple
    mem[ZP_PX]  = vx_88 & 0xFF
    mem[ZP_PXH] = (vx_88 >> 8) & 0xFF
    mem[ZP_PY]  = vy_88 & 0xFF
    mem[ZP_PYH] = (vy_88 >> 8) & 0xFF
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
        mem[ZP_DX] = wx & 0xFF
        mem[ZP_DY] = wy & 0xFF
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


ENTRY_BR_PROJECT_X = 0x480F
ENTRY_BR_PROJECT_Y = 0x4812


def test_project_x():
    """fp_project_x_subpx: vx, vx_frac, recip_hi, recip_lo → sx."""
    sc = SpanClip6502()
    mem = sc.mpu.memory
    cases = []
    # Sample a few vy values and a few vx values.
    for vy_idx in [10, 50, 200, 500]:
        rh, rl = fp.fp_recip(vy_idx)
        for vx in [-50, 0, 30, 100]:
            for vx_frac in [0, 64, 128, 200]:
                cases.append((vx, vx_frac, rh, rl))
    fail = 0
    for vx, vx_frac, rh, rl in cases:
        mem[0x20] = vx & 0xFF       # zp_br_t0
        mem[0x21] = vx_frac          # zp_br_t1
        mem[0x1A] = rh               # zp_br_rhi
        mem[0x1B] = rl               # zp_br_rlo
        sc._run(ENTRY_BR_PROJECT_X)
        got = s16_from_zp(mem, 0x17)
        want = fp.fp_project_x_subpx(vx, vx_frac, rh, rl)
        ok = got == want
        if not ok:
            fail += 1
            if fail <= 5:
                print(f"  FAIL project_x(vx={vx}, frac={vx_frac}, rh={rh:02X}, rl={rl:02X}): "
                      f"got={got}, want={want}")
    if fail == 0:
        print(f"  OK   project_x: {len(cases)} cases pass")
    else:
        print(f"  ... {fail}/{len(cases)} failed")
    return fail


def test_project_y():
    """fp_project_y: height_delta, recip_hi, recip_lo → sy."""
    sc = SpanClip6502()
    mem = sc.mpu.memory
    cases = []
    for vy_idx in [10, 50, 200, 500]:
        rh, rl = fp.fp_recip(vy_idx)
        for h in [-30, -10, 0, 5, 20, 40]:
            cases.append((h, rh, rl))
    fail = 0
    for h, rh, rl in cases:
        mem[0x20] = h & 0xFF
        mem[0x1A] = rh
        mem[0x1B] = rl
        sc._run(ENTRY_BR_PROJECT_Y)
        got = s16_from_zp(mem, 0x17)
        want = fp.fp_project_y(h, rh, rl)
        ok = got == want
        if not ok:
            fail += 1
            if fail <= 5:
                print(f"  FAIL project_y(h={h}, rh={rh:02X}, rl={rl:02X}): "
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
    total = f1 + f2 + f3 + f4 + f5 + f6 + f7
    print()
    if total == 0:
        print(f"All tests passed.")
    else:
        print(f"{total} failures.")
