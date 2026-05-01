#!/usr/bin/env python3
"""Show all segs touching a given map vertex, with their NOVT state."""
import os, sys
os.environ['SDL_VIDEODRIVER'] = 'dummy'
os.environ['PYGAME_HIDE_SUPPORT_PROMPT'] = '1'
import pygame; pygame.init(); pygame.display.set_mode((1, 1))

import doom_wireframe as dw

vidx = int(sys.argv[1]) if len(sys.argv) > 1 else 11

v = dw.fp_vertexes[vidx]
print(f"Vertex {vidx} = {v} (prescaled coords)")
print(f"  Map coord (× PRESCALE={dw.PRESCALE}): "
      f"({v[0] * dw.PRESCALE + dw.MAP_CENTER_X}, "
      f"{v[1] * dw.PRESCALE + dw.MAP_CENTER_Y})")
print(f"  Linedef endpoint? {'yes' if vidx in dw._ld_endpoint_verts else 'NO (BSP-internal split)'}")
print(f"  Covered by solid_ap? {vidx in dw._vert_covered_by_solid_ap}")
print()

print(f"Segs touching vertex {vidx}:")
for si in dw._vert_to_segs.get(vidx, ()):
    sv = dw.fp_segs_vwh[si]
    s = sv[0]
    v1, v2 = s[0], s[1]
    fi = sv[1]
    bi = sv[2]
    side = 'V1' if v1 == vidx else 'V2'
    novt = dw._seg_novt_flags[si]
    n1 = bool(novt & dw._SF_NOVT1)
    n2 = bool(novt & dw._SF_NOVT2)
    we_novt = n1 if v1 == vidx else n2
    if bi is None:
        role = 'solid'
    else:
        bs = dw.fp_sectors[bi]
        if bs[1] < sv[4] or bs[0] > sv[3]:
            role = 'portal-steps'
        else:
            role = 'portal-plain'
    rule4 = []
    if (si, 1) in dw._novt_rule4: rule4.append('V1')
    if (si, 2) in dw._novt_rule4: rule4.append('V2')
    ap1 = dw._seg_novt_aperture.get((si, 1))
    ap2 = dw._seg_novt_aperture.get((si, 2))
    print(f"  s{si:3d} v=({v1},{v2}) front={fi} back={bi} {role:13s} "
          f"side={side} our_novt={we_novt} "
          f"novt={'V1' if n1 else '  '}{'V2' if n2 else '  '} "
          f"rule4={rule4 or '-'}")
    if ap1: print(f"        APV1 aperture heights: bch={ap1[0]} bfh={ap1[1]}")
    if ap2: print(f"        APV2 aperture heights: bch={ap2[0]} bfh={ap2[1]}")
