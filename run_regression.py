#!/usr/bin/env python3
"""One-shot regression + metrics for the optimization grind.
Rebuilds the angle module, runs all correctness checks, prints a compact
PASS/FAIL summary plus frame cycles and binary sizes. Exit 0 iff all green."""
import os, sys, subprocess, re
os.environ['SDL_VIDEODRIVER'] = 'dummy'
os.environ['PYGAME_HIDE_SUPPORT_PROMPT'] = '1'

ROOT = os.path.dirname(os.path.abspath(__file__))
os.chdir(ROOT)
fails = []

def build(asm):
    r = subprocess.run(['./beebasm', '-i', asm], capture_output=True, text=True)
    out = r.stdout + r.stderr
    if re.search(r'error|Assert', out, re.I):
        fails.append(f'build {asm}: ' + out.strip().splitlines()[-1])
        return False
    return True

# Angle module bin must be rebuilt explicitly (harness loads the .bin).
build('slope_div.asm'); build('bsp_render.asm'); build('span_clip.asm')

def run(label, argv, want):
    try:
        r = subprocess.run([sys.executable] + argv, capture_output=True, text=True, timeout=1200)
    except subprocess.TimeoutExpired:
        fails.append(f'{label}: TIMEOUT'); print(f'  {label}: TIMEOUT'); return ''
    out = r.stdout + r.stderr
    ok = want(out)
    print(f'  {label}: {"OK" if ok else "FAIL"}')
    if not ok:
        fails.append(label)
        print('    ' + '\n    '.join(out.strip().splitlines()[-6:]))
    return out

print('== correctness ==')
run('test_slope_div', ['test_slope_div.py'], lambda o: 'PASS' in o and 'FAIL' not in o)
run('test_bca',       ['test_bca.py'],       lambda o: 'PASS' in o and 'FAIL' not in o)
run('test_bsp_render',['test_bsp_render.py'],lambda o: 'All tests passed' in o)
run('check_angle',    ['check_angle_calls.py'], lambda o: re.search(r'TOTAL .*: 0 differ vs python, 0 differ', o) is not None)
ct = run('compare_traversal', ['compare_traversal.py'], lambda o: o.count('diff=0 px') == 10 and 'DIFFER' not in o)
run('compare_subsector', ['compare_subsector.py'], lambda o: re.search(r'TOTAL:.*0 pixel/span-affecting, 0 px', o) is not None)

# Frame cycles (BspRender6502 reference positions)
print('== frame cycles ==')
try:
    import pygame; pygame.init(); pygame.display.set_mode((1, 1))
    import doom_wireframe as dw
    from bsp_render_6502 import BspRender6502
    import compare_renders as C
    r = BspRender6502(dw.packed_layout, dw.packed_rom_main, dw.packed_rom_detail,
                      dw.packed_bbox_table, dw.MAP_CENTER_X, dw.MAP_CENTER_Y, dw.PRESCALE)
    tot = 0
    for (px, py, ab) in C.POSITIONS:
        tot += r.render_frame(px, py, ab, dw.player_floor(px, py))
    print(f'  TOTAL {tot:,}  MEAN {tot//len(C.POSITIONS):,}')
except Exception as e:
    print(f'  frame-cycle measure error: {e}')

print('== binary sizes ==')
for b in ('span_clip.bin', 'bsp_render.bin', 'bsp_render_ang.bin'):
    if os.path.exists(b):
        print(f'  {b}: {os.path.getsize(b)}')

print('\n' + ('ALL GREEN' if not fails else 'FAILURES: ' + ', '.join(fails)))
sys.exit(1 if fails else 0)
