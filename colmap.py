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

    # per-column (128-unit) lists
    colidx = []
    collist = []
    for c in range(COLS):
        cx0 = RAWX_MIN + c * 128 - RADIUS
        cx1 = RAWX_MIN + (c + 1) * 128 + RADIUS
        mine = [i for i, (x1, y1, dx, dy) in enumerate(colsegs)
                if max(x1, x1 + dx) >= cx0 and min(x1, x1 + dx) <= cx1]
        colidx.append((len(collist), len(mine)))
        collist.extend(mine)

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

    _built = dict(colsegs=colsegs, colidx=colidx, collist=collist,
                  ss_vz=bytes(ss_vz), ss_info=bytes(ss_info),
                  mv_minpass=bytes(mv_minpass),
                  use_lines=use_lines, walk_lines=walk_lines,
                  movers=movers)
    return _built


# ── binary emission ─────────────────────────────────────────────────────
SPEED = 12                # world units / frame (walk_drv SPEED)
USE_TRACE = 60            # SPACE trace length (raw units; DOOM uses 64)


def step_table():
    """64 x 4: (dx, dy) s16 8.8 movement deltas — byte-exact with the
    old beebasm FOR table (INT(x + 65536.5) AND &FFFF idiom)."""
    import math, struct
    out = bytearray()
    for i in range(64):
        for v in (SPEED * 32 * math.cos(i * math.pi / 32),
                  SPEED * 32 * math.sin(i * math.pi / 32)):
            out += struct.pack('<H', int(v + 65536.5) & 0xFFFF)
    return bytes(out)


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
        A = dict(idx=0x7600, colseg=0x77E0, ss_vz=0xE750, ss_info=0xE830,
                 minpass=0xE910, usetab=0xE918)
    else:
        A = dict(idx=0xB4A4, colseg=0xB8C0, ss_vz=0x8C00, ss_info=0x8CE0,
                 minpass=0xBFC0, usetab=0xBE00)
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
    out = {A['colseg']: bytes(seg_blob), A['idx']: bytes(idx_blob),
           A['ss_vz']: m['ss_vz'], A['ss_info']: m['ss_info'],
           A['minpass']: m['mv_minpass'], A['usetab']: bytes(ub)}
    # home-range asserts (free-space windows audited 2026-08-14)
    if flat:
        assert A['idx'] + len(idx_blob) <= A['colseg']
        assert A['colseg'] + len(seg_blob) <= 0x7F00, \
            'collision blob reaches the flat PMOVE region at $7F00'
        assert 0xE750 + len(m['ss_vz']) <= 0xE830
        assert 0xE830 + len(m['ss_info']) <= 0xE910
        assert A['usetab'] + len(ub) <= 0xEA00, 'USETAB reaches the FB'
    else:
        assert 0xB8C0 + len(seg_blob) <= 0xBFC0, 'COLSEG overruns MV_MINPASS'
        assert 0xB4A4 + len(idx_blob) <= 0xB700, 'COLIDX blob reaches DIR'
        assert len(m['ss_vz']) <= 0xE0 and len(m['ss_info']) <= 0xE0
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
    dirs_off = lay['off_seg_hdr'] + lay['n_segs'] * 16

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


def box_blocked(rx, ry):
    m = build()
    bx0, by0, bx1, by1 = rx - RADIUS, ry - RADIUS, rx + RADIUS, ry + RADIUS
    c0 = max(0, min(COLS - 1, (bx0 - RAWX_MIN) >> 7))
    c1 = max(0, min(COLS - 1, (bx1 - RAWX_MIN) >> 7))
    for c in {c0, c1}:
        off, cnt = m['colidx'][c]
        for k in range(cnt):
            if _box_hits_seg(bx0, by0, bx1, by1,
                             m['colsegs'][m['collist'][off + k]]):
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
    """Full DOOM try-move for one candidate. Returns (ok, new_vz)."""
    if not (RAWX_MIN <= nx <= RAWX_MIN + 36 * 128 - 1 and
            RAWY_MIN <= ny <= RAWY_MIN + 22 * 128 - 1):
        return False, z_ps
    if box_blocked(nx, ny):
        return False, z_ps
    return dest_check(nx, ny, z_ps, mover_pos)


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
