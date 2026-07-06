#!/usr/bin/env python3
"""Prove nj_raster.py pixel-exact vs the 6502 rasteriser: hash every line of
the golden corpus (build/raster_ab.json, captured from the 6502 by
tools/raster_ab.py) with the pure-Python drawer and compare sha1 prefixes.
"""
import hashlib, json, os, sys
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), '..'))
os.chdir(os.path.join(os.path.dirname(os.path.abspath(__file__)), '..'))
import nj_raster

GOLD = os.path.join('build', 'raster_ab.json')


def main():
    gold = json.load(open(GOLD))
    bad = 0
    for n, (key, h) in enumerate(gold.items()):
        x0, y0, x1, y1 = map(int, key.split(','))
        fb = nj_raster.new_fb()
        nj_raster.draw_line(fb, x0, y0, x1, y1)
        if hashlib.sha1(bytes(fb)).hexdigest()[:16] != h:
            bad += 1
            if bad <= 10:
                print(f'MISMATCH {key}')
        if n % 10000 == 0:
            print(f'...{n}, {bad} bad', file=sys.stderr)
    print(f'NJ-PYTHON CHECK: {len(gold)} corpus lines, {bad} mismatches — '
          + ('PASS' if bad == 0 else 'FAIL'))
    sys.exit(1 if bad else 0)


if __name__ == '__main__':
    main()
