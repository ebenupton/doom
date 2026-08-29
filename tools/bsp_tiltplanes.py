#!/usr/bin/env python3
"""Zero the BSP side violations without opening gaps: iterate plane TILTS
(re-derive guilty partition lines as integer separating lines) with bounded
vertex NUDGES (move synthetic split vertices to lattice points satisfying
every ancestor half-plane; the vertex stays shared, so walls kink <=2 units
but never crack). Tilt constraints: integer lattice anchor (walk band stays
K-free), gcd-normalized dir with |ndx|+|ndy| <= 63 (DBOUND <= 95), same
orientation sense, prefer dirs already in the DIR set (budget 118/128),
smallest angular tilt first. Node child bboxes recomputed at the end."""
import struct, sys, math
sys.setrecursionlimit(4000)
IN = sys.argv[1] if len(sys.argv) > 2 else '/Users/ebenupton/doom/e1m1_zkdepth.wad'
OUT = sys.argv[-1]

data = open(IN, 'rb').read()
n, off = struct.unpack_from('<II', data, 4)
L = {}; order = []
for i in range(n):
    fp, sz, nm = struct.unpack_from('<II8s', data, off + 16 * i)
    nm = nm.rstrip(b'\0').decode(); order.append(nm)
    L[nm] = data[fp:fp + sz]
