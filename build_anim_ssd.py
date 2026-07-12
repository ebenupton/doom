#!/usr/bin/env python3
"""Shared banked-image builder (GC 2026-07-12: the rotating spin/modelb
discs are retired — this module survives because build_walk_ssd.py imports
build_images() for the L0/C/L2/LOW bank images and the sincos table).

The animation driver ($3C00) + a 64-frame sincos table ($3E00) are overlaid into
the LOW image (both sit in the clipper-vacated $3C00-$47FF region the render never
touches), so there is NO separate driver file — !BOOT just *SRLOADs the banks,
*LOADs LOW, MODE 4, and jumps to $3C00. SHIFT-BREAK autoboots it."""
import os, subprocess
os.environ.setdefault('SDL_VIDEODRIVER', 'dummy')
os.environ.setdefault('PYGAME_HIDE_SUPPORT_PROMPT', '1')
import pygame; pygame.init()
import doom_wireframe as dw
import fp
from banked_bsp import BankedBspRender, BANK_L0, BANK_C, BANK_L2

SECTOR = 256
TOTAL_SECTORS = 800
SSD_SIZE = TOTAL_SECTORS * SECTOR
import abi
DRV_ADDR = abi.DRV_ORG
TAB_ADDR = abi.DRV_TAB
N_FRAMES = 64
ANGLE_STEP = 256 // N_FRAMES        # 4


def sincos_table():
    """64 entries x 8 bytes: smag,sneg,sone,cmag,cneg,cone,ab,pad."""
    t = bytearray(N_FRAMES * 8)
    for i in range(N_FRAMES):
        a = (i * ANGLE_STEP) & 0xFF
        sm, sn, so, cm, cn, co = fp.fp_sincos(a)
        e = i * 8
        t[e+0] = sm & 0xFF
        t[e+1] = 1 if sn else 0
        t[e+2] = 1 if so else 0
        t[e+3] = cm & 0xFF
        t[e+4] = 1 if cn else 0
        t[e+5] = 1 if co else 0
        t[e+6] = a
        t[e+7] = 0
    return bytes(t)


def build_images():
    r = BankedBspRender(dw.packed_layout, dw.packed_rom_main, dw.packed_rom_detail,
                        dw.packed_bbox_table, dw.MAP_CENTER_X, dw.MAP_CENTER_Y, dw.PRESCALE)
    bm = r.bm
    L0 = bytes(bm._banks[BANK_L0]); C = bytes(bm._banks[BANK_C]); L2 = bytes(bm._banks[BANK_L2])
    low_end = 0x2C00 + os.path.getsize('bsp_render_bk.bin')   # CODE region
    low = bytearray(bm[0x1B40:max(low_end, TAB_ADDR + N_FRAMES*8)])
    def overlay(addr, data):
        off = addr - 0x1B40
        low[off:off+len(data)] = data
    overlay(DRV_ADDR, open('ANIMDRV', 'rb').read())
    overlay(TAB_ADDR, sincos_table())
    # sanity: engine CODE starts at $2C00; the sincos table ends at $2400
    # (the driver's clear/input block sits at $2400-$2BFF, part of ANIMDRV)
    assert TAB_ADDR + N_FRAMES*8 <= 0x2C00, "table collides with bsp_render code"
    return L0, C, L2, bytes(low)
