#!/usr/bin/env python3
"""Runtime-written cache planes must not sit on data tables. Both builds.

This is the bug class the codebase keeps re-hitting, from both sides:

  * banked, earlier: COLIDX was moved to $AB00, which was inside the
    rcache psi planes ($A900-$AEFF). colmap.py's blobs() still carries
    the note.
  * flat, 2026-08-24: the psi planes RC_PH_0 ($E900) and RC_P2L_1
    ($E800) sat on MV_MINPASS, USETAB, MV_SS_ID/INFO and the tail of
    SS_VZ. Every armed frame sprayed cached psi bytes over them, so on
    the tube the doors whose use lines fell in the trampled tail stopped
    opening -- and only SOME did, because it depends which node ids the
    cache armed.

Neither was caught by a gate, for the same reason both times: the
movement suites never render (so the cache never arms) and the render
suites never move (so the tables are never read). Nothing had to know
about both, so nothing did. This does: it takes the plane bases from the
LINKED map and the table homes from colmap/anim, and rejects any
overlap. It is arithmetic, so it costs nothing and cannot drift.
"""
import os, sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, ROOT)
os.chdir(ROOT)
os.environ.setdefault('SDL_VIDEODRIVER', 'dummy')
os.environ.setdefault('PYGAME_HIDE_SUPPORT_PROMPT', '1')
import pygame; pygame.init()
import symmap, colmap, anim_sectors as an, doom_wireframe as dw

# node-indexed: the store is `STA <plane>,Y` with Y = node id, so each
# plane is exactly n_nodes bytes
# The rcache psi planes (length = node count) ...
PLANES = ('RC_P1L_0', 'RC_P1L_1', 'RC_P2L_0', 'RC_P2L_1', 'RC_PH_0', 'RC_PH_1')
# ...and every OTHER relocatable cache block, with its real length.  These
# were missing, and the gate cheerfully passed a rehome that put four VXCACHE
# planes inside the flat seg-header table (ROM_SEG_HDR_C $8600 + 5,884 B).
# Only tube_walk caught it, four frames in.  A cache the gate does not know
# about is a cache that can land anywhere.  2026-08-30.
SIZED_PLANES = (('VXCACHE_XLO', 0x200), ('VXCACHE_XHI', 0x200),
                ('VXCACHE_YLO', 0x200), ('VXCACHE_YHI', 0x200),
                ('VRCACHE_BASE', 0x200), ('RCACHE_STATE', 138),
                ('VYCACHE_R_S', 0x100), ('VYCACHE_KEY', 0x100),
                ('VYCACHE_L', 0x100), ('VYCACHE_H', 0x100))


def n_nodes():
    # NOT packed_bbox_table // 8 -- that is 512 slots, not the node count.
    # The store is `STA <plane>,Y` with Y = node id, so the plane is
    # exactly as long as the node list.
    return len(dw.nodes)


