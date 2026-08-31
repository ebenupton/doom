"""Test bsp_render.asm primitives against fp.py reference.

Run with `python3 test_bsp_render.py` from the doom directory.

Each test sets up zp inputs, JSRs the routine, reads zp outputs,
and compares against the Python reference.
"""
import os
os.environ['SDL_VIDEODRIVER'] = 'dummy'
os.environ['PYGAME_HIDE_SUPPORT_PROMPT'] = '1'
import pygame; pygame.init(); pygame.display.set_mode((1, 1))

import doom_wireframe as dw
import fp
import abi

# Symbols resolve for the build the shared rig IS (banked since 2026-08-29;
# DOOM_FLAT_RIG=1 restores flat).  zp/pool names are identical in both maps
# by rule, so only CODE entries actually move -- but a stale flat entry in a
# banked rig is a silent jump into the wrong build, so resolve it all here.
import functools as _ft, os as _os
_BANKED = 0 if dw.FLAT_RIG else 1     # dw is the single switch
from symmap import sym as _raw_sym
_sym = _ft.partial(_raw_sym, banked=_BANKED)
ENTRY_BR_UMUL8 = _sym('umul8_zp')
ENTRY_BR_RECIP_HI = _sym('recip_hi')   # junior arm is inlined at nc_ok

ZP_A    = _sym('zp_br_a')
ZP_B    = _sym('zp_br_b')
ZP_RESL = _sym('zp_br_res_l')
ZP_RESH = _sym('zp_br_res_h')
ZP_T0   = _sym('zp_br_t0')
ZP_T1   = _sym('zp_br_t1')
ZP_RHI  = _sym('zp_br_r_m8')
ZP_RLO  = _sym('zp_br_r_s')


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
    sc = dw.make_span_rig()
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


# (test_smul8 removed 2026-07-16: br_smul8 deleted — no engine callers)


def test_recip():
    """Floating-mantissa reciprocal: (M8, S) for the FULL 9.1 index domain
    (every idx 2..1023) plus the clamp corners."""
    sc = dw.make_span_rig()
    mem = sc.mpu.memory
    cases = list(range(2, 1024)) + [0, 1, 1024, 2048, 65535]
    fail = 0
    recip_base = _sym('RECIP_M8')
    srecip = _sym('RECIP_S')
    for vy_idx in cases:
        if vy_idx < 256:
            # junior arm is INLINED at nc_ok (seg_xform) since 2026-07-27:
            # (M8, S) = straight table reads — validate the tables the
            # inline serves (NIBBLE-SWAPPED page-0 layout, 2026-08-10;
            # the instruction sequence itself is covered by every
            # rendering gate)
            sw = ((vy_idx & 0x0F) << 4) | (vy_idx >> 4)
            got_hi = mem[recip_base + sw]
            got_lo = mem[srecip + sw]
        else:
            # senior ladder ABI: A = idx hi (>= 1), Y = idx lo
            sc.mpu.y = vy_idx & 0xFF
            sc.mpu.a = (vy_idx >> 8) & 0xFF
            sc._run(ENTRY_BR_RECIP_HI)
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


ENTRY_BR_VIEW_SETUP = _sym('view_setup')

# zp slots.  NAME BOTH HALVES: lo+1 is not the hi byte in general.  Zero
# page is linker-allocated and tools/zprotate rotates cold bytes out of
# it, so an adjacency that holds today is not a property of the pair --
# zp_br_px moved to absolute on 2026-08-31 while zp_br_px_h stayed put.
ZP_PX    = _sym('zp_br_px');    ZP_PXH  = _sym('zp_br_px_h')
ZP_PY    = _sym('zp_br_py');    ZP_PYH  = _sym('zp_br_py_h')
ZP_SMAG  = _sym('zp_br_smag');  ZP_SNEG = _sym('zp_br_sneg'); ZP_SONE = _sym('zp_br_sone')
ZP_CMAG  = _sym('zp_br_cmag');  ZP_CNEG = _sym('zp_br_cneg'); ZP_CONE = _sym('zp_br_cone')
ZP_FVXLO = _sym('zp_br_fvx_l'); ZP_FVXHI = _sym('zp_br_fvx_h')
ZP_FVYLO = _sym('zp_br_fvy_l'); ZP_FVYHI = _sym('zp_br_fvy_h')
ZP_DX    = _sym('zp_br_dx');    ZP_DY    = _sym('zp_br_dy')
ZP_VXLO  = _sym('zp_br_vx_l');  ZP_VXHI  = _sym('zp_br_vx_h')
ZP_VYLO  = _sym('zp_br_vy_l');  ZP_VYHI  = _sym('zp_br_vy_h')


