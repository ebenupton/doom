#!/usr/bin/env python3
"""Player-movement collision map — DOOM P_TryMove/P_UseLines replica.

Pack-time generator + the canonical python movement model. The 6502
implementation (src/bsp/pmove.s + the drivers) and every python mirror
(tube walk convergence, tests) consume THIS module, so there is exactly
one statement of the rules:

  - blocking: player is a radius-16 box; one-sided lines and
    ML_BLOCKING two-sided lines stop the box (P_BlockLinesIterator ->
    P_BoxOnLineSide, restricted to lines a box can ever reach — the
    reachability-pruned, colinear-merged COLSEG set below)
  - step/opening: crossing into a sector whose floor is >24 above the
    player's current floor is blocked; door sectors use the LIVE mover
    ceiling (opening < 56 blocks) — DOOM's P_CheckPosition opening
    rules, evaluated at the destination sector (found by BSP descent)
  - z: viewz = sector floor + 41 (prescaled: the SS_VZ table), snapped
    (no bob — Eben's "no jogging"); on a moving lift floor the live
    mover height substitutes
  - use (SPACE): a 64-unit trace along the view direction against the
    USE line set: DR doors toggle (open/close/reverse), the S1 exit
    switch respawns; walkover lines (the WR lift, the W1 floor) fire on
    a committed move crossing them

Movers idle at their rest pose until triggered (the anim CFG wait
sentinel 0 = hold forever; see anim_sectors).

Table homes (bank WALK banked / flat):
  COLSEG   $B8C0 / $7600   n*8: x1,y1,dx,dy (center-relative raw s16 LE)
  COLIDX   $B4A4 / +blob   36 * (u16 list offset, u8 count)
  COLLIST  follows COLIDX  u8 seg indices per 128-unit column
  SS_VZ    $8C00 / $E750   per-subsector prescale(floor+41) (s8)
  SS_INFO  $8CE0 / $E830   per-subsector: $FF none | mover idx (b7=ceil)
  USETAB   after COLIDX/COLLIST in the same blob: use + walkover lines
"""
import os

RADIUS = 16
STEP_PS = 3          # 24 world units, prescaled
DOOR_MIN_OPEN_PS = 7 # 56 world units, prescaled
EYE_PS = 5           # +41 world, prescaled, for live lift floors
USE_RANGE = 64

RAWX_MIN, RAWY_MIN = -1936, -1584    # walk clamp rect (walk_drv.asm)
COLS = 36

_built = None


