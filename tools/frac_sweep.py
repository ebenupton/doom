#!/usr/bin/env python3
"""Fractional walker-grid divergence sweep (2026-07-25, autonomous grind).

Walker positions live on the 8.8 grid; the integer-pose suite never
samples it (the zp_ys_v1ok cull-leak hid there). Sweep jittered poses
around known-walkable anchors:
  gate 1: engine vs the PYTHON MIRROR (pyref) — any diff byte = a real
          cross-impl bug (the exactness contract);
  gate 2: engine vs FLOAT (verify displacement) — miss > 8px flagged as
          structural (the 1-2px band = the recorded quantization alias).
Prints a ranked hit list; reproducible via --seed.
"""
import os, sys, random, argparse
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), '..'))
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
os.chdir(os.path.join(os.path.dirname(os.path.abspath(__file__)), '..'))
os.environ.setdefault('SDL_VIDEODRIVER', 'dummy')
os.environ.setdefault('PYGAME_HIDE_SUPPORT_PROMPT', '1')
import pygame; pygame.init(); pygame.display.set_mode((1, 1))
import doom_wireframe as dw
import pyref_render
import verify_6502_vs_python as V
from bsp_render_6502 import BspRender6502

ANCHORS = [(1056, -3616), (1024, -3500), (1500, -3700), (800, -3400),
           (1200, -3000), (2112, -2368), (1984, -2496), (1856, -2368),
           (2500, -2600), (1792, -3351), (1400, -3650), (2345, -3123),
           (192, -2368), (3648, -2368), (3648, -4800), (-486, -3307)]

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--n', type=int, default=64)
    ap.add_argument('--seed', type=int, default=1)
    args = ap.parse_args()
    rng = random.Random(args.seed)

    r = BspRender6502(dw.packed_layout, dw.packed_rom_main, dw.packed_rom_detail,
                      dw.packed_bbox_table, dw.MAP_CENTER_X, dw.MAP_CENTER_Y,
                      dw.PRESCALE)
    hits = []
    for k in range(args.n):
        ax, ay = ANCHORS[k % len(ANCHORS)]
        # jitter on the exact 8.8 grid: +/- 16 world units in 1/32 steps
        px = ax + rng.randint(-512, 512) / 32.0
        py = ay + rng.randint(-512, 512) / 32.0
        ab = rng.randint(0, 255)
        try:
            r.render_frame(px, py, ab, dw.player_floor(px, py))
        except Exception as e:
            print(f'[{k}] ({px},{py},{ab}) ENGINE EXC: {e}')
            continue
        sc = r.sc
        if sc.mpu.pc != 0xFF00:
            print(f'[{k}] ({px},{py},{ab}) TRUNCATED frame')
            hits.append((99999, px, py, ab, 'truncated'))
            continue
        fb = bytes(sc.mpu.memory[sc.SCREEN_START:sc.SCREEN_START + 5120])
        ref, _ = pyref_render.render_ref_fb(px, py, ab)
        nd = sum(1 for a, b in zip(fb, bytes(ref)) if a != b)
        tag = ''
        if nd:
            tag = f'MIRROR diff {nd}B'
            hits.append((nd, px, py, ab, tag))
        else:
            mo, no, mm, nm, cyc, done = V.compare(px, py, ab)
            if mm > 8 or mo > 8:
                tag = f'float over={mo}px({no}) miss={mm}px({nm})'
                hits.append((max(mm, mo), px, py, ab, tag))
        print(f'[{k}] ({px:.5f},{py:.5f},{ab}) {"OK" if not tag else tag}')
    print('\n=== ranked hits ===')
    for s, px, py, ab, tag in sorted(hits, reverse=True):
        print(f'  ({px},{py},{ab}): {tag}')
    print(f'{len(hits)} hits / {args.n} poses')

if __name__ == '__main__':
    main()
