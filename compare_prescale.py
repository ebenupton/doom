#!/usr/bin/env python3
"""Render each baseline position under both prescales and compare counts."""
import os, sys
os.environ['SDL_VIDEODRIVER'] = 'dummy'
os.environ['PYGAME_HIDE_SUPPORT_PROMPT'] = '1'
import pygame; pygame.init(); pygame.display.set_mode((1, 1))

# Subprocess under each prescale
import subprocess, json, textwrap

SCRIPT = textwrap.dedent("""
    import os, sys, math, json
    os.environ['SDL_VIDEODRIVER'] = 'dummy'
    os.environ['PYGAME_HIDE_SUPPORT_PROMPT'] = '1'
    import pygame; pygame.init(); pygame.display.set_mode((1,1))
    import doom_wireframe as dw
    from fe6502 import Frontend6502
    fe = Frontend6502(dw.packed_rom_banks, dw.packed_rom_recip,
                      dw.packed_bbox_table, dw.packed_layout)
    POSITIONS = [
        (1056, -3616, 64), (1056, -3616, 0), (1056, -3616, 32),
        (1056, -3616, 96), (1200, -3300, 64),
    ]
    out = []
    for px, py, ab in POSITIONS:
        fz = dw.player_floor(px, py)
        cmds, cyc = fe.render_frame(px, py, ab, fz)
        n_seg = sum(1 for c in cmds if c[0] in 'SP')
        n_portal = sum(1 for c in cmds if c[0] == 'P')
        out.append({'pos': [px, py, ab], 'segs': n_seg, 'portals': n_portal,
                    'cycles': cyc, 'total_cmds': len(cmds)})
    # Also Python FP mul count for the first position
    dw.fp_module.mul_reset()
    px_88 = int((1056 - dw.MAP_CENTER_X) * 256 / dw.PRESCALE)
    py_88 = int((-3616 - dw.MAP_CENTER_Y) * 256 / dw.PRESCALE)
    vz_ps = dw._prescale_height(dw.player_floor(1056, -3616) + 41)
    sc = dw.fp_sincos(64)
    ctx = dw.fp_view_context(px_88, py_88, sc)
    ang_rad = dw.byte_to_radians(64)
    cos_f, sin_f = math.cos(ang_rad), math.sin(ang_rad)
    tmp = pygame.Surface((dw.FP_RENDER_W, dw.FP_RENDER_H))
    dw.render_bsp_fp(len(dw.nodes) - 1, dw.FPClipSpans(), ctx, vz_ps,
                     1056, -3616, cos_f, sin_f, tmp,
                     [None] * len(dw.vertexes), [None] * len(dw.vwh_table))
    print("RESULT", json.dumps({'prescale': dw.PRESCALE, 'positions': out,
                                 'fp_muls': dict(dw.fp_module.mul_counts)}))
""")

def run(prescale):
    env = {**os.environ, 'DOOM_PRESCALE': str(prescale)}
    r = subprocess.run([sys.executable, '-c', SCRIPT], capture_output=True,
                       text=True, env=env)
    for line in r.stdout.splitlines():
        if line.startswith('RESULT '):
            return json.loads(line[7:])
    print("failed:", r.stderr)
    return None

r8 = run(8)
r16 = run(16)
print(f"\n{'pos':25s} {'p8 segs':>8s} {'p16 segs':>9s} {'p8 cyc':>10s} {'p16 cyc':>10s}  ratio")
print("-" * 75)
for a, b in zip(r8['positions'], r16['positions']):
    ratio = b['cycles'] / a['cycles'] if a['cycles'] else 0
    print(f"  pos{a['pos']!r:22s} {a['segs']:>8d} {b['segs']:>9d} "
          f"{a['cycles']:>10d} {b['cycles']:>10d}  {ratio:.2f}x")
print()
print(f"FP muls (spawn East):")
print(f"  prescale=8:  {r8['fp_muls']}  (total {sum(r8['fp_muls'].values())})")
print(f"  prescale=16: {r16['fp_muls']}  (total {sum(r16['fp_muls'].values())})")