def build():
    """Compute (and memoize) the whole collision map. Returns a dict."""
    global _built
    if _built is not None:
        return _built
    import doom_wireframe as dw
    import collections
    CX, CY = dw.MAP_CENTER_X, dw.MAP_CENTER_Y
    RAWX_MAX = RAWX_MIN + 36 * 128
    RAWY_MAX = RAWY_MIN + 22 * 128
    movers = sorted(dw.ANIM_SECTORS)

    # mover far poses (DOOM rest rules) for reachability + door minima
    def far_heights(s):
        fh, ch = dw.sectors[s][0], dw.sectors[s][1]
        nb = set()
        for ld in dw.linedefs:
            ss = [dw.sidedefs[sd][5] for sd in (ld[5], ld[6]) if sd != 0xFFFF]
            if s in ss:
                nb.update(x for x in ss if x != s)
        if dw.ANIM_SECTORS[s] == 'ceil':
            ch = min(dw.sectors[n][1] for n in nb) - 4
        else:
            fh = min(dw.sectors[n][0] for n in nb)
        return fh, ch

    H = {s: (dw.sectors[s][0], dw.sectors[s][1]) for s in range(len(dw.sectors))}
    for s in movers:
        H[s] = far_heights(s)

    # reachability flood fill (movers at far pose = openings open)
    adj = collections.defaultdict(set)
    for ld in dw.linedefs:
        r, l = ld[5], ld[6]
        if r == 0xFFFF or l == 0xFFFF or (ld[2] & 1):
            continue
        sr, sl = dw.sidedefs[r][5], dw.sidedefs[l][5]
        if min(H[sr][1], H[sl][1]) - max(H[sr][0], H[sl][0]) < 56:
            continue
        if H[sl][0] - H[sr][0] <= 24:
            adj[sr].add(sl)
        if H[sr][0] - H[sl][0] <= 24:
            adj[sl].add(sr)
    sx, sy = 1056, -3616
    nid = len(dw.nodes) - 1
    while not (nid & 0x8000):
        n = dw.nodes[nid]
        nid = n[12] if (n[3] * (sx - n[0]) - n[2] * (sy - n[1])) > 0 else n[13]
    spawn_sec = dw.seg_sectors(dw.segs[dw.ssectors[nid & 0x7FFF][1]])[0]
    seen = {spawn_sec}
    work = [spawn_sec]
    while work:
        s = work.pop()
        for t in adj[s]:
            if t not in seen:
                seen.add(t)
                work.append(t)

    # collision line set: one-sided fronting reachable + blocking-flag.
    # The bbox cull margin is 64 (NOT the 16 radius): the walk rect is
    # only the blockmap indexing domain — the player legally stands up
    # to a box-radius OUTSIDE it against perimeter walls that sit just
    # beyond it (ld 127 west wall x=-768 / ld 332 south y=-4864 were
    # culled by the 16-margin and became walk-through holes once the
    # old hard clamp died — Eben's 2026-08-14 void clips). A REACHABLE
    # blocking line outside even the wide margin is a build error.
    raw = []
    for li, ld in enumerate(dw.linedefs):
        v1, v2, flags, special, tag, r, l = ld
        x1, y1 = dw.vertexes[v1][:2]
        x2, y2 = dw.vertexes[v2][:2]
        sr = dw.sidedefs[r][5] if r != 0xFFFF else None
        sl = dw.sidedefs[l][5] if l != 0xFFFF else None
        blocking = ((sl is None or sr is None)
                    and (sr if sl is None else sl) in seen) or \
                   ((sl is not None and sr is not None) and (flags & 1)
                    and (sr in seen or sl in seen))
        if not blocking:
            continue
        if (max(x1, x2) < CX + RAWX_MIN - 64 or min(x1, x2) > CX + RAWX_MAX + 64 or
                max(y1, y2) < CY + RAWY_MIN - 64 or min(y1, y2) > CY + RAWY_MAX + 64):
            assert False, \
                f'reachable blocking line {li} outside the census margin'
        raw.append(((x1 - CX, y1 - CY), (x2 - CX, y2 - CY)))

    # colinear-merge chains (same idiom as the render seg merge)
    segs = raw
    merged = True
    while merged:
        merged = False
        out = []
        used = [False] * len(segs)
        bystart = collections.defaultdict(list)
        for i, (a, b) in enumerate(segs):
            bystart[a].append(i)
        for i, (a, b) in enumerate(segs):
            if used[i]:
                continue
            used[i] = True
            cur = b
            d = (b[0] - a[0], b[1] - a[1])
            while True:
                nxt = None
                for j in bystart.get(cur, ()):
                    if used[j]:
                        continue
                    c, e = segs[j]
                    d2 = (e[0] - c[0], e[1] - c[1])
                    if d[0] * d2[1] == d[1] * d2[0] and d[0] * d2[0] + d[1] * d2[1] > 0:
                        nxt = j
                        break
                if nxt is None:
                    break
                used[nxt] = True
                cur = segs[nxt][1]
                merged = True
            out.append((a, cur))
        segs = out
    assert len(segs) < 256, f'{len(segs)} collision segs (u8 indexing)'
    colsegs = [(a[0], a[1], b[0] - a[0], b[1] - a[1]) for a, b in segs]

    # per-column (128-unit) lists — built AFTER ports (below) so port
    # entries can ride the same u8 index space at >= len(colsegs)
    colidx = None
    collist = None

    # per-subsector VZ + mover info
    ps = dw._prescale_height
    ss_vz = bytearray(len(dw.fp_ssectors))
    ss_info = bytearray([0xFF]) * 0     # rebuilt below
    ss_info = bytearray(len(dw.fp_ssectors))
    for ssi, (cnt, first) in enumerate(dw.fp_ssectors):
        sec = dw.fp_segs_vwh[first][1]
        ss_vz[ssi] = ps(dw.sectors[sec][0] + 41) & 0xFF
        if sec in dw.ANIM_SECTORS:
            mi = movers.index(sec)
            ss_info[ssi] = mi | (0x80 if dw.ANIM_SECTORS[sec] == 'ceil' else 0)
        else:
            ss_info[ssi] = 0xFF
    # non-mover reachable sectors must be >= 56 tall (no static SS_CEIL
    # plane — assert the assumption)
    for s in seen:
        if s not in dw.ANIM_SECTORS:
            assert dw.sectors[s][1] - dw.sectors[s][0] >= 56, \
                f'sector {s} shorter than PLAYER_HEIGHT — SS_CEIL plane needed'

    # per-mover: min passable door pos (fh + 56, prescaled); lifts unused
    mv_minpass = bytearray(6)
    for mi, s in enumerate(movers):
        if dw.ANIM_SECTORS[s] == 'ceil':
            mv_minpass[mi] = (ps(dw.sectors[s][0]) + DOOR_MIN_OPEN_PS) & 0xFF
        else:
            mv_minpass[mi] = 0

    # use lines (special 1 = DR door both faces; special 11 = exit) and
    # walkover lines (special 88 WR lift / 36 W1 floor, by tag)
    use_lines = []
    walk_lines = []
    tag2mover = {}
    for ld in dw.linedefs:
        special, tag = ld[3], ld[4]
        if special in (88, 36) and tag:
            for s in movers:
                if dw.sectors[s][6] == tag:
                    tag2mover[tag] = movers.index(s)
    for ld in dw.linedefs:
        v1, v2, flags, special, tag, r, l = ld
        x1, y1 = dw.vertexes[v1][0] - CX, dw.vertexes[v1][1] - CY
        x2, y2 = dw.vertexes[v2][0] - CX, dw.vertexes[v2][1] - CY
        if special == 1:
            back = dw.sidedefs[l][5] if dw.sidedefs[r][5] not in dw.ANIM_SECTORS \
                else dw.sidedefs[r][5]
            # DR door: tag 0, mover = the back (door) sector of the line
            door = dw.sidedefs[l][5]
            if door not in dw.ANIM_SECTORS:
                door = dw.sidedefs[r][5]
            assert door in dw.ANIM_SECTORS, f'DR line {ld} without mover back'
            use_lines.append((x1, y1, x2 - x1, y2 - y1, movers.index(door)))
        elif special == 11:
            use_lines.append((x1, y1, x2 - x1, y2 - y1, 0xFE))   # exit: respawn
        elif special in (88, 36) and tag in tag2mover:
            walk_lines.append((x1, y1, x2 - x1, y2 - y1, tag2mover[tag]))
    assert len(use_lines) <= 16 and len(walk_lines) <= 8
    # P_UseLines ordering: DOOM picks the NEAREST crossed line; the 6502
    # scans first-in-table. These are observationally identical iff no
    # single USE_RANGE trace can cross two use lines with DIFFERENT
    # actions (same-door face pairs are order-indifferent). Enforce that
    # equivalence here so a future map fails the build instead of
    # silently mis-ordering (the task-7 analysis, 2026-08-14).
    for i, (ax, ay, adx, ady, aact) in enumerate(use_lines):
        for bx, by, bdx, bdy, bact in use_lines[i + 1:]:
            if aact == bact:
                continue
            # conservative: min bbox gap between the two lines must
            # exceed the trace reach
            gap_x = max(0, max(min(ax, ax + adx), min(bx, bx + bdx))
                        - min(max(ax, ax + adx), max(bx, bx + bdx)))
            gap_x = max(0, max(min(ax, ax+adx) - max(bx, bx+bdx),
                               min(bx, bx+bdx) - max(ax, ax+adx)))
            gap_y = max(0, max(min(ay, ay+ady) - max(by, by+bdy),
                               min(by, by+bdy) - max(ay, ay+ady)))
            assert max(gap_x, gap_y) > USE_TRACE + 4, \
                f'use lines with different actions within trace range ' \
                f'({aact} vs {bact}) — implement nearest-hit ordering'

    # ── aggregation ports (task 8): two-sided lines where openings can
    # bind on a crossing box — mover-adjacent, floor step > 24, or a
    # static opening < 56. Baked at REST pose; live mover substitution
    # at test time. ob_vz = prescale(max fh)+5 (vz domain, +5 = the eye
    # offset used everywhere in pmove); ot_ps = prescale(min ch).
    ports = []
    for li, ld in enumerate(dw.linedefs):
        v1, v2, flags, special, tag, r, l = ld
        if r == 0xFFFF or l == 0xFFFF or (flags & 1):
            continue
        sr, sl = dw.sidedefs[r][5], dw.sidedefs[l][5]
        if sr not in seen and sl not in seen:
            continue
        is_mover = sr in dw.ANIM_SECTORS or sl in dw.ANIM_SECTORS
        fr, fl = dw.sectors[sr], dw.sectors[sl]
        if not (is_mover or abs(fr[0] - fl[0]) > 24
                or min(fr[1], fl[1]) - max(fr[0], fl[0]) < 56):
            continue
        x1, y1 = dw.vertexes[v1][:2]
        x2, y2 = dw.vertexes[v2][:2]
        ob = ps(max(fr[0], fl[0])) + EYE_PS
        ot = ps(min(fr[1], fl[1]))
        mv = 0xFF
        for sec in (sr, sl):
            if sec in dw.ANIM_SECTORS:
                mv = movers.index(sec) | (0x80 if dw.ANIM_SECTORS[sec] == 'ceil' else 0)
        import math as _m
        ang = int(round(_m.atan2(y2 - y1, x2 - x1) * 32 / _m.pi)) & 63
        ports.append((x1 - CX, y1 - CY, x2 - x1, y2 - y1,
                      ob & 0xFF, ot & 0xFF, mv, ang))
    assert len(colsegs) + len(ports) < 256, 'u8 collision index space'

    # per-column lists over the unified universe: solids then ports
    # (idx >= len(colsegs) = port; the engine dispatches on COL_N_SOLID)
    colidx = []
    collist = []
    universe = (list(colsegs)
                + [(p[0], p[1], p[2], p[3]) for p in ports])
    for c in range(COLS):
        cx0 = RAWX_MIN + c * 128 - RADIUS
        cx1 = RAWX_MIN + (c + 1) * 128 + RADIUS
        mine = [i for i, (x1, y1, dx, dy) in enumerate(universe)
                if max(x1, x1 + dx) >= cx0 and min(x1, x1 + dx) <= cx1]
        colidx.append((len(collist), len(mine)))
        collist.extend(mine)

    _built = dict(colsegs=colsegs, colidx=colidx, collist=collist, ports=ports,
                  ss_vz=bytes(ss_vz), ss_info=bytes(ss_info),
                  mv_minpass=bytes(mv_minpass),
                  use_lines=use_lines, walk_lines=walk_lines,
                  movers=movers)
    return _built


