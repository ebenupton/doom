"""Capture the br_project_y call stream (vertex, h, rhi, rlo) across the
standard suite and simulate hit rates for candidate cache organizations.

This sizes the per-vertex (vertex,height) Y cache before any asm work.
"""
import os, sys
os.environ['SDL_VIDEODRIVER'] = 'dummy'
os.environ['PYGAME_HIDE_SUPPORT_PROMPT'] = '1'
import pygame; pygame.init(); pygame.display.set_mode((1, 1))
import doom_wireframe as dw
import trace_compare as tc

PY = 0xDAC0          # br_project_y
DPY = 0x575F         # do_project_y entry (group boundary)
V_LO, V_HI = 0x77, 0x78
H = 0x20
RHI, RLO = 0x1A, 0x1B
TOP_DLT, BOT_DLT = 0x68, 0x69
BTOP_DLT, BBOT_DLT = 0x0A7A, 0x0A7B

POSITIONS = [(1056,-3616,65),(1500,-3700,1),(1024,-3500,65),
             (800,-3400,96),(1200,-3000,129),(1056,-3616,129)]

def capture(px, py, ab):
    _ = dw.Instrumented6502Spans()
    sc = dw._span_clip_6502
    tc.setup_wad(sc)
    tc.setup_view_zp(sc, px, py, ab)
    sc._run(tc.ENTRY_BR_VIEW_SETUP)
    sc.init(); sc.clear_screen(); sc._run(0x481B)
    mpu = sc.mpu; mem = mpu.memory
    mpu.pc = 0x4815; mpu.sp = 0xFD; mpu.p = 0x30
    mem[0x01FF] = 0xFE; mem[0x01FE] = 0xFF
    stream = []
    cur_dlts = (0,0,0,0)
    while mpu.pc != 0xFF00:
        if mpu.pc == DPY:
            cur_dlts = (mem[TOP_DLT], mem[BOT_DLT], mem[BTOP_DLT], mem[BBOT_DLT])
        if mpu.pc == PY:
            v = mem[V_LO] | (mem[V_HI] << 8)
            h = mem[H]
            # class = first dlt slot (top,bot,btop,bbot) whose value == h
            cls = next((i for i,d in enumerate(cur_dlts) if d == h), 0)
            stream.append((v, h, mem[RHI], mem[RLO], cls))
        mpu.step()
    return stream

# Cache models. Each returns (hits, total).
def model_current(stream):
    # 256 direct-mapped on (rhi,rlo,h); key (rhi,rlo,h)
    tab = {}; hits = 0
    for v,h,rhi,rlo,cls in stream:
        idx = (rlo + h + rhi) & 255
        if tab.get(idx) == (rhi,rlo,h): hits += 1
        else: tab[idx] = (rhi,rlo,h)
    return hits, len(stream)

def model_class_indexed(stream, nclass):
    # per-vertex, exactly one slot per height-class (0..nclass-1). Classes
    # >= nclass are never cached (always recompute). Slot stores h; hit iff
    # stored h == h. Seeded empty at first sight of vertex this frame.
    slot = {}; seen = set(); hits = 0; cacheable = 0
    for v,h,rhi,rlo,cls in stream:
        if v not in seen:
            seen.add(v)
            for c in range(nclass): slot[(v,c)] = None
        if cls >= nclass:
            continue                     # uncached class -> always raw
        cacheable += 1
        if slot[(v,cls)] == h: hits += 1
        else: slot[(v,cls)] = h
    return hits, len(stream), cacheable

def model_vert_class(stream, nslot):
    # per-vertex, nslot slots, keyed by h (value), LRU within vertex.
    # seeded empty at first sight of a vertex this frame (mirrors vc_miss).
    slots = {}      # v -> list of (h, age)
    seen = set(); hits = 0; clk = 0
    for v,h,rhi,rlo,cls in stream:
        clk += 1
        if v not in seen:
            seen.add(v); slots[v] = []
        lst = slots[v]
        found = any(sh == h for sh,_ in lst)
        if found:
            hits += 1
            slots[v] = [(sh, clk if sh==h else a) for sh,a in lst]
        else:
            if len(lst) >= nslot:
                lst.sort(key=lambda x: x[1])      # evict oldest
                lst.pop(0)
            lst.append((h, clk))
            slots[v] = lst
    return hits, len(stream)

def model_vert_class_fixed(stream, nclass):
    # per-vertex, exactly nclass class-indexed slots; class = position in the
    # 4-cycle (top,bot,btop,bbot). We don't have class here, so approximate by
    # treating it as a direct-mapped per-vertex table of size nclass keyed h%nclass.
    tab = {}; seen = set(); hits = 0
    for v,h,rhi,rlo in stream:
        if v not in seen:
            seen.add(v)
            for c in range(nclass): tab[(v,c)] = None
        c = (h & 0xff) % nclass
        if tab.get((v,c)) == h: hits += 1
        else: tab[(v,c)] = h
    return hits, len(stream)

if __name__ == '__main__':
    allstream = []
    for p in POSITIONS:
        s = capture(*p)
        allstream += s
        print(f'{p}: {len(s)} br_project_y calls')
    print(f'\ntotal calls: {len(allstream)}')
    # distinct (vertex) and distinct (vertex,h)
    vs = set(v for v,*_ in allstream)
    vh = set((v,h) for v,h,_,_,_ in allstream)
    print(f'distinct vertices: {len(vs)}, distinct (vertex,h): {len(vh)}')
    # class distribution
    from collections import Counter, defaultdict
    cc = Counter(c for *_,c in allstream)
    print(f'class mix (0=top,1=bot,2=btop,3=bbot): '
          + ', '.join(f'{k}:{cc[k]}' for k in sorted(cc)))
    perv = defaultdict(set)
    for v,h,_,_,_ in allstream: perv[v].add(h)
    import statistics
    counts = sorted(len(s) for s in perv.values())
    print(f'distinct-h-per-vertex: min={counts[0]} med={statistics.median(counts)} '
          f'max={counts[-1]} mean={statistics.mean(counts):.2f}')
    print()
    h,t = model_current(allstream)
    print(f'current (rhi,rlo,h) 256-direct-map:    {h:6d}/{t} = {100*h/t:.1f}% hit')
    for n in (1,2,3,4,6,8):
        h,t = model_vert_class(allstream, n)
        print(f'per-vertex LRU {n}-slot:                  {h:6d}/{t} = {100*h/t:.1f}% hit')
    print()
    for n in (2,3,4):
        h,t,cab = model_class_indexed(allstream, n)
        print(f'per-vertex class-indexed {n}-class:       {h:6d}/{t} = {100*h/t:.1f}% hit '
              f'(of {cab} cacheable; {t-cab} classes>={n} always raw)')
