#!/usr/bin/env python3
"""Unit tests for native 6502 fp_div8 and fp_linfn."""
import os
os.environ['SDL_VIDEODRIVER'] = 'dummy'
os.environ['PYGAME_HIDE_SUPPORT_PROMPT'] = '1'
import pygame; pygame.init(); pygame.display.set_mode((1, 1))

import doom_wireframe as dw
import fe6502
import subprocess
from fp import fp_div8 as py_fp_div8, fp_linfn as py_fp_linfn

fe = fe6502.Frontend6502(dw.packed_rom_banks, dw.packed_rom_recip,
                          dw.packed_bbox_table, dw.packed_layout)
mpu = fe.mpu
mem = mpu.memory

r = subprocess.run(['./beebasm', '-D', 'BANKED=0', '-i', 'doom_fe.asm', '-v'],
                    capture_output=True, text=True)
addrs = {}
for i, line in enumerate(r.stdout.split('\n')):
    s = line.strip()
    if s in ('.fp_div8', '.fp_linfn'):
        nl = r.stdout.split('\n')[i+1].strip()
        addrs[s[1:]] = int(nl.split()[0], 16)
print(f"fp_div8 at ${addrs['fp_div8']:04X}, fp_linfn at ${addrs['fp_linfn']:04X}")

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
    for _ in range(50000):
        pc = mpu.pc
        if pc == 0xFF00 or pc == 0x0000:
            break
        mpu.step()

print("Testing fp_div8...")
n_ok, n_fail = 0, 0
tests = [
    (0, 1), (100, 5), (-100, 5), (100, -5), (-100, -5),
    (0, 100), (1, 1), (255, 1), (160, 256), (160, 1),
    (50, 100), (200, 150), (-200, 150), (-50, -10),
    (100, 0),  # div by 0 → 0
    (128, 4),
]
for num, den in tests:
    ws16(0x4C, num)   # zp_tmp0 (num)
    ws16(0x4E, den)   # zp_tmp2 (den)
    # Wait — fp_div8 expects num in zp_tmp0 ($48), not $4C. Let me check.

# Actually let me re-check the ZP addresses from the source
# zp_tmp0 = $48, zp_tmp2 = $4C
print("\n(correcting ZP addresses)")
for num, den in tests:
    ws16(0x48, num)   # zp_tmp0 (num input)
    ws16(0x4C, den)   # zp_tmp2 (den input)
    call(addrs['fp_div8'])
    asm = rs16(0x70)
    py = py_fp_div8(num, den)
    # py may exceed s16; truncate to compare
    py_trunc = py & 0xFFFF
    if py_trunc >= 32768: py_trunc -= 65536
    ok = asm == py_trunc
    if ok:
        n_ok += 1
    else:
        n_fail += 1
        print(f"  FAIL: num={num} den={den} asm={asm} py={py} py_trunc={py_trunc}")
print(f"  fp_div8: {n_ok} OK, {n_fail} FAIL")

print("\nTesting fp_linfn...")
n_ok, n_fail = 0, 0
# fp_linfn inputs: $60=y1, $62=y2, $64=sx1, $66=sx2
# Outputs: $68=slope, $6A=intercept
tests_lf = [
    (50, 100, 0, 128),    # simple line
    (100, 50, 0, 128),    # reverse direction
    (0, 159, 0, 255),     # full screen diagonal
    (80, 80, 0, 100),     # horizontal
    (50, 100, 50, 50),    # zero dx (vertical)
    (30, 100, -50, 200),  # sx1 negative
    (100, 50, 100, 200),  # positive sx
    (50, 100, -100, 100),
]
for y1, y2, sx1, sx2 in tests_lf:
    ws16(0x60, y1)
    ws16(0x62, y2)
    ws16(0x64, sx1)
    ws16(0x66, sx2)
    call(addrs['fp_linfn'])
    asm_slope = rs16(0x68)
    asm_intercept = rs16(0x6A)
    py_slope, py_intercept = py_fp_linfn(y1, y2, sx1, sx2)
    # Truncate py slope to s16
    py_slope_trunc = py_slope & 0xFFFF
    if py_slope_trunc >= 32768: py_slope_trunc -= 65536
    ok = asm_slope == py_slope_trunc and asm_intercept == py_intercept
    if ok:
        n_ok += 1
    else:
        n_fail += 1
        print(f"  FAIL: y1={y1} y2={y2} sx1={sx1} sx2={sx2}")
        print(f"    asm: slope={asm_slope} intercept={asm_intercept}")
        print(f"    py:  slope={py_slope} intercept={py_intercept}")
print(f"  fp_linfn: {n_ok} OK, {n_fail} FAIL")
