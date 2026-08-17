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
sub('LAY_HDR_STRIDE', __import__('wad_packed').SEG_HDR_SIZE)
sub('LAY_HDR_BYTES', f"${lay['off_dirs'] - lay['off_seg_hdr']:04X}")
sub('LAY_SS_FH_OFF', f"${lay['off_ss_fh'] - lay['off_seg_hdr']:04X}")
sub('LAY_LV1_OFF', f"${lay['off_lv1'] - lay['off_seg_hdr']:04X}")
import wad_packed as _wp
sub('LAY_SH_DIAG', _wp.SH_DIAG)
sub('LAY_SH_FLAGS', _wp.SH_FLAGS)
sub('LAY_SH_BFH', _wp.SH_BFH)
sub('LAY_SH_BCH', _wp.SH_BCH)
sub('LAY_N_DIRS', lay['n_dirs'])
sub('LAY_MAX_DIRS', lay['max_dirs'])
open(p, 'w').write(s)
print('src/layout.inc regenerated')
