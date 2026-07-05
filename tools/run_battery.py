#!/usr/bin/env python3
"""Exhaustive pixel-identity battery: plot_run vs the NJ rasteriser.

Every (dx, dy) in the dispatch band (8*dy <= dx), both y directions, a
spread of x bit-phases and y cell-phases: draw via RASTER_ENTRY and via
plot_run into cleared framebuffers and byte-compare.

    python3 tools/run_battery.py quick|full
"""
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), '..'))
os.environ.setdefault('SDL_VIDEODRIVER', 'dummy')
from span_clip_6502 import SpanClip6502
from symmap import sym

sc = SpanClip6502()
mem = sc.mpu.memory
RX0, RY0 = sym('RASTER_ZP_X0'), sym('RASTER_ZP_Y0')
RX1, RY1 = sym('RASTER_ZP_X1'), sym('RASTER_ZP_Y1')
PLOT_RUN = sym('plot_run')
SCREEN, SIZE = sc.SCREEN_START, sc.SCREEN_SIZE


def draw(entry, x0, y0, x1, y1):
    for i in range(SIZE):
        mem[SCREEN + i] = 0
    mem[RX0], mem[RY0], mem[RX1], mem[RY1] = x0, y0, x1, y1
    sc._run(entry)
    return bytes(mem[SCREEN:SCREEN + SIZE])


def main():
    mode = sys.argv[1] if len(sys.argv) > 1 else 'quick'
    if mode == 'quick':
        cases = [(dx, dy) for dx in (8, 16, 33, 64, 100, 200, 255)
                 for dy in (1, 2, 3, 5, 7, 11) if 8 * dy <= dx]
        phases = [(20, 80), (21, 77), (27, 42), (13, 103)]
    else:
        cases = [(dx, dy) for dx in range(8, 256)
                 for dy in range(1, 32) if 8 * dy <= dx]
        phases = [(20, 80), (23, 77)]
    bad = checked = 0
    for (dx, dy) in cases:
        for (bx, by) in phases:
            x0 = min(bx, 255 - dx)
            for y1 in (by - dy, by + dy):
                a = draw(0xA900, x0, by, x0 + dx, y1)
                b = draw(PLOT_RUN, x0, by, x0 + dx, y1)
                checked += 1
                if a != b:
                    bad += 1
                    if bad <= 5:
                        na = sum(bin(v).count('1') for v in a)
                        nb = sum(bin(v).count('1') for v in b)
                        print(f'MISMATCH dx={dx} dy={dy} ({x0},{by})->'
                              f'({x0+dx},{y1}) nj={na}px run={nb}px')
        if checked % 2000 < len(phases) * 2:
            print(f'...{checked} checked, {bad} bad')
    print(f'BATTERY: {checked} draws compared, {bad} mismatches')
    sys.exit(1 if bad else 0)


if __name__ == '__main__':
    main()