def write_view_state(mem, vx_88, vy_88, sc_tuple):
    """Write player view state into ZP."""
    s_mag, s_neg, s_one, c_mag, c_neg, c_one = sc_tuple
    # zp staging is mag8 again (2026-08-31, the trig8 restore) -- the
    # engine derives mag5'/eps itself in rot_select
    mem[ZP_PX]  = vx_88 & 0xFF
    mem[ZP_PXH] = (vx_88 >> 8) & 0xFF
    mem[ZP_PY]  = vy_88 & 0xFF
    mem[ZP_PYH] = (vy_88 >> 8) & 0xFF
    mem[_sym('zp_br_px_x')] = (vx_88 >> 16) & 0xFF
    mem[_sym('zp_br_py_x')] = (vy_88 >> 16) & 0xFF
    mem[ZP_SMAG] = s_mag
    mem[ZP_SNEG] = 1 if s_neg else 0
    mem[ZP_SONE] = 1 if s_one else 0
    mem[ZP_CMAG] = c_mag
    mem[ZP_CNEG] = 1 if c_neg else 0
    mem[ZP_CONE] = 1 if c_one else 0


def test_view_setup():
    """Compare 6502 frac_vx/vy against fp_view_context."""
    sc = dw.make_span_rig()
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
        # COUNT-NATIVE (2026-08-10): the engine quantizes the 8.8 frac
        # terms to s16 counts in view_setup — rns(fv_88, 3).
        want_fvx = fp.rns(ctx[3], 3)
        want_fvy = fp.rns(ctx[4], 3)
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
    """Position-path check (rot_w_pages era, 2026-08-11): br_to_view
    died — the ref is built by vxcache_frame through the SAME page-
    decomposed rotate as vertices. Validate the staged vxcache_ref
    against the mirror: ref_c = rns(ref_88, 3)."""
    sc = dw.make_span_rig()
    mem = sc.mpu.memory
    cases = [(0x0500, -0x0300, 32), (0x1234, -0x0500, 64),
             (-0x0080, 0x0080, 200), (0x2F00, -0x1D00, 7)]
    fail = 0
    for vx88, vy88, ab in cases:
        sc_tuple = fp.fp_sincos(ab)
        write_view_state(mem, vx88, vy88, sc_tuple)
        mem[_sym('bca_ab')] = ab & 0xFF
        sc._run(ENTRY_BR_VIEW_SETUP)
        rx = _sym('vxcache_ref_x'); ry = _sym('vxcache_ref_y')
        got_x = s16_from_zp(mem, rx)
        got_y = s16_from_zp(mem, ry)
        ctx = fp.fp_view_context(vx88, vy88, sc_tuple)
        # THE REF SPLIT (2026-08-31): the engine rounds the integer
        # rotation (through rot_w_pages) and the summed fracs separately
        # -- rns(int,3) + rns(frac,3), exactly as fp_to_view_totals_t16
        # models it.  Single-rounding differs by +-1 count.
        want_x = fp.rns(ctx[5] - ctx[3], 3) + fp.rns(ctx[3], 3)
        want_y = fp.rns(ctx[6] - ctx[4], 3) + fp.rns(ctx[4], 3)
        ok = got_x == want_x and got_y == want_y
        if not ok:
            fail += 1
            print(f"  FAIL ref(vx={vx88:5X} vy={vy88:5X} a={ab}): "
                  f"got=({got_x},{got_y}) want=({want_x},{want_y})")
        else:
            print(f"  OK   ref(a={ab:3d}) = ({got_x:+6d},{got_y:+6d})")
    return fail


ENTRY_BR_PROJECT_Y = _sym('project_y')  # paged entry retired 2026-07-26: zero callers; naked contract = A = h


# One recip sample per shift value S=1..10 (idx chosen mid-range for each
# bit-length band) plus the S-band edges, so every rns24/rns32 branch and
# half constant is exercised.
_IDX_SWEEP = [2, 3, 4, 5, 8, 9, 12, 16, 17, 24, 32, 33, 48, 64, 65, 100,
              128, 129, 200, 256, 257, 400, 512, 513, 800, 1023]



def _rns_reselect(sc, mem):
    """Mirror the RNS_SELECT macro (the rns_select subroutine is retired):
    patch rns_go_op from rns_vec_l[S-1], S = zp_br_r_s."""
    mem[_sym('rns_go_op')] = mem[_sym('rns_vec_l') - 1
                                 + mem[_sym('zp_br_r_s')]]