# ── binary emission ─────────────────────────────────────────────────────
SPEED = 12                # world units / frame (walk_drv SPEED)
USE_TRACE = 60            # SPACE trace length (raw units; DOOM uses 64)


# (step_table DELETED 2026-08-17: the 64 x 4 movement-delta table lost its
#  last reader when the single-step momentum rework (cb8cfdc) replaced table
#  stepping with arithmetic. It sat in bank A at $BC00 for weeks, seeded every
#  build, read by nobody — and its page is part of what the seg side tables
#  moved into.)


def use_vectors():
    """64 x 4: (ux, uy) s16 raw-unit SPACE trace vectors."""
    import math, struct
    out = bytearray()
    for i in range(64):
        for v in (USE_TRACE * math.cos(i * math.pi / 32),
                  USE_TRACE * math.sin(i * math.pi / 32)):
            out += struct.pack('<H', int(v + 65536.5) & 0xFFFF)
    return bytes(out)


def blobs(flat=True):
    """{address: bytes} for the build's homes.
    COLSEG then the COLIDX/COLLIST blob sit in the build's collision
    pocket; SS planes, MV_MINPASS and USETAB in the high-table area.
    COLIDX = 36 * (u16 collist ABS address, u8 count); USETAB = u8
    n_use, n_use*9 (x1,y1,dx,dy s16 LE + action), u8 n_walk, n_walk*9.
    Addresses are mirrored in gen_abi.py (COLSEG_BASE etc.) for pmove.s.
    """
    import struct
    m = build()
    # flat homes = the TUBE parasite map ($7500-$82FF is the replaced
    # raster blob there; the flat py65 harness never installs these —
    # only drivers move the player). Banked homes = bank WALK free
    # windows (audited 2026-08-14), same bank as the node SoA so the
    # whole movement test runs under one paging context.
    # COLSEG stride is 9 since the P_SlideMove arc (2026-08-14): +1 baked
    # wall-angle byte (direction quantized to the 64-angle space) for the
    # slide projection. Banked: USETAB lives in BANK A ($BE00 — pmove_use
    # pages SEG for its list) so the widened COLSEG fits bank B.
    if flat:
        A = dict(idx=0x7600, colseg=0x7810, ss_vz=0xE750,
                 minpass=0xE910, mv_ss_id=0xE980, mv_ss_info=0xE988,
                 usetab=0xE918)
    else:
        # idx $B4A4 -> $AB00 -> $AF8A (both 2026-08-15): the first home
        # overlapped the $B400-$B4FF SSMASK staging page (the 256B mask
        # copy-down dragged COLIDX bytes into ANIM_SSMASK 164-220); the
        # $AB00 fix landed ON THE RCACHE PSI PLANES ($A900-$AEFF,
        # bca.s RC_P1L_0..RC_PH_1 — runtime-written; only harmless in
        # tests because neither the fuzz nor the movement path renders).
        # $AF8A = after RCACHE_STATE ($AF00+$89), before ANIM CFG $B300.
        # LESSON: zero-runs in the shipped image are NOT free space —
        # ships-zero runtime BSS looks identical; audit the equates.
        # ss_vz $8C00 -> $8D00 2026-08-19: fifth of the five adjacent SS
        # planes; ss_info died into SS_SI's top bits (MV_CEIL carries the
        # per-mover ceiling flag it used to hold in b7)
        A = dict(idx=0xAF8A, colseg=0xB8C0, ss_vz=0x8D00,
                 minpass=0xBFC0, mv_ss_id=0xBFC6, mv_ss_info=0xBFCE,
                 usetab=0xBE00)
    import math
    seg_blob = bytearray()
    for x1, y1, dx, dy in m['colsegs']:
        ang = int(round(math.atan2(dy, dx) * 32 / math.pi)) & 63
        seg_blob += struct.pack('<hhhhB', x1, y1, dx, dy, ang)
    list_base = A['idx'] + 108
    idx_blob = bytearray()
    for off, cnt in m['colidx']:
        idx_blob += struct.pack('<HB', list_base + off, cnt)
    idx_blob += bytes(m['collist'])
    ub = bytearray([len(m['use_lines'])])
    for x1, y1, dx, dy, act in m['use_lines']:
        ub += struct.pack('<hhhhB', x1, y1, dx, dy, act)
    ub.append(len(m['walk_lines']))
    for x1, y1, dx, dy, act in m['walk_lines']:
        ub += struct.pack('<hhhhB', x1, y1, dx, dy, act)
    # COLPORT: aggregation ports at $0200 BOTH builds (the shared page
    # freed by the records-to-bank-C move; main = no paging in the scan).
    # SHIPPING: $0200 is the OS vector page until the takeover, so no
    # COLPORT ships at $1A00 (2026-08-18, the sqr swap): inside LOW and
    # the tube CODE file, loaded directly — no staging, no copy-down.
    # (It lived at $0200 with a boot dance until the sqr quad, which is
    # boot-GENERATED and needs no shipping, took the OS pages instead.)
    pb = bytearray()
    for p in m['ports']:
        # WALL ANGLE AT +8, matching the solid record: pm_box_vs_seg
        # writes pm_blkang from +8 for whichever record the box
        # straddled, so one shared store serves both kinds (see
        # pm_port_aggr's header for the bug this layout retired).
        pb += struct.pack('<hhhhBBBB', p[0], p[1], p[2], p[3],
                          p[7], p[4], p[5], p[6])
    import abi as _abi0
    assert _abi0.COLPORT_BASE + len(pb) <= 0x1C00, 'COLPORT overruns the pool'
    # MV_SS probe list (2026-08-19 claw-back): the <=8 mover subsectors as
    # parallel id/info arrays, $FF-padded to 8 — pmove probes these twice
    # per MOVE instead of the render paying 8 cycles per visited subsector
    # for info bits packed into SS_PLO. The info byte keeps the classic
    # SS_INFO format (mover idx, b7 = ceiling).
    _mvss = [(ssi, v) for ssi, v in enumerate(m['ss_info']) if v != 0xFF]
    assert len(_mvss) <= 8, f'{len(_mvss)} mover subsectors overflow the 8-slot probe list'
    _ids = bytes([p[0] for p in _mvss] + [0xFF] * (8 - len(_mvss)))
    _inf = bytes([p[1] for p in _mvss] + [0xFF] * (8 - len(_mvss)))
    out = {A['colseg']: bytes(seg_blob), A['idx']: bytes(idx_blob),
           A['ss_vz']: m['ss_vz'],
           A['minpass']: m['mv_minpass'],
           A['mv_ss_id']: _ids, A['mv_ss_info']: _inf,
           A['usetab']: bytes(ub),
           _abi0.COLPORT_BASE: bytes(pb)}
    # (the bank-B $A900 / flat $8400 staging emits died 2026-08-18: at
    #  $1A00 the ports ship directly inside LOW / the tube CODE file,
    #  and anim_init's copy-down is gone with them)
    if not flat:
        pass
    # the asm dispatches on idx >= COL_N_SOLID (abi constant): pin it
    import abi as _abi
    assert len(m['colsegs']) == _abi.COL_N_SOLID, \
        f'COL_N_SOLID {_abi.COL_N_SOLID} != {len(m["colsegs"])} — update gen_abi'
    # home-range asserts (free-space windows audited 2026-08-14)
    if flat:
        assert A['idx'] + len(idx_blob) <= A['colseg']
        assert A['colseg'] + len(seg_blob) <= 0x7F10, \
            'collision blob reaches the flat PMOVE region at $7F10'
        assert 0xE750 + len(m['ss_vz']) <= 0xE830
        assert 0xE988 + 8 <= 0xEA00, 'MV_SS lists reach the flat FB'
        assert A['usetab'] + len(ub) <= 0xEA00, 'USETAB reaches the FB'
    else:
        assert 0xB8C0 + len(seg_blob) <= 0xBFC0, 'COLSEG overruns MV_MINPASS'
        assert 0xAF8A + len(idx_blob) <= 0xB300, \
            'COLIDX blob reaches the ANIM CFG page at $B300'
        assert len(m['ss_vz']) <= 0x100
        assert A['usetab'] + len(ub) <= 0xBE8F, 'USETAB (bank A) reaches TABL0'
    out['addrs'] = A
    return out


