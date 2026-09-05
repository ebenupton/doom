#!/usr/bin/env python3
"""Systematic branch-alignment pass for the NJ rasteriser.

THE COST BEING ATTACKED.  On a 6502 a TAKEN relative branch costs one extra
cycle when its target sits on a different page from the byte after the
branch; an absolute-indexed READ costs one extra when base_lo + index
carries.  Both depend only on WHERE the code sits, so they are pure layout
tax: cycles bought with nothing.

THE KEY PROPERTY that makes an exhaustive search possible: the rasteriser's
algorithm does not depend on its own address, so the number of times each
branch is TAKEN is layout-invariant.  Measure those counts once (with
tools/raster_bench.py over the canned engine workload) and the cost of ANY
candidate layout is a closed-form sum -- no re-simulation, ~10 us per
candidate.  That turns "try a few alignments and re-measure" into a real
search over millions of layouts.

THE MOVE SET, and why each move is cycle-neutral:
  PADDING   bytes inserted immediately after an unconditional transfer
            (JMP / RTS / RTI) are never executed: control cannot fall into
            them, and no label moves onto them (labels travel with their
            code).  They cost only space.
  REORDER   two chunks delimited by unconditional transfers may swap places
            when no relative branch spans the boundary between them, since
            every remaining edge is an absolute JMP or a table entry that
            the assembler re-resolves.
Both are enumerated here; both preserve the executed instruction sequence
exactly, so the pixel output is unchanged by construction -- and that is
then PROVED, not assumed, against the 42,462-line golden corpus.

Usage:
  python3 tools/raster_align.py census      # where the layout tax is
  python3 tools/raster_align.py search      # find the best layout
  python3 tools/raster_align.py apply       # write it into the source
"""
import os, re, sys, json, subprocess, argparse

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, ROOT)
sys.path.insert(0, os.path.join(ROOT, 'tools'))

SRC = os.path.join(ROOT, 'src', 'boot', 'linedraw_or.s')
BOOT = os.path.join(ROOT, 'src', 'boot')
CFG = os.path.join(ROOT, 'src', 'boot', 'cfg')

BRANCH_OPS = {0x10: 'BPL', 0x30: 'BMI', 0x50: 'BVC', 0x70: 'BVS',
              0x90: 'BCC', 0xB0: 'BCS', 0xD0: 'BNE', 0xF0: 'BEQ'}
# absolute-indexed READ opcodes (write forms have no page penalty)
IDX_READ = {0xBD, 0xB9, 0xBC, 0xBE, 0x1D, 0x19, 0x3D, 0x39, 0x5D, 0x59,
            0x7D, 0x79, 0xDD, 0xD9, 0xFD, 0xF9, 0x3C, 0x1C}
UNCOND = {0x4C: 3, 0x6C: 3, 0x60: 1, 0x40: 1}      # JMP abs/ind, RTS, RTI

VARIANTS = dict(
    banked=dict(defs=('FLATORG=0',), cfg='linedraw_or_banked.cfg',
                out='linedraw_or_reloc.bin', org=0xA200, budget=0x0C00),
    flat=dict(defs=('FLATORG=1',), cfg='linedraw_or_flat.cfg',
              out='linedraw_or_flat.bin', org=0x7500, budget=0x0B00),
    # HOSTT: hostg.s .includes the same raster sources, so the tube host
    # is a third layout of this code -- and the one that draws every pixel
    # in the copro build.  Its ORG is $1900 and the entry is linedraw4
    # inside the program; the budget is what the host has below the screen.
    hostt=dict(src='hostg.s', defs=('BANKED=1',), cfg='hostg.cfg',
               org=0x1900, budget=0x3F00, entry='linedraw4'))


# ---------------------------------------------------------------- assembling

def assemble(variant, src_text=None, out=None):
    """Assemble+link the blob, optionally from a patched source text.
    Returns (image bytes, listing path)."""
    v = VARIANTS[variant]
    src = os.path.join(BOOT, v['src']) if v.get('src') else SRC
    tmp = None
    if src_text is not None:
        tmp = os.path.join(ROOT, 'build', '_align_src.s')
        open(tmp, 'w').write(src_text)
        src = tmp
    obj = os.path.join(ROOT, 'build', f'_align_{variant}.o')
    binp = out or os.path.join(ROOT, 'build', f'_align_{variant}.bin')
    lst = os.path.join(ROOT, 'build', f'_align_{variant}.lst')
    os.makedirs(os.path.join(ROOT, 'build'), exist_ok=True)
    cmd = ['ca65', '-I', BOOT, '-l', lst]
    for d in v['defs']:
        cmd += ['-D', d]
    subprocess.run(cmd + [src, '-o', obj], cwd=ROOT, check=True,
                   capture_output=True)
    lbl = os.path.join(ROOT, 'build', f'_align_{variant}.lbl')
    subprocess.run(['ld65', '-C', os.path.join(CFG, v['cfg']), obj, '-o', binp,
                    '-Ln', lbl], cwd=ROOT, check=True, capture_output=True)
    return open(binp, 'rb').read(), lst


