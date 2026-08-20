#!/usr/bin/env python3
"""Differential fuzz: clip_ref oracle vs the python clipper reference
(EndpointClipSpans, records mode — the live verdict spec).

Ops (independent 'segs', applied immediately on both sides):
  portal(xa, xb, yt_a, yt_b, yb_a, yb_b)   closed columns [xa, xb];
      oracle: top-sense line yt + bot-sense line yb over [xa, xb]
      reference: spans.tighten(xa, xb, xa, xb, yt_a, yt_b, yb_a, yb_b)
  solid(xa, xb)
      oracle: mark_solid; reference: spans.mark_solid

After each op the FULL per-column aperture state is compared:
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
import endpoint_spans as es


def ref_aperture(sp, x):
    for s in sp.spans:
        if s[0] <= x <= s[1]:
            return (es._span_top_store(s, x), es._span_bot_store(s, x))
    return None


def gen_op(rng):
    r = rng.random()
    if r < 0.25:
        xa = rng.randint(-20, SCREEN_W + 10)
        return ('solid', xa, xa + rng.randint(0, 90))
    xa = rng.randint(-30, SCREEN_W - 1 + 20)
    xb = xa + rng.randint(1, 140)
    yt_a = rng.randint(-60, SCREEN_H + 50)
    yt_b = yt_a + rng.randint(-70, 70)
    if r < 0.40:                      # top-only: bottom pushed off-screen
        yb_a = yb_b = SCREEN_H + 300
    elif r < 0.55:                    # bot-only
        yb_a, yb_b = yt_a, yt_b
        yt_a = yt_b = -300
    else:                             # true portal band
        yb_a = yt_a + rng.randint(0, 90)
        yb_b = yt_b + rng.randint(0, 90)
    return ('portal', xa, xb, yt_a, yt_b, yb_a, yb_b)


def apply_op(op, oracle, sp):
    if op[0] == 'solid':
        _, xa, xb = op
        oracle.mark_solid(xa, xb)
        sp.mark_solid(xa, xb)
    else:
        _, xa, xb, yt_a, yt_b, yb_a, yb_b = op
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


def run_seq(ops):
    """Apply ops; return (op_index, diffs) of first divergence or None."""
    oracle = ClipRef()
    sp = es.EndpointClipSpans()
    for i, op in enumerate(ops):
        apply_op(op, oracle, sp)
        diffs = compare(oracle, sp)
        if diffs:
            return i, diffs
    return None


def minimize(ops, bad_i):
    """Drop ops (keeping the last) while the divergence class survives."""
    keep = list(ops[:bad_i + 1])
    target = {c for *_, c in run_seq(keep)[1]}
    changed = True
    while changed:
        changed = False
        for i in range(len(keep) - 1):          # never drop the final op
            trial = keep[:i] + keep[i + 1:]
            r = run_seq(trial)
            if r and ({c for *_, c in r[1]} & target):
                keep = trial
                changed = True
                break
    return keep


def main():
    n_seqs = int(sys.argv[1]) if len(sys.argv) > 1 else 400
    n_ops = int(sys.argv[2]) if len(sys.argv) > 2 else 12
    seed0 = int(sys.argv[3]) if len(sys.argv) > 3 else 1
    counts = {'STATE': 0, 'Y>1': 0, 'Y=1': 0, 'clean': 0}
    first = {}
    for sd in range(seed0, seed0 + n_seqs):
        rng = random.Random(sd)
        ops = [gen_op(rng) for _ in range(n_ops)]
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
        print(f"\n=== first {c} (seed {sd}), minimized to {len(small)} ops ===")
        for op in small:
            print("  ", op)
        sample = [d for d in r[1] if d[3] == c][:6]
        others = len(r[1]) - len(sample)
        for x, oa, ra, cls in sample:
            print(f"   col {x}: oracle {oa}  reference {ra}  [{cls}]")
        if others > 0:
            print(f"   ... {others} more differing columns")


if __name__ == '__main__':
    main()
