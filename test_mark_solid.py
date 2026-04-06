#!/usr/bin/env python3
"""Unit test for native 6502 mark_solid against Python FPClipSpans.mark_solid.

Sets up various span configurations in RAM, calls native mark_solid, and
compares the resulting span array to Python's reference.
"""
import os
os.environ['SDL_VIDEODRIVER'] = 'dummy'
os.environ['PYGAME_HIDE_SUPPORT_PROMPT'] = '1'
import pygame; pygame.init(); pygame.display.set_mode((1, 1))

import doom_wireframe as dw
import fe6502
import subprocess
from wad_packed import (SPAN_HDR, SPAN_SIZE, MAX_SPANS,
                        read_all_spans, write_all_spans)
from fp import fp_eval

fe = fe6502.Frontend6502(dw.packed_rom_banks, dw.packed_rom_recip,
                          dw.packed_bbox_table, dw.packed_layout)
mpu = fe.mpu
mem = mpu.memory

# Find addresses
r = subprocess.run(['./beebasm', '-i', 'doom_fe.asm', '-v'],
                    capture_output=True, text=True)
addrs = {}
for i, line in enumerate(r.stdout.split('\n')):
    s = line.strip()
    if s in ('.mark_solid',):
        nl = r.stdout.split('\n')[i+1].strip()
        addrs[s[1:]] = int(nl.split()[0], 16)
print(f"mark_solid at ${addrs['mark_solid']:04X}")

SPANS_BASE = 0x20D0
ZP_MS_LO = 0xF0
ZP_MS_HI = 0xF2

def ws16(a, v):
    mem[a] = v & 0xFF
    mem[a+1] = (v >> 8) & 0xFF

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

def setup_spans(span_list):
    """Write a list of (xlo, xhi, tfn, bfn) span tuples to SPANS_BASE.
    tfn = (slope, intercept).  Computes inner_top/bot via fp_eval."""
    mem[SPANS_BASE] = len(span_list)
    mem[SPANS_BASE + 1] = 0
    for i, (xlo, xhi, tfn, bfn) in enumerate(span_list):
        o = SPANS_BASE + SPAN_HDR + i * SPAN_SIZE
        mem[o + 0] = xlo & 0xFF
        mem[o + 1] = xhi & 0xFF
        ws16(o + 2, tfn[0])        # tslope
        ws16(o + 4, bfn[0])        # bslope
        ws16(o + 6, tfn[1])        # tintercept
        ws16(o + 8, bfn[1])        # bintercept
        # inner_top = max(fp_eval(tfn, xlo), fp_eval(tfn, (256 if xhi==0 else xhi)-1))
        xhi_s = 256 if xhi == 0 else xhi
        top_l = fp_eval(tfn, xlo)
        top_r = fp_eval(tfn, xhi_s - 1)
        bot_l = fp_eval(bfn, xlo)
        bot_r = fp_eval(bfn, xhi_s - 1)
        ws16(o + 10, max(top_l, top_r))
        ws16(o + 12, min(bot_l, bot_r))

def read_spans():
    """Read spans back as list of tuples (xlo, xhi, tfn, bfn, inner_top, inner_bot)."""
    n = mem[SPANS_BASE]
    out = []
    for i in range(n):
        o = SPANS_BASE + SPAN_HDR + i * SPAN_SIZE
        xlo = mem[o]
        xhi = mem[o + 1]
        ts = mem[o + 2] | (mem[o + 3] << 8)
        if ts >= 32768: ts -= 65536
        bs = mem[o + 4] | (mem[o + 5] << 8)
        if bs >= 32768: bs -= 65536
        ti = mem[o + 6] | (mem[o + 7] << 8)
        if ti >= 32768: ti -= 65536
        bi = mem[o + 8] | (mem[o + 9] << 8)
        if bi >= 32768: bi -= 65536
        it = mem[o + 10] | (mem[o + 11] << 8)
        if it >= 32768: it -= 65536
        ib = mem[o + 12] | (mem[o + 13] << 8)
        if ib >= 32768: ib -= 65536
        out.append((xlo, xhi, (ts, ti), (bs, bi), it, ib))
    return out

def py_mark_solid(span_list, lo, hi):
    """Python reference mark_solid."""
    from fp import fp_eval
    FP_RENDER_W = 256
    ilo = max(0, lo)
    ihi = min(FP_RENDER_W, hi + 1)
    if ilo >= ihi:
        return list(span_list)
    new = []
    for xlo, xhi, tfn, bfn in span_list:
        xhi_s = 256 if xhi == 0 else xhi
        if xhi_s <= ilo or xlo >= ihi:
            new.append((xlo, xhi, tfn, bfn))
            continue
        if xlo < ilo:
            new.append((xlo, ilo & 0xFF, tfn, bfn))
        if ihi < xhi_s:
            new.append((ihi & 0xFF, xhi, tfn, bfn))
    return new

def expected_result(span_list, lo, hi):
    """Compute expected output as (xlo, xhi, tfn, bfn, inner_top, inner_bot) tuples."""
    result = py_mark_solid(span_list, lo, hi)
    out = []
    for xlo, xhi, tfn, bfn in result:
        xhi_s = 256 if xhi == 0 else xhi
        top_l = fp_eval(tfn, xlo)
        top_r = fp_eval(tfn, xhi_s - 1)
        bot_l = fp_eval(bfn, xlo)
        bot_r = fp_eval(bfn, xhi_s - 1)
        out.append((xlo, xhi, tfn, bfn, max(top_l, top_r), min(bot_l, bot_r)))
    return out

tests = [
    # Single full-screen span, mark middle
    ([(0, 0, (0, 0), (0, 159))], 64, 192),
    # Mark left edge
    ([(0, 0, (0, 0), (0, 159))], 0, 64),
    # Mark right edge
    ([(0, 0, (0, 0), (0, 159))], 192, 255),
    # Mark entire range
    ([(0, 0, (0, 0), (0, 159))], 0, 255),
    # Two spans, mark crossing boundary
    ([(0, 128, (0, 0), (0, 159)), (128, 0, (0, 0), (0, 159))], 96, 160),
    # Sloped top/bot
    ([(0, 0, (10, 50), (-10, 150))], 64, 192),
    # Off-screen (negative lo)
    ([(0, 0, (0, 0), (0, 159))], -50, 50),
    # Off-screen (hi > 255)
    ([(0, 0, (0, 0), (0, 159))], 200, 300),
    # Multiple spans, mark middle
    ([(0, 64, (0, 0), (0, 159)), (64, 128, (5, 20), (-5, 130)),
      (128, 192, (0, 30), (0, 100)), (192, 0, (10, 10), (-10, 140))], 80, 180),
    # Empty mark (ilo >= ihi)
    ([(0, 0, (0, 0), (0, 159))], 100, 99),
]

n_ok, n_fail = 0, 0
for spans_in, lo, hi in tests:
    setup_spans(spans_in)
    ws16(ZP_MS_LO, lo)
    ws16(ZP_MS_HI, hi)
    call(addrs['mark_solid'])
    got = read_spans()
    expected = expected_result(spans_in, lo, hi)
    if got == expected:
        n_ok += 1
    else:
        n_fail += 1
        print(f"  FAIL: lo={lo} hi={hi}")
        print(f"    input: {spans_in}")
        print(f"    expected: {expected}")
        print(f"    got:      {got}")

print(f"\n{n_ok} OK, {n_fail} FAIL")