V = [list(struct.unpack_from('<hh', L['VERTEXES'], i * 4)) for i in range(len(L['VERTEXES']) // 4)]
SG = [struct.unpack_from('<HHhHHH', L['SEGS'], i * 12) for i in range(len(L['SEGS']) // 12)]
SS = [struct.unpack_from('<HH', L['SSECTORS'], i * 4) for i in range(len(L['SSECTORS']) // 4)]
N = [list(struct.unpack_from('<hhhhhhhhhhhhHH', L['NODES'], i * 28)) for i in range(len(L['NODES']) // 28)]
LDEF = [struct.unpack_from('<HHHHHHH', L['LINEDEFS'], i * 14) for i in range(len(L['LINEDEFS']) // 14)]

def under(nid):
    if nid & 0x8000:
        c, f = SS[nid & 0x7FFF]; return list(range(f, f + c))
    return under(N[nid][12]) + under(N[nid][13])

def norm(dx, dy):
    g = math.gcd(abs(dx), abs(dy)); ndx, ndy = dx // g, dy // g
    if ndy < 0 or (ndy == 0 and ndx < 0): ndx, ndy = -ndx, -ndy
    return ndx, ndy

existing = set()
for l in LDEF:
    (x1, y1), (x2, y2) = V[l[0]], V[l[1]]
    if (x2 - x1, y2 - y1) != (0, 0): existing.add(norm(x2 - x1, y2 - y1))
for e in N: existing.add(norm(e[2], e[3]))

def node_viol(nid):
    e = N[nid]; px, py, dx, dy = e[0], e[1], e[2], e[3]
    v = 0
    for side, ch in ((0, e[12]), (1, e[13])):
        want = 1 if side == 0 else -1
        for si in under(ch):
            for vi in (SG[si][0], SG[si][1]):
                x, y = V[vi]
                if (dy * (x - px) - dx * (y - py)) * want < 0: v += 1
    return v

def egcd(p, q):
    if q == 0: return (p, 1, 0)
    g_, x_, y_ = egcd(q, p % q)
    return (g_, y_, x_ - (p // q) * y_)

newdirs = set()

def tilt_pass():
    fixed = 0
    for nid in [x for x in range(len(N)) if node_viol(x)]:
        e = N[nid]
        opx, opy, odx, ody = e[0], e[1], e[2], e[3]
        P0 = sorted({tuple(V[v]) for si in under(e[12]) for v in (SG[si][0], SG[si][1])})
        P1 = sorted({tuple(V[v]) for si in under(e[13]) for v in (SG[si][0], SG[si][1])})
        oang = math.atan2(ody, odx)
        cands = []
        for a in range(-63, 64):
            for b in range(-63, 64):
                if (a, b) == (0, 0) or abs(a) + abs(b) > 63: continue
                if math.gcd(abs(a), abs(b)) != 1: continue
                if a * odx + b * ody <= 0: continue
                ang = abs(math.atan2(b, a) - oang)
                ang = min(ang, 2 * math.pi - ang)
                nd = norm(a, b)
                cands.append((nd not in existing and nd not in newdirs, ang, a, b))
        cands.sort()
        for isnew, ang, a, b in cands:
            s0 = [b * x - a * y for (x, y) in P0]
            s1 = [b * x - a * y for (x, y) in P1]
            lo, hi = max(s1), min(s0)
            if hi < lo: continue
            c = (lo + hi) // 2
            g_, u, v = egcd(b, -a)
            px0, py0 = u * c * g_, v * c * g_
            t = round(((opx - px0) * a + (opy - py0) * b) / (a * a + b * b))
            npx, npy = px0 + t * a, py0 + t * b
            assert b * npx - a * npy == c
            if not (-32768 <= npx < 32768 and -32768 <= npy < 32768): continue
            N[nid][0], N[nid][1], N[nid][2], N[nid][3] = npx, npy, a, b
            if node_viol(nid) == 0:
                newdirs.add(norm(a, b))
                print(f'  node {nid}: dir ({odx},{ody})->({a},{b}) '
                      f'tilt {math.degrees(ang):.2f}deg newdir={isnew}')
                fixed += 1
                break
            N[nid][0], N[nid][1], N[nid][2], N[nid][3] = opx, opy, odx, ody
    return fixed

LDV = set()
for l in LDEF: LDV.add(l[0]); LDV.add(l[1])

# loader-mergeable pairs: nudges must PRESERVE their collinearity or the
# colinear merge dies (+1 packed seg, pixel-visible fragmentation class)
def seg_sector_(si):
    s_ = SG[si]; sd = LDEF[s_[3]][5 + s_[4]]
    return SD_[sd][5]
SD_ = [struct.unpack_from('<hh8s8s8sH', L['SIDEDEFS'], i * 30) for i in range(len(L['SIDEDEFS']) // 30)]
def back_sector_(si):
    s_ = SG[si]; sd = LDEF[s_[3]][5 + (1 - s_[4])]
    return SD_[sd][5] if sd != 0xFFFF else -1
merge_mid = {}          # vertex -> (outer1, outer2) it must stay collinear with
for c, f in SS:
    for a in range(f, f + c - 1):
        b = a + 1
        if SG[a][1] != SG[b][0]: continue
        if seg_sector_(a) != seg_sector_(b) or back_sector_(a) != back_sector_(b): continue
        av1, av2, bv2 = V[SG[a][0]], V[SG[a][1]], V[SG[b][1]]
        if (av2[0]-av1[0])*(bv2[1]-av1[1]) != (av2[1]-av1[1])*(bv2[0]-av1[0]): continue
        merge_mid[SG[a][1]] = (SG[a][0], SG[b][1])
def keeps_merges(vi, x, y):
    if vi in merge_mid:
        o1, o2 = merge_mid[vi]
        (x1, y1), (x2, y2) = V[o1], V[o2]
        if (x - x1) * (y2 - y1) != (y - y1) * (x2 - x1): return False
    # vi may also be an OUTER endpoint of some pair: moving it breaks that
    # pair's collinearity too
    for mid, (o1, o2) in merge_mid.items():
        if vi in (o1, o2):
            (mx, my) = V[mid]
            (ox, oy) = V[o2 if vi == o1 else o1]
            if (x - mx) * (oy - my) != (y - my) * (ox - mx): return False
    return True

# per-subsector ancestor half-plane chains (recomputed each pass: tilts move planes)
def anc_chains():
    anc = {}
    def walkc(nid, chain):
        if nid & 0x8000:
            anc[nid & 0x7FFF] = list(chain); return
        e = N[nid]
        walkc(e[12], chain + [(nid, 1)])
        walkc(e[13], chain + [(nid, -1)])
    walkc(len(N) - 1, [])
    return anc

vss = {}
for ssi, (c, f) in enumerate(SS):
    for si in range(f, f + c):
        for vi in (SG[si][0], SG[si][1]):
            vss.setdefault(vi, set()).add(ssi)

def nudge_pass():
    anc = anc_chains()
    def vertex_ok(vi, x, y):
        for ssi in vss[vi]:
            for nid, want in anc[ssi]:
                e = N[nid]
                if (e[3] * (x - e[0]) - e[2] * (y - e[1])) * want < 0: return False
        return True
    bad = set()
    for nid in [x for x in range(len(N)) if node_viol(x)]:
        e = N[nid]
        for side, ch in ((0, e[12]), (1, e[13])):
            want = 1 if side == 0 else -1
            for si in under(ch):
                for vi in (SG[si][0], SG[si][1]):
                    x, y = V[vi]
                    if (e[3] * (x - e[0]) - e[2] * (y - e[1])) * want < 0: bad.add(vi)
    moved = 0
    for vi in sorted(bad):
        assert vi not in LDV, f'vertex {vi} is an ORIGINAL linedef vertex'
        x0, y0 = V[vi]
        best = None
        for r in range(1, 3):
            cands = [(dx, dy) for dx in range(-r, r + 1) for dy in range(-r, r + 1)
                     if max(abs(dx), abs(dy)) == r]
            cands.sort(key=lambda d: d[0] * d[0] + d[1] * d[1])
            for dx, dy in cands:
                if vertex_ok(vi, x0 + dx, y0 + dy) and keeps_merges(vi, x0 + dx, y0 + dy):
                    best = (dx, dy); break
            if best: break
        if best is None: continue
        V[vi][0], V[vi][1] = x0 + best[0], y0 + best[1]
        print(f'  vertex {vi}: ({x0},{y0}) -> ({V[vi][0]},{V[vi][1]}) d={best}')
        moved += 1
    return moved

def total_viol():
    return sum(node_viol(nid) for nid in range(len(N)))

def hill_pass():
    "joint descent: accept any nudge/tilt that strictly reduces TOTAL violations"
    improved = 0
    # vertex moves (r<=2), global objective
    bad = set()
    for nid in [x for x in range(len(N)) if node_viol(x)]:
        e = N[nid]
        for side, ch in ((0, e[12]), (1, e[13])):
            want = 1 if side == 0 else -1
            for si in under(ch):
                for vi in (SG[si][0], SG[si][1]):
                    x, y = V[vi]
                    if (e[3] * (x - e[0]) - e[2] * (y - e[1])) * want < 0: bad.add(vi)
    for vi in sorted(bad):
        if vi in LDV: continue
        x0, y0 = V[vi]
        base = total_viol()
        best = None
        for dx in range(-2, 3):
            for dy in range(-2, 3):
                if (dx, dy) == (0, 0): continue
                if not keeps_merges(vi, x0 + dx, y0 + dy): continue
                V[vi][0], V[vi][1] = x0 + dx, y0 + dy
                tv = total_viol()
                if best is None or tv < best[0]:
                    best = (tv, dx, dy)
        V[vi][0], V[vi][1] = x0, y0
        if best and best[0] < base:
            V[vi][0], V[vi][1] = x0 + best[1], y0 + best[2]
            print(f'  hill vertex {vi}: ({x0},{y0}) -> ({V[vi][0]},{V[vi][1]}) viol {base}->{best[0]}')
            improved += 1
    # tilt moves accepting reductions
    for nid in [x for x in range(len(N)) if node_viol(x)]:
        e = N[nid]
        opx, opy, odx, ody = e[0], e[1], e[2], e[3]
        base = node_viol(nid)
        P0 = sorted({tuple(V[v]) for si in under(e[12]) for v in (SG[si][0], SG[si][1])})
        P1s = sorted({tuple(V[v]) for si in under(e[13]) for v in (SG[si][0], SG[si][1])})
        oang = math.atan2(ody, odx)
        bestt = None
        for a in range(-63, 64):
            for b in range(-63, 64):
                if (a, b) == (0, 0) or abs(a) + abs(b) > 63: continue
                if math.gcd(abs(a), abs(b)) != 1: continue
                if a * odx + b * ody <= 0: continue
                s0 = [b * x - a * y for (x, y) in P0]
                s1 = [b * x - a * y for (x, y) in P1s]
                # choose c minimizing violations: candidates at each point value
                vals = sorted(set(s0) | set(s1))
                for c in vals:
                    v = sum(1 for s in s0 if s < c) + sum(1 for s in s1 if s > c)
                    if bestt is None or v < bestt[0]:
                        g_, u, vv = egcd(b, -a)
                        px0, py0 = u * c * g_, vv * c * g_
                        t = round(((opx - px0) * a + (opy - py0) * b) / (a * a + b * b))
                        npx, npy = px0 + t * a, py0 + t * b
                        if -32768 <= npx < 32768 and -32768 <= npy < 32768:
                            bestt = (v, a, b, npx, npy)
        if bestt and bestt[0] < base:
            N[nid][0], N[nid][1], N[nid][2], N[nid][3] = bestt[3], bestt[4], bestt[1], bestt[2]
            newdirs.add(norm(bestt[1], bestt[2]))
            print(f'  hill node {nid}: viol {base}->{bestt[0]} dir ({odx},{ody})->({bestt[1]},{bestt[2]})')
            improved += 1
    return improved

for it in range(10):
    t = tilt_pass()
    m = nudge_pass()
    h = hill_pass() if (t == 0 and m == 0) else 0
    g = [nid for nid in range(len(N)) if node_viol(nid)]
    tot = sum(node_viol(nid) for nid in g)
    print(f'iter {it}: tilts {t}, nudges {m}, hill {h}, guilty nodes {len(g)} ({tot} violations)', flush=True)
    if t == 0 and m == 0 and h == 0: break
print('final guilty:', [nid for nid in range(len(N)) if node_viol(nid)])
print('new dirs added:', len(newdirs - existing))

# recompute all node child bboxes from (possibly moved) seg extents
def bbox_of(child):
    ids = under(child)
    xs = [V[v][0] for si in ids for v in (SG[si][0], SG[si][1])]
    ys = [V[v][1] for si in ids for v in (SG[si][0], SG[si][1])]
    return (max(ys), min(ys), min(xs), max(xs))
for e in N:
    e[4:8] = list(bbox_of(e[12]))
    e[8:12] = list(bbox_of(e[13]))

lumps = []
for nm in order:
    if nm == 'NODES': payload = b''.join(struct.pack('<hhhhhhhhhhhhHH', *e) for e in N)
    elif nm == 'VERTEXES': payload = b''.join(struct.pack('<hh', *v) for v in V)
    else: payload = L[nm]
    lumps.append((nm, payload))
out = bytearray(b'PWAD' + b'\0' * 8); dirents = []
for nm, p in lumps: dirents.append((len(out), len(p), nm)); out += p
diroff = len(out)
for fp, sz, nm in dirents: out += struct.pack('<II8s', fp, sz, nm.encode().ljust(8, b'\0'))
struct.pack_into('<II', out, 4, len(lumps), diroff)
open(OUT, 'wb').write(out)
print('wrote', OUT)
