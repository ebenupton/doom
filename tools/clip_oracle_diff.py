#!/usr/bin/env python3
"""Differential fuzz: clip_ref oracle vs the python clipper reference
(EndpointClipSpans, records mode — the live verdict spec).

Ops are CHAINS of connected segs (Eben's spec: the oracle's half-open
tiling gives every column ONE claiming authority; joints share a column
and a y value, exactly like adjacent segs of a subsector):
  chain = breakpoints x0<x1<...<xk with joint (yt, yb) values; each
  interval [xi, xi+1) is a portal seg or a solid seg.
      oracle:    portal -> top+bot lines [xi, xi+1); solid -> mark_solid
      reference: portal -> tighten(xi, xi+1, xi, xi+1, y...) — the
                 CLOSED interval the engine's DCL/tighten actually
                 receives (adjacent segs share the joint column);
                 solid -> mark_solid(xi, xi+1 - 1)?  NO: closed
                 mark_solid(xi, xi+1) mirrors span_mark_solid's closed
                 interval as the engine issues it for a seg ending at
                 projected column xi+1.
Comparison runs at CHAIN COMPLETION (mid-chain the growing end is
legitimately different between the two tilings).

Per-column aperture state is compared:
  oracle.aperture(x)  vs  reference span covering x -> (top, bot)
Diffs are classified:
  STATE  open-vs-solid disagreement       (the authority-extent class)
  Y>1    boundary differs by more than 1  (structural)
  Y=1    off-by-one boundary              (known rounding drift)

Usage: clip_oracle_diff.py [n_seqs] [ops_per_seq] [seed0]
Prints per-class counts and a MINIMIZED repro for the first STATE and
first Y>1 divergence found.
"""
import os, sys, random, copy
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
os.chdir(os.path.join(os.path.dirname(os.path.abspath(__file__)), '..'))
os.environ.setdefault('SDL_VIDEODRIVER', 'dummy')
os.environ.setdefault('PYGAME_HIDE_SUPPORT_PROMPT', '1')

from clip_ref import ClipRef, line as oline, SCREEN_W, SCREEN_H
import endpoint_spans as es        # natively half-open since 2026-08-21


def ref_aperture(sp, x):
    for s in sp.spans:
        if s[0] <= x < s[1]:               # native [xstart, xend)
            return (es._span_top_store(s, x), es._span_bot_store(s, x))
    return None


def gen_chain(rng):
    """A chain: list of ('portal'|'solid', xa, xb, yt_a, yt_b, yb_a, yb_b)
    with shared joint columns and joint-continuous y values."""
    k = rng.randint(1, 6)
    xs = [rng.randint(-30, SCREEN_W + 10)]
    for _ in range(k):
        xs.append(xs[-1] + rng.randint(1, 70))
    # joint y values (portal band per joint)
    yts, ybs = [], []
    yt = rng.randint(-60, SCREEN_H + 50)
    for _ in range(k + 1):
        yt = max(-300, min(500, yt + rng.randint(-40, 40)))
        yts.append(yt)
        ybs.append(yt + rng.randint(0, 90))
    segs = []
    for i in range(k):
        kind = 'solid' if rng.random() < 0.3 else 'portal'
        segs.append((kind, xs[i], xs[i + 1],
                     yts[i], yts[i + 1], ybs[i], ybs[i + 1]))
    return segs


def apply_chain(chain, oracle, sp):
    for (kind, xa, xb, yt_a, yt_b, yb_a, yb_b) in chain:
        # NATIVE ABI: both sides speak [xa, xb) directly — no arithmetic
        if kind == 'solid':
            oracle.mark_solid(xa, xb)
            sp.mark_solid(xa, xb)
        else:
            oracle.draw_line(oline(xa, yt_a, xb, yt_b, 'top'))
            oracle.draw_line(oline(xa, yb_a, xb, yb_b, 'bot'))
            sp.tighten(xa, xb, xa, xb, yt_a, yt_b, yb_a, yb_b)


def compare(oracle, sp):
    """Return list of (x, oracle_ap, ref_ap, cls)."""
    diffs = []
    for x in range(SCREEN_W):
        oa = oracle.aperture(x)
        ra = ref_aperture(sp, x)
        if oa == ra:
            continue
        if (oa is None) != (ra is None):
            diffs.append((x, oa, ra, 'STATE'))
        else:
            d = max(abs(oa[0] - ra[0]), abs(oa[1] - ra[1]))
            diffs.append((x, oa, ra, 'Y=1' if d <= 1 else 'Y>1'))
    return diffs


def make_ref():
    # native seed span (0, 255) = columns 0..254 — nothing to trim
    return es.EndpointClipSpans()


def run_seq(chains):
    """Apply chains; compare at each chain COMPLETION. Returns
    (chain_index, diffs) of first divergence or None."""
    oracle = ClipRef()
    sp = make_ref()
    for i, chain in enumerate(chains):
        apply_chain(chain, oracle, sp)
        diffs = compare(oracle, sp)
        if diffs:
            return i, diffs
    return None


def minimize(chains, bad_i):
    """Drop whole chains, then segs within chains, while the divergence
    class survives."""
    keep = [list(c) for c in chains[:bad_i + 1]]
    target = {c for *_, c in run_seq(keep)[1]}
    def ok(trial):
        r = run_seq(trial)
        return r and ({c for *_, c in r[1]} & target)
    changed = True
    while changed:
        changed = False
        for i in range(len(keep) - 1):
            trial = keep[:i] + keep[i + 1:]
            if ok(trial):
                keep = trial; changed = True; break
        else:
            for i in range(len(keep)):
                for j in range(len(keep[i])):
                    trial = [list(c) for c in keep]
                    del trial[i][j]
                    if trial[i] and ok(trial):
                        keep = trial; changed = True; break
                if changed: break
    return keep


def main():
    n_seqs = int(sys.argv[1]) if len(sys.argv) > 1 else 400
    n_ops = int(sys.argv[2]) if len(sys.argv) > 2 else 12
    seed0 = int(sys.argv[3]) if len(sys.argv) > 3 else 1
    counts = {'STATE': 0, 'Y>1': 0, 'Y=1': 0, 'clean': 0}
    first = {}
    for sd in range(seed0, seed0 + n_seqs):
        rng = random.Random(sd)
        ops = [gen_chain(rng) for _ in range(n_ops)]
        r = run_seq(ops)
        if not r:
            counts['clean'] += 1
            continue
        bad_i, diffs = r
        classes = {c for *_, c in diffs}
        for c in ('STATE', 'Y>1', 'Y=1'):
            if c in classes:
                counts[c] += 1
                if c not in first:
                    first[c] = (sd, ops, bad_i, diffs)
                break                            # count worst class only
    print(f"{n_seqs} sequences x {n_ops} ops: {counts}")
    for c in ('STATE', 'Y>1'):
        if c not in first:
            continue
        sd, ops, bad_i, diffs = first[c]
        small = minimize(ops, bad_i)
        r = run_seq(small)
        nseg = sum(len(ch) for ch in small)
        print(f"\n=== first {c} (seed {sd}), minimized to "
              f"{len(small)} chain(s) / {nseg} seg(s) ===")
        for ch in small:
            for seg in ch:
                print("  ", seg)
            print("   --")
        sample = [d for d in r[1] if d[3] == c][:6]
        others = len(r[1]) - len(sample)
        for x, oa, ra, cls in sample:
            print(f"   col {x}: oracle {oa}  reference {ra}  [{cls}]")
        if others > 0:
            print(f"   ... {others} more differing columns")


if __name__ == '__main__':
    main()
