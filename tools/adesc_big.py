#!/usr/bin/env python3
"""Leaf-1 always-descend verdicts over the FULL inside corpus (Eben,
2026-08-20): 277k positions x 4 orientations = 1.11M frames, sharded
across worker processes.  the static bake stays off everywhere: this is a
from-scratch re-derivation, no baked policy.

PASS 1  every frame, watcher records per (node, boxside): visits,
        rejects, check cycles; frames containing a rejecting LEAF-1
        check are logged (site, chk, frame cycles, fb hash) for pass 2.
PASS 2  per sometimes-rejecting candidate (ascending reject count,
        capped): re-run its rejecting frames with that site warped to
        visible; Δ = cyc_b - cyc_a per frame, FB hash must match.
Verdict WIN iff never worse at ANY frame and total Δ < 0.

Progress: one line per minute to stderr.  Output: build/adesc_l1_big.json
"""
import os, sys, json, time
os.environ.pop('DOOM_ADESC_ON', None)     # 2026-09-04: the bake is off by
                                          # DEFAULT now (DSGN b2/b3 are the
                                          # walk's dynamic bits); the sweep
                                          # still wants a policy-free base
os.environ.setdefault('SDL_VIDEODRIVER', 'dummy')
os.environ.setdefault('PYGAME_HIDE_SUPPORT_PROMPT', '1')
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
os.chdir(os.path.join(os.path.dirname(os.path.abspath(__file__)), '..'))

import multiprocessing as mp

ANGLES = (0, 64, 128, 192)
NWORK = 6
REJ_CAP = 5000          # candidates rejecting on more frames: presumed LOSS
PASS2_BUDGET = 1_500_000
CORPUS = os.environ.get('ADESC_CORPUS', 'build/inside_corpus.txt')
OUT = 'build/adesc_l1_big.json'
P1_STATE = 'build/adesc_p1_state.json'

def log(*a):
    print(time.strftime('[%H:%M:%S]'), *a, file=sys.stderr, flush=True)

# ---------------------------------------------------------------- worker --
_W = {}
def _init_worker():
    # SERIALIZED init: asmbuild's build memo is per-process, so every
    # spawned worker relinks the engine — concurrent ld65 over the shared
    # build dir corrupts objects. flock makes inits take turns.
    import fcntl
    _lk = open('build/.adesc_init_lock', 'w')
    fcntl.flock(_lk, fcntl.LOCK_EX)
    try:
        import pygame; pygame.init()
        import doom_wireframe as dw
        from bsp_render_6502 import BspRender6502
        import bsp_render_6502 as br
        from symmap import sym
        r = BspRender6502(dw.packed_layout, dw.packed_rom_main,
                          dw.packed_rom_detail, dw.packed_bbox_table,
                          dw.MAP_CENTER_X, dw.MAP_CENTER_Y, dw.PRESCALE)
        _W.update(dw=dw, br=br, r=r, sc=r.sc,
                  E=sym('bbox_visible'), ZN=sym('zp_node_ch_l'),
                  ZS=sym('zp_bbox_side'),
                  leaf1={(i, s) for i, n in enumerate(dw.nodes)
                         for s in (0, 1) if n[12 + s] & 0x8000})
    finally:
        fcntl.flock(_lk, fcntl.LOCK_UN)
        _lk.close()

def _frame(x, y, ab, policy):
    """One watched frame. Returns (cycles, fbh, checks)."""
    dw, br, r, sc = _W['dw'], _W['br'], _W['r'], _W['sc']
    E, ZN, ZS = _W['E'], _W['ZN'], _W['ZS']
    checks = []
    old = sc._run
    def run(entry, max_cycles=500000):
        if entry != br.ENTRY_BR_RENDER_FRAME:
            return old(entry, max_cycles)
        mpu, mem = sc.mpu, sc.mpu.memory
        mpu.pc = entry; mpu.sp = 0xDD; mpu.p = 0x30
        mem[0x01DF] = 0xFE; mem[0x01DE] = 0xFF
        mpu.processorCycles = 0
        in_chk = None
        for _ in range(10_000_000):
            pc = mpu.pc
            if pc == 0xFF00:
                break
            if pc == E:
                key = (mem[ZN], mem[ZS])
                if key in policy:
                    sp = mpu.sp
                    ret = (mem[0x100+sp+1] | (mem[0x100+sp+2] << 8)) + 1
                    mpu.sp = (sp + 2) & 0xFF
                    mpu.p |= 0x01
                    mpu.pc = ret
                    continue
                in_chk = (key, mpu.processorCycles, mpu.sp)
            elif in_chk is not None and mpu.sp > in_chk[2] + 1:
                checks.append((in_chk[0], mpu.p & 1,
                               mpu.processorCycles - in_chk[1]))
                in_chk = None
            mpu.step()
        sc.last_cycles = mpu.processorCycles
        return mpu.processorCycles
    sc._run = run
    try:
        cyc = r.render_frame(x, y, ab, dw.player_floor(x, y))
    finally:
        sc._run = old
    mem = sc.mpu.memory
    s0 = sc.SCREEN_START
    import zlib
    return cyc, zlib.crc32(bytes(mem[s0:s0+5120])), checks   # crc32: STABLE
    # across processes — hash(bytes) is per-process salted and poisoned a
    # whole PASS 2 with false PIXEL-UNSAFE verdicts (2026-08-20)

