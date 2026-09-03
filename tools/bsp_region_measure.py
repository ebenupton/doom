#!/usr/bin/env python3
"""Region pose battery for the overnight tree polish (2026-09-03).

Renders a FIXED battery on the BANKED rig (what ships) in a fixed
order and reports per-pose cycles.  Optional argv[1] = candidate wad
(set as DOOM_ALT_WAD before doom_wireframe imports); argv[2] = tag.

Battery: spawn room, the spawn<->armour hallway (the PRIORITY views),
the armour room, the east courtyard, and the known heavy pose.
"""
import os, sys, json
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
if len(sys.argv) > 1 and sys.argv[1] != '-':
    os.environ['DOOM_ALT_WAD'] = sys.argv[1]
TAG = sys.argv[2] if len(sys.argv) > 2 else os.environ.get('DOOM_ALT_WAD', 'shipped')
os.environ.setdefault('SDL_VIDEODRIVER', 'dummy')
os.environ['PYGAME_HIDE_SUPPORT_PROMPT'] = '1'
import pygame; pygame.init(); pygame.display.set_mode((1, 1))
import doom_wireframe as dw
from banked_bsp import BankedBspRender

BATTERY = [
    ('S-N ', 1056, -3616,  64, 'spawn'),
    ('S-W *', 1056, -3616, 128, 'spawn'),
    ('S-E ', 1056, -3616,   0, 'spawn'),
    ('S-S ', 1056, -3616, 192, 'spawn'),
    ('S2-W*',  880, -3500, 128, 'spawn'),
    ('S3-E ', 1300, -3500,   0, 'spawn'),
    ('H1-W*',  704, -3488, 128, 'hall'),
    ('H2-W*',  448, -3392, 128, 'hall'),
    ('H2-E*',  448, -3392,   0, 'hall'),
    ('H3-E*',  256, -3300,   0, 'hall'),
    ('A-E *', -224, -3232,   0, 'armour'),
    ('A-N ', -224, -3232,  64, 'armour'),
    ('A2-SE', -416, -3040, 224, 'armour'),
    ('C1-W ', 1984, -3232, 128, 'court'),
    ('C2-E ', 1600, -3232,   0, 'court'),
    ('C3-N ', 2200, -3500,  64, 'court'),
    ('C4-W ', 2560, -3100, 128, 'court'),
    ('HV   ', 1133, -3242, 144, 'heavy'),
]

VERIFY = [( -224, -3232,   0), (1056, -3616,  64), (2560, -3100, 128),
          ( 704, -3488, 128)]

def main():
    r = BankedBspRender(dw.packed_layout, dw.packed_rom_main,
                        dw.packed_rom_detail, dw.packed_bbox_table,
                        dw.MAP_CENTER_X, dw.MAP_CENTER_Y, dw.PRESCALE)
    # VERIFIED NUMBERS ONLY (2026-09-03, the shuf8 lesson: a broken tree
    # renders NOTHING and looks like a -95% miracle): FB-diff four poses
    # against the float reference before measuring anything.  OBJECTS OFF
    # for the verify frames -- pyref draws no billboards (the documented
    # OBJ_DRAW gap); with the bitmap seeded every object-visible pose
    # false-fails by its billboard pixels (the 16x 44-byte red herring).
    sys.path.insert(0, os.path.join(os.path.dirname(os.path.dirname(
        os.path.abspath(__file__))), 'tools'))
    import pyref_render
    from bsp_render_6502 import disable_objects
    disable_objects(r.sc.mpu.memory)
    vbad = 0
    for (vx, vy, vab) in VERIFY:
        r.render_frame(vx, vy, vab, dw.player_floor(vx, vy))
        fb = bytes(r.sc.mpu.memory[0x5800:0x6C00])
        ref, _ = pyref_render.render_ref_fb(vx, vy, vab)
        nd = sum(1 for a, b in zip(fb, ref) if a != b)
        if nd > 8:                       # seam-wobble tolerance; a broken
            vbad += 1                    # tree diffs by tens-to-hundreds
            print(f'  VERIFY FAIL ({vx},{vy},{vab}): {nd} FB bytes differ')
    if vbad:
        print(f'== battery [{TAG}] == UNRELIABLE: {vbad} verify failures')
        return
    # battery WITH objects (comparable to the shipped baseline): reseed
    L = dw.packed_layout
    _anyb = __import__('symmap').sym('OBJ_ANYB', banked=1)
    _bits = L['off_obj'] + 7 * L['n_obj']
    for i in range(L['obj_bits_len']):
        r.sc.mpu.memory[_anyb + i] = dw.packed_rom_main[_bits + i]
    out = {}
    groups = {}
    print(f'== battery [{TAG}] ==')
    for name, x, y, ab, grp in BATTERY:
        c = r.render_frame(x, y, ab, dw.player_floor(x, y))
        out[name.strip()] = c
        groups.setdefault(grp, []).append(c)
        flag = ' <<<< OVER 250k' if c > 250_000 and grp in ('spawn', 'court') else ''
        print(f'  {name} ({x:5d},{y:6d},{ab:3d}) {c:8,}{flag}')
    print('-- groups --')
    for g, cs in groups.items():
        print(f'  {g:7s} n={len(cs)} total={sum(cs):9,} max={max(cs):8,}')
    pri = [out[n.strip()] for n, *_r in [(b[0],) for b in BATTERY] if '*' in n]
    print(f'  PRIORITY total={sum(pri):9,} max={max(pri):8,}')
    print(f'  BATTERY  total={sum(out.values()):9,}')
    json.dump(out, open(f'/tmp/battery_{TAG.replace("/","_")}.json', 'w'))

if __name__ == '__main__':
    main()