def install(mem, flat=True):
    b = blobs(flat)
    for addr, blob in b.items():
        if isinstance(addr, str):
            continue
        for i, v in enumerate(blob):
            mem[addr + i] = v


# ── canonical python movement model (mirrors pmove.s exactly) ───────────
def find_ss(rx, ry):
    """Subsector id for a center-relative raw point — descends the PACKED
    node SoA with the engine's literal rules (pm_find_ss). Descending
    dw.nodes instead is NOT equivalent: the packer's sense-normalization
    (axis child swaps, canonical general directions) preserves every
    strict verdict but flips which child an exact TIE lands on — the two
    residual 2026-08-14 fuzz divergences were both on-partition points."""
    import doom_wireframe as dw
    rom = dw.packed_rom_main
    lay = dw.packed_layout
    md = lay['max_dirs']
    dirs_off = lay['off_dirs']          # (was off_seg_hdr + n_segs*16 — the
                                       #  header array is page-slotted now)

    def s16(lo, hi):
        v = lo | (hi << 8)
        return v - 0x10000 if v >= 0x8000 else v

    nid = lay['n_nodes'] - 1
    while True:
        t = rom[0x800 + nid]
        form = t & 3
        if form == 0:                       # side0 iff px > nx (ties side1)
            side = 0 if rx > s16(rom[nid], rom[0x100 + nid]) else 1
        elif form == 1:                     # side0 iff py > ny
            side = 0 if ry > s16(rom[0x200 + nid], rom[0x300 + nid]) else 1
        else:                               # general (form >= 2): DIR delta form
            dxv = rx - s16(rom[nid], rom[0x100 + nid])
            dyv = ry - s16(rom[0x200 + nid], rom[0x300 + nid])
            sgn = rom[0x500 + nid]
            di = rom[0x400 + nid]
            adx = rom[dirs_off + di]
            ady = rom[dirs_off + md + di]
            ndy = -ady if (sgn & 0x80) else ady
            ndx = -adx if (sgn & 0x40) else adx
            side = 0 if ndy * dxv - ndx * dyv > 0 else 1
        if side == 0:
            if t & 0x80:                    # NF_RLEAF
                return rom[0x600 + nid]
            nid = rom[0x600 + nid]
        else:
            if t & 0x40:                    # NF_LLEAF
                return rom[0x700 + nid]
            nid = rom[0x700 + nid]