def pass1_shard(job):
    shard_id, positions, progress_path = job
    _init_worker()
    leaf1 = _W['leaf1']
    agg = {}                # (n,s) -> [visits, rejects, chk_cycles]
    rejlog = []             # (x,y,ab,cyc,fbh, [(n,s,chk)...])
    done = 0
    t0 = time.time()
    for (x, y) in positions:
        for ab in ANGLES:
            try:
                cyc, fbh, checks = _frame(x, y, ab, frozenset())
            except Exception:
                continue
            rejs = []
            for key, v, c in checks:
                a = agg.setdefault(key, [0, 0, 0])
                a[0] += 1; a[2] += c
                if v == 0:
                    a[1] += 1
                    if key in leaf1:
                        rejs.append((key[0], key[1], c))
            if rejs:
                rejlog.append((x, y, ab, cyc, fbh, rejs))
            done += 1
        if done % 400 == 0:
            open(progress_path, 'w').write(f'{done} {time.time()-t0:.0f}')
    open(progress_path, 'w').write(f'{done} {time.time()-t0:.0f}')
    return shard_id, {str(k): v for k, v in agg.items()}, rejlog

def pass2_shard(job):
    shard_id, items, progress_path = job
    # items: (site, x, y, ab, cyc_a, fbh_a)
    _init_worker()
    out = []
    done = 0
    for (site, x, y, ab, cyc_a, fbh_a) in items:
        try:
            cyc_b, fbh_b, _ = _frame(x, y, ab, frozenset({tuple(site)}))
            out.append((site, cyc_b - cyc_a, fbh_b == fbh_a))
        except Exception:
            out.append((site, None, False))
        done += 1
        if done % 100 == 0:
            open(progress_path, 'w').write(str(done))
    open(progress_path, 'w').write(str(done))
    return shard_id, out

# ---------------------------------------------------------------- driver --
def run_pool(tag, jobs, fn, total_units):
    t0 = time.time()
    with mp.get_context('spawn').Pool(NWORK) as pool:
        async_res = pool.map_async(fn, jobs)
        while not async_res.ready():
            async_res.wait(60)
            done = 0
            for _, _, pp in jobs:
                try:
                    done += int(open(pp).read().split()[0])
                except Exception:
                    pass
            el = time.time() - t0
            rate = done / el if el else 0
            eta = (total_units - done) / rate / 60 if rate else 0
            log(f'{tag}: {done:,}/{total_units:,} '
                f'({100*done/total_units:.1f}%), {rate:.0f}/s, ETA {eta:.0f} min')
        return async_res.get()