# ------------------------------------------------------- source <-> listing

def expand_source(variant):
    """The source as the assembler sees it: [(file, lineno, text), ...] with
    .include expanded in order.  Conditional blocks are NOT evaluated (the
    listing prints skipped lines too, so the walk still lines up)."""
    out = []

    def rd(path, depth=0):
        for i, line in enumerate(open(path), 1):
            t = line.rstrip('\n')
            out.append((path, i, t))
            m = re.match(r'\s*\.include\s+"([^"]+)"', t)
            if m and depth < 4:
                inc = os.path.normpath(os.path.join(os.path.dirname(path),
                                                    m.group(1)))
                if os.path.exists(inc):
                    rd(inc, depth + 1)
    v = VARIANTS[variant]
    rd(os.path.join(BOOT, v['src']) if v.get('src') else SRC)
    return out


LST_ROW = re.compile(r'^([0-9A-Fa-f]{6})([r ])\s+\d+\s{1,2}(.*)$')


def parse_listing(lst, variant):
    """[(offset, nbytes, file, lineno, text)] for every source line that
    emitted bytes, plus the full row list for the source walk."""
    src = expand_source(variant)
    rows = []
    si = 0
    for line in open(lst):
        m = LST_ROW.match(line.rstrip('\n'))
        if not m:
            continue
        off = int(m.group(1), 16)
        rest = m.group(3)
        # byte columns: pairs of hex digits (or 'rr'/'xx') up to 8 chars wide,
        # then the source text.  Split on the run of spaces before the text.
        mb = re.match(r'^((?:[0-9A-Fa-frx]{2} )*)\s*(.*)$', rest)
        bytecol, text = mb.group(1), mb.group(2)
        n = len(bytecol.split())
        text = text.strip()
        # Walk the source forward to the next line carrying this text.
        # A BLANK listing row must NOT drive the walk: the listing emits
        # blanks the source does not have, and matching one to the next
        # blank source line jumps the pointer over a whole .include (which
        # is exactly how 665 rows landed in the wrong file).  Blank rows
        # emit no bytes, so skipping them costs nothing.
        if not text:
            rows.append(dict(off=off, n=n, file=None, line=None, text=text))
            continue
        j = si
        found = None
        while j < len(src):
            if src[j][2].strip() == text:
                found = j
                break
            j += 1
        if found is not None:
            si = found + 1
            f, ln, _ = src[found]
        else:
            f, ln = None, None
        rows.append(dict(off=off, n=n, file=f, line=ln, text=text))
    return rows


# ------------------------------------------------------------- layout model

class Layout:
    """Atoms, references and safe padding slots for one blob variant."""

    RASTER_SRC = ('nj-linedraw4-or.s', 'shallow_12_hamiltonian-or.s',
                  'shallow_23_hamiltonian-or.s')

    def __init__(self, variant):
        self.variant = variant
        v = VARIANTS[variant]
        self.org = v['org']
        self.budget = v['budget']
        self.image, lst = assemble(variant)
        self.rows = [r for r in parse_listing(lst, variant) if r['n']]
        self.size = len(self.image)
        self.entry = self.org
        if v.get('entry'):
            import build_boot
            lbl = os.path.join(ROOT, 'build', f'_align_{variant}.lbl')
            self.entry = build_boot.symbols(lbl)[v['entry']]
        self._decode()

    def _decode(self):
        """Instruction atoms.  A listing row that emitted bytes and whose
        text starts with a 3-letter mnemonic is one instruction; anything
        else (.byte tables) is data and never a padding site."""
        img, org = self.image, self.org
        self.branches = []      # dicts: off, target, op
        self.indexed = []       # dicts: off, base
        self.slots = []         # (offset_after, row_index) padding sites
        for i, r in enumerate(self.rows):
            off = r['off']
            if off >= len(img):
                continue
            op = img[off]
            txt = r['text']
            mn = re.match(r'(?:\w+:\s*)?([A-Z]{3})\b', txt)
            if not mn:
                continue                       # data (.byte tables)
            if op in BRANCH_OPS and r['n'] == 2:
                d = img[off + 1]
                d = d - 256 if d & 0x80 else d
                self.branches.append(dict(off=off, target=off + 2 + d, op=op))
            elif op in IDX_READ and r['n'] == 3:
                base = img[off + 1] | (img[off + 2] << 8)
                if org <= base < org + len(img):
                    self.indexed.append(dict(off=off, base=base - org))
            if op in UNCOND and r['n'] == UNCOND[op]:
                # Only the RASTER sources are padding sites.  hostt's image
                # is a whole program; putting pads in its own code would
                # shift the tube glue for no gain and is not this pass's
                # business.
                if os.path.basename(r['file'] or '') in self.RASTER_SRC:
                    self.slots.append(dict(off=off + r['n'], row=i,
                                           after=txt, file=r['file'],
                                           line=r['line']))
        # a slot is only usable if we know which source line to write after
        self.slots = [s for s in self.slots if s['line'] is not None]

    # -- the analytic cost model -------------------------------------------
    def regions(self, pads):
        """Cumulative byte offset applied to code at each slot boundary."""
        cuts = [s['off'] for s in self.slots]
        return cuts, [sum(pads[:i + 1]) for i in range(len(pads))]

    def shift_of(self, off, cuts, cum):
        """Bytes of padding inserted strictly before `off`."""
        lo, hi = 0, len(cuts)
        while lo < hi:                       # bisect_right
            mid = (lo + hi) // 2
            if cuts[mid] <= off:
                lo = mid + 1
            else:
                hi = mid
        return cum[lo - 1] if lo else 0


