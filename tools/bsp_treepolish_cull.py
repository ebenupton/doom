#!/usr/bin/env python3
"""Cull-aware tree polish: re-partition subtrees of e1m1_zkdepth.wad over the
SAME segs (no new splits, no vertex changes, single-sector strictly-convex
leaves, <=CAP segs, loader-mergeable chains atomic), minimizing EXPECTED
TRAVERSAL COST over a map-wide visibility corpus instead of subsector count.

Cost model (cycles, corpus-expected):
  leaf L:  visits(L) * (C_SS + C_SEG * engine_units(L))
  node n:  visits(children) * C_NODE
where visits(S) = corpus poses whose float render visited any ORIGINAL
subsector containing a seg of S (per-seg pose bitmask, numpy OR/popcount).
Segs already processed at a pose cost the same in every arrangement and
cancel; C_SEG here prices the backface test of an unprocessed seg in a
visited leaf. Stripped (non-renderable) wad segs carry weight 0; mergeable
chains count once.

Usage: treepolish_cull.py corpus.npz out.wad [C_NODE C_SS C_SEG] [CAP]
"""
import struct, sys, math, time, pickle
import numpy as np
sys.setrecursionlimit(100000)
sys.path.insert(0,'/Users/ebenupton/doom')
import os
os.chdir('/Users/ebenupton/doom')

CORPUS=sys.argv[1]; OUT=sys.argv[2]
C_NODE=float(sys.argv[3]) if len(sys.argv)>3 else 60.0
C_SS=float(sys.argv[4]) if len(sys.argv)>4 else 95.0
C_SEG=float(sys.argv[5]) if len(sys.argv)>5 else 50.0
CAP=int(sys.argv[6]) if len(sys.argv)>6 else 28

WAD='/Users/ebenupton/doom/e1m1_zkdepth.wad'
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
def back_sector(si):
    s_=SG[si]; ld=LD[s_[3]]
    sd=ld[5+(1-s_[4])]
    return SD[sd][5] if sd!=0xFFFF else -1

# original subsector of each seg
seg_ss={}
for ssi,(c,f) in enumerate(SS):
    for i in range(f,f+c): seg_ss[i]=ssi

# --- corpus masks -------------------------------------------------------
cz=np.load(CORPUS)
VIS=cz['vis']            # (poses, n_ss) bool
NP_,NSS=VIS.shape
W=(NP_+63)//64
ssmask=np.zeros((NSS,W),dtype=np.uint64)
packed=np.packbits(VIS.T,axis=1)   # (n_ss, ceil(poses/8)) uint8
pb=np.zeros((NSS, W*8),dtype=np.uint8); pb[:, :packed.shape[1]]=packed
ssmask=pb.view(np.uint64).reshape(NSS,W)
POPC=np.vectorize(lambda x: bin(int(x)).count('1'))
def popcount(m):
    return int(np.unpackbits(m.view(np.uint8)).sum())
segmask={i: ssmask[seg_ss[i]] for i in range(NSEG)}

# --- engine weights: stripped segs 0, chains count once ----------------
os.environ['SDL_VIDEODRIVER']='dummy'; os.environ['PYGAME_HIDE_SUPPORT_PROMPT']='1'
import pygame; pygame.init(); pygame.display.set_mode((1,1))
import doom_wireframe as dw
renderable={}
for i in range(NSEG):
    # wad seg -> dw.segs same index space (upscaled raw list)
    renderable[i] = dw._is_renderable(dw.segs[i]) if hasattr(dw,'_is_renderable') else True

# mergeable chains = atomic units (same criterion as the loader merge)
unit_of={}; units={}
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
def engine_units(ids):
    seen=set(); n=0
    for i in ids:
        u=unit_of[i]
        if u in seen: continue
        seen.add(u)
        if any(renderable[m] for m in units[u]): n+=1
    return n

def groupmask(ids):
    m=np.zeros(W,dtype=np.uint64)
    for i in ids: m|=segmask[i]
    return m

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
    if len(ids)>CAP: return False
    if len({SEC[i] for i in ids})>1: return False
    for k in ids:
        (px,py),(qx,qy)=P1[k],P2[k]
        dx,dy=qx-px,qy-py
        for i in ids:
            for p in (P1[i],P2[i]):
                if dy*(p[0]-px)-dx*(p[1]-py)<0: return False
    return True

