#!/usr/bin/env python3
"""A/B pixel-identity harness for whole-rasteriser swaps.

Corpus: exhaustive (dx,dy) box 0..96 x 4 direction quadrants x 2 phases,
plus long-line stripes (one axis up to 250) for span/stripe-crossing
coverage. Draw each via RASTER_ENTRY into a cleared FB and hash it.

    python3 tools/raster_ab.py capture   # hash corpus with CURRENT bin
    python3 tools/raster_ab.py check     # compare current bin vs captured
"""
import hashlib
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
GOLD = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..',
                    'build', 'raster_ab.json')


def corpus():
    for dx in range(0, 97):
        for dy in range(0, 97):
            for (sx, sy) in ((1, 1), (1, -1), (-1, 1), (-1, -1)):
                for (bx, by) in ((30, 100), (37, 83)):
                    x0, y0 = bx, by
                    x1, y1 = x0 + sx * dx, y0 + sy * dy
                    if 0 <= x1 <= 255 and 0 <= y1 <= 159:
                        yield (x0, y0, x1, y1)
    for long in range(97, 251, 7):
        for short in range(0, 33, 3):
            for (sx, sy) in ((1, 1), (1, -1), (-1, 1), (-1, -1)):
                x0, y0 = (2 if sx > 0 else 253), (120 if sy < 0 else 20)
                x1, y1 = x0 + sx * long, y0 + sy * short
                if 0 <= x1 <= 255 and 0 <= y1 <= 159:
                    yield (x0, y0, x1, y1)                # shallow long
                x1, y1 = x0 + sx * short, y0 + sy * min(long, 139)
                if 0 <= x1 <= 255 and 0 <= y1 <= 159:
                    yield (x0, y0, x1, y1)                # steep long


def draw_hash(x0, y0, x1, y1):
    for i in range(SIZE):
        mem[SCREEN + i] = 0
    mem[RX0], mem[RY0], mem[RX1], mem[RY1] = x0, y0, x1, y1
    sc._run(0xA900)
    return hashlib.sha1(bytes(mem[SCREEN:SCREEN + SIZE])).hexdigest()[:16]


def main():
    mode = sys.argv[1] if len(sys.argv) > 1 else 'check'
    if mode == 'capture':
        out = {}
        for n, (x0, y0, x1, y1) in enumerate(corpus()):
            out[f'{x0},{y0},{x1},{y1}'] = draw_hash(x0, y0, x1, y1)
            if n % 10000 == 0:
                print(f'...{n}')
        json.dump(out, open(GOLD, 'w'))
        print(f'{len(out)} corpus lines hashed -> {GOLD}')
    else:
        gold = json.load(open(GOLD))
        bad = 0
        for n, (key, h) in enumerate(gold.items()):
            x0, y0, x1, y1 = map(int, key.split(','))
            if draw_hash(x0, y0, x1, y1) != h:
                bad += 1
                if bad <= 10:
                    print(f'MISMATCH {key}')
            if n % 10000 == 0:
                print(f'...{n}, {bad} bad')
        print(f'AB CHECK: {len(gold)} lines, {bad} mismatches')
        sys.exit(1 if bad else 0)


if __name__ == '__main__':
    main()
