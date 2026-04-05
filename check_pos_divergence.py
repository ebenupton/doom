#!/usr/bin/env python3
"""Check whether point_on_side diverges between raw and prescaled data at prescale=16."""
import os
os.environ['SDL_VIDEODRIVER'] = 'dummy'
os.environ['PYGAME_HIDE_SUPPORT_PROMPT'] = '1'
import pygame; pygame.init(); pygame.display.set_mode((1, 1))

import doom_wireframe as dw
from fp import PRESCALE

# Raw (Python FP) version:
def raw_point_on_side(x, y, node):
    dx, dy = x - node[0], y - node[1]
    return 0 if (node[3] * dx - node[2] * dy) > 0 else 1

# Prescaled (6502) version — operates on integer-divided values
def pre_point_on_side(px_pre, py_pre, node):
    """Mirrors what the 6502 computes."""
    pdx = node[2] // PRESCALE
    pdy = node[3] // PRESCALE
    nx_pre = node[0] // PRESCALE
    ny_pre = node[1] // PRESCALE
    dx = px_pre - nx_pre
    dy = py_pre - ny_pre
    return 0 if (pdy * dx - pdx * dy) > 0 else 1

POSITIONS = [
    (1056, -3616, 64, "spawn East"),
    (1056, -3616, 0, "spawn North"),
    (1056, -3616, 32, "spawn NE"),
    (1056, -3616, 96, "spawn SE"),
    (1200, -3300, 64, "moved East"),
]

print(f"PRESCALE={PRESCALE}")
for px, py, ab, name in POSITIONS:
    px_pre = px // PRESCALE
    py_pre = py // PRESCALE
    # Wait — 6502 stores px_88 = int((px-center)*256/PRESCALE), not px/PRESCALE.
    # The integer part used in point_on_side-equivalent arithmetic is
    # px_88 >> 8, which is (px - MAP_CENTER) // PRESCALE.
    px_rel = (px - dw.MAP_CENTER_X) // PRESCALE
    py_rel = (py - dw.MAP_CENTER_Y) // PRESCALE

    mismatches = 0
    for ni, node in enumerate(dw.nodes):
        raw_side = raw_point_on_side(px, py, node)
        # Equivalent prescaled arithmetic: node_x and node_y need to be
        # in the same coordinate system as px_rel, py_rel (relative to
        # MAP_CENTER, divided by PRESCALE).
        nx_rel = (node[0] - dw.MAP_CENTER_X) // PRESCALE
        ny_rel = (node[1] - dw.MAP_CENTER_Y) // PRESCALE
        pdx = node[2] // PRESCALE
        pdy = node[3] // PRESCALE
        dx = px_rel - nx_rel
        dy = py_rel - ny_rel
        pre_side = 0 if (pdy * dx - pdx * dy) > 0 else 1
        if raw_side != pre_side:
            mismatches += 1
            if mismatches <= 3:
                print(f"  {name}: node {ni} raw={raw_side} pre={pre_side} "
                      f"raw_cross={node[3]*(px-node[0]) - node[2]*(py-node[1])} "
                      f"pre_cross={pdy*dx - pdx*dy}")
    print(f"  {name}: {mismatches} point_on_side mismatches out of {len(dw.nodes)}")
