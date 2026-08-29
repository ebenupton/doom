#!/usr/bin/env python3
"""Tree polish: for every subtree of e1m1_zkdepth.wad, search for an exact
split-free re-partition over the SAME segs (no new vertices, single-sector
strictly-convex leaves); graft every maximal improvement; write OUT wad."""
import struct, sys, math, time
sys.setrecursionlimit(100000)
WAD='/Users/ebenupton/doom/e1m1_zkdepth.wad'
OUT=sys.argv[1]
data=open(WAD,'rb').read()
nl,off=struct.unpack_from('<II',data,4)
L={}; order=[]
for i in range(nl):
    fp,sz,nm=struct.unpack_from('<II8s',data,off+16*i)
    nm=nm.rstrip(b'\0').decode(); order.append(nm)
    L[nm]=data[fp:fp+sz]
V=[struct.unpack_from('<hh',L['VERTEXES'],i*4) for i in range(len(L['VERTEXES'])//4)]
SG=[list(struct.unpack_from('<HHhHHH',L['SEGS'],i*12)) for i in range(len(L['SEGS'])//12)]
SS=[list(struct.unpack_from('<HH',L['SSECTORS'],i*4)) for i in range(len(L['SSECTORS'])//4)]
N=[list(struct.unpack_from('<hhhhhhhhhhhhHH',L['NODES'],i*28)) for i in range(len(L['NODES'])//28)]
LD=[struct.unpack_from('<HHHHHHH',L['LINEDEFS'],i*14) for i in range(len(L['LINEDEFS'])//14)]
SD=[struct.unpack_from('<hh8s8s8sH',L['SIDEDEFS'],i*30) for i in range(len(L['SIDEDEFS'])//30)]
NSEG=len(SG)
P1={i:V[SG[i][0]] for i in range(NSEG)}; P2={i:V[SG[i][1]] for i in range(NSEG)}
def seg_sector(si):
    s=SG[si]; sd=LD[s[3]][5+s[4]]
    return SD[sd][5]
SEC={i:seg_sector(i) for i in range(NSEG)}

# mergeable chains (same original ss, contiguous, colinear, same front/back sectors) = atomic units
def back_sector(si):
    s_=SG[si]; ld=LD[s_[3]]
    sd=ld[5+(1-s_[4])]
    return SD[sd][5] if sd!=0xFFFF else -1
unit_of={}
units={}
uid=0
for c,f in SS:
    i=f
    while i<f+c:
        chain=[i]
        while chain[-1]+1<f+c:
            a,b=chain[-1],chain[-1]+1
            if SG[a][1]!=SG[b][0]: break
            if SEC[a]!=SEC[b] or back_sector(a)!=back_sector(b): break
            av1,av2,bv2=V[SG[a][0]],V[SG[a][1]],V[SG[b][1]]
            if (av2[0]-av1[0])*(bv2[1]-av1[1])!=(av2[1]-av1[1])*(bv2[0]-av1[0]): break
            chain.append(b)
        units[uid]=tuple(chain)
        for x in chain: unit_of[x]=uid
        uid+=1
        i=chain[-1]+1
print(f'{len(units)} units over {NSEG} segs ({sum(1 for u in units.values() if len(u)>1)} chains)')

def classify(k,i):
    (px,py),(qx,qy)=P1[k],P2[k]
    dx,dy=qx-px,qy-py
    def sd_(p):
        v=dy*(p[0]-px)-dx*(p[1]-py)
        return 0 if v>0 else (1 if v<0 else 2)
    a,b=sd_(P1[i]),sd_(P2[i])
    if a==2 and b==2:
        ddx,ddy=P2[i][0]-P1[i][0],P2[i][1]-P1[i][1]
        return 0 if (ddx*dx+ddy*dy)>0 else 1
    if a==2: return b
    if b==2: return a
    return a if a==b else 2

def convex_single(ids):
    if len(ids)>8: return False
    if len({SEC[i] for i in ids})>1: return False
    for k in ids:
        (px,py),(qx,qy)=P1[k],P2[k]
        dx,dy=qx-px,qy-py
        for i in ids:
            for p in (P1[i],P2[i]):
                if dy*(p[0]-px)-dx*(p[1]-py)<0: return False
    return True

cache={}
STATE_CAP=250000
class Blown(Exception): pass
def solve(ids):
    key=frozenset(ids)
    if key in cache: return cache[key]
    if len(cache)>STATE_CAP: raise Blown
    if convex_single(ids):
        cache[key]=(1,None); return cache[key]
    best=(10**9,None)
    idset=set(ids)
    seen=set()
    for k in ids:
        (px,py),(qx,qy)=P1[k],P2[k]
        dx,dy=qx-px,qy-py
        g=math.gcd(abs(dx),abs(dy)); ndx,ndy=dx//g,dy//g
        c=ndy*px-ndx*py
        lk=(ndx,ndy,c) if (ndx,ndy,c)>=(-ndx,-ndy,-c) else (-ndx,-ndy,-c)
        if lk in seen: continue
        seen.add(lk)
        F=[];B=[];ok=True
        done=set()
        for i in ids:
            u=unit_of[i]
            if u in done: continue
            done.add(u)
            mem=[m for m in units[u] if m in idset]
            cls={classify(k,m) for m in mem}
            if len(cls)>1 or 2 in cls: ok=False;break
            (F if cls.pop()==0 else B).extend(mem)
        if not ok or not F or not B: continue
        fs,_=solve(tuple(F)); bs,_=solve(tuple(B))
        if fs+bs<best[0]: best=(fs+bs,(k,tuple(F),tuple(B)))
    cache[key]=best
    return best

def under(nid):
    if nid&0x8000:
        c,f=SS[nid&0x7FFF]; return list(range(f,f+c))
    return under(N[nid][12])+under(N[nid][13])
def count_ss(nid):
    if nid&0x8000: return 1
    return count_ss(N[nid][12])+count_ss(N[nid][13])

# evaluate every node, largest-first; keep maximal winners
nodes_by_size=sorted(range(len(N)), key=lambda i:-len(under(i)))
chosen=[]  # (nid, saved, segids)
covered=set()
for nid in nodes_by_size:
    ids=under(nid)
    if len(ids)<3 or len(ids)>170: continue
    if nid in covered: continue
    cur=count_ss(nid)
    cache.clear()
    try:
        t0=time.time()
        opt,_=solve(tuple(ids))
        dt=time.time()-t0
    except Blown:
        continue
    if opt<cur:
        chosen.append((nid,cur-opt,ids))
        print(f'node {nid}: {len(ids)} segs, ss {cur} -> {opt} (saved {cur-opt}) [{dt:.1f}s]')
        # mark all descendants covered
        def mark(x):
            if x&0x8000: return
            covered.add(x); mark(N[x][12]); mark(N[x][13])
        mark(nid)
print('chosen grafts:',[(c[0],c[1]) for c in chosen])

# ---- splice all chosen grafts ----
# re-solve each chosen graft (cache-per-graft) and emit plans
plans={}
for nid,_,ids in chosen:
    cache.clear()
    solve(tuple(ids))
    plans[nid]=dict(cache)

parent={}
def wpar(nid):
    if nid&0x8000: return
    for c in (N[nid][12],N[nid][13]):
        parent[c]=nid; wpar(c)
wpar(len(N)-1)

new_SG=[None]*NSEG
new_SS=[]
new_nodes_all=[]   # list of node entries with symbolic children
node_sym={}        # symbolic id -> final id later
def emit_leaf(ids, seg_cursor):
    first=seg_cursor[0]
    for i in sorted(ids):
        new_SG[seg_cursor[0]]=SG[i]; seg_cursor[0]+=1
    new_SS.append([len(ids),first])
    xs=[p[0] for i in ids for p in (P1[i],P2[i])]
    ys=[p[1] for i in ids for p in (P1[i],P2[i])]
    return 0x8000|(len(new_SS)-1),(max(ys),min(ys),min(xs),max(xs))
def emit_plan(ids, pc, seg_cursor):
    st=pc[frozenset(ids)]
    if st[1] is None:
        return emit_leaf(ids, seg_cursor)
    k,F,B=st[1]
    c0,bb0=emit_plan(F,pc,seg_cursor)
    c1,bb1=emit_plan(B,pc,seg_cursor)
    sym=('new',len(new_nodes_all))
    px,py=P1[k]; dx,dy=P2[k][0]-P1[k][0],P2[k][1]-P1[k][1]
    new_nodes_all.append([px,py,dx,dy,*bb0,*bb1,c0,c1])
    bb=(max(bb0[0],bb1[0]),min(bb0[1],bb1[1]),min(bb0[2],bb1[2]),max(bb0[3],bb1[3]))
    return sym,bb
graft_root={}
def emit_tree(nid, seg_cursor):
    """emit original tree, diverting at grafts; returns (childref, bbox)"""
    if nid in plans:
        ids=under(nid)
        return emit_plan(tuple(ids), plans[nid], seg_cursor)
    if nid&0x8000:
        ssid=nid&0x7FFF; c,f=SS[ssid]
        return emit_leaf(list(range(f,f+c)), seg_cursor)
    e=N[nid]
    c0,bb0=emit_tree(e[12],seg_cursor)
    c1,bb1=emit_tree(e[13],seg_cursor)
    sym=('new',len(new_nodes_all))
    new_nodes_all.append([e[0],e[1],e[2],e[3],*bb0,*bb1,c0,c1])
    bb=(max(bb0[0],bb1[0]),min(bb0[1],bb1[1]),min(bb0[2],bb1[2]),max(bb0[3],bb1[3]))
    return sym,bb
cur=[0]
root_sym,_=emit_tree(len(N)-1,cur)
assert cur[0]==NSEG and all(s is not None for s in new_SG)
# resolve: nodes are already in child-before-parent order (post-order) -> ids = index
NN=[]
for e in new_nodes_all:
    ee=e[:12]
    for c in (e[12],e[13]):
        ee.append(c if isinstance(c,int) else c[1])
    NN.append(ee)
print(f'final: {len(new_SS)} ss, {len(NN)} nodes, {NSEG} segs (was {len(SS)} ss, {len(N)} nodes)')
lumps=[]
for nm in order:
    if nm=='SEGS': payload=b''.join(struct.pack('<HHhHHH',*s) for s in new_SG)
    elif nm=='SSECTORS': payload=b''.join(struct.pack('<HH',*s) for s in new_SS)
    elif nm=='NODES': payload=b''.join(struct.pack('<hhhhhhhhhhhhHH',*e) for e in NN)
    else: payload=L[nm]
    lumps.append((nm,payload))
out=bytearray(b'PWAD'+b'\0'*8); dirents=[]
for nm,p in lumps: dirents.append((len(out),len(p),nm)); out+=p
diroff=len(out)
for fp,sz,nm in dirents: out+=struct.pack('<II8s',fp,sz,nm.encode().ljust(8,b'\0'))
struct.pack_into('<II',out,4,len(lumps),diroff)
open(OUT,'wb').write(out)
print('wrote',OUT)