cache={}
STATE_CAP=400000
class Blown(Exception): pass
def solve(ids):
    key=frozenset(ids)
    if key in cache: return cache[key]
    if len(cache)>STATE_CAP: raise Blown
    best=(float('inf'),None)
    if convex_single(ids):
        visits=popcount(groupmask(ids))
        best=(visits*(C_SS+C_SEG*engine_units(ids)), None)
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
        nodecost=popcount(groupmask(ids))*C_NODE
        tot=fs+bs+nodecost
        if tot<best[0]: best=(tot,(k,tuple(F),tuple(B)))
    cache[key]=best
    return best

def under(nid):
    if nid&0x8000:
        c,f=SS[nid&0x7FFF]; return list(range(f,f+c))
    return under(N[nid][12])+under(N[nid][13])
def cur_score(nid):
    """score of the CURRENT arrangement under the same model"""
    if nid&0x8000:
        ids=under(nid)
        return popcount(groupmask(ids))*(C_SS+C_SEG*engine_units(ids))
    ids=under(nid)
    return (popcount(groupmask(ids))*C_NODE + cur_score(N[nid][12]) + cur_score(N[nid][13]))

nodes_by_size=sorted(range(len(N)), key=lambda i:-len(under(i)))
chosen=[]; covered=set()
for nid in nodes_by_size:
    ids=under(nid)
    if len(ids)<3 or len(ids)>170 or nid in covered: continue
    cur=cur_score(nid)
    cache.clear()
    try:
        t0=time.time()
        opt,_=solve(tuple(ids))
        dt=time.time()-t0
    except Blown:
        continue
    if opt<cur-1e-9:
        chosen.append((nid,cur-opt,ids))
        print(f'node {nid}: {len(ids)} segs, score {cur:,.0f} -> {opt:,.0f} (saved {cur-opt:,.0f} cyc-corpus) [{dt:.1f}s]', flush=True)
        def mark(x):
            if x&0x8000: return
            covered.add(x); mark(N[x][12]); mark(N[x][13])
        mark(nid)
print('chosen grafts:',[(c[0],round(c[1])) for c in chosen])

plans={}
for nid,_,ids in chosen:
    cache.clear()
    solve(tuple(ids))
    plans[nid]=dict(cache)

new_SG=[None]*NSEG; new_SS=[]; new_nodes_all=[]
def emit_leaf(ids, cur):
    first=cur[0]
    for i in sorted(ids):
        new_SG[cur[0]]=SG[i]; cur[0]+=1
    new_SS.append([len(ids),first])
    xs=[p[0] for i in ids for p in (P1[i],P2[i])]
    ys=[p[1] for i in ids for p in (P1[i],P2[i])]
    return 0x8000|(len(new_SS)-1),(max(ys),min(ys),min(xs),max(xs))
def emit_plan(ids, pc, cur):
    st=pc[frozenset(ids)]
    if st[1] is None:
        return emit_leaf(ids, cur)
    k,F,B=st[1]
    c0,bb0=emit_plan(F,pc,cur); c1,bb1=emit_plan(B,pc,cur)
    px,py=P1[k]; dx,dy=P2[k][0]-P1[k][0],P2[k][1]-P1[k][1]
    sym=('new',len(new_nodes_all))
    new_nodes_all.append([px,py,dx,dy,*bb0,*bb1,c0,c1])
    bb=(max(bb0[0],bb1[0]),min(bb0[1],bb1[1]),min(bb0[2],bb1[2]),max(bb0[3],bb1[3]))
    return sym,bb
def emit_tree(nid, cur):
    if nid in plans:
        return emit_plan(tuple(under(nid)), plans[nid], cur)
    if nid&0x8000:
        ssid=nid&0x7FFF; c,f=SS[ssid]
        return emit_leaf(list(range(f,f+c)), cur)
    e=N[nid]
    c0,bb0=emit_tree(e[12],cur); c1,bb1=emit_tree(e[13],cur)
    sym=('new',len(new_nodes_all))
    new_nodes_all.append([e[0],e[1],e[2],e[3],*bb0,*bb1,c0,c1])
    bb=(max(bb0[0],bb1[0]),min(bb0[1],bb1[1]),min(bb0[2],bb1[2]),max(bb0[3],bb1[3]))
    return sym,bb
cur=[0]
root_sym,_=emit_tree(len(N)-1,cur)
assert cur[0]==NSEG and all(s is not None for s in new_SG)
NN=[]
for e in new_nodes_all:
    ee=e[:12]
    for c in (e[12],e[13]):
        ee.append(c if isinstance(c,int) else c[1])
    NN.append(ee)
print(f'final: {len(new_SS)} ss, {len(NN)} nodes, {NSEG} segs (was {len(SS)} ss, {len(N)} nodes)')
sizes={}
for c,f in new_SS: sizes[c]=sizes.get(c,0)+1
print('leaf sizes:',dict(sorted(sizes.items())))
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