def test_project_x():
    """project_x_c (the ONLY X projector since the classic entry +
    px_shrink were proven unreachable and deleted, 2026-08-11): input
    is s16 COUNTS in vx_l/vx_h; returns rns((c<<3)*m9, S+8) UNBIASED in
    res — the +128 tail moved into the callers with the px tail-call
    dispatch (2026-08-12), so this bench, as a caller, applies it in
    the reference instead. The entry selects its own net kernel."""
    sc = dw.make_span_rig()
    mem = sc.mpu.memory
    cases = []
    for vy_idx in _IDX_SWEEP:
        rh, rl = fp.fp_recip(vy_idx)
        for c in range(-16384, 16385, 971):
            cases.append((c, rh, rl))
    fail = 0
    ZP_CL, ZP_CH = _sym('zp_br_vx_l'), _sym('zp_br_vx_h')
    E_C = _sym('project_x_c')
    for c, rh, rl in cases:
        mem[ZP_CL] = c & 0xFF
        mem[ZP_CH] = (c >> 8) & 0xFF
        mem[_sym('zp_br_r_m8')] = rh
        mem[_sym('zp_br_r_s')] = rl
        sc._run(E_C)
        got = mem[_sym('zp_br_res_l')] | (mem[_sym('zp_br_res_h')] << 8)
        # EXACT reference (fp_project_x would take its SHRINK path for
        # wide X88 and truncate — _c never shrinks): b123 = floor(c*m9
        # / 256) by the narrow-body identity, then the net = S-3 kernel:
        # RN for net >= 1, pure shift (mod 2^16, the wide contract) for
        # net <= 0.
        m9 = 256 + rh
        P = (c * m9) >> 8
        net = rl - 3
        if net >= 1:
            r = (P + (1 << (net - 1))) >> net
        else:
            r = P << -net
        want = r & 0xFFFF               # UNBIASED (the +128 lives in the
                                        # callers since the tail-call move)
        ok = got == want
        if not ok:
            fail += 1
            if fail < 6:
                print(f"  FAIL project_x_c(c={c}, m8={rh}, s={rl}): got={got} want={want}")
    print(f"  {'OK  ' if not fail else 'FAIL'} project_x_c: {len(cases)-fail}/{len(cases)} cases pass")
    return fail


# (test_project_x_wide DELETED 2026-08-11: it exercised the px_shrink
# dispatch, whose domain — s16 integer view-x parts — is empty by
# construction under count-native totals; the shrink was proven
# unreachable and removed. project_x_c's full-range counts sweep in
# test_project_x covers the live projector.)

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
    sc = dw.make_span_rig()
    mem = sc.mpu.memory
    cases = []
    for vy_idx in _IDX_SWEEP:
        rh, rl = fp.fp_recip(vy_idx)
        for h in range(-64, 65):
            cases.append((h, rh, rl))
    fail = 0
    for h, rh, rl in cases:
        mem[_sym('zp_br_r_m8')] = rh
        mem[_sym('zp_br_r_s')] = rl
        _rns_reselect(sc, mem)       # refresh the per-vertex shifter vector
        sc.mpu.a = h & 0xFF          # naked-entry REG contract: A = h (the
                                     # entry stores zp_br_t0 itself)
        sc._run(ENTRY_BR_PROJECT_Y)
        # register contract (2026-07-19): Y = sy lo, A = sy hi (the zp
        # store-backs were test-only and died — cp_havepsi precedent)
        got = sc.mpu.y | (sc.mpu.a << 8)
        if got >= 0x8000: got -= 0x10000
        # project_y outputs HALF_H + Y_BIAS based values (the bias the
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
    print("== umul8_zp ==")
    f1 = test_umul8()
    f2 = 0   # (br_smul8 retired)
    print("== br_recip ==")
    f3 = test_recip()
    print("== view_setup ==")
    f4 = test_view_setup()
    print("== position ref (rot_w_pages) ==")
    f5 = test_to_view()
    print("== br_project_x ==")
    f6 = test_project_x()
    print("== project_y ==")
    f7 = test_project_y()
    print("== br_project_x (wide) ==")
    f8 = 0   # test_project_x_wide deleted (shrink domain empty)
    total = f1 + f2 + f3 + f4 + f5 + f6 + f7 + f8
    print()
    if total == 0:
        print(f"All tests passed.")
    else:
        print(f"{total} failures.")
