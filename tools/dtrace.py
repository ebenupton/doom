#!/usr/bin/env python3
"""Analyse a dwalk_bench --trace pickle: where the D cache's cycles go.

Per check (cached twin), joined by (node, side) with the pristine twin's
verdict for the same frame:
  served reject   path inv, or L/R/S with C=0      -> SAVED a classify
  served descend  L/R/S with C=1: RIGHT if pristine also descended,
                  WASTED if pristine rejected the same box (the whole
                  subtree's cycles are the staleness cost; only the
                  OUTERMOST wasted descent is charged — nested checks
                  the pristine never reached are inside it)
  recompute       miss/fresh: the store's overhead over a bare classify

Prints per-phase totals (saved / wasted / overhead), the dynamic-tag
criterion's precision (served descends that drew nothing), and the
per-(node,side) ledger for static-tag candidates.
"""
import sys, pickle
from collections import defaultdict

SERVED = ('L', 'R', 'S')


def analyse(path, top=25, phases=None):
    d = pickle.load(open(path, 'rb'))
    frames = d['frames']
    ph_tot = defaultdict(lambda: defaultdict(int))
    ledger = defaultdict(lambda: defaultdict(int))   # (node,side) -> counters
    draw0 = defaultdict(int)
    for (phase, px, py, ab, fwd, cyc, pcyc, cchk, pchk) in frames:
        if phases and not any(phase.startswith(p) for p in phases):
            continue
        base = phase.split(' ')[0]
        pr = {(r[0], r[1]): r for r in pchk}
        pcost = [r[6] for r in pchk]
        mean_p = sum(pcost) / max(1, len(pcost))
        T = ph_tot[base]
        T['frames'] += 1
        T['cyc'] += cyc
        T['pcyc'] += pcyc
        for r in cchk:
            node, side, pth, ilo, ihi, v, ccyc, scyc, sdraw = r[:9]
            nf = r[9] if len(r) > 9 else '-'
            key = (node, side)
            L = ledger[key]
            p = pr.get(key)
            T['checks'] += 1
            if pth == 'inv' or (pth in SERVED and v == 0):
                T['serve_rej'] += 1
                saved = (p[6] if p else mean_p) - ccyc
                T['saved'] += saved
                L['srej'] += 1
                L['saved'] += saved
            elif pth in SERVED:
                T['serve_desc'] += 1
                L['sdesc'] += 1
                credit = (p[6] if p else mean_p) - ccyc   # classify avoided
                T['desc_credit'] += credit
                L['saved'] += credit
                T['sd_' + nf] += 1
                if p is None:
                    T['nested_unknown'] += 1          # inside a wasted descent
                elif p[5] == 0:
                    T['wasted'] += 1
                    T['wasted_cyc'] += scyc
                    T['wasted_' + nf] += 1
                    T['wasted_cyc_' + nf] += scyc
                    L['wasted'] += 1
                    L['wasted_cyc'] += scyc
                    draw0[('wasted', sdraw == 0)] += 1
                    kind = 'cull' if p[3] < 0 else 'occl'   # pristine's reason
                    T['wasted_' + kind] += 1
                    T['wasted_cyc_' + kind] += scyc
                    L['w_' + kind] += 1
                    draw0[(pth, 'wasted', sdraw == 0)] += 1
                else:
                    T['right'] += 1
                    T['right_cyc'] += scyc
                    L['right'] += 1
                    draw0[('right', sdraw == 0)] += 1
                    draw0[(pth, 'right', sdraw == 0)] += 1
                    if sdraw == 0:
                        L['right_draw0'] += 1
            elif pth in ('miss', 'fresh'):
                T['recompute'] += 1
                ovh = ccyc - (p[6] if p else mean_p)
                T['recompute_ovh'] += ovh
                L['recomp'] += 1
                L['ovh'] += ovh
            else:
                T['other:' + pth] += 1
    print(f'{"phase":10s} {"n":>4s} {"cached":>8s} {"prist":>8s} {"save%":>6s} '
          f'{"srej":>5s} {"saved":>6s} {"sdesc":>5s} {"credit":>6s} {"right":>5s} '
          f'{"waste":>5s} {"w_n":>4s} {"w_f":>4s} {"wasted":>7s} {"wast_n":>6s} '
          f'{"recomp":>6s} {"r_ovh":>6s}')
    for ph, T in ph_tot.items():
        n = T['frames']
        print(f'{ph:10s} {n:4d} {T["cyc"]/n:8.0f} {T["pcyc"]/n:8.0f} '
              f'{100*(T["pcyc"]-T["cyc"])/max(1,T["pcyc"]):6.1f} '
              f'{T["serve_rej"]/n:5.1f} {T["saved"]/n:6.0f} '
              f'{T["serve_desc"]/n:5.1f} {T["desc_credit"]/n:6.0f} '
              f'{T["right"]/n:5.1f} {T["wasted"]/n:5.1f} '
              f'{T["wasted_n"]/n:4.1f} {T["wasted_f"]/n:4.1f} '
              f'{T["wasted_cyc"]/n:7.0f} {T["wasted_cyc_n"]/n:6.0f} '
              f'{T["recompute"]/n:6.1f} {T["recompute_ovh"]/n:6.0f}')
    for ph, T in ph_tot.items():
        if T['wasted']:
            print(f'  {ph}: wasted by pristine reason — cull {T["wasted_cull"]} '
                  f'({T["wasted_cyc_cull"]} cyc) / occluded {T["wasted_occl"]} '
                  f'({T["wasted_cyc_occl"]} cyc)')
    print('(per frame: srej = served rejects, saved = classify cycles they saved; '
          'sdesc = served descends, credit = classify cycles they saved over the '
          'probe; right/waste = pristine agreed/rejected (w_n/w_f = at near/far '
          'sites); wasted = subtree cycles of outermost wasted descends (wast_n = '
          'the near-site share); r_ovh = recompute store overhead)')
    print('\nDynamic criterion (served descend drew NOTHING):')
    for k in sorted(draw0, key=str):
        print(f'  {str(k):40s} {draw0[k]}')
    print(f'\nPer-(node,side) ledger, top {top} by net loss (saved - wasted - ovh):')
    rows = []
    for key, L in ledger.items():
        net = L['saved'] - L['wasted_cyc'] - L['ovh']
        rows.append((net, key, L))
    rows.sort()
    print(f'{"node":>4s} {"sd":>2s} {"net":>8s} {"srej":>5s} {"saved":>7s} '
          f'{"sdesc":>5s} {"right":>5s} {"r_d0":>4s} {"waste":>5s} {"wasted":>7s} '
          f'{"recomp":>6s} {"ovh":>6s}')
    for net, (node, side), L in rows[:top]:
        print(f'{node:4d} {side:2d} {net:8.0f} {L["srej"]:5d} {L["saved"]:7.0f} '
              f'{L["sdesc"]:5d} {L["right"]:5d} {L["right_draw0"]:4d} {L["wasted"]:5d} '
              f'{L["wasted_cyc"]:7.0f} {L["recomp"]:6d} {L["ovh"]:6.0f}')
    wtot = sum(r[2]['wasted_cyc'] for r in rows)
    acc = 0
    marks = []
    for i, r in enumerate(sorted(rows, key=lambda r: -r[2]['wasted_cyc'])):
        acc += r[2]['wasted_cyc']
        if i + 1 in (1, 2, 4, 8, 16, 32):
            marks.append(f'top{i+1}={100*acc/max(1,wtot):.0f}%')
    print('wasted-cycle concentration: ' + ' '.join(marks))
    tot_net = sum(r[0] for r in rows)
    neg = sum(r[0] for r in rows if r[0] < 0)
    print(f'ledger net {tot_net:.0f} over {len(rows)} sites; '
          f'negative sites sum {neg:.0f} ({sum(1 for r in rows if r[0] < 0)} sites)')
    return d


if __name__ == '__main__':
    args = sys.argv[1:]
    phases = None
    if '--phases' in args:
        i = args.index('--phases')
        phases = args[i + 1].split(',')
        del args[i:i + 2]
    analyse(args[0], phases=phases)
