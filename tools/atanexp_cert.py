#!/usr/bin/env python3
"""atanexp certification + table generator (option F, 2026-07-17).

ONE SOURCE for the log2/atanexp pipeline:
  ta'(num,den) = ATANEXP[L(den) - L(num)]     (num < den; num==0 -> TA0)
  L(v) = L8[v]            for v in [1,255]
       = L8[v >> 3] + 96  for v in [256,2047]   (3 octaves * 32 steps)
  L8[v] = round(log2(v) * 32)                    (0..255 for v in [1,255])
  ATANEXP[k] = mid(min,max) of the EXACT ta over every (num,den) pair
               in bucket k  -> minimizes the worst-case bucket error
  exact ta   = tantoangle[floor(num*1024/den)]   (the DOOM convention)

The certificate is EXHAUSTIVE over the finite domain (den 2..2047,
num 1..den-1) and prints EPSILON = max |ta' - ta_exact| in fine units.
The 6502 and the python mirror both consume THESE tables; the role
bias (+-EPSILON via the twin afr constants) makes every downstream
verdict a superset of the exact convention -> pixel-identical.

Writes build/atanexp_tables.json: {L8, ATANEXP, TA0, EPSILON, DMAX}.
"""
import json, math, os, sys
os.chdir(os.path.join(os.path.dirname(os.path.abspath(__file__)), '..'))
sys.path.insert(0, '.')
import angle_bbox as A

DMAX = 2047
L8 = [0] + [min(255, round(math.log2(v) * 32)) for v in range(1, 256)]
# (clamped: round(32*log2 254..255) = 256 overflows the byte — the 6502
#  seed masked it to 0 and the top-mantissa corners went wild; the cert
#  models the SAME clamp so epsilon covers it. L8[0] unused.)
def L(v):
    # >=256: >>3 with HALF-BIT RECOVERY (2026-07-19, Eben): when the
    # last shifted-out bit is 1, average the two neighbouring L8
    # entries (round-to-nearest) instead of truncating — the 6502 does
    # (L8[i] + L8[i+1] + C) >> 1 with the shifted-out carry as the +1.
    # Index 255 has no neighbour: flat (the 6502 guards identically).
    if v < 256:
        return L8[v]
    i = v >> 3
    if (v & 4) and i < 255:
        return ((L8[i] + L8[i + 1] + 1) >> 1) + 96
    return L8[i] + 96

TA0 = A._tantoangle[0]

# pass 1: bucket the exact ta values by k = L(den) - L(num)
lo = {}
hi = {}
for den in range(2, DMAX + 1):
    Ld = L(den)
    for num in range(1, den):
        k = Ld - L(num)
        ta = A._tantoangle[(num * 1024) // den]
        if k not in lo or ta < lo[k]: lo[k] = ta
        if k not in hi or ta > hi[k]: hi[k] = ta

kmax = max(hi)
kmin = min(lo)
print("kmin =", kmin, " (negative = rounding jitter near num~den: those")
print("       buckets FOLD into slot 0 — mirror and 6502 must clamp k<0 -> 0)")
# fold k <= 0 into slot 0 (the 6502 clamps BCC -> 0)
ATANEXP = [0] * 256
eps = 0
if kmin < 0:
    l = min(lo[k] for k in lo if k <= 0)
    h = max(hi[k] for k in hi if k <= 0)
    lo = {k: v for k, v in lo.items() if k > 0}; lo[0] = l
    hi = {k: v for k, v in hi.items() if k > 0}; hi[0] = h
for k in range(0, 256):
    if k in lo:
        ATANEXP[k] = (lo[k] + hi[k] + 1) // 2
        eps = max(eps, ATANEXP[k] - lo[k], hi[k] - ATANEXP[k])
    else:
        ATANEXP[k] = 0          # beyond kmax: ta ~ 0 (num << den)
# FORCED: ATANEXP[0] = 512 (2026-07-19). Bucket 0's mid is ~506, but at
# ta = 512 every octant PAIR collapses (base+512 == base'-512 mod 4096
# for all four quadrants), which lets the 6502's sign-dispatched
# pipeline treat s == 0 ties (L8-equal, magnitudes unequal) exactly
# like the diagonal — no 16-bit fallback compare. Costs a one-sided
# bucket-0 error (512 - lo[0], verified <= EPSILON below); the superset
# certificate is unchanged as long as eps stays within the baked bias.
ATANEXP[0] = 512
eps = max(eps, 512 - lo[0], hi[0] - 512)
assert 512 - lo[0] <= 12, f'bucket-0 error {512 - lo[0]} busts the baked bias (EPSILON_F must cover it)'
# k can exceed 255? L range: L(2047)-L(1) = 96+L8[255] = 96+255 = 351!?
print("kmax =", kmax, " (table clamps above 255: verify those buckets)")
over = [k for k in lo if k > 255]
if over:
    # clamped buckets read ATANEXP[255]: fold their range into slot 255
    l = min(lo[k] for k in over + [255] if k in lo)
    h = max(hi[k] for k in over + [255] if k in hi)
    ATANEXP[255] = (l + h + 1) // 2
    eps = max(eps, ATANEXP[255] - l, h - ATANEXP[255])
    print("clamped buckets:", len(over), " slot-255 range:", l, h)

print("EPSILON =", eps, "fine units ( =", eps / 16, "columns )")
json.dump({'L8': L8, 'ATANEXP': ATANEXP, 'TA0': TA0,
           'EPSILON': eps, 'DMAX': DMAX},
          open('tools/atanexp_tables.json', 'w'))
print("wrote tools/atanexp_tables.json (CHECKED IN — the one table source)")