def _box_hits_seg(bx0, by0, bx1, by1, seg):
    x1, y1, dx, dy = seg
    lx0, lx1 = (x1, x1 + dx) if dx >= 0 else (x1 + dx, x1)
    ly0, ly1 = (y1, y1 + dy) if dy >= 0 else (y1 + dy, y1)
    # bbox overlap (strict: touching is not blocking, matching the s16 asm)
    if bx1 <= lx0 or bx0 >= lx1 or by1 <= ly0 or by0 >= ly1:
        return False
    if dx == 0 or dy == 0:
        return True                      # axis line: overlap IS the test
    # diagonal: the two quadrant corners must straddle the line
    if (dx > 0) == (dy > 0):
        c1 = (bx0, by1)
        c2 = (bx1, by0)
    else:
        c1 = (bx0, by0)
        c2 = (bx1, by1)
    s1 = (c1[0] - x1) * dy - (c1[1] - y1) * dx
    s2 = (c2[0] - x1) * dy - (c2[1] - y1) * dx
    return (s1 > 0) != (s2 > 0)


def _port_live(p, mover_pos):
    ob, ot, mv = p[4], p[5], p[6]
    ob = ob - (256 if ob >= 128 else 0)
    ot = ot - (256 if ot >= 128 else 0)
    if mv != 0xFF:
        pos = mover_pos[mv & 0x3F]
        pos = pos - (256 if pos >= 128 else 0)
        if mv & 0x80:
            ot = pos                      # door: live ceiling
        else:
            ob = pos + EYE_PS             # lift: live floor (vz domain)
    return ob, ot


def box_scan(rx, ry, z_ps, mover_pos):
    """P_CheckPosition over the box: solids block; crossed ports either
    block (opening/head too small) or aggregate tm_ob (the vz-domain
    openbottom max). Returns (blocked, tm_ob)."""
    m = build()
    n_solid = len(m['colsegs'])
    bx0, by0, bx1, by1 = rx - RADIUS, ry - RADIUS, rx + RADIUS, ry + RADIUS
    c0 = max(0, min(COLS - 1, (bx0 - RAWX_MIN) >> 7))
    c1 = max(0, min(COLS - 1, (bx1 - RAWX_MIN) >> 7))
    tm_ob = -40    # mirrors the asm sentinel (SBC-sign-safe)
    for c in ([c0] if c0 == c1 else [c0, c1]):   # 6502 scan order (blkang
                                                 # identity needs it exact)
        off, cnt = m['colidx'][c]
        for k in range(cnt):
            idx = m['collist'][off + k]
            if idx < n_solid:
                if _box_hits_seg(bx0, by0, bx1, by1, m['colsegs'][idx]):
                    return True, tm_ob
                continue
            p = m['ports'][idx - n_solid]
            if _box_hits_seg(bx0, by0, bx1, by1, p[:4]):
                ob, ot = _port_live(p, mover_pos)
                if ot - (ob - EYE_PS) < DOOR_MIN_OPEN_PS:
                    return True, tm_ob         # opening too small (or shut)
                if ot - (z_ps - EYE_PS) < DOOR_MIN_OPEN_PS:
                    return True, tm_ob         # head bump
                if ob > tm_ob:
                    tm_ob = ob
    return False, tm_ob


