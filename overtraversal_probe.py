#!/usr/bin/env python3
"""Over-traversal robustness probe.

Invariant under test: a subsector whose whole screen extent is occluded
(the corner-projection walk would have pruned it) must be a perfect no-op
when visited anyway — its lines all clip away, its mark_solid hits only
closed columns, its tightens have no records. Any deviation is a seg-math
bug (the reason the renderer is not yet robust to over-traversal).

Method: run the packed pipeline with a frustum-reject-only bbox (descend
everything in-frustum). For every subsector outside the corner walk's
visit set, snapshot span state + lit-pixel count around the call and
report violations with the responsible subsector.

    PYTHONPATH=. python3 overtraversal_probe.py [px py ab]...
"""
import os
import sys
os.environ.setdefault('SDL_VIDEODRIVER', 'dummy')
os.environ.setdefault('PYGAME_HIDE_SUPPORT_PROMPT', '1')
import pygame; pygame.init()
import numpy as np
import doom_wireframe as dw
import fp
from fp import PRESCALE, MAP_CENTER_X as MCX, MAP_CENTER_Y as MCY, NEAR_FP, fp_to_view
from wad_packed import spans_init_full
from endpoint_spans import EndpointClipSpans

W, H = dw.FP_RENDER_W, dw.FP_RENDER_H


def setup(px, py, ab):
    px8 = int((px - MCX) * 256 / PRESCALE)
    py8 = int((py - MCY) * 256 / PRESCALE)
    ctx = fp.fp_view_context(px8, py8, fp.fp_sincos(ab))
    vz = dw._prescale_height(dw.player_floor(px, py) + 41)
    cf = pygame.math.Vector2(1, 0).rotate(ab * 360 / 256).x
    sf = pygame.math.Vector2(1, 0).rotate(ab * 360 / 256).y
    ram = bytearray(dw.packed_layout['ram_size'])
    spans_init_full(ram, dw.packed_layout['ram_spans'], W, H - 1)
    return ctx, vz, cf, sf, ram


def reject_only(node, side, ctx):
    """Frustum-reject-only bbox: in-frustum -> full width (max descend)."""
    base = 4 + side * 4
    rt, rb, rl, rr = (node[base], node[base + 1], node[base + 2], node[base + 3])
    top = (rt - MCY) // PRESCALE
    bot = (rb - MCY) // PRESCALE
    left = (rl - MCX) // PRESCALE
    right = (rr - MCX) // PRESCALE
    px, py = ctx[0], ctx[1]
    if left <= px <= right and bot <= py <= top:
        return 0, W - 1
    pts = [fp_to_view(wx, wy, ctx)[1:3]
           for (wx, wy) in ((left, top), (right, top), (right, bot), (left, bot))]
    if all(p[1] < NEAR_FP for p in pts):
        return None
    if all(p[0] + p[1] < 0 for p in pts):
        return None
    if all(p[0] > p[1] for p in pts):
        return None
    return 0, W - 1


def corner_visits(px, py, ab):
    ctx, vz, cf, sf, ram = setup(px, py, ab)
    seen = []
    orig = dw.packed_render_subsector
    def hook(idx, *a, **k):
        seen.append(idx)
        return orig(idx, *a, **k)
    dw.packed_render_subsector = hook
    surf = pygame.Surface((W, H))
    dw.packed_render_bsp(len(dw.nodes) - 1, dw.Instrumented6502Spans(), ctx, vz,
                         px, py, cf, sf, surf, ram)
    dw.packed_render_subsector = orig
    return set(seen)


def probe(px, py, ab, verbose=True):
    corner = corner_visits(px, py, ab)
    ctx, vz, cf, sf, ram = setup(px, py, ab)
    clips = dw.Instrumented6502Spans()
    surf = pygame.Surface((W, H))
    violations = []
    orig_ss = dw.packed_render_subsector
    orig_bbox = dw.fp_bbox_visible_fixed
    def sspan(c):
        return [tuple(s) if not isinstance(s, tuple) else s for s in c.spans]

    def hook(idx, cl, *a, **k):
        extra = idx not in corner
        if extra:
            before = sspan(cl)
            px_before = int((pygame.surfarray.array3d(surf).sum(2) > 0).sum())
        orig_ss(idx, cl, *a, **k)
        if extra:
            after = sspan(cl)
            px_after = int((pygame.surfarray.array3d(surf).sum(2) > 0).sum())
            if before != after or px_before != px_after:
                violations.append((idx, px_after - px_before, before, after))
                if verbose:
                    print(f"  VIOLATION ss={idx}: pixels {px_before}->{px_after}, "
                          f"spans {'CHANGED' if before != after else 'same'}")
                    if before != after and len(violations) <= 2:
                        bs, as_ = set(before), set(after)
                        for s in sorted(bs - as_): print(f"    - {s}")
                        for s in sorted(as_ - bs): print(f"    + {s}")
    dw.packed_render_subsector = hook
    dw.fp_bbox_visible_fixed = reject_only
    try:
        dw.packed_render_bsp(len(dw.nodes) - 1, clips, ctx, vz,
                             px, py, cf, sf, surf, ram)
    finally:
        dw.packed_render_subsector = orig_ss
        dw.fp_bbox_visible_fixed = orig_bbox
    return violations


def main():
    if len(sys.argv) > 1:
        args = [int(a) for a in sys.argv[1:]]
        positions = [tuple(args[i:i + 3]) for i in range(0, len(args), 3)]
    else:
        positions = [(973, -3367, 239), (1354, -3748, 95), (893, -3218, 123),
                     (955, -3735, 222), (1056, -3616, 137)]
    total = 0
    for (px, py, ab) in positions:
        print(f"({px},{py},{ab}):")
        v = probe(px, py, ab)
        print(f"  {len(v)} violating subsectors")
        total += len(v)
    print(f"\nTOTAL: {total} violations")
    sys.exit(1 if total else 0)


if __name__ == '__main__':
    main()
