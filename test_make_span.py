#!/usr/bin/env python3
"""Unit test for native 6502 fp_eval and make_span against Python reference."""
import os
os.environ['SDL_VIDEODRIVER'] = 'dummy'
os.environ['PYGAME_HIDE_SUPPORT_PROMPT'] = '1'
import pygame; pygame.init(); pygame.display.set_mode((1, 1))

import doom_wireframe as dw
import fe6502
import subprocess
from fp import fp_eval as py_fp_eval

fe = fe6502.Frontend6502(dw.packed_rom_banks, dw.packed_rom_recip,
                          dw.packed_bbox_table, dw.packed_layout)
mpu = fe.mpu
mem = mpu.memory

r = subprocess.run(['./beebasm', '-D', 'BANKED=0', '-i', 'doom_fe.asm', '-v'],
                    capture_output=True, text=True)
addrs = {}
for i, line in enumerate(r.stdout.split('\n')):
    s = line.strip()
    if s in ('.fp_eval', '.make_span'):
        nl = r.stdout.split('\n')[i+1].strip()
        addrs[s[1:]] = int(nl.split()[0], 16)
print(f"fp_eval at ${addrs['fp_eval']:04X}, make_span at ${addrs['make_span']:04X}")

# ZP slots
ZP_TMP2 = 0x4C
ZP_MK_TSLOPE = 0xDB
ZP_MK_TINTERCEPT = 0xDD
ZP_MK_BSLOPE = 0xDF
ZP_MK_BINTERCEPT = 0xE1
ZP_MK_XLO = 0xE3
ZP_MK_XHI = 0xE4
ZP_MK_OUT = 0xE5
ZP_MK_TMP = 0xE7

def ws16(a, v):
    mem[a] = v & 0xFF
    mem[a+1] = (v >> 8) & 0xFF

def rs16(a):
    v = mem[a] | (mem[a+1] << 8)
    return v - 65536 if v >= 32768 else v

def call(addr):
    mpu.sp = 0xFD
    mem[0x01FF] = 0xFE
    mem[0x01FE] = 0xFF
    mpu.pc = addr
    for _ in range(5000):
        pc = mpu.pc
        if pc == 0xFF00 or pc == 0x0000:
            break
        mpu.step()

def call_fp_eval(slope, x, intercept):
    ws16(ZP_TMP2, slope)
    ws16(ZP_MK_TMP, intercept)
    # A register seeded via STA instruction before PC jump — use a tiny stub
    # Actually simplest: write a 2-byte setup+JSR sequence at some address.
    # Or: load A manually via mpu.a.
    mpu.a = x & 0xFF
    call(addrs['fp_eval'])
    return rs16(0x70)

# Test fp_eval
print("Testing fp_eval...")
n_ok, n_fail = 0, 0
test_vals = [
    (0, 0, 0),       # zero slope
    (0, 100, 50),    # zero slope nonzero intercept
    (10, 50, 0),     # simple positive
    (100, 200, 30),  # larger positive
    (-100, 50, 10),  # negative slope
    (358, 100, 50),  # large slope (outside s8)
    (-358, 100, 50),
    (127, 255, -50),
    (-128, 255, 100),
    (200, 0, 75),    # x=0
    (200, 255, 75),  # x=255
]
for slope, x, intercept in test_vals:
    asm = call_fp_eval(slope, x, intercept)
    py = py_fp_eval((slope, intercept), x)
    ok = asm == py
    if ok:
        n_ok += 1
    else:
        n_fail += 1
        print(f"  FAIL: slope={slope} x={x} intercept={intercept} asm={asm} py={py}")
print(f"  fp_eval: {n_ok} OK, {n_fail} FAIL")

# Test make_span
SCRATCH_OUT = 0x046A  # write output here
print("\nTesting make_span...")
n_ok, n_fail = 0, 0

def call_make_span(xlo, xhi, tfn, bfn):
    mem[ZP_MK_XLO] = xlo & 0xFF
    mem[ZP_MK_XHI] = xhi & 0xFF
    ws16(ZP_MK_TSLOPE, tfn[0])
    ws16(ZP_MK_TINTERCEPT, tfn[1])
    ws16(ZP_MK_BSLOPE, bfn[0])
    ws16(ZP_MK_BINTERCEPT, bfn[1])
    mem[ZP_MK_OUT] = SCRATCH_OUT & 0xFF
    mem[ZP_MK_OUT + 1] = (SCRATCH_OUT >> 8) & 0xFF
    call(addrs['make_span'])
    # Read back the span
    xlo_r = mem[SCRATCH_OUT + 0]
    xhi_r = mem[SCRATCH_OUT + 1]
    ts = rs16(SCRATCH_OUT + 2)
    bs = rs16(SCRATCH_OUT + 4)
    ti = rs16(SCRATCH_OUT + 6)
    bi = rs16(SCRATCH_OUT + 8)
    it = rs16(SCRATCH_OUT + 10)
    ib = rs16(SCRATCH_OUT + 12)
    return xlo_r, xhi_r, (ts, ti), (bs, bi), it, ib

def py_make_span(xlo, xhi, tfn, bfn):
    if xlo >= xhi: return None
    top_l = py_fp_eval(tfn, xlo)
    top_r = py_fp_eval(tfn, xhi - 1)
    bot_l = py_fp_eval(bfn, xlo)
    bot_r = py_fp_eval(bfn, xhi - 1)
    return (xlo, xhi, tfn, bfn, max(top_l, top_r), min(bot_l, bot_r))

ms_tests = [
    (0, 256, (0, 0), (0, 159)),      # full screen, flat
    (0, 128, (10, 50), (0, 150)),    # left half, sloped top
    (64, 192, (-20, 100), (30, 120)),  # middle, various
    (0, 256, (50, 0), (-50, 159)),   # steep slopes
    (100, 200, (200, -50), (-200, 200)),  # extreme slopes
]
for xlo, xhi, tfn, bfn in ms_tests:
    # xhi in span format wraps: 256 → 0
    xhi_packed = xhi & 0xFF
    got = call_make_span(xlo, xhi_packed, tfn, bfn)
    py = py_make_span(xlo, xhi, tfn, bfn)
    if py is None:
        continue  # skip invalid test
    # Compare all fields
    expected = (xlo & 0xFF, xhi & 0xFF, tfn, bfn, py[4], py[5])
    if got == expected:
        n_ok += 1
    else:
        n_fail += 1
        print(f"  FAIL: xlo={xlo} xhi={xhi} tfn={tfn} bfn={bfn}")
        print(f"    asm={got}")
        print(f"    py ={expected}")
print(f"  make_span: {n_ok} OK, {n_fail} FAIL")
