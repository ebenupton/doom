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
PLANES = ('RC_P1L_0', 'RC_P1L_1', 'RC_P2L_0', 'RC_P2L_1', 'RC_PH_0', 'RC_PH_1')


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
