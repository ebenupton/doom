#!/usr/bin/env python3
"""Rotation-cache / forward-cache effectiveness benchmark (Eben's spec,
2026-07-21): at each benchmark location, measure COLD (pristine), a
16-frame in-place ROTATION run (rcache territory), and a 16-frame
FORWARD walk (dcache territory) — every frame byte-compared against the
pixel-exact Python reference, and every frame ALSO rendered on a twin
engine forced pristine (its bca_cachepos is spoiled before each render,
so the classifier always sees "moved + no D_FWD") for an exact
same-scene uncached cycle baseline.

Locations arrived as engine-native prescaled 8.8 coords + angle byte:
    px88.frac  py88.frac  ab
"""
import os, sys
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), '..'))
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
os.chdir(os.path.join(os.path.dirname(os.path.abspath(__file__)), '..'))
os.environ.setdefault('SDL_VIDEODRIVER', 'dummy')
os.environ.setdefault('PYGAME_HIDE_SUPPORT_PROMPT', '1')
import pygame; pygame.init()
import doom_wireframe as dw
import pyref_render
from bsp_render_6502 import BspRender6502
from symmap import sym

# (int16.8 as 24-bit hex, angle byte) — Eben, 2026-07-21
LOCS = [
    (0xFFEE72, 0xFFDCBA, 0x3C),
    (0x002E29, 0x005EEB, 0x04),
    (0x00DF9A, 0x003CC8, 0xCC),
    (0x00B636, 0x0002E9, 0x88),
]
N = 16
STEP = 8.0     # world units per forward frame (walkseq's stride)


def world(v24, center):
    s = v24 - 0x1000000 if v24 & 0x800000 else v24
    return center + (s / 256.0) * dw.PRESCALE


def fb(eng):
    sc = eng.sc
    return bytes(sc.mpu.memory[sc.SCREEN_START:sc.SCREEN_START + sc.SCREEN_SIZE])


def mkeng():
    return BspRender6502(dw.packed_layout, dw.packed_rom_main, dw.packed_rom_detail,
                         dw.packed_bbox_table, dw.MAP_CENTER_X, dw.MAP_CENTER_Y,
                         dw.PRESCALE)


def main():
    eng, prs = mkeng(), mkeng()
    mem, pmem = eng.sc.mpu.memory, prs.sc.mpu.memory
    D_ENABLE, D_FWD = sym('D_ENABLE'), sym('D_FWD')
    CACHEPOS = sym('bca_cachepos')
    mem[D_ENABLE] = 1              # cached engine: full classifier
    pmem[D_ENABLE] = 0             # twin: D off AND cachepos spoiled per frame

    def render_pair(px, py, ab, fwd):
        mem[D_FWD] = 1 if fwd else 0
        c = eng.render_frame(px, py, ab, dw.player_floor(px, py))
        pmem[CACHEPOS] = (pmem[CACHEPOS] + 1) & 0xFF   # force "moved": pristine
        p = prs.render_frame(px, py, ab, dw.player_floor(px, py))
        ref, _ = pyref_render.render_ref_fb(px, py, ab)
        # CACHE gate: cached engine == pristine engine (the caches must
        # never change pixels). pyref deltas are the pre-existing
        # engine-vs-float backlog (soak: 2.67%) — reported, non-fatal.
        ok = fb(eng) == fb(prs)
        blog = fb(prs) != bytes(ref)
        return c, p, ok, blog

    bad = backlog = 0
    print(f'{"location":>26s} {"cold":>7s} | {"rot store":>9s} {"rot warm":>8s} '
          f'{"pristine":>8s} {"save":>6s} | {"fwd store":>9s} {"fwd warm":>8s} '
          f'{"pristine":>8s} {"save":>6s}')
    tot_rw = tot_rp = tot_fw = tot_fp = 0
    for (x24, y24, ab0) in LOCS:
        px0 = world(x24, dw.MAP_CENTER_X)
        py0 = world(y24, dw.MAP_CENTER_Y)
        # ---- cold (arrive: moving-pristine) ----
        c_cold, p_cold, ok, bl = render_pair(px0, py0, ab0, False)
        bad += not ok; backlog += bl
        # ---- rotations: 16 in-place frames, ab += 4 ----
        rots = [(px0, py0, (ab0 + 4 * (k + 1)) & 0xFF) for k in range(N)]
        r_cyc, r_prs = [], []
        for (px, py, ab) in rots:
            c, p, ok, bl = render_pair(px, py, ab, False)
            r_cyc.append(c); r_prs.append(p); bad += not ok; backlog += bl
        # ---- reset pose (pristine re-entry), then 16 forward frames ----
        c2, p2, ok, bl = render_pair(px0, py0, ab0, False)
        bad += not ok; backlog += bl
        v = pygame.math.Vector2(1, 0).rotate(ab0 * 360 / 256)
        f_cyc, f_prs = [], []
        px, py = px0, py0
        for k in range(N):
            px, py = px + v.x * STEP, py + v.y * STEP
            c, p, ok, bl = render_pair(px, py, ab0, True)
            f_cyc.append(c); f_prs.append(p); bad += not ok; backlog += bl
        rw = sum(r_cyc[1:]) / (N - 1); rp = sum(r_prs[1:]) / (N - 1)
        fw = sum(f_cyc[1:]) / (N - 1); fp = sum(f_prs[1:]) / (N - 1)
        tot_rw += rw; tot_rp += rp; tot_fw += fw; tot_fp += fp
        name = f'{x24:06X}.{y24:06X}.{ab0:02X}'
        print(f'{name:>26s} {c_cold:7d} | {r_cyc[0]:9d} {rw:8.0f} {rp:8.0f} '
              f'{100*(rp-rw)/rp:5.1f}% | {f_cyc[0]:9d} {fw:8.0f} {fp:8.0f} '
              f'{100*(fp-fw)/fp:5.1f}%')
    print(f'{"MEAN over locations":>26s} {"":7s} | {"":9s} {tot_rw/4:8.0f} '
          f'{tot_rp/4:8.0f} {100*(tot_rp-tot_rw)/tot_rp:5.1f}% | {"":9s} '
          f'{tot_fw/4:8.0f} {tot_fp/4:8.0f} {100*(tot_fp-tot_fw)/tot_fp:5.1f}%')
    if backlog:
        print(f'  (note: {backlog} frames carry the KNOWN engine-vs-float '
              f'backlog — identical cached and pristine)')
    if bad:
        print(f'CACHEBENCH: FAIL ({bad} cached-vs-pristine divergent frames)')
        sys.exit(1)
    print('CACHEBENCH: every frame — cached engine == pristine engine, byte-exact')


if __name__ == '__main__':
    main()
