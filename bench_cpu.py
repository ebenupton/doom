#!/usr/bin/env python3
"""Benchmark the engine in both 6502 and 65C02 modes and verify identical output.

The harness (span_clip_6502) reads DOOM_CPU at import time to pick both the
beebasm -D C02 flag and the py65 MPU class, so each mode must run in its own
subprocess. For each mode we build the angle module with the matching flag, render
the reference positions, sum cycles, and hash the framebuffer. The driver then
compares: 65C02 output MUST be bit-identical to 6502 (only cycles may differ)."""
import os, sys, subprocess, hashlib

FB_LO, FB_HI = 0x5800, 0x6C00


def worker(mode):
    os.environ['DOOM_CPU'] = mode
    os.environ.setdefault('SDL_VIDEODRIVER', 'dummy')
    os.environ.setdefault('PYGAME_HIDE_SUPPORT_PROMPT', '1')
    import pygame; pygame.init()
    import doom_wireframe as dw
    c02 = '1' if mode == '65c02' else '0'
    # angle module is loaded by the harness as a prebuilt .bin -> build it here
    subprocess.run(['./beebasm', '-i', 'slope_div.asm', '-D', 'BANKED=0', '-D', f'C02={c02}'],
                   check=True, capture_output=True)
    from bsp_render_6502 import BspRender6502
    import compare_renders as C
    r = BspRender6502(dw.packed_layout, dw.packed_rom_main, dw.packed_rom_detail,
                      dw.packed_bbox_table, dw.MAP_CENTER_X, dw.MAP_CENTER_Y, dw.PRESCALE)
    tot = 0; hashes = []
    for (px, py, ab) in C.POSITIONS:
        tot += r.render_frame(px, py, ab, dw.player_floor(px, py))
        fb = bytes(r.sc.mpu.memory[FB_LO:FB_HI])
        hashes.append(hashlib.md5(fb).hexdigest()[:8])
    print(f'CYCLES {tot}')
    print(f'NPOS {len(C.POSITIONS)}')
    print('FBHASH ' + ','.join(hashes))


def run_mode(mode):
    out = subprocess.run([sys.executable, __file__, mode], capture_output=True, text=True)
    d = {}
    for line in out.stdout.splitlines():
        if line.startswith('CYCLES'): d['cyc'] = int(line.split()[1])
        elif line.startswith('NPOS'): d['npos'] = int(line.split()[1])
        elif line.startswith('FBHASH'): d['fb'] = line.split(' ', 1)[1]
    if 'cyc' not in d:
        print(f'--- {mode} FAILED ---\n{out.stdout[-1500:]}\n{out.stderr[-1500:]}')
        sys.exit(1)
    return d


def main():
    a = run_mode('6502')
    b = run_mode('65c02')
    same = a['fb'] == b['fb']
    n = a['npos']
    print(f"reference positions      : {n}")
    print(f"6502   total cycles      : {a['cyc']:,}   mean {a['cyc']//n:,}")
    print(f"65C02  total cycles      : {b['cyc']:,}   mean {b['cyc']//n:,}")
    delta = a['cyc'] - b['cyc']
    pct = 100 * delta / a['cyc'] if a['cyc'] else 0
    print(f"saved by 65C02           : {delta:,} cycles ({pct:+.2f}%)")
    print(f"output bit-identical     : {same}")
    if not same:
        print("  MISMATCH — 65C02 build does not match 6502 output!")
        sys.exit(2)


if __name__ == '__main__':
    if len(sys.argv) > 1 and sys.argv[1] in ('6502', '65c02'):
        worker(sys.argv[1])
    else:
        main()