def prepare(layout, weights, idx_weights):
    """Freeze the model into flat arrays for fast evaluation."""
    import numpy as np
    cuts = np.array([s['off'] for s in layout.slots], dtype=np.int32)

    def reg(offs):
        return np.searchsorted(cuts, offs, side='right')

    b = layout.branches
    bs = np.array([x['off'] for x in b], dtype=np.int32)
    bt = np.array([x['target'] for x in b], dtype=np.int32)
    bw = np.array([weights.get(x['off'], 0) for x in b], dtype=np.int64)
    keep = bw > 0
    m = dict(bs=bs[keep], bt=bt[keep], bw=bw[keep],
             brs=reg(bs[keep]), brt=reg(bt[keep]))
    # every branch, weighted or not, still has to stay IN RANGE
    m['all_s'], m['all_t'] = bs, bt
    m['all_rs'], m['all_rt'] = reg(bs), reg(bt)
    ix = layout.indexed
    m['ib'] = np.array([x['base'] for x in ix], dtype=np.int32)
    m['irb'] = reg(m['ib'])
    # Per-site index histogram, folded into a 256-entry table over the
    # base's LOW byte: cost[lo] = how many of this site's reads carry when
    # the table starts at lo (cross iff lo + index > 255).  Folding it here
    # turns the inner loop of the search from ~8 numpy calls per site into
    # one gather, which is what makes millions of candidates affordable.
    m['ihist'] = [idx_weights.get(x['off'], {}) for x in ix]
    m['itab'] = np.zeros((len(ix), 256), dtype=np.int64)
    for k, h in enumerate(m['ihist']):
        for lo in range(256):
            m['itab'][k, lo] = sum(n for i, n in h.items() if lo + i > 255)
    m['n_slots'] = len(cuts)
    m['org'] = layout.org
    return m


def cost(m, pads):
    """Weighted layout tax (cycles) for a padding vector.  Returns
    (cost, in_range) -- in_range False means some branch went out of ±127."""
    import numpy as np
    cum = np.concatenate(([0], np.cumsum(pads)))       # cum[r] for region r
    org = m['org']
    s = org + m['bs'] + cum[m['brs']] + 2
    t = org + m['bt'] + cum[m['brt']]
    c = int((m['bw'] * ((s >> 8) != (t >> 8))).sum())
    if len(m['ib']):
        lo = (org + m['ib'] + cum[m['irb']]) & 0xFF
        c += int(m['itab'][np.arange(len(m['ib'])), lo].sum())
    a = org + m['all_s'] + cum[m['all_rs']] + 2
    at = org + m['all_t'] + cum[m['all_rt']]
    d = at - a
    return c, bool(np.all((d >= -128) & (d <= 127)))


def cost_batch(m, pads):
    """Vectorised cost over a batch of padding vectors, shape (N, n_slots).
    Returns (cost[N], ok[N]) — ok False where a branch left ±127 range."""
    import numpy as np
    N = pads.shape[0]
    cum = np.zeros((N, m['n_slots'] + 1), dtype=np.int32)
    np.cumsum(pads, axis=1, out=cum[:, 1:])
    org = m['org']
    s = org + m['bs'][None, :] + cum[:, m['brs']] + 2
    t = org + m['bt'][None, :] + cum[:, m['brt']]
    c = (m['bw'][None, :] * ((s >> 8) != (t >> 8))).sum(1)
    if len(m['ib']):
        lo = (org + m['ib'][None, :] + cum[:, m['irb']]) & 0xFF
        c = c + m['itab'][np.arange(len(m['ib']))[None, :], lo].sum(1)
    a = org + m['all_s'][None, :] + cum[:, m['all_rs']] + 2
    at = org + m['all_t'][None, :] + cum[:, m['all_rt']]
    d = at - a
    ok = ((d >= -128) & (d <= 127)).all(1)
    return c, ok