def box_blocked(rx, ry):
    """Legacy solid-only probe (tools)."""
    m = build()
    n_solid = len(m['colsegs'])
    bx0, by0, bx1, by1 = rx - RADIUS, ry - RADIUS, rx + RADIUS, ry + RADIUS
    c0 = max(0, min(COLS - 1, (bx0 - RAWX_MIN) >> 7))
    c1 = max(0, min(COLS - 1, (bx1 - RAWX_MIN) >> 7))
    for c in {c0, c1}:
        off, cnt = m['colidx'][c]
        for k in range(cnt):
            idx = m['collist'][off + k]
            if idx < n_solid and _box_hits_seg(bx0, by0, bx1, by1,
                                               m['colsegs'][idx]):
                return True
    return False


def dest_check(rx, ry, z_ps, mover_pos):
    """(ok, new_vz) for a candidate point already box-clear. mover_pos =
    6 live pos_hi bytes (prescaled s8)."""
    m = build()
    ss = find_ss(rx, ry)
    info = m['ss_info'][ss]
    if info != 0xFF:
        mi = info & 0x3F
        pos = mover_pos[mi] - (256 if mover_pos[mi] >= 128 else 0)
        if info & 0x80:                       # door: live ceiling
            mp = m['mv_minpass'][mi]
            if pos < (mp - 256 if mp >= 128 else mp):
                return False, z_ps
            vz = m['ss_vz'][ss]
        else:                                 # lift: live floor
            vz = (pos + EYE_PS) & 0xFF
    else:
        vz = m['ss_vz'][ss]
    svz = vz - (256 if vz >= 128 else 0)
    if svz - z_ps > STEP_PS:
        return False, z_ps
    return True, svz


def try_move(px, py, nx, ny, z_ps, mover_pos):
    """Full DOOM try-move for one candidate. Returns (ok, new_vz).
    NO walk-rect reject: the engine has none and neither does DOOM (an
    out-of-range blockmap block just yields no lines) — what keeps the
    player in is the map's own enclosing walls, which the census
    asserts are all present. The old hard clamp was a driver-era
    artifact; it survived here until the momentum fuzz caught the model
    freezing where the engine walked (2026-08-15). Only the COLUMN
    index is clamped, mirroring pm_column."""
    blocked, tm_ob = box_scan(nx, ny, z_ps, mover_pos)
    if blocked:
        return False, z_ps
    ok, vz = dest_check(nx, ny, z_ps, mover_pos)
    if not ok:
        return False, z_ps
    if tm_ob > vz:                        # crossed-line floors bind (the
        vz = tm_ob                        # DOOM tmfloorz aggregation)
        if vz - z_ps > STEP_PS:
            return False, z_ps
    return True, vz


# ── momentum physics (DOOM 35Hz, task 9) ───────────────────────────────
# THE canonical statement of the player momentum rules; pmove.s pm_frame
# is its 6502 expression and the lockstep fuzz is the gate.
#
# Units: velocities/displacements are s16 8.8 PRESCALED (1.0 = 8 world
# units), positions are 24-bit 8.8 prescaled center-relative (the DV_PX
# format). The scale is chosen because DOOM_fixed/2048 == our 8.8:
# DOOM's forwardmove*2048 thrust IS the literal 25 below.
#
# Per DOOM tic (35Hz; P_PlayerThink + P_XYMovement order):
#   1. thrust: mom += 25 * (cos,sin)(view), sign-magnitude (25*mag5)>>5
#      (back = negated; both keys cancel exactly)
#   2. clamp each axis to +/-960 (MAXMOVE 30 world units)
#   3. displacement += mom   (position applied per FRAME, batched)
#   4. friction: if no input and both |mom| < 2 (STOPSPEED): mom = 0
#      else mom = (mom*232)>>8 FLOOR (DOOM FixedMul 0xE800 semantics:
#      arithmetic shift, so -1 decays only via the stop rule — as DOOM)
# Tic clock: PAL fields * 7/10 accumulated (50Hz * 0.7 = 35Hz), fields
# capped at 32/frame (hiccup clamp).
#
# Frame displacement applies in <=15-world-unit chunks (DOOM's MAXMOVE/2
# halving, extended: halve until each axis chunk <= 480), each chunk via
# try_move. A blocked chunk with a wall angle projects BOTH the leftover
# displacement AND the momentum onto the wall (P_HitSlideLine as a true
# dot-product projection on the mag5 grid: p = (d.w>>5 terms summed),
# slide = (p*wmag)>>5 per axis — DOOM's aprox-dist*cos(delta) is an
# approximation of exactly this); at most 2 wall projections per frame,
# then the axis fallback (y-only, then x-only, zeroing the blocked
# axis' momentum), then full stop (mom = 0,0).
MM_THRUST = 24            # walk forwardmove (DOOM 0x19 = 25; trimmed to
                          # 24 so the single-step form lands on the same
                          # 8.0 u/tic top speed the per-tic loop reached
                          # — the per-tic floor used to drag the
                          # attractor 3.8% below 32T/3, and the closed
                          # form does not reproduce that drag)
MM_MAXMOVE = 960          # 30 world units, 8.8 prescaled
MM_HALF = 480             # MAXMOVE/2 chunk ceiling — DO NOT RAISE past
                          # 724 without redoing the tunnelling proof:
                          # crossing a wall needs > 2*RADIUS = 32 world
                          # units of perpendicular travel in ONE chunk,
                          # and a cap of c permits c*sqrt(2)
MM_STOP = 2               # STOPSPEED 0x1000 on our grid
MM_FRICTION = 232         # 0xE800 >> 8
MM_FIELDS_CAP = 10        # was 32. The single-step tables stop here, and
                          # a tighter hiccup clamp cuts the worst-case
                          # travel in one frame to 56 world units, not 177

