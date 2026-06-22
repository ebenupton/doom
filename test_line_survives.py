#!/usr/bin/env python3
"""Unit test for native 6502 line_survives against Python FPClipSpans.line_survives."""
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

# Find line_survives address
r = subprocess.run(['./beebasm', '-D', 'BANKED=0', '-i', 'doom_fe.asm', '-v'],
                    capture_output=True, text=True)
ls_addr = None
for i, line in enumerate(r.stdout.split('\n')):
    if line.strip() == '.line_survives':
        nl = r.stdout.split('\n')[i+1].strip()
        ls_addr = int(nl.split()[0], 16)
        break
print(f"line_survives at ${ls_addr:04X}")

SPANS_BASE = 0x20D0
SPAN_HDR = 2
SPAN_SIZE = 16

# ZP slots for line_survives args
ZP_LS_X1 = 0xC6
ZP_LS_Y1 = 0xC8
ZP_LS_X2 = 0xCA
ZP_LS_Y2 = 0xCC

def ws16(addr, v):
    mem[addr] = v & 0xFF
    mem[addr + 1] = (v >> 8) & 0xFF

def write_span(i, xlo, xhi, inner_top, inner_bot):
    # New span layout: s16 slopes at +2/+4, intercepts at +6/+8, inner at +10/+12.
    o = SPANS_BASE + SPAN_HDR + i * SPAN_SIZE
    mem[o + 0] = xlo & 0xFF
    mem[o + 1] = xhi & 0xFF
    ws16(o + 2, 0); ws16(o + 4, 0)
    ws16(o + 6, inner_top); ws16(o + 8, inner_bot)
    ws16(o + 10, inner_top); ws16(o + 12, inner_bot)

def set_spans(specs):
    mem[SPANS_BASE] = len(specs)
    for i, s in enumerate(specs):
        write_span(i, *s)

def call_ls(lx1, ly1, lx2, ly2):
    ws16(ZP_LS_X1, lx1)
    ws16(ZP_LS_Y1, ly1)
    ws16(ZP_LS_X2, lx2)
    ws16(ZP_LS_Y2, ly2)
    mpu.sp = 0xFD
    mem[0x01FF] = 0xFE
    mem[0x01FE] = 0xFF
    mpu.pc = ls_addr
    for _ in range(5000):
        pc = mpu.pc
        if pc == 0xFF00 or pc == 0x0000:
            break
        mpu.step()
    return (mpu.p & 0x01) != 0

def py_ls(specs, lx1, ly1, lx2, ly2):
    """Mirror FPClipSpans.line_survives."""
    if abs(lx1 - lx2) < 1:
        return False
    xl, xr = (lx1, lx2) if lx1 <= lx2 else (lx2, lx1)
    y_lo, y_hi = min(ly1, ly2), max(ly1, ly2)
    found = False
    for xlo, xhi, it, ib in specs:
        xhi_eff = 256 if xhi == 0 else xhi
        if xhi_eff <= xl or xlo >= xr:
            continue
        found = True
        if y_lo < it or y_hi > ib:
            return False
    return found

tests = [
    # Line entirely inside a single span's inner bbox
    ([(0, 0, 0, 159)], 10, 20, 100, 40),
    # Line with y below inner_top (fails)
    ([(0, 0, 50, 100)], 10, 20, 100, 60),
    # Line with y above inner_bot (fails)
    ([(0, 0, 50, 100)], 10, 60, 100, 150),
    # Line outside x range of any span
    ([(50, 100, 0, 159)], 10, 20, 40, 40),
    # Zero-width line (fails)
    ([(0, 0, 0, 159)], 10, 20, 10, 60),
    # Line spans two spans, both survive
    ([(0, 128, 0, 159), (128, 0, 0, 159)], 10, 20, 200, 100),
    # Line spans two, second fails
    ([(0, 128, 0, 159), (128, 0, 50, 100)], 10, 20, 200, 150),
    # Negative line
    ([(0, 0, 0, 159)], -50, 30, -10, 40),  # outside spans, found=False
    # Cross-x line
    ([(0, 128, 0, 159)], -10, 30, 50, 40),
    # Narrow check
    ([(0, 0, 0, 159)], 0, 0, 255, 159),
]

n_ok, n_fail = 0, 0
for specs, lx1, ly1, lx2, ly2 in tests:
    set_spans([(xl, xh, it, ib) for xl, xh, it, ib in specs])
    asm = call_ls(lx1, ly1, lx2, ly2)
    py = py_ls(specs, lx1, ly1, lx2, ly2)
    ok = asm == py
    if ok:
        n_ok += 1
    else:
        n_fail += 1
        print(f"  FAIL: spans={specs} line=({lx1},{ly1})-({lx2},{ly2}) asm={asm} py={py}")
print(f"{n_ok} OK, {n_fail} FAIL")
