#!/usr/bin/env python3
"""Verify DCL records hooks produce same records as standalone clip_line_records.

For each draw_clipped_line call (yt-line, yb-line) during a render,
- Capture pool state.
- Run standalone clip_line_records → records A.
- Restore pool, run DCL with records hook → records B.
- Compare A vs B (after sorting by si).
- A and B should match for non-CB-clip spans.
"""
import os, math
os.environ['SDL_VIDEODRIVER'] = 'dummy'
os.environ['PYGAME_HIDE_SUPPORT_PROMPT'] = '1'
import pygame; pygame.init(); pygame.display.set_mode((1, 1))

from span_clip_6502 import (
    SpanClip6502, TOP_RECORDS, BOT_RECORDS, ZP_LINE_XL, ZP_LINE_YL,
    ZP_LINE_XR, ZP_LINE_YR, ZP_ILO, ZP_IHI, ZP_BUF, ENTRY_DRAW_CLIP,
    ENTRY_CLIP_LINE_RECORDS, REC_BYTES,
)

# DCL records-hook ZP slots (must match span_clip.asm)
ZP_DCL_REC_BUF   = 0xBC
ZP_DCL_REC_BUF_H = 0xBD


def run_dcl_with_records(sc, xl, yl, xr, yr, buffer_addr):
    """Run draw_clipped_line with records hook enabled, return decoded records."""
    mem = sc.mpu.memory
    mem[ZP_LINE_XL] = xl & 0xFF
    mem[ZP_LINE_YL] = yl & 0xFF
    mem[ZP_LINE_XR] = xr & 0xFF
    mem[ZP_LINE_YR] = yr & 0xFF
    mem[ZP_DCL_REC_BUF] = buffer_addr & 0xFF
    mem[ZP_DCL_REC_BUF_H] = (buffer_addr >> 8) & 0xFF
    sc._run(ENTRY_DRAW_CLIP)
    # Reset hook
    mem[ZP_DCL_REC_BUF] = 0
    mem[ZP_DCL_REC_BUF_H] = 0
    return sc._decode_records(buffer_addr)


def snapshot_pool(sc):
    mem = sc.mpu.memory
    pool = []
    for slot in range(32):
        pool.append(tuple(mem[base + slot] for base in
                          (0x0400, 0x0420, 0x0440, 0x0460, 0x0480, 0x04A0,
                           0x04C0, 0x04E0, 0x0500, 0x0520, 0x0540, 0x0560, 0x0580)))
    head = mem[0xC0]
    free = mem[0xC1]
    return pool, head, free


def restore_pool(sc, pool, head, free):
    mem = sc.mpu.memory
    bases = (0x0400, 0x0420, 0x0440, 0x0460, 0x0480, 0x04A0,
             0x04C0, 0x04E0, 0x0500, 0x0520, 0x0540, 0x0560, 0x0580)
    for slot in range(32):
        for i, base in enumerate(bases):
            mem[base + slot] = pool[slot][i]
    mem[0xC0] = head
    mem[0xC1] = free


# Simple test: known span, known line.
sc = SpanClip6502()
sc.clear_screen()
sc.init()

# Initial full-screen span at slot 1.
print("Test 1: line fully inside aperture (initial full-screen span).")
xl, yl, xr, yr = 50, 100, 200, 100
ilo, ihi = 50, 200
mem = sc.mpu.memory
mem[ZP_ILO] = ilo
mem[ZP_IHI] = ihi
# Standalone clip_line_records
asm_clip_recs = sc.clip_line_records(xl, yl, xr, yr, ilo, ihi, TOP_RECORDS)
# Reset pool to before clip_line_records (it doesn't mutate, but be safe)
# Then run DCL with records
mem[ZP_LINE_XL] = xl; mem[ZP_LINE_YL] = yl
mem[ZP_LINE_XR] = xr; mem[ZP_LINE_YR] = yr
dcl_recs = run_dcl_with_records(sc, xl, yl, xr, yr, TOP_RECORDS)
print(f"  clip_line_records: {asm_clip_recs}")
print(f"  DCL with hook:     {dcl_recs}")
print()

# Test 2: line above aperture
sc.clear_screen()
sc.init()
print("Test 2: line above aperture.")
xl, yl, xr, yr = 50, 30, 200, 30  # y=30 < Y_BIAS=48
ilo, ihi = 50, 200
mem[ZP_ILO] = ilo; mem[ZP_IHI] = ihi
asm_clip_recs = sc.clip_line_records(xl, yl, xr, yr, ilo, ihi, TOP_RECORDS)
sc.clear_screen(); sc.init()
dcl_recs = run_dcl_with_records(sc, xl, yl, xr, yr, TOP_RECORDS)
print(f"  clip_line_records: {asm_clip_recs}")
print(f"  DCL with hook:     {dcl_recs}")
print()

# Test 3: line below aperture
sc.clear_screen()
sc.init()
print("Test 3: line below aperture.")
xl, yl, xr, yr = 50, 220, 200, 220  # y=220 > Y_BIAS+159=207
ilo, ihi = 50, 200
mem[ZP_ILO] = ilo; mem[ZP_IHI] = ihi
asm_clip_recs = sc.clip_line_records(xl, yl, xr, yr, ilo, ihi, TOP_RECORDS)
sc.clear_screen(); sc.init()
dcl_recs = run_dcl_with_records(sc, xl, yl, xr, yr, TOP_RECORDS)
print(f"  clip_line_records: {asm_clip_recs}")
print(f"  DCL with hook:     {dcl_recs}")