# --- single-step (closed-form) momentum -------------------------------
# The per-tic recurrence m <- floor((m+T)*a) is affine, so n tics of it
# collapse to one affine step. With a = 232/256 and u* = T/(1-a):
#   m' = m*alpha + T*beta        alpha = a^n, beta = alpha + (a-alpha)/(1-a)
#   D  = m*gamma + T*delta       gamma = (1-a^n)/(1-a)
#                                delta = gamma + (n-gamma)/(1-a)
# n need not be a whole number, and THAT is the point: displacement
# becomes continuous in the frame period instead of jumping a whole
# tic's worth when the period wobbles by one field (the +/-23% wobble
# that read as jerkiness). Everything is indexed by the field count.
#
# Two identities keep the tables at 48 bytes instead of 96:
#   gamma = (1-alpha)/(1-a)      -> derived from alpha, 1-a = 3/32
#   beta  = a*gamma              -> one multiply
# Only alpha (u8) and delta (u16) are stored. Operands are non-negative
# so the 6502 sign-magnitude multiplies truncate the same way Python's
# >> does, and the final >>8 runs on a two's-complement accumulator
# (floor) seeded with 128 (round-to-nearest, which is what holds the
# residual frame-rate dependence of the top speed under 0.3%).
SS_RATE = 179             # tics per PAL field, Q8: 179/256 = 0.69922,
                          # i.e. 34.96 Hz. Replaces the 7/10 accumulator
                          # AND its carried remainder (ticrem retires)
SS_K = 171                # 1/(1-a) = 32/3 in Q4


def _ss_build():
    """(alpha u8, delta u16) indexed by field count. Mirrored byte for
    byte in pmove.s — tools/pm_fuzz.py asserts the two agree."""
    a = MM_FRICTION / 256
    al, de = [], []
    for f in range(MM_FIELDS_CAP + 1):
        n = f * SS_RATE / 256
        an = a ** n
        S = (1 - an) / (1 - a)
        al.append(round(an * 256))
        de.append(round((S + (n - S) / (1 - a)) * 256))
    return al, de


SS_ALPHA, SS_DELTA = _ss_build()


def ss_coeffs(f):
    """(alpha, beta, gamma, delta) for a field count — integer, exact."""
    al = SS_ALPHA[f]
    ga = ((256 - al) * SS_K) >> 4
    return al, (ga * MM_FRICTION) >> 8, ga, SS_DELTA[f]


def _sc16(v, mag5):
    """(v * mag5) >> 5 sign-magnitude (ps_scale16): truncate toward 0."""
    s = -1 if v < 0 else 1
    return s * ((abs(v) * mag5) >> 5)


def _unit5(ang):
    """(cmag5, sneg-cos, smag5, sneg-sin) of a 64-grid angle: mag 0..32
    (unity folded to 32), matching the $BA00 table + cone/sone flags."""
    import fp
    sm, sn, so, cm, cn, co = fp.fp_sincos5((ang & 63) * 4)
    return (32 if co else cm), cn, (32 if so else sm), sn


def wall_project(dx, dy, wall_ang):
    """P_HitSlideLine on the mag5 grid: project (dx,dy) onto the wall
    direction. Returns (sdx, sdy)."""
    cw, cn, sw, sn = _unit5(wall_ang)
    p = _sc16(-dx if cn else dx, cw) + _sc16(-dy if sn else dy, sw)
    sdx, sdy = _sc16(p, cw), _sc16(p, sw)
    return (-sdx if cn else sdx), (-sdy if sn else sdy)


def momentum_tics(mx, my, ticrem, fields, fwd, back, angidx):
    """The frame's whole momentum integration in ONE affine step.
    Returns (mx, my, ticrem, dx, dy); ticrem is retired and passes
    straight through — the engine no longer touches the byte.

    Replaces the per-tic loop (see the SS_ notes above). The clamp to
    MM_MAXMOVE is gone with the loop: it never bound — the attractor is
    ~232 against a 960 ceiling, and wall projection cannot grow a
    momentum — and |m| <= 255 is now STRUCTURAL, because the 6502 feeds
    m to the multiplies as a u8 magnitude. pm_fuzz asserts it."""
    f = min(fields, MM_FIELDS_CAP)
    if f == 0:
        return mx, my, ticrem, 0, 0
    al, be, ga, de = ss_coeffs(f)
    tx = ty = 0
    if fwd != back:
        cw, cn, sw, sn = _unit5(angidx)
        tx = -_sc16(MM_THRUST, cw) if cn else _sc16(MM_THRUST, cw)
        ty = -_sc16(MM_THRUST, sw) if sn else _sc16(MM_THRUST, sw)
        if back:
            tx, ty = -tx, -ty
    # +128 = round to nearest; >> is floor, matching a two's-complement
    # accumulator with its low byte dropped
    dx = (mx * ga + tx * de + 128) >> 8
    dy = (my * ga + ty * de + 128) >> 8
    mx = (mx * al + tx * be + 128) >> 8
    my = (my * al + ty * be + 128) >> 8
    if fwd == back and -MM_STOP < mx < MM_STOP \
            and -MM_STOP < my < MM_STOP:
        mx = my = 0                   # DOOM stop rule, once per frame
    return mx, my, ticrem, dx, dy


def _blk_ang(px, py, nx, ny, z_ps, mover_pos):
    """Wall angle of the box_scan block at (nx,ny); None = sector-rule
    block (no slide). ORDER IS LOAD-BEARING: pm_column_scan walks each
    column list BACKWARDS (LDY pm_n / DEY), so when the box straddles a
    corner and hits two walls, the engine reports the LAST one in list
    order — mirror that here. (box_scan's own verdict is order-free: any
    hit blocks and tm_ob is a max, which is why the try suite stayed
    clean at 0/9,456 while every corner slide diverged.)
    DEVIATION from DOOM: P_SlideMove picks the NEAREST crossed line via
    bestslidefrac; we take a scan-order hit. Corner-only, cosmetic."""
    m = build()
    n_solid = len(m['colsegs'])
    bx0, by0, bx1, by1 = nx - RADIUS, ny - RADIUS, nx + RADIUS, ny + RADIUS
    c0 = max(0, min(COLS - 1, (bx0 - RAWX_MIN) >> 7))
    c1 = max(0, min(COLS - 1, (bx1 - RAWX_MIN) >> 7))
    import math
    for c in ([c0] if c0 == c1 else [c0, c1]):
        off, cnt = m['colidx'][c]
        for k in reversed(range(cnt)):          # engine order (see above)
            idx = m['collist'][off + k]
            if idx < n_solid:
                s = m['colsegs'][idx]
                if _box_hits_seg(bx0, by0, bx1, by1, s):
                    return int(round(math.atan2(s[3], s[2]) * 32 / math.pi)) & 63
            else:
                p = m['ports'][idx - n_solid]
                if _box_hits_seg(bx0, by0, bx1, by1, p[:4]):
                    ob, ot = _port_live(p, mover_pos)
                    if (ot - (ob - EYE_PS) < DOOR_MIN_OPEN_PS or
                            ot - (z_ps - EYE_PS) < DOOR_MIN_OPEN_PS):
                        return p[7] & 63
    return None                           # sector-rule (or bounds) block


