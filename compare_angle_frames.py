"""Check the angle-space column change (M1) hasn't broken the Python renderer
vs the current perspective state.

Renders the packed Python frame at each suite position with the perspective
column (current) and the angle column (_USE_ANGLE_COL), capturing every drawn
line, and reports:
  - line-count delta
  - how many perspective lines have a near-identical angle counterpart
    (both endpoints within TOL px) — a faithful +/-1 conversion keeps ~all of
    them; a radical break (missing walls / garbage) shows up as big drops.
"""
import os
os.environ['SDL_VIDEODRIVER'] = 'dummy'
os.environ['PYGAME_HIDE_SUPPORT_PROMPT'] = '1'
import pygame; pygame.init(); pygame.display.set_mode((1, 1))
import doom_wireframe as dw
import fp
import trace_compare as tc
from wad_packed import spans_init_full

TOL = 2
POS = [(1056,-3616,65),(1500,-3700,1),(1024,-3500,65),
       (800,-3400,96),(1200,-3000,129),(1056,-3616,129)]


def render_lines(px, py, ab, angle):
    dw._USE_ANGLE_COL = angle
    spans = dw.Instrumented6502Spans()
    sc = dw._span_clip_6502
    tc.setup_wad(sc); tc.setup_view_zp(sc, px, py, ab)
    sc._run(tc.ENTRY_BR_VIEW_SETUP); sc.init(); sc.clear_screen()
    px_88 = int((px - dw.MAP_CENTER_X) * 256 / dw.PRESCALE)
    py_88 = int((py - dw.MAP_CENTER_Y) * 256 / dw.PRESCALE)
    ctx = fp.fp_view_context(px_88, py_88, fp.fp_sincos(ab))
    vz = dw._prescale_height(dw.player_floor(px, py) + 41)
    cos_f = pygame.math.Vector2(1, 0).rotate(ab * 360 / 256).x
    sin_f = pygame.math.Vector2(1, 0).rotate(ab * 360 / 256).y
    p_ram = bytearray(dw.packed_layout['ram_size'])
    spans_init_full(p_ram, dw.packed_layout['ram_spans'],
                    dw.FP_RENDER_W, dw.FP_RENDER_H - 1)
    surf = pygame.Surface((256, 160))
    captured = []
    orig_dc = spans.draw_clipped
    def cap_dc(lines, *a, **k):
        captured.extend(tuple(int(v) for v in ln) for ln in lines)
        return orig_dc(lines, *a, **k)
    spans.draw_clipped = cap_dc
    dw.packed_render_bsp(len(dw.nodes) - 1, spans, ctx, vz,
                         px, py, cos_f, sin_f, surf, p_ram)
    dw._USE_ANGLE_COL = False
    return captured


def norm(l):
    x1, y1, x2, y2 = l
    return (x1, y1, x2, y2) if (x1, y1) <= (x2, y2) else (x2, y2, x1, y1)


def matched(a, b, tol):
    bb = [norm(l) for l in b]
    used = [False] * len(bb)
    m = 0
    for la in (norm(l) for l in a):
        for i, lb in enumerate(bb):
            if used[i]:
                continue
            if all(abs(la[k] - lb[k]) <= tol for k in range(4)):
                used[i] = True; m += 1; break
    return m


if __name__ == '__main__':
    print(f'{"position":22s} {"persp":>6s} {"angle":>6s} {"exact":>6s} '
          f'{"<=2px":>6s} {"lost":>5s}')
    tp = ta = te = tm = 0
    for px, py, ab in POS:
        lp = render_lines(px, py, ab, False)
        la = render_lines(px, py, ab, True)
        e = matched(lp, la, 0)
        m = matched(lp, la, TOL)
        tp += len(lp); ta += len(la); te += e; tm += m
        print(f'{str((px,py,ab)):22s} {len(lp):6d} {len(la):6d} {e:6d} '
              f'{m:6d} {len(lp)-m:5d}')
    print(f'\ntotal perspective lines : {tp}')
    print(f'total angle lines       : {ta}')
    print(f'exact-match             : {te} ({100*te/tp:.1f}%)')
    print(f'match within {TOL}px        : {tm} ({100*tm/tp:.1f}%)')
    print(f'perspective lines lost   : {tp-tm} ({100*(tp-tm)/tp:.1f}%)')
