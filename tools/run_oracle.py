#!/usr/bin/env python3
"""Extract NJ rasteriser run-length sequences from the emulator (the oracle).

For each (dx, dy) in the shallow dispatch band, draw the line via
RASTER_ENTRY into a cleared framebuffer, read back the lit pixels, and
record the per-row run lengths. Verifies the sequence is a pure function
of (dx, dy, y-direction) — independent of x0 bit phase and cell phase —
then writes build/nj_runs.json for the recurrence derivation.

    python3 tools/run_oracle.py quick    # small sample, phase checks
    python3 tools/run_oracle.py full     # whole band (slow, one-off)
"""
import json
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
SCREEN, SIZE = sc.SCREEN_START, sc.SCREEN_SIZE


def draw_and_extract(x0, y0, x1, y1):
    """Clear FB, draw via NJ, return {row: (xmin, xmax)} of lit pixels."""
    for i in range(SIZE):
        mem[SCREEN + i] = 0
    mem[RX0], mem[RY0], mem[RX1], mem[RY1] = x0, y0, x1, y1
    sc._run(0xA900)
    rows = {}
    for i in range(SIZE):
        b = mem[SCREEN + i]
        if not b:
            continue
        cell = i // 8
        y = (cell // 32) * 8 + (i & 7)
        xbase = (cell % 32) * 8
        for bit in range(8):
            if b & (0x80 >> bit):
                x = xbase + bit
                lo, hi = rows.get(y, (x, x))
                rows[y] = (min(lo, x), max(hi, x))
    return rows


def runs_of(x0, y0, x1, y1):
    """Per-row (in y order from y0 end) run lengths + continuity check."""
    rows = draw_and_extract(x0, y0, x1, y1)
    ys = sorted(rows)
    # continuity: rows must be consecutive, runs must abut in x
    assert ys == list(range(ys[0], ys[-1] + 1)), 'row gap'
    seq = []
    step = 1 if x1 >= x0 else -1
    ordered = ys if y1 >= y0 else list(reversed(ys))
    prev_end = None
    for y in ordered:
        lo, hi = rows[y]
        seq.append(hi - lo + 1)
        edge = lo if step > 0 else hi
        if prev_end is not None:
            assert edge == prev_end + step, f'x discontinuity at row {y}'
        prev_end = (hi if step > 0 else lo)
    total = sum(seq)
    assert total == abs(x1 - x0) + 1, f'pixel count {total} != dx+1'
    return seq


def main():
    mode = sys.argv[1] if len(sys.argv) > 1 else 'quick'
    out = {}
    if mode == 'quick':
        cases = [(dx, dy) for dx in (16, 33, 64, 100, 200, 255)
                 for dy in (1, 2, 3, 5, 7) if 4 * dy <= dx]
    else:
        cases = [(dx, dy) for dx in range(8, 256)
                 for dy in range(1, dx // 4 + 1) if 4 * dy <= dx]
    checked = 0
    for (dx, dy) in cases:
        x0 = min(20, 255 - dx)                         # keep the line on-screen
        y0 = 80                                        # dy <= 63 fits both ways
        base = runs_of(x0, y0, x0 + dx, y0 - dy)       # y decreasing on screen
        up = runs_of(x0, y0, x0 + dx, y0 + dy)         # y increasing
        out[f'{dx},{dy},d'] = base
        out[f'{dx},{dy},u'] = up
        if mode == 'quick':
            # phase independence: x bit phase, cell phase, y phase
            for (px, py) in ((21, 101), (27, 77), (13, 42)):
                px = min(px, 255 - dx)
                assert runs_of(px, py, px + dx, py - dy) == base, (dx, dy, px, py, 'd')
                assert runs_of(px, py, px + dx, py + dy) == up, (dx, dy, px, py, 'u')
        checked += 1
        if checked % 200 == 0:
            print(f'{checked}/{len(cases)}')
    path = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..',
                        'build', 'nj_runs.json')
    with open(path, 'w') as f:
        json.dump(out, f)
    print(f'{checked} (dx,dy) cases -> {path}')


if __name__ == '__main__':
    main()
