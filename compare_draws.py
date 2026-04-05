#!/usr/bin/env python3
"""Count segs processed/drawn and back-face culls in the Python FP path.
Run under each prescale via subprocess and compare."""
import os, sys, subprocess, json, textwrap

SCRIPT = textwrap.dedent("""
    import os, sys, math, json
    os.environ['SDL_VIDEODRIVER'] = 'dummy'
    os.environ['PYGAME_HIDE_SUPPORT_PROMPT'] = '1'
    import pygame; pygame.init(); pygame.display.set_mode((1,1))
    import doom_wireframe as dw

    POSITIONS = [
        (1056, -3616, 64), (1056, -3616, 0), (1056, -3616, 32),
        (1056, -3616, 96), (1200, -3300, 64),
    ]

    # Track back-face cull vs pass by monkey-patching fp_render_seg
    bf_culled = [0]
    bf_passed = [0]
    near_clipped = [0]
    has_gap_failed = [0]
    drawn = [0]
    _orig = dw.fp_render_seg
    def _tracked(si, clips, ctx, vz, surface, vcache, vwh_cache, deferred=None):
        svwh = dw.fp_segs_vwh[si]
        s = svwh[0]
        ldx, ldy = svwh[13], svwh[14]
        lv1 = dw.fp_vertexes[dw.linedefs[s[3]][0]]
        px_int, py_int = ctx[0], ctx[1]
        dot = ldy * (px_int - lv1[0]) - ldx * (py_int - lv1[1])
        if s[4] == 1:
            dot = -dot
        if dot <= 0:
            bf_culled[0] += 1
            return
        bf_passed[0] += 1
        segs_drawn_before = len(dw.map_trace['segs_drawn'])
        _orig(si, clips, ctx, vz, surface, vcache, vwh_cache, deferred)
        if len(dw.map_trace['segs_drawn']) > segs_drawn_before:
            drawn[0] += 1
    dw.fp_render_seg = _tracked

    out = []
    for px, py, ab in POSITIONS:
        bf_culled[0] = bf_passed[0] = drawn[0] = 0
        for k in dw.map_trace:
            if hasattr(dw.map_trace[k], 'clear'):
                dw.map_trace[k].clear()
        px_88 = int((px - dw.MAP_CENTER_X) * 256 / dw.PRESCALE)
        py_88 = int((py - dw.MAP_CENTER_Y) * 256 / dw.PRESCALE)
        vz_ps = dw._prescale_height(dw.player_floor(px, py) + 41)
        sc = dw.fp_sincos(ab)
        ctx = dw.fp_view_context(px_88, py_88, sc)
        ang_rad = dw.byte_to_radians(ab)
        cos_f, sin_f = math.cos(ang_rad), math.sin(ang_rad)
        tmp = pygame.Surface((dw.FP_RENDER_W, dw.FP_RENDER_H))
        dw.fp_module.mul_reset()
        dw.render_bsp_fp(len(dw.nodes) - 1, dw.FPClipSpans(), ctx, vz_ps,
                         int(px), int(py), cos_f, sin_f, tmp,
                         [None] * len(dw.vertexes), [None] * len(dw.vwh_table))
        out.append({
            'pos': [px, py, ab],
            'bf_culled': bf_culled[0],
            'bf_passed': bf_passed[0],
            'drawn': drawn[0],
            'segs_visited': len(dw.map_trace['segs_processed']),
        })
    print("RESULT", json.dumps({'prescale': dw.PRESCALE, 'positions': out}))
""")

def run(prescale):
    env = {**os.environ, 'DOOM_PRESCALE': str(prescale)}
    r = subprocess.run([sys.executable, '-c', SCRIPT], capture_output=True,
                       text=True, env=env)
    for line in r.stdout.splitlines():
        if line.startswith('RESULT '):
            return json.loads(line[7:])
    print("STDERR:", r.stderr[-2000:])
    return None

r8 = run(8)
r16 = run(16)

print(f"\n{'pos':22s} {'bf_cull':>8s} {'bf_pass':>8s} {'drawn':>8s}   {'bf_cull':>8s} {'bf_pass':>8s} {'drawn':>8s}")
print(f"{'':22s} {'p8':>8s} {'p8':>8s} {'p8':>8s}   {'p16':>8s} {'p16':>8s} {'p16':>8s}")
print("-" * 80)
for a, b in zip(r8['positions'], r16['positions']):
    print(f"  pos {a['pos']!r:16s} "
          f"{a['bf_culled']:>8d} {a['bf_passed']:>8d} {a['drawn']:>8d}  "
          f"{b['bf_culled']:>8d} {b['bf_passed']:>8d} {b['drawn']:>8d}")