def tables(flat):
    """Every colmap/anim home, sized from the blob it actually ships.

    blobs() hands back address -> bytes, so the lengths here are the real
    ones and a table added later is covered without touching this file.
    """
    B = colmap.blobs(flat=flat)
    names = {v: k for k, v in B['addrs'].items()}
    out = [(names.get(a, f'colmap@${a:04X}'), a, len(v))
           for a, v in B.items() if a != 'addrs']
    # the anim mover workspace is written by the state machine every tic
    # and read by pmove -- same exposure, different allocator
    ws = symmap.sym('ANIM_WS', banked=0 if flat else 1,
                    c02=1 if flat else None)
    out.append(('anim_ws', ws, 3 * len(an.MOVERS)))
    # the anim TABLE homes (SSMASK/TABL0/CFG + friends): the 2026-08-25
    # strike -- the flat psi planes were rehomed ONTO $E500/$E600, the
    # worker patched through psi-corrupted addresses, and the tube
    # misrendered everywhere off spawn. gen_6502_tables() is the one
    # source of the homes AND the real blob sizes.
    for a, blob in an.gen_6502_tables(flat=flat).items():
        out.append((f'anim@${a:04X}', a, len(blob)))
    # the packed-WAD object table + art templates: installed by the
    # loader at layout constants, INVISIBLE to the linker map. The
    # 2026-08-27 strike: the LOD hex template grew the art blob past the
    # flat hole's real wall (colmap USEVEC at $B800) and colmap stomped
    # it -- the copro free-ran the whole template table.
    # FLAT ONLY: the banked homes are inside the bank-SEG window, where
    # same-address pairs against other banks' tables (the L2 psi planes
    # at $A900/$AA00) are routine; layout.inc asserts fence the banked
    # blob against its real neighbour (the vertex planes) instead.
    if flat:
        L = dw.packed_layout
        # THE BIG LEVEL BLOBS.  These were NOT registered, and the gate
        # passed a rehome that put four cache planes straight inside the
        # seg-header table (flat ROM_SEG_HDR_C $8600 + 5,884 B runs to
        # $9D1B).  Only tube_walk caught it, four frames in.  2026-08-30.
        # The LV1 K planes and DBOUND, and the WORK segment they can collide
        # with.  Flat ROM_BKTLO_C sits at $0C10-$0C8F and the WORK region is
        # $0C20-$0CFF: a 112-byte overlap this gate did not see, found only
        # when a ZP rotation reordered WORK and moved which variable landed
        # on bsp_render_6502's region-reload canary (2026-08-31).
        for _nm, _len in (('ROM_BKTLO_C', 128), ('ROM_BKTHI_C', 128),
                          ('ROM_DBOUND_C', 128)):
            try:
                out.append((f'wad:{_nm}', symmap.sym(_nm, banked=0, c02=1), _len))
            except KeyError:
                pass
        import re as _re
        _cfg = open(os.path.join(ROOT, 'src', 'engine_flat.cfg')).read()
        for _m in _re.finditer(r'^\s*(WORK):\s*start = \$([0-9A-Fa-f]+), '
                               r'size = \$([0-9A-Fa-f]+)', _cfg, _re.M):
            out.append(('seg:WORK', int(_m.group(2), 16), int(_m.group(3), 16)))
        for _nm, _len in (('ROM_SEG_HDR_C', L['off_ss_cnt'] - L['off_seg_hdr']),
                          ('ROM_VERTS_C',   L['off_seg_hdr'] - L['off_verts']),
                          ('NODE_SOA',      L['off_verts'])):
            try:
                out.append((f'wad:{_nm}', symmap.sym(_nm, banked=0, c02=1), _len))
            except KeyError:
                pass
        obj_a = symmap.sym('ROM_OBJ_C', banked=0, c02=1)
        art_a = symmap.sym('OBJ_ART', banked=0, c02=1)
        # FLAT gathers the 16-object legacy subset (see bsp_render_6502)
        out.append(('wad:obj_planes', obj_a, 7 * 16 + L['obj_bits_len']))
        # PER BUILD.  The loader copies LAY_N_OBJ_ART entries, and flat stops
        # at 35 -- its art home is exactly 152 bytes, with SS_VZ_BASE below
        # and pmf_mul24s above, so it never receives the pillar block.
        # Registering the full packed length here made flat look like it was
        # overrunning minpass and usetab, which it is not.
        out.append(('wad:obj_art', art_a, 4 * 35))
        # OBJ_ANYB bitmap (2026-08-29): python-placed, invisible to the
        # linker — register so future placements collide loudly (the
        # byte-plane experiment landed on engine_pmbf/VXCACHE senior pages)
        _anyb = symmap.sym('OBJ_ANYB', banked=0, c02=1)
        out.append(('obj_anyb', _anyb, L['obj_bits_len']))
        # angle-module tables (python-loaded; a PMEXT cut landed on
        # L8_TAB) + the colmap y-cell prescreen tables (2026-08-29)
        for _nm, _ln in (('L8_TAB', 256), ('AE_LO', 256), ('AE_HI', 256),
                         ('VATOX', 1025)):   # (CY tables register via colmap)
            out.append((f'tbl:{_nm}', symmap.sym(_nm, banked=0, c02=1), _ln))
    # the LINKED engine regions (code + data bins): a cache plane over
    # CODE is the same class with a worse failure mode. Region extents
    # from the ld65 cfg + the real bin sizes (concatenated per file).
    import engine_load
    seen = {}
    for start, fname in engine_load._regions(0 if flat else 1):
        if fname not in seen:
            seen[fname] = (start, os.path.getsize(os.path.join(ROOT, fname)))
    for fname, (start, size) in seen.items():
        out.append((f'region:{fname}', start, size))
    return out