def search(m, budget, depth2=True, iters=400_000, seed=1, log=print):
    """Exhaustive over 1- and 2-slot insertions, then iterated local search.

    Depth 1 and 2 are complete: every legal (slot, bytes) and every legal
    (slot_i, a) + (slot_j, b) with a + b <= budget is evaluated.  Beyond
    that the space is C(budget+S, S), so the pass switches to restarts of
    single-slot hill climbing, which for this size converges to the depth-2
    optimum or better on every restart tried."""
    import numpy as np
    S = m['n_slots']
    rng = np.random.default_rng(seed)
    base, _ = cost_batch(m, np.zeros((1, S), dtype=np.int32))
    best = (int(base[0]), np.zeros(S, dtype=np.int32))
    log(f'  depth 0 (as built): {best[0]} cyc')

    # ---- depth 1: complete ----
    cand = []
    for i in range(S):
        for a in range(1, budget + 1):
            v = np.zeros(S, dtype=np.int32); v[i] = a
            cand.append(v)
    P = np.array(cand, dtype=np.int32)
    c, ok = cost_batch(m, P)
    c = np.where(ok, c, 1 << 30)
    k = int(c.argmin())
    if c[k] < best[0]:
        best = (int(c[k]), P[k].copy())
    log(f'  depth 1 ({len(P):,} layouts): {int(c[k])} cyc')

    # ---- depth 2: complete ----
    if depth2:
        pairs = [(i, j) for i in range(S) for j in range(i + 1, S)]
        for (i, j) in pairs:
            ab = [(a, b) for a in range(1, budget) for b in range(1, budget + 1 - a)]
            P = np.zeros((len(ab), S), dtype=np.int32)
            aa = np.array(ab, dtype=np.int32)
            P[:, i] = aa[:, 0]; P[:, j] = aa[:, 1]
            c, ok = cost_batch(m, P)
            c = np.where(ok, c, 1 << 30)
            k = int(c.argmin())
            if c[k] < best[0]:
                best = (int(c[k]), P[k].copy())
        log(f'  depth 2 (complete, {len(pairs):,} slot pairs): {best[0]} cyc')

    # ---- beyond: restarts of single-slot hill climbing ----
    cur = best[1].copy(); curc = best[0]
    for it in range(iters):
        if it % 20_000 == 0 and it:
            cur = best[1].copy(); curc = best[0]
            cur[rng.integers(S)] = rng.integers(0, budget // 2 + 1)
            cc, ok = cost_batch(m, cur[None, :])
            curc = int(cc[0]) if ok[0] and cur.sum() <= budget else 1 << 30
        i = int(rng.integers(S))
        room = budget - (cur.sum() - cur[i])
        if room <= 0:
            continue
        trial = np.repeat(cur[None, :], room + 1, axis=0)
        trial[:, i] = np.arange(room + 1)
        c, ok = cost_batch(m, trial)
        c = np.where(ok, c, 1 << 30)
        k = int(c.argmin())
        if c[k] < curc:
            curc = int(c[k]); cur = trial[k].copy()
            if curc < best[0]:
                best = (curc, cur.copy())
    log(f'  local search ({iters:,} moves): {best[0]} cyc')
    # ---- trim: the slack is a resource, so spend the least that buys the
    # win.  The banked blob has only 119 B before it reaches VPLOTC, and a
    # layout that eats all of it leaves the next edit nowhere to grow.
    c0, pads = best
    for i in range(S):
        for v in range(0, int(pads[i])):
            t = pads.copy(); t[i] = v
            c, ok = cost_batch(m, t[None, :])
            if ok[0] and int(c[0]) <= c0:
                pads = t
                break
    log(f'  trimmed to {int(pads.sum())} B of padding at {c0} cyc')
    return c0, pads


# ------------------------------------------------------------- reordering

def units(layout):
    """Maximal blocks of code that may be REORDERED as a whole.

    Cut the blob at every safe slot (control never flows across one).  A
    relative branch that crosses a cut pins the two sides together, because
    reordering would put its target out of reach; merge those chunks.  What
    survives is a set of self-contained units whose only outward edges are
    absolute JMPs and table entries — both re-resolved by the assembler —
    so any permutation of them assembles to the same executed code.

    The unit holding offset 0 is pinned: RASTER_ENTRY is the blob's first
    byte and the engine JMPs to it by address.
    """
    cuts = [s['off'] for s in layout.slots]
    bounds = [0] + cuts + [layout.size]
    nch = len(bounds) - 1

    def chunk_of(off):
        lo, hi = 0, nch
        while lo < hi:
            mid = (lo + hi) // 2
            if bounds[mid + 1] <= off:
                lo = mid + 1
            else:
                hi = mid
        return lo

    parent = list(range(nch))

    def find(a):
        while parent[a] != a:
            parent[a] = parent[parent[a]]; a = parent[a]
        return a

    def join(a, b):
        ra, rb = find(a), find(b)
        if ra != rb:
            parent[max(ra, rb)] = min(ra, rb)

    for br in layout.branches:
        a, b = chunk_of(br['off']), chunk_of(br['target'])
        if a != b:
            join(a, b)
    # collapse each component to the contiguous span it covers, then merge
    # any spans that overlap — units have to be contiguous to be swapped
    spans = {}
    for i in range(nch):
        r = find(i)
        lo, hi = spans.get(r, (i, i))
        spans[r] = (min(lo, i), max(hi, i))
    merged = []
    for lo, hi in sorted(spans.values()):
        if merged and lo <= merged[-1][1]:
            merged[-1][1] = max(merged[-1][1], hi)
        else:
            merged.append([lo, hi])
    return [dict(chunks=(lo, hi), lo=bounds[lo], hi=bounds[hi + 1],
                 size=bounds[hi + 1] - bounds[lo],
                 pinned=(lo == 0)) for lo, hi in merged]


class View:
    """A Layout re-expressed under a unit permutation (offsets remapped).
    Everything the cost model reads — branch sites/targets, indexed bases,
    padding slots — is relative, so the same model code serves both."""

    def __init__(self, layout, order):
        U = units(layout)
        self.units, self.order, self.org = U, list(order), layout.org
        self.size, self.budget = layout.size, layout.budget
        base, acc = {}, 0
        for u in order:
            base[u] = acc; acc += U[u]['size']
        assert acc == layout.size

        def mp(off):
            for i, u in enumerate(U):
                if u['lo'] <= off < u['hi']:
                    return base[i] + off - u['lo']
            return acc                       # one past the end
        self.map = mp
        self.branches = [dict(b, off=mp(b['off']), target=mp(b['target']))
                         for b in layout.branches]
        self.indexed = [dict(x, base=mp(x['base'])) for x in layout.indexed]
        self.slots = sorted((dict(s, off=mp(s['off'])) for s in layout.slots),
                            key=lambda s: s['off'])


def prepare_view(view, weights, idx_weights, layout):
    """prepare() for a permuted view: weights are keyed by ORIGINAL offset,
    so they are looked up before the remap."""
    import numpy as np
    w = {}
    for b0, b1 in zip(layout.branches, view.branches):
        if weights.get(b0['off']):
            w[b1['off']] = weights[b0['off']]
    ih = {}
    for x0, x1 in zip(layout.indexed, view.indexed):
        if idx_weights.get(x0['off']):
            ih[x1['off']] = idx_weights[x0['off']]
    return prepare(view, w, ih)


# ------------------------------------------------------------------- driver

def load_weights(variant, layout=None):
    """Run the canned workload on this variant's image and key the results
    by BLOB OFFSET (layout-invariant identity)."""
    import raster_bench as B
    wl = B.load_workload()
    L = layout or Layout(variant)
    b = B.Bench(image=L.image, org=L.org, entry=L.entry, budget=L.budget,
                name=variant)
    total, dig, w, ih = B.measure(b, wl)
    return wl, b, total, dig, w, ih


def cmd_census(a):
    """Report (and optionally gate) the layout tax.

    The alignment this pass buys is nailed to the blob's ORG: move the
    rasteriser's home and every page boundary moves under it.  --max turns
    that from a silent loss into a failing gate.
    """
    worst = 0
    for variant in a.variants:
        L = Layout(variant)
        wl, b, total, dig, w, ih = load_weights(variant, L)
        m = prepare(L, w, ih)
        import numpy as np
        c, _ = cost(m, np.zeros(m['n_slots'], dtype=np.int64))
        nfr = len(wl['frames'])
        U = units(L)
        print(f'--- {variant}: {L.size} B at ${L.org:04X}, '
              f'slack {L.budget - L.size} B')
        print(f'    workload {len(wl["lines"])} lines / {nfr} frames, '
              f'{total:,} cyc ({total/nfr:,.0f}/frame)')
        print(f'    layout tax {c} cyc ({c/nfr:.1f}/frame, {c/total:.2%} of the blob)')
        print(f'    {len(L.branches)} branches ({len(w)} ever taken), '
              f'{len(L.indexed)} internal indexed reads, '
              f'{len(L.slots)} safe padding slots, {len(U)} reorderable units')
        top = sorted(((wt, off) for off, wt in w.items()), reverse=True)
        cross = []
        for br in L.branches:
            s = L.org + br['off'] + 2; t = L.org + br['target']
            if (s >> 8) != (t >> 8) and w.get(br['off']):
                cross.append((w[br['off']], br))
        cross.sort(reverse=True, key=lambda x: x[0])
        print(f'    crossing branches, worst first:')
        for wt, br in cross[:8]:
            row = next(r for r in L.rows if r['off'] == br['off'])
            print(f'      ${L.org + br["off"]:04X} {row["text"][:26]:26} '
                  f'{wt:5d} cyc   {os.path.basename(row["file"] or "?")}:{row["line"]}')
        worst = max(worst, c / nfr)
    if a.max is not None:
        ok = worst <= a.max
        print(f'RASTERALIGN: {"PASS" if ok else "FAIL"} — worst variant '
              f'{worst:.1f} cyc/frame of layout tax (limit {a.max})')
        return 0 if ok else 1


def cmd_search(a):
    """Complete at depth 1 and 2 for padding, complete over single unit
    swaps for reordering, heuristic beyond both.

    Exhausting the joint space is not possible and saying so is part of the
    design: padding alone is C(budget+S, S) layouts (10^40 for the banked
    blob) and the unit orders are 10! on top.  What IS exhausted is every
    move of depth 1 and 2, which is where the whole prize turned out to
    live; the local search past that only ever shaved single cycles.
    """
    import numpy as np, itertools, json, time
    res = {}
    for variant in a.variants:
        L = Layout(variant)
        wl, b, total, dig, w, ih = load_weights(variant, L)
        # Alignment is periodic mod 256, so more than a page of total shift
        # can never buy anything a smaller one cannot; cap the search there
        # (HOSTT has 12.6 KB of headroom, which would make depth 2 infinite).
        budget = min(L.budget - L.size, a.budget)
        U = units(L)
        idx = list(range(len(U)))
        print(f'=== {variant}: {L.size} B, slack {budget}, '
              f'{len(L.slots)} slots, {len(U)} units', flush=True)

        def depth1(order):
            """Best cost reachable from `order` with ONE padding insertion."""
            V = View(L, order)
            m = prepare_view(V, w, ih, L)
            S = m['n_slots']
            P = np.zeros((S * (budget + 1), S), dtype=np.int32)
            k = 0
            for i in range(S):
                for x in range(budget + 1):
                    P[k, i] = x; k += 1
            c, ok = cost_batch(m, P)
            return int(np.where(ok, c, 1 << 30).min())

        # ---- reordering: every single swap of two units (complete) ----
        t0 = time.time()
        free = [i for i in idx if not U[i]["pinned"]]
        swaps = [(i, j) for i in free for j in free if i < j]
        base1 = depth1(idx)
        ranked = []
        for (i, j) in swaps:
            o = list(idx); o[i], o[j] = o[j], o[i]
            ranked.append((depth1(o), tuple(o)))
        ranked.sort()
        print(f'    {len(swaps)} single unit swaps in {time.time()-t0:.0f}s: '
              f'best {ranked[0][0] if ranked else base1} vs {base1} as built',
              flush=True)

        # ---- full padding search on the as-built order and the best swaps -
        best = None
        cands = [tuple(idx)] + [o for c, o in ranked[:a.perms] if c < base1]
        for o in cands:
            V = View(L, o)
            m = prepare_view(V, w, ih, L)
            tag = 'as-built order' if o == tuple(idx) else f'order {o}'
            print(f'    {tag}:', flush=True)
            c, pads = search(m, budget, depth2=True, iters=a.iters,
                             log=lambda s: print('  ' + s, flush=True))
            if best is None or c < best[0]:
                best = (c, pads, o)
        c, pads, o = best
        V = View(L, o)
        print(f'    BEST {variant}: {c} cyc (was {base1 and ""}'
              f'{depth1.__name__ and ""}{c}), '
              f'{int(pads.sum())} B of padding, order '
              f'{"as built" if o == tuple(idx) else o}', flush=True)
        # map each chosen pad back to the source line it follows
        out = []
        for k, v in enumerate(pads):
            if not v:
                continue
            s_new = V.slots[k]
            out.append(dict(n=int(v), off=int(s_new["off"]),
                            file=s_new["file"], line=int(s_new["line"]),
                            after=s_new["after"]))
        res[variant] = dict(before=int(cost(prepare(L, w, ih),
                                            np.zeros(len(L.slots),
                                                     dtype=np.int64))[0]),
                            best=int(c), order=list(o),
                            pad_bytes=int(pads.sum()), pads=out,
                            blob_cycles=int(total), frames=len(wl["frames"]))
    json.dump(res, open(a.out, "w"), indent=1)
    print(f"wrote {a.out}")


PAD_TAG = 'align:'
PADS_INC = os.path.join(BOOT, 'raster', 'align_pads.inc')
RA_BUILD = dict(banked=1, hostt=2, flat=3)
RASTER_FILES = [os.path.join(BOOT, 'raster', f) for f in
                ('nj-linedraw4-or.s', 'shallow_12_hamiltonian-or.s',
                 'shallow_23_hamiltonian-or.s')]


def strip_pads(text):
    """Remove every line this tool inserted, so a re-tune starts clean."""
    return '\n'.join(l for l in text.split('\n') if PAD_TAG not in l)


def clean_sources():
    n = 0
    for f in RASTER_FILES + [SRC, os.path.join(BOOT, 'hostg.s')]:
        t = open(f).read()
        c = strip_pads(t)
        if c != t:
            open(f, 'w').write(c); n += 1
    if os.path.exists(PADS_INC):
        os.remove(PADS_INC); n += 1
    return n


def pad_name(f, line):
    stem = os.path.basename(f).split('-')[0].split('_')[0].upper()[:2]
    return f'RA_PAD_{stem}{line:04d}'


def cmd_apply(a):
    """Write the chosen padding into the sources.

    THREE BUILDS SHARE THESE SOURCES: the banked engine blob at $A200, the
    tube host's copy inside HOSTT, and the (currently unloaded) flat blob.
    A pad that aligns one misaligns another, so the amounts live in a
    generated table selected by RA_BUILD, and each site in the raster
    source is just `.res RA_PAD_xxxx, $EA`.  A build that sets no RA_BUILD
    gets zeros and the code it always had.
    """
    if a.clear:
        print(f'cleared {clean_sources()} file(s)'); return
    res = json.load(open(a.out))
    clean_sources()
    sites = {}                          # (file, line) -> {variant: n}
    for variant, r in res.items():
        if a.variants and variant not in a.variants:
            continue
        if list(r['order']) != sorted(r['order']):
            sys.exit(f'{variant}: best layout reorders units {r["order"]}; '
                     'apply writes padding only — a reorder is a source move')
        for p in r['pads']:
            sites.setdefault((p['file'], p['line']), {})[variant] = p['n']
    if not sites:
        print('nothing to apply'); return
    names = {k: pad_name(*k) for k in sites}

    # --- the generated table ------------------------------------------
    out = ['; GENERATED by tools/raster_align.py — DO NOT EDIT.',
           ';',
           '; Branch-alignment padding for the NJ rasteriser.  On a 6502 a',
           '; taken branch costs one extra cycle when its target is on a',
           '; different page from the byte after the branch, so where the',
           '; code sits is worth real cycles.  Each RA_PAD below is a count',
           '; of never-executed bytes inserted after an unconditional',
           '; transfer to move the code that follows onto a better page.',
           ';',
           '; The three builds of these sources have three different homes,',
           '; so each gets its own column.  RA_BUILD selects one; a build',
           '; that sets none gets zeros and the original layout.',
           ';   1 = banked engine blob, ORG $A200 (banked_bsp / bank C)',
           ';   2 = tube host, inside HOSTT at $1900 (hostg.s)',
           ';   3 = flat blob, ORG $7500',
           '',
           '.ifndef RA_BUILD',
           'RA_BUILD = 0',
           '.endif', '']
    for variant in ('banked', 'hostt', 'flat'):
        vals = [(names[k], sites[k].get(variant, 0)) for k in sorted(sites)]
        if not any(v for _, v in vals) and variant not in res:
            continue
        kw = '.if' if variant == 'banked' else '.elseif'
        out.append(f'{kw} RA_BUILD = {RA_BUILD[variant]}')
        for n, v in vals:
            out.append(f'{n} = {v}')
        out.append('')
    out += ['.else']
    for k in sorted(sites):
        out.append(f'{names[k]} = 0')
    out += ['.endif', '']
    open(PADS_INC, 'w').write('\n'.join(out))
    print(f'  {os.path.relpath(PADS_INC, ROOT)}: {len(sites)} pad site(s)')

    # --- the .res lines, and the include that defines their names -----
    byfile = {}
    for (f, ln) in sites:
        byfile.setdefault(f, []).append(ln)
    for f, lns in byfile.items():
        lines = open(f).read().split('\n')
        for ln in sorted(lns, key=lambda x: -x):
            ind = re.match(r'\s*', lines[ln - 1]).group(0) or '    '
            per = ' '.join(f'{v}={n}' for v, n in
                           sorted(sites[(f, ln)].items()))
            lines.insert(ln, f'{ind}.res {names[(f, ln)]}, $EA   ; {PAD_TAG} '
                             f'never executed — page-alignment ({per})')
        open(f, 'w').write('\n'.join(lines))
        print(f'  {os.path.relpath(f, ROOT)}: {len(lns)} pad(s)')
    # the table has to be defined before the first .res that reads it
    nj = RASTER_FILES[0]
    t = open(nj).read()
    if 'align_pads.inc' not in t:
        lines = t.split('\n')
        k = next(i for i, l in enumerate(lines) if l.startswith('SCREEN_WIDTH'))
        lines.insert(k, '   .include "raster/align_pads.inc"   ; ' + PAD_TAG
                        + ' generated pad table (tools/raster_align.py)')
        lines.insert(k + 1, '')
        open(nj, 'w').write('\n'.join(lines))
    for wrapper, variant in ((SRC, 'banked'), (os.path.join(BOOT, 'hostg.s'),
                                               'hostt')):
        t = open(wrapper).read()
        if 'RA_BUILD' in t:
            continue
        lines = t.split('\n')
        k = next(i for i, l in enumerate(lines)
                 if '.include "raster/nj-linedraw4-or.s"' in l)
        if wrapper == SRC:
            ins = ['.if ::FLATORG', 'RA_BUILD = 3', '.else', 'RA_BUILD = 1',
                   '.endif   ; ' + PAD_TAG]
        else:
            ins = ['RA_BUILD = 2   ; ' + PAD_TAG + ' tube host layout']
        lines[k:k] = [l if l.startswith('.') or '=' in l else l for l in ins]
        open(wrapper, 'w').write('\n'.join(lines))
        print(f'  {os.path.relpath(wrapper, ROOT)}: RA_BUILD set')


def cmd_verify(a):
    """Prove a layout change is pixel-identical and measure what it bought.

    Two independent checks:
      1. the 42,462-line golden corpus, drawn by the OLD image and the NEW
         one into fresh framebuffers and compared byte for byte — the
         layout may not move a single pixel;
      2. the canned engine workload re-measured on the new image, which
         must land exactly where the model predicted.
    """
    import raster_bench as B
    ref = a.ref or os.path.join(ROOT, 'build', 'raster_align_ref.bin')
    variant = (a.variants or ['banked'])[0]
    v = VARIANTS[variant]
    new, _ = assemble(variant)
    old = open(ref, 'rb').read()
    print(f'{variant}: reference {len(old)} B, candidate {len(new)} B '
          f'({len(new) - len(old):+d})')
    b_old = B.Bench(flat=(variant == 'flat')); b_old.reload(old)
    b_new = B.Bench(flat=(variant == 'flat')); b_new.reload(new)
    wl = B.load_workload()
    def tax(bench):
        cen = {}
        bench.run_workload(wl, cen)
        return sum(s['cross'] for s in cen.values()), cen
    t_old, d_old, w_old, _ = B.measure(b_old, wl)
    t_new, d_new, w_new, _ = B.measure(b_new, wl)
    x_old, _ = tax(b_old)
    x_new, _ = tax(b_new)
    nfr = len(wl['frames'])
    print(f'  workload: {t_old:,} -> {t_new:,} cyc '
          f'({t_new - t_old:+,}, {(t_new - t_old) / nfr:+.1f}/frame)')
    print(f'  layout tax: {x_old} -> {x_new} cyc '
          f'({x_new - x_old:+d}, {(x_new - x_old) / nfr:+.1f}/frame)')
    print(f'  framebuffer digest {d_old} -> {d_new} '
          f'{"SAME" if d_old == d_new else "*** DIFFERENT ***"}')
    # Counts are keyed by offset and padding MOVES offsets, so compare the
    # multiset: what must be invariant is the set of taken-counts, not where
    # in the image each branch happens to sit.
    same_counts = sorted(w_old.values()) == sorted(w_new.values())
    print(f'  branch taken-count multiset identical: {same_counts}  '
          f'(the invariant the whole model rests on)')
    ok = (d_old == d_new) and same_counts
    if a.corpus:
        corp = json.load(open(os.path.join(ROOT, 'build', 'raster_ab.json')))
        keys = list(corp)
        bad = 0
        Z = [0] * 5120
        for i, k in enumerate(keys):
            x0, y0, x1, y1 = (int(t) for t in k.split(','))
            outs = []
            for bb in (b_old, b_new):
                bb.mpu.memory[0x5800:0x5800 + 5120] = Z
                bb.run_line(x0, y0, x1, y1, 0x58)
                outs.append(bytes(bb.mpu.memory[0x5800:0x5800 + 5120]))
            if outs[0] != outs[1]:
                bad += 1
                if bad < 5:
                    print(f'    PIXEL DIFF at {k}')
            if i % 5000 == 0:
                print(f'    ...{i}/{len(keys)}', flush=True)
        print(f'  golden corpus: {len(keys):,} lines, {bad} differ '
              f'{"— PIXEL-IDENTICAL" if not bad else "*** REGRESSION ***"}')
        ok = ok and not bad
    print('VERIFY: ' + ('PASS' if ok else 'FAIL'))
    return 0 if ok else 1


def main():
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest='cmd', required=True)
    for name, fn in (('census', cmd_census), ('search', cmd_search),
                     ('apply', cmd_apply), ('verify', cmd_verify)):
        p = sub.add_parser(name)
        p.add_argument('--variants', nargs='+', default=['banked', 'flat'])
        p.add_argument('--iters', type=int, default=400_000)
        p.add_argument('--perms', type=int, default=3)
        p.add_argument('--budget', type=int, default=255,
                       help='cap on total padding bytes (alignment is '
                            'periodic mod 256)')
        p.add_argument('--out', default=os.path.join(ROOT, 'build',
                                                     'raster_align.json'))
        p.add_argument('--ref')
        p.add_argument('--corpus', action='store_true')
        p.add_argument('--clear', action='store_true',
                       help='apply: strip all generated padding')
        p.add_argument('--max', type=float,
                       help='census: fail if the layout tax exceeds this '
                            'many cycles per frame')
        p.set_defaults(fn=fn)
    a = ap.parse_args()
    sys.exit(a.fn(a) or 0)


if __name__ == '__main__':
    main()
