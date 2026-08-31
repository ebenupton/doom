#!/usr/bin/env python3
"""zprotate -- swap cold zero-page occupants out, hot absolute scalars in.

    python3 tools/zprotate.py             the swap plan
    python3 tools/zprotate.py --apply N   apply the top N swaps

Rotation, not overlaying.  Evicting a COLD zp variable to absolute is
always sound -- absolute addressing reaches it from anywhere, it just
costs a cycle and a byte per access -- and the vacated byte is then
genuinely free for a hot one.  No liveness analysis is needed, and none
of the overlay machinery's assumptions are being trusted.

NET = (accesses gained by the promoted scalar)
    - (accesses lost by the evicted one)

WHAT MAY NOT BE EVICTED, and why each is fatal:
  * indirect bases -- (zp),Y and (zp,X) EXIST ONLY IN ZERO PAGE.  There
    is no absolute form; moving one is not a slowdown, it is a build
    error or, worse, a wild pointer.
  * an indirect JMP vector -- same: JMP (abs) exists, but the engine's
    vectors are read as zp pairs and the DRIVER writes them.
  * ABI-pinned bytes -- anything abi.inc names is a cross-language
    contract with Python harnesses and the tube glue.
  * indexed bases -- zp,X becomes abs,X, which is legal, but the whole
    BLOCK must move together and this tool moves single bytes.
"""
import os, re, sys, collections

ROOT = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), '..'))
os.chdir(ROOT); sys.path.insert(0, ROOT); sys.path.insert(0, os.path.join(ROOT, 'tools'))
os.environ.setdefault('SDL_VIDEODRIVER', 'dummy')
os.environ['PYGAME_HIDE_SUPPORT_PROMPT'] = '1'


def abi_names():
    import abi
    return {n for n in dir(abi) if not n.startswith('_')}


def unsafe_names():
    """Names that MUST NOT leave zero page, found by reading the source.

    The measured filter alone is not sound.  It excludes a byte only if
    the CORPUS happened to execute an indirect or indexed access through
    it, so a pointer whose only dereference sits on a path this corpus
    never takes reads as a plain cold scalar.  zp_pm_p -- the collision
    list pointer, dereferenced as (zp_pm_p),Y in pm_frame's straddle
    arms -- was offered for eviction for exactly that reason, and moving
    it would have assembled a wild pointer rather than failing.

    So the source is the authority.  Three fatal patterns:
      (name)      -- (zp),Y / (zp,X) exist ONLY in zero page.
      name+N      -- somebody depends on what follows it; moving name
                     alone silently re-aims the neighbour reference.
      name,X/,Y   -- an indexed base: the whole block must move together.
    """
    import glob
    pats = [re.compile(r'\(\s*(\w+)\s*[),]'),
            re.compile(r'\b(\w+)\s*[+-]\s*[\$\d]'),
            re.compile(r'\b(\w+)\s*,\s*[XY]\b')]
    bad = set()
    for f in glob.glob(os.path.join(ROOT, 'src', '**', '*.s'), recursive=True) + \
             glob.glob(os.path.join(ROOT, 'src', '**', '*.inc'), recursive=True):
        for line in open(f):
            line = line.split(';')[0]
            for pat in pats:
                bad.update(m.group(1) for m in pat.finditer(line))
    return bad


def plan():
    import zptrawl as T
    hits, modes, nposes, nmove = T.corpus_counts(None)
    names = T.symbols()
    pinned = abi_names() | unsafe_names()

    # --- eviction candidates: ZP bytes reached ONLY by direct zp access ---
    evict = []
    for a in range(0x100):
        m = modes.get(a, {})
        if not m:
            continue
        if m.get('ind') or m.get('zpx') or m.get('zpy'):
            continue                      # indirect/indexed: must stay in ZP
        n = names.get(a)
        if not n:
            # NO NAME, NO MOVE.  An unnamed zero-page byte is one the map
            # cannot see -- in practice the HIGH BYTE of a pointer whose
            # reservation was declared .res 1 with the second byte carried
            # as a "FREE" pad.  $5A read as free and 5.4 accesses/frame;
            # it is zp_pm_p+1, and there is nothing to move.
            continue
        if n in pinned:
            continue                      # ABI contract
        evict.append((hits.get(a, 0), a, n))
    evict.sort()

    # --- promotion candidates: hot absolute scalars (trawl's filters) ---
    promo = [(c, a, names.get(a, '')) for a, c in hits.items()
             if T.promotable(a, modes) and names.get(a, '') not in pinned]
    promo.sort(reverse=True)
    return evict, promo, nposes


def main():
    evict, promo, nposes = plan()
    print(f'\n  ZP ROTATION -- {nposes} render poses + movement')
    print('  ' + '=' * 68)
    print(f'  evictable ZP bytes (direct access only, not ABI): {len(evict)}')
    print(f'  promotable absolute scalars                     : {len(promo)}')
    print(f'\n  {"in":<22}{"gain":>8}   {"out":<22}{"cost":>8}{"net":>8}')
    print('  ' + '-' * 68)
    net_total, n = 0, 0
    for (gain, ha, hn), (cost, ca, cn) in zip(promo, evict):
        if gain <= cost:
            break
        net = (gain - cost) / nposes
        net_total += net; n += 1
        print(f'  {hn or hex(ha):<22}{gain/nposes:8.1f}   '
              f'{cn:<22}{cost/nposes:8.1f}{net:8.1f}')
    if not n:
        print('  none -- zero page already holds the hottest scalars')
    else:
        print('  ' + '-' * 68)
        print(f'  {n} swaps, net {net_total:,.0f} cycles/frame')
    print()


if __name__ == '__main__':
    main()
