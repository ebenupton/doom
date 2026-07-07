#!/usr/bin/env python3
"""Prove visibility-lazy mover patching is invisible in the output.

Invariant: a mover whose subsectors aren't visited this frame has stale
table bytes, but those bytes are never read — so a frame rendered with
LAZY patching (subsector-hook flushes only) must byte-match the same
frame rendered after an eager flush_all().

Scenario: the camera dwells at several vantages (door 4 visible; nowhere
near any mover; facing the lift; back to door 4 after it cycled unseen
for seconds) while all six movers animate continuously.  Every frame is
rendered twice through the pixel-exact reference: lazy first, then eager
— any divergence fails.  Also reports patch work per frame to show the
saving (frames with no mover visible must apply zero patches).
"""
import os, sys
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), '..'))
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
os.chdir(os.path.join(os.path.dirname(os.path.abspath(__file__)), '..'))
os.environ['DOOM_ANIM'] = '1'
os.environ.setdefault('SDL_VIDEODRIVER', 'dummy')
os.environ.setdefault('PYGAME_HIDE_SUPPORT_PROMPT', '1')
import pygame; pygame.init()
import doom_wireframe as dw
import anim_sectors as an
import pyref_render

DT = 1 / 15.0
VANTAGES = [
    ('door4',   an.camera_for(an.MOVERS[4]),   30),
    ('nowhere', (1056, -3616, 128),            45),   # spawn: no mover in view
    ('lift70',  an.camera_for(an.MOVERS[70]),  30),
    ('door4b',  an.camera_for(an.MOVERS[4]),   15),   # returns after ~5s unseen
]


def main():
    an.install()
    bad = 0
    frame = 0
    per_vantage = []
    for name, (px, py, ab), nframes in VANTAGES:
        applies = 0
        for _ in range(nframes):
            frame += 1
            an.tick(DT)
            lazy_fb, _ = pyref_render.render_ref_fb(px, py, ab)
            applies += an.STATS['frame_applies']
            an.flush_all()
            eager_fb, _ = pyref_render.render_ref_fb(px, py, ab)
            if lazy_fb != eager_fb:
                bad += 1
                nd = sum(1 for a, b in zip(lazy_fb, eager_fb) if a != b)
                print(f'frame {frame} ({name}): LAZY != EAGER, {nd} bytes')
        per_vantage.append((name, nframes, applies))
    an.uninstall()
    for name, nf, ap in per_vantage:
        print(f'{name:8s}: {nf} frames, {ap} lazy patch applications '
              f'({ap/nf:.2f}/frame)')
    nowhere = dict((n, a) for n, _, a in per_vantage)['nowhere']
    ok = bad == 0 and nowhere == 0
    if nowhere:
        print(f'FAIL: {nowhere} patches applied with no mover visible')
    print(f'ANIM LAZY CHECK: {frame} frames, {bad} mismatches — '
          + ('PASS' if ok else 'FAIL'))
    sys.exit(0 if ok else 1)


if __name__ == '__main__':
    main()
