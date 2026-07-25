#!/usr/bin/env python3
"""Page-tail audit (Eben's question, 2026-07-26): page-anchored tables
whose true extent leaves a dead tail in the page. Curated manifest —
sizes derive from live census counts (vertices/nodes/subsectors), so
the report tracks the map. Run after any layout change.

Tails are genuinely dead ONLY if the resident's indexing can never
reach them (vertex hi pages: idx&255 <= 197; node planes: idx <= 219).
Placement rules for co-tenants:
  - main <$1B40 tails need disc staging (banked) / DATA-span homes
    (copro) — the VDESC lesson;
  - $70-$7F zp-adjacent and $1A00 (JBASE) are raster/driver territory;
  - bank-resident tails ship free with the bank image.
"""
import os, sys
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), '..'))
os.chdir(os.path.join(os.path.dirname(os.path.abspath(__file__)), '..'))
os.environ.setdefault('SDL_VIDEODRIVER', 'dummy')
os.environ.setdefault('PYGAME_HIDE_SUPPORT_PROMPT', '1')
import pygame; pygame.init()
import doom_wireframe as dw
from symmap import sym

NV = len(dw.fp_vertexes)          # 454
NHI = NV - 256                    # senior plane occupancy
NN = len(dw.nodes)                # 220
NS = len(dw.fp_ssectors)          # 221
NEX = len(dw.vspan_expl)          # explicit entries

def rows():
    # (name, base, used_in_last_page, page_span_bytes, home)
    out = []
    # --- per-vertex 512-entry planes: hi page holds NHI of 256 ---
    for n in ('VC_EVY', 'VC_EVX', 'VC_RHI', 'VC_RLO', 'VC_SXL', 'VC_SXH', 'VC_CLIP'):
        out.append((n + ' (hi)', sym(n) + 0x100, NHI, 256, 'main runtime'))
    for n in ('VP_XLO', 'VP_XHI', 'VP_YLO', 'VP_YHI'):
        out.append((n + ' (hi)', sym(n) + 0x100, NHI, 256, 'L2/flat ROM'))
    try:
        for n in ('VXC_XLO', 'VXC_XHI', 'VXC_XEXT', 'VXC_YLO', 'VXC_YHI', 'VXC_YEXT'):
            out.append((n + ' (hi)', sym(n) + 0x100, NHI, 256, 'bank C runtime'))
    except KeyError:
        pass
    # --- VDESC planes (bank C staging + flat TABLES) ---
    out.append(('VDESC hi (banked C)', 0xB300, NHI, 256, 'bank C'))
    out.append(('VDESC hi (flat)', 0xDD00, NHI, 256, 'flat TABLES'))
    # --- node/ss planes: used NN or NS of 256 ---
    for n, used in (('NODE_CLLO', NN), ('NODE_TYPE', NN), ('SS_CNT', NS),
                    ('SS_PLO', NS), ('SS_PHI', NS)):
        out.append((n, sym(n), used, 256, 'flat ROM/main'))
    for n in ('BBP_T_LO0', 'BBP_T_LO1', 'BBP_T_HI0', 'BBP_T_HI1',
              'BBP_B_LO0', 'BBP_B_LO1', 'BBP_B_HI0', 'BBP_B_HI1',
              'BBP_L_LO0', 'BBP_L_LO1', 'BBP_L_HI0', 'BBP_L_HI1',
              'BBP_R_LO0', 'BBP_R_LO1', 'BBP_R_HI0', 'BBP_R_HI1'):
        try:
            out.append((n, sym(n), NN, 256, 'flat ROM'))
        except KeyError:
            pass
    # --- singletons ---
    out.append(('VDONE', sym('VDONE'), 57, 256, 'main <$1B40'))
    out.append(('ANIM_SSMASK tail', 0x0A80, NS, 0x0BE8 - 0x0A80, 'main <$1B40'))
    out.append(('VEXPL_LO/HI (packed @ $60)', sym('VEXPL_LO'), NEX, 0x60, 'already sub-page packed'))
    return out

total = 0
print(f'{"table":30s} {"base":>6s} {"used":>5s} {"span":>5s} {"tail":>5s}  home')
for name, base, used, span, home in rows():
    tail = span - used
    if tail <= 0:
        continue
    total += tail
    print(f'{name:30s} {base:>6X} {used:>5d} {span:>5d} {tail:>5d}  {home}')
print(f'\nTOTAL dead tail bytes: {total}')