def main():
    N = n_nodes()
    ok = True
    for banked in (1, 0):
        tag = 'BANKED' if banked else 'FLAT'
        c02 = 1 if not banked else None          # the parasite is the C02 flat
        t, _ = symmap._load(0 if not banked else 1, c02)
        planes = [(p, t[p], N) for p in PLANES if p in t]
        # FLAT ONLY: flat has no bank window, so an address collision there
        # is REAL.  Banked, two names at one window address are usually
        # different PHYSICAL banks (VYCACHE is bank A, VPLOTC bank C) and
        # comparing raw addresses just manufactures false positives.
        if not banked:
            planes += [(p, t[p], L) for p, L in SIZED_PLANES if p in t]
        if not planes:
            print(f'  {tag}: no psi planes in the map -- check the names')
            ok = False
            continue
        hits = []
        for pn, pa, pl in planes:
            for tn, ta, tl in tables(flat=not banked):
                lo, hi = max(pa, ta), min(pa + pl, ta + tl)
                if lo < hi:
                    hits.append(f'{pn} (${pa:04X}+{pl}) over {tn} '
                                f'(${ta:04X}+{tl}): ${lo:04X}-${hi - 1:04X}')
        # pairwise: the tables themselves must not overlap either (the
        # LOD-art-vs-USEVEC strike was table-over-table, psi-invisible).
        # FLAT ONLY: banked homes are window addresses in different
        # sideways banks, so same-address pairs there are routine.
        if not banked:
            T = tables(flat=True)
            for i in range(len(T)):
                for j in range(i + 1, len(T)):
                    (an_, aa, al), (bn, ba, bl) = T[i], T[j]
                    # A SEGMENT does not collide with its own tenants: WORK
                    # is $0C20-$0CFF and obj_anyb lives INSIDE it by design.
                    # The segment entry is here to catch tables that stray
                    # into it, not the variables it is supposed to hold.
                    if an_.startswith('seg:') or bn.startswith('seg:'):
                        inner = (aa >= ba and aa + al <= ba + bl) or \
                                (ba >= aa and ba + bl <= aa + al)
                        if inner:
                            continue
                    lo, hi = max(aa, ba), min(aa + al, ba + bl)
                    if lo < hi:
                        hits.append(f'{an_} (${aa:04X}+{al}) over {bn} '
                                    f'(${ba:04X}+{bl}): ${lo:04X}-${hi - 1:04X}')
        if hits:
            ok = False
            print(f'  {tag}: {len(hits)} OVERLAP(S) -- a cache plane is '
                  f'writing over a data table:')
            for h in hits:
                print(f'    {h}')
        else:
            span = f'${min(p[1] for p in planes):04X}..'
            print(f'  {tag}: {len(planes)} planes x {len(tables(not banked))} '
                  f'tables, no overlap  ({N} nodes/plane)')

    print('TABLEOVERLAP: ' + ('PASS' if ok else 'FAIL'))
    return 0 if ok else 1


if __name__ == '__main__':
    sys.exit(main())