def main():
    positions = []
    for line in open(CORPUS):
        if line.startswith('#'):
            continue
        x, y = line.split()
        positions.append((int(x), int(y)))
    total = len(positions) * len(ANGLES)
    log(f'corpus: {len(positions):,} positions x {len(ANGLES)} = {total:,} frames, '
        f'{NWORK} workers')

    # Warm the engine build ONCE before any pool: concurrent worker inits
    # each drive asmbuild, and parallel ld65 over the shared build dir
    # corrupts objects (the smoke run's 'Invalid string index' crash).
    log('warming engine build...')
    import pygame as _pg; _pg.init()
    from symmap import sym as _sym
    _sym('bbox_visible')

    os.makedirs('build/adesc_prog', exist_ok=True)
    if os.environ.get('ADESC_RESUME') and os.path.exists(P1_STATE):
        log(f'RESUME: loading pass-1 state from {P1_STATE}')
        st = json.load(open(P1_STATE))
        agg = st['agg']
        rejlog = [tuple(f[:5]) + ([tuple(r) for r in f[5]],) for f in st['rejlog']]
        res = []
    else:
        shards = [positions[i::NWORK*3] for i in range(NWORK*3)]
        jobs = [(i, sh, f'build/adesc_prog/p1_{i}') for i, sh in enumerate(shards)]
        res = run_pool('PASS1', jobs, pass1_shard, total)

    if not res and os.environ.get('ADESC_RESUME'):
        pass                                 # agg/rejlog loaded above
    else:
     agg = {}
     rejlog = []
     for _, a, rl in res:
         for k, v in a.items():
             t = agg.setdefault(k, [0, 0, 0])
             for j in range(3):
                 t[j] += v[j]
         rejlog.extend(rl)
    log(f'PASS1 done: {len(agg)} sites seen, {len(rejlog):,} frames with leaf-1 rejects')
    json.dump(dict(agg=agg, rejlog=rejlog), open(P1_STATE, 'w'))
    log(f'pass-1 state saved to {P1_STATE}')

    import pygame; pygame.init()
    import doom_wireframe as dw
    leaf1 = {(i, s) for i, n in enumerate(dw.nodes)
             for s in (0, 1) if n[12 + s] & 0x8000}
    cands = sorted(k for k in leaf1 if str(k) in agg)
    stats = {k: agg[str(k)] for k in cands}

    never = [k for k in cands if stats[k][1] == 0]
    some = sorted((k for k in cands if stats[k][1] > 0), key=lambda k: stats[k][1])
    log(f'leaf-1 candidates: {len(cands)}  never-reject: {len(never)}  '
        f'sometimes: {len(some)}')

    verdicts = {}
    for k in never:
        v, rej, chk = stats[k]
        verdicts[str(k)] = dict(visits=v, rejects=0, chk_cycles=chk,
                                delta_total=-chk, worst=0, verdict='WIN')

    # per-candidate rejecting frame lists
    by_site = {}
    for (x, y, ab, cyc, fbh, rejs) in rejlog:
        for (n, s, c) in rejs:
            by_site.setdefault((n, s), []).append((x, y, ab, cyc, fbh, c))

    budget = PASS2_BUDGET
    items = []
    p2meta = {}
    for k in some:
        frames = by_site.get(k, [])
        if len(frames) > REJ_CAP or len(frames) > budget:
            verdicts[str(k)] = dict(visits=stats[k][0], rejects=stats[k][1],
                                    chk_cycles=stats[k][2],
                                    verdict='LOSS(capped)')
            continue
        budget -= len(frames)
        p2meta[k] = frames
        for (x, y, ab, cyc, fbh, c) in frames:
            items.append((list(k), x, y, ab, cyc, fbh))
    log(f'PASS2: {len(items):,} bypass frames across {len(p2meta)} candidates '
        f'({sum(1 for k in some if str(k) in verdicts)} capped to LOSS)')

    if items:
        shards2 = [items[i::NWORK*2] for i in range(NWORK*2)]
        jobs2 = [(i, sh, f'build/adesc_prog/p2_{i}') for i, sh in enumerate(shards2)]
        res2 = run_pool('PASS2', jobs2, pass2_shard, len(items))
        deltas = {}
        for _, out in res2:
            for site, d, okpix in out:
                deltas.setdefault(tuple(site), []).append((d, okpix))
        for k, frames in p2meta.items():
            v, rej, chk_all = stats[k]
            chk_rej = sum(c for *_, c in frames)
            ds = deltas.get(k, [])
            if any(d is None or not okpix for d, okpix in ds):
                verdicts[str(k)] = dict(visits=v, rejects=rej,
                                        verdict='PIXEL-UNSAFE')
                continue
            dtot = -(chk_all - chk_rej) + sum(d for d, _ in ds)
            worst = max((d for d, _ in ds), default=0)
            verdicts[str(k)] = dict(visits=v, rejects=rej, chk_cycles=chk_all,
                                    delta_total=dtot, worst=worst,
                                    verdict='WIN' if (worst <= 0 and dtot < 0)
                                            else 'LOSS')

    wins = [k for k in cands if verdicts.get(str(k), {}).get('verdict') == 'WIN']
    tot = sum(-verdicts[str(k)]['delta_total'] for k in wins)
    log(f'RESULT: {len(wins)}/{len(cands)} WIN, ~{tot:,} cycles over '
        f'{total:,} frames ({tot // total} /frame)')
    json.dump(dict(corpus=CORPUS, frames=total, level=1,
                   candidates=[list(k) for k in cands],
                   wins=[list(k) for k in wins], verdicts=verdicts),
              open(OUT, 'w'), indent=1)
    log(f'wrote {OUT}')

if __name__ == '__main__':
    main()
