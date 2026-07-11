#!/usr/bin/env python3
"""Regenerate src/layout.inc from the live packed layout (single variant).
Run after any packer/layout change; doom_wireframe asserts agreement on
import, so a stale inc fails the first harness run loudly."""
import os, re, sys
os.environ['SDL_VIDEODRIVER'] = 'dummy'
os.environ['PYGAME_HIDE_SUPPORT_PROMPT'] = '1'
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
import pygame; pygame.init()
import doom_wireframe as dw
lay = dw.packed_layout
p = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
                 'src', 'layout.inc')
s = open(p).read()
def sub(name, val):
    global s
    s = re.sub(rf'^{name}\s*=\s*\S+', f'{name}   = {val}', s, flags=re.M)
sub('LAY_N_SEGS', lay['n_segs'])
sub('LAY_N_NODES', lay['n_nodes'])
sub('LAY_ROOT', lay['n_nodes'] - 1)
sub('LAY_OFF_VERTS', f"${lay['off_verts']:04X}")
sub('LAY_OFF_SS', f"${lay['off_ss']:04X}")
sub('LAY_OFF_SEG_HDR', f"${lay['off_seg_hdr']:04X}")
sub('LAY_N_DIRS', lay['n_dirs'])
sub('LAY_MAX_DIRS', lay['max_dirs'])
open(p, 'w').write(s)
print('src/layout.inc regenerated')
