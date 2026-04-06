#!/usr/bin/env python3
"""Unit test for native 6502 tighten against Python FPClipSpans.tighten."""
import os
os.environ['SDL_VIDEODRIVER'] = 'dummy'
os.environ['PYGAME_HIDE_SUPPORT_PROMPT'] = '1'
import pygame; pygame.init(); pygame.display.set_mode((1, 1))

import doom_wireframe as dw
import fe6502
import subprocess
from wad_packed import SPAN_HDR, SPAN_SIZE, read_all_spans, write_all_spans
from fp import fp_eval

fe = fe6502.Frontend6502(dw.packed_rom_banks, dw.packed_rom_recip,
                          dw.packed_bbox_table, dw.packed_layout)
mpu = fe.mpu
mem = mpu.memory

r = subprocess.run(['./beebasm', '-i', 'doom_fe.asm', '-v'],
                    capture_output=True, text=True)
addrs = {}
for i, line in enumerate(r.stdout.split('\n')):
    s = line.strip()
    if s in ('.tighten',):
        nl = r.stdout.split('\n')[i+1].strip()
        addrs[s[1:]] = int(nl.split()[0], 16)
print(f"tighten at ${addrs['tighten']:04X}")

SPANS_BASE = 0x20D0
ZP_MS_LO = 0xF0
ZP_MS_HI = 0xF2
# tighten expects sx/y values at $60-$67 + zp_tg_ox0 ($90) / ox1 ($92)
ZP_Y1 = 0x60  # yt1 (fp_linfn)
ZP_Y2 = 0x62  # yt2
ZP_SX1 = 0x64  # sx1
ZP_SX2 = 0x66  # sx2
ZP_TG_OX0 = 0x90  # stash for yb1
ZP_TG_OX1 = 0x92  # stash for yb2

def ws16(a, v):
    mem[a] = v & 0xFF
    mem[a+1] = (v >> 8) & 0xFF

def call(addr):
    mpu.sp = 0xFD
    mem[0x01FF] = 0xFE
    mem[0x01FE] = 0xFF
    mpu.pc = addr
    for _ in range(200000):
        pc = mpu.pc
        if pc == 0xFF00 or pc == 0x0000:
            break
        mpu.step()

def setup_spans(span_list):
    """Write list of (xlo, xhi, tfn, bfn) to SPANS_BASE."""
    mem[SPANS_BASE] = len(span_list)
    mem[SPANS_BASE + 1] = 0
    for i, (xlo, xhi, tfn, bfn) in enumerate(span_list):
        o = SPANS_BASE + SPAN_HDR + i * SPAN_SIZE
        mem[o + 0] = xlo & 0xFF
        mem[o + 1] = xhi & 0xFF
        ws16(o + 2, tfn[0])
        ws16(o + 4, bfn[0])
        ws16(o + 6, tfn[1])
        ws16(o + 8, bfn[1])
        xhi_s = 256 if xhi == 0 else xhi
        ws16(o + 10, max(fp_eval(tfn, xlo), fp_eval(tfn, xhi_s - 1)))
        ws16(o + 12, min(fp_eval(bfn, xlo), fp_eval(bfn, xhi_s - 1)))

def read_spans():
    return read_all_spans(mem, SPANS_BASE)

def py_tighten(span_list, lo, hi, sx1, sx2, yt1, yt2, yb1, yb2):
    clip = dw.FPClipSpans()
    clip.spans = []
    for xlo, xhi, tfn, bfn in span_list:
        xhi_s = 256 if xhi == 0 else xhi
        it = max(fp_eval(tfn, xlo), fp_eval(tfn, xhi_s - 1))
        ib = min(fp_eval(bfn, xlo), fp_eval(bfn, xhi_s - 1))
        ot = min(fp_eval(tfn, xlo), fp_eval(tfn, xhi_s - 1))
        ob = max(fp_eval(bfn, xlo), fp_eval(bfn, xhi_s - 1))
        clip.spans.append((xlo, xhi_s, tfn, bfn, it, ib, ot, ob))
    clip.tighten(lo, hi, sx1, sx2, yt1, yt2, yb1, yb2, False, False)
    return clip.spans

tests = [
    # Single full-screen span, tighten middle with a sloped top
    ([(0, 0, (0, 0), (0, 159))], 64, 192, 64, 192, 20, 30, 100, 100),
    # Tighten with slopes that match source (no change)
    ([(0, 0, (0, 0), (0, 159))], 0, 255, 0, 255, 0, 0, 159, 159),
    # Tighten a portion with new bounds both tighter
    ([(0, 0, (0, 0), (0, 159))], 50, 200, 50, 200, 40, 60, 110, 110),
    # Multiple spans
    ([(0, 64, (0, 0), (0, 159)), (64, 128, (5, 20), (-5, 130)),
      (128, 192, (0, 30), (0, 100)), (192, 0, (10, 10), (-10, 140))],
     70, 180, 70, 180, 50, 50, 100, 100),
    # Tighten with top dominating throughout
    ([(0, 0, (0, 0), (0, 159))], 0, 255, 0, 255, 50, 50, 150, 150),
]

n_ok, n_fail = 0, 0
for spans_in, lo, hi, sx1, sx2, yt1, yt2, yb1, yb2 in tests:
    setup_spans(spans_in)
    ws16(ZP_MS_LO, lo)
    ws16(ZP_MS_HI, hi)
    ws16(ZP_Y1, yt1)
    ws16(ZP_Y2, yt2)
    ws16(ZP_SX1, sx1)
    ws16(ZP_SX2, sx2)
    ws16(ZP_TG_OX0, yb1)
    ws16(ZP_TG_OX1, yb2)
    call(addrs['tighten'])
    got = read_spans()
    py_result = py_tighten(spans_in, lo, hi, sx1, sx2, yt1, yt2, yb1, yb2)
    # Compare ignoring outer_top/outer_bot (asm doesn't store them)
    got_simple = [(s[0], s[1], s[2], s[3], s[4], s[5]) for s in got]
    py_simple = [(s[0], s[1], s[2], s[3], s[4], s[5]) for s in py_result]
    if got_simple == py_simple:
        n_ok += 1
    else:
        n_fail += 1
        print(f"  FAIL: lo={lo} hi={hi} sx=({sx1},{sx2}) yt=({yt1},{yt2}) yb=({yb1},{yb2})")
        print(f"    in: {spans_in}")
        print(f"    expected ({len(py_simple)}):")
        for s in py_simple: print(f"      {s}")
        print(f"    got ({len(got_simple)}):")
        for s in got_simple: print(f"      {s}")

print(f"\n{n_ok} OK, {n_fail} FAIL")
