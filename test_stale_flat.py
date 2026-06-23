#!/usr/bin/env python3
"""Catch stale flat-address reads in the banked build. build_banked copies tables
into banks but leaves the original flat copies resident, so a banked code path
that still reads a flat address passes in the model but fails on real HW (zeros).
Zero each moved flat region in the model, re-render, and see which one breaks."""
import os
os.environ.setdefault('SDL_VIDEODRIVER', 'dummy')
os.environ.setdefault('PYGAME_HIDE_SUPPORT_PROMPT', '1')
import pygame; pygame.init()
import doom_wireframe as dw
from banked_bsp import BankedBspRender
FB=(0x5800,0x8000)

# moved flat regions (old flat base, length) -> now in bank/LOW
REGIONS = {
 'ROM_MAIN $6C00': (0x6C00, 0x2000),
 'sqr $A500':      (0xA500, 0x400),
 'FHCH $B600':     (0xB600, 0x1000),
 'bbox $C600':     (0xC600, 0x800),
 'trig $DC00':     (0xDC00, 0x400),
 'VWH $E484':      (0xE484, 0x600),
 'recip $E000':    (0xE000, 0x484),
 'TA_HI $F200':    (0xF200, 0x401),
 'VATOX $F601':    (0xF601, 0x401),
}

def mk():
    return BankedBspRender(dw.packed_layout, dw.packed_rom_main, dw.packed_rom_detail,
                           dw.packed_bbox_table, dw.MAP_CENTER_X, dw.MAP_CENTER_Y, dw.PRESCALE)

def render_nz(r, zero=()):
    for (a,n) in zero:
        for i in range(n): r.bm[a+i]=0
    r.render_frame(1056,-3616,128, dw.player_floor(1056,-3616))
    return sum(1 for b in r.bm[FB[0]:FB[1]] if b)

def main():
    base = render_nz(mk())
    print(f"baseline (nothing zeroed): {base} nz")
    # zero ALL moved regions at once
    allz = render_nz(mk(), list(REGIONS.values()))
    print(f"all moved flat regions zeroed: {allz} nz")
    if allz == base:
        print("-> no stale flat reads; bug is elsewhere"); return
    # binary-isolate: zero each region alone
    for name,(a,n) in REGIONS.items():
        nz = render_nz(mk(), [(a,n)])
        flag = '  <-- STALE READ' if nz != base else ''
        print(f"  zero {name:16s}: {nz} nz{flag}")

if __name__=='__main__':
    main()