def momentum_frame(px88, py88, z_ps, mx, my, ticrem, fields, fwd, back,
                   angidx, mover_pos):
    """One driver frame: tic integration + chunked displacement with
    wall projection. Positions 24-bit 8.8 prescaled center-relative.
    d_fwd (the bca forward-coherence D-class gate) is 1 ONLY when the
    frame's displacement is EXACTLY parallel to the view unit on the
    mag6 grid (cross == 0, dot > 0) and every chunk committed clean:
    friction's independent per-axis floors drift the momentum off the
    ray, and the bbox classifier's certified epsilon has no slack for
    that — so the cache serves on axis/diagonal runs (where alignment
    is exact) and safely sits out the rest.
    Returns (px88, py88, z_ps, mx, my, ticrem, d_fwd)."""
    mx, my, ticrem, dx, dy = momentum_tics(mx, my, ticrem, fields,
                                           fwd, back, angidx)
    if dx == 0 and dy == 0:
        return px88, py88, z_ps, mx, my, ticrem, 0
    tdx, tdy = dx, dy                     # the frame's intended move
    clean = True
    k = 0
    while (abs(dx) >> k) > MM_HALF or (abs(dy) >> k) > MM_HALF:
        k += 1
    chunks = 1 << k
    cdx, cdy = dx >> k, dy >> k           # arithmetic halves (DOOM >>1)
    slides = 0
    while chunks:
        nx88, ny88 = px88 + cdx, py88 + cdy
        nx, ny = nx88 >> 5, ny88 >> 5     # 8.8 prescaled -> raw world int
        px, py = px88 >> 5, py88 >> 5
        ok, vz = try_move(px, py, nx, ny, z_ps, mover_pos)
        if ok:
            px88, py88, z_ps = nx88, ny88, vz
            chunks -= 1
            continue
        if cdx == 0 and cdy == 0:
            break
        if slides < 2:
            w = _blk_ang(px, py, nx, ny, z_ps, mover_pos)
            if w is not None:
                slides += 1
                clean = False
                rx, ry = cdx * chunks, cdy * chunks
                rx, ry = wall_project(rx, ry, w)
                mx, my = wall_project(mx, my, w)
                k = 0
                while (abs(rx) >> k) > MM_HALF or (abs(ry) >> k) > MM_HALF:
                    k += 1
                chunks, cdx, cdy = 1 << k, rx >> k, ry >> k
                continue
        # axis fallback: y-only then x-only; zero the dead axis' momentum
        clean = False
        if cdy and try_move(px, py, px, (py88 + cdy) >> 5,
                            z_ps, mover_pos)[0]:
            ok, vz = try_move(px, py, px, (py88 + cdy) >> 5, z_ps, mover_pos)
            py88 += cdy
            z_ps = vz
            mx = 0
            cdx = 0
            chunks -= 1
            continue
        if cdx and try_move(px, py, (px88 + cdx) >> 5, py,
                            z_ps, mover_pos)[0]:
            ok, vz = try_move(px, py, (px88 + cdx) >> 5, py, z_ps, mover_pos)
            px88 += cdx
            z_ps = vz
            my = 0
            cdy = 0
            chunks -= 1
            continue
        mx = my = 0                       # boxed in: full stop
        break
    d_fwd = 0
    if clean:
        cw, cn, sw, sn = _unit5(angidx)
        ux = -cw if cn else cw
        uy = -sw if sn else sw
        if tdx * uy == tdy * ux:          # exactly on the view ray
            if (tdx != 0 and (tdx > 0) == (ux > 0)) or \
               (tdx == 0 and tdy != 0 and (tdy > 0) == (uy > 0)):
                d_fwd = 1                 # ... pointing forward
    return px88, py88, z_ps, mx, my, ticrem, d_fwd


def _seg_cross(ax, ay, adx, ady, bx, by, bdx, bdy):
    """True iff segment A strictly crosses segment B (double straddle)."""
    def side(px, py, x, y, dx, dy):
        return (px - x) * dy - (py - y) * dx
    s1 = side(ax, ay, bx, by, bdx, bdy)
    s2 = side(ax + adx, ay + ady, bx, by, bdx, bdy)
    if (s1 > 0) == (s2 > 0):
        return False
    s3 = side(bx, by, ax, ay, adx, ady)
    s4 = side(bx + bdx, by + bdy, ax, ay, adx, ady)
    return (s3 > 0) != (s4 > 0)


def use_hit(px, py, ux, uy):
    """First use line crossed by the 64-unit trace. Returns action or None."""
    m = build()
    for x1, y1, dx, dy, act in m['use_lines']:
        if _seg_cross(px, py, ux, uy, x1, y1, dx, dy):
            return act
    return None


def walk_hits(px, py, dx, dy):
    """Walkover movers crossed by a committed move delta."""
    m = build()
    out = []
    for x1, y1, ldx, ldy, act in m['walk_lines']:
        if _seg_cross(px, py, dx, dy, x1, y1, ldx, ldy):
            out.append(act)
    return out
