#!/usr/bin/env python3
"""Unit test for the native 6502 has_gap routine.

Constructs various span arrays directly in mpu memory, calls has_gap
with various (lo, hi) inputs, and compares the carry-flag result to
Python's FPClipSpans.has_gap.
"""
import os
os.environ['SDL_VIDEODRIVER'] = 'dummy'
os.environ['PYGAME_HIDE_SUPPORT_PROMPT'] = '1'
import pygame; pygame.init(); pygame.display.set_mode((1, 1))

import doom_wireframe as dw
import fe6502
import subprocess

fe = fe6502.Frontend6502(dw.packed_rom_banks, dw.packed_rom_recip,
                          dw.packed_bbox_table, dw.packed_layout)
mpu = fe.mpu
mem = mpu.memory

# Find has_gap address
r = subprocess.run(['./beebasm', '-D', 'BANKED=0', '-i', 'doom_fe.asm', '-v'],
                    capture_output=True, text=True)
hg_addr = None
for i, line in enumerate(r.stdout.split('\n')):
    if line.strip() == '.has_gap':
        nl = r.stdout.split('\n')[i+1].strip()
        hg_addr = int(nl.split()[0], 16)
        break
print(f"has_gap at ${hg_addr:04X}")

SPANS_BASE = 0x20D0
SPAN_HDR = 2
SPAN_SIZE = 16

def ws16(addr, v):
    mem[addr] = v & 0xFF
    mem[addr + 1] = (v >> 8) & 0xFF

def write_span(i, xlo, xhi, inner_top, inner_bot, outer_top=0, outer_bot=159):
    # New span layout: s16 slopes at +2/+4, intercepts at +6/+8, inner at +10/+12.
    o = SPANS_BASE + SPAN_HDR + i * SPAN_SIZE
    mem[o + 0] = xlo & 0xFF
    mem[o + 1] = xhi & 0xFF
    ws16(o + 2, 0)   # tslope (s16)
    ws16(o + 4, 0)   # bslope (s16)
    ws16(o + 6, inner_top)   # tintercept
    ws16(o + 8, inner_bot)   # bintercept
    ws16(o + 10, inner_top)
    ws16(o + 12, inner_bot)

def set_spans(specs):
    mem[SPANS_BASE] = len(specs)
    for i, s in enumerate(specs):
        write_span(i, *s)

def call_has_gap(lo, hi):
    # Load args: has_gap reads zp_x_lo_clip ($2C) / zp_x_hi_clip ($2E) directly
    ws16(0x2C, lo)
    ws16(0x2E, hi)
    # Set up fake return stack
    mpu.sp = 0xFD
    mem[0x01FF] = 0xFE
    mem[0x01FE] = 0xFF
    mpu.pc = hg_addr
    for _ in range(2000):
        pc = mpu.pc
        if pc == 0xFF00 or pc == 0x0000:
            break
        mpu.step()
    return (mpu.p & 0x01) != 0  # carry

def py_has_gap(specs, lo, hi):
    """Python reference: mirror FPClipSpans.has_gap."""
    ilo = max(0, lo)
    ihi = min(255, hi)
    for xlo, xhi, it, ib in specs:
        xhi_eff = 256 if xhi == 0 else xhi
        if xlo > ihi:
            break
        if xhi_eff <= ilo:
            continue
        if it < ib:
            return True
    return False

# Test cases: list of (spec, lo, hi)
tests = [
    # Single full-screen span with gap
    ([(0, 0, 0, 159)], 0, 160),
    ([(0, 0, 0, 159)], -10, 10),
    ([(0, 0, 0, 159)], 100, 200),
    ([(0, 0, 0, 159)], 255, 260),
    ([(0, 0, 0, 159)], 256, 300),     # fully right of range
    ([(0, 0, 0, 159)], -50, -10),     # fully left of range
    # Single full-screen span with NO gap
    ([(0, 0, 100, 100)], 0, 160),     # inner_top == inner_bot
    ([(0, 0, 100, 50)], 0, 160),      # inner_top > inner_bot
    # Two spans, gap in second only
    ([(0, 128, 50, 50), (128, 0, 0, 159)], 0, 160),
    # Two spans, gap in first only
    ([(0, 128, 0, 159), (128, 0, 50, 50)], 0, 160),
    # Probe specific X range
    ([(0, 128, 50, 50), (128, 0, 0, 159)], 0, 100),  # only first
    ([(0, 128, 50, 50), (128, 0, 0, 159)], 130, 200),  # only second
    # Three spans, middle with gap
    ([(0, 80, 50, 50), (80, 160, 0, 159), (160, 0, 50, 50)], 0, 300),
    # Edge case: xhi=0=256 first span
    ([(0, 0, 0, 159)], 0, 0),
    ([(0, 0, 0, 159)], 255, 255),
    # Empty span list
    ([], 0, 160),
]

n_ok = 0
n_fail = 0
for specs, lo, hi in tests:
    set_spans([(xl, xh, it, ib) for xl, xh, it, ib in specs])
    asm = call_has_gap(lo, hi)
    py = py_has_gap(specs, lo, hi)
    ok = asm == py
    if ok:
        n_ok += 1
    else:
        n_fail += 1
        print(f"  FAIL: spans={specs} lo={lo} hi={hi} asm={asm} py={py}")
print(f"{n_ok} OK, {n_fail} FAIL")
