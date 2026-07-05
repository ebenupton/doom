#!/usr/bin/env python3
"""Validate the angle-space bbox against the corner-projection walk.

Renders the packed pipeline with _USE_ANGLE_BBOX and compares pixels to
the corner walk (must be identical — over-descent is proven harmless, so
any pixel diff means the angle path UNDER-reports somewhere). Also counts
visited subsectors (descend cost).
"""
import os
import sys
os.environ.setdefault('SDL_VIDEODRIVER', 'dummy')
os.environ.setdefault('PYGAME_HIDE_SUPPORT_PROMPT', '1')
import pygame; pygame.init()
import random
import numpy as np
import doom_wireframe as dw
import angle_bbox as A
from overtraversal_probe import setup

W, H = dw.FP_RENDER_W, dw.FP_RENDER_H


def render(px, py, ab, mode):
    ctx, vz, cf, sf, ram = setup(px, py, ab)
    if mode == 'corner':
        dw._USE_ANGLE_BBOX = False
    else:
        dw._USE_ANGLE_BBOX = True
        dw._VIEW_AB = ab
    visits = []
    orig = dw.packed_render_subsector
    def hook(idx, *a, **k):
        visits.append(idx)
        return orig(idx, *a, **k)
    dw.packed_render_subsector = hook
    surf = pygame.Surface((W, H))
    try:
        dw.packed_render_bsp(len(dw.nodes) - 1, dw.Instrumented6502Spans(),
                             ctx, vz, px, py, cf, sf, surf, ram)
    finally:
        dw.packed_render_subsector = orig
        dw._USE_ANGLE_BBOX = False
    return (pygame.surfarray.array3d(surf).sum(2) > 0), len(visits)


def far(B, ref):
    n = 0
    for x in range(W):
        ry = np.where(ref[x])[0]
        bo = np.where(B[x] & ~ref[x])[0]
        if len(bo):
            d = (np.full(len(bo), 99) if len(ry) == 0
                 else np.abs(ry[None, :] - bo[:, None]).min(axis=1))
            n += int((d > 2).sum())
    return n


HARD = [(1056, -3616, 137), (1056, -3328, 14), (955, -3735, 222),
        (1354, -3748, 95), (893, -3218, 123), (973, -3367, 239),
        (1056, -3616, 128), (1500, -3700, 1)]


def main():
    random.seed(11)
    positions = HARD + [(random.randint(850, 1450), random.randint(-3850, -3050),
                         random.randint(0, 255)) for _ in range(60)]
    modes = ['angle']
    stats = {m: {'bad': 0, 'worst': 0, 'visits': 0} for m in modes}
    corner_visits_total = 0
    for i, (px, py, ab) in enumerate(positions):
        t, tv = render(px, py, ab, 'corner')
        corner_visits_total += tv
        for m in modes:
            r, rv = render(px, py, ab, m)
            d = max(far(r, t), far(t, r))
            stats[m]['visits'] += rv
            if d > 2:
                stats[m]['bad'] += 1
                if i < len(HARD) or d > stats[m]['worst']:
                    print(f"  {m}: ({px},{py},{ab}) diverges {d}px "
                          f"(visits {rv} vs corner {tv})")
            stats[m]['worst'] = max(stats[m]['worst'], d)
        if (i + 1) % 20 == 0:
            print(f"  ...{i+1}/{len(positions)}")
    print(f"\ncorner walk: {corner_visits_total} total subsector visits")
    for m in modes:
        s = stats[m]
        print(f"{m:10s}: {s['bad']}/{len(positions)} divergent, worst={s['worst']}px, "
              f"visits {s['visits']} ({s['visits']/corner_visits_total:+.1%} vs corner)")


if __name__ == '__main__':
    main()
