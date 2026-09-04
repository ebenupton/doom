#!/usr/bin/env python3
"""Layout fuzzer (Eben, 2026-09-04): prove no code depends on WHERE things sit.

Two modes, both "permute the map, rebuild, demand identical pixels":

  zp      shuffle the order of the ZEROPAGE reservations in src/zp.inc, so
          every linker-allocated zero-page symbol lands at a different
          address.  Anything that baked an address instead of a symbol —
          or that relied on two reservations happening to be adjacent —
          diverges or crashes.
  banked  move individual banked tables in the ABI master (tools/gen_abi.py)
          to different free addresses, one or several at a time.  Anything
          that assumed a page boundary, an adjacency, or a literal breaks.

The oracle is the framebuffer: render a fixed pose set and compare the
hashes with the unshuffled build.  Cycle counts are reported too — a pure
permutation should not move them either, so a delta is a finding in its
own right.

Runs in a scratch git worktree; the working tree is never touched.
Usage:  layout_fuzz.py [zp|banked|both] [--iters N] [--seed S] [--keep]
"""
import os, sys, re, json, random, hashlib, subprocess, argparse, shutil

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
POSES = [(1056, -3616, 1), (1056, -3616, 65), (1024, -3500, 65), (1500, -3700, 1),
         (800, -3400, 96), (1200, -3000, 129), (2112, -2368, 35), (1984, -2496, 67),
         (1856, -2368, 3), (2500, -2600, 67), (-486, -3307, 243), (1230, -3120, 242)]

RENDER = r'''
import os, sys, json, hashlib
sys.path.insert(0, os.getcwd()); sys.path.insert(0, os.path.join(os.getcwd(), "tools"))
os.environ.setdefault("SDL_VIDEODRIVER", "dummy"); os.environ["PYGAME_HIDE_SUPPORT_PROMPT"] = "1"
import pygame; pygame.init(); pygame.display.set_mode((1, 1))
import doom_wireframe as dw
from banked_bsp import BankedBspRender
POSES = %s
r = BankedBspRender(dw.packed_layout, dw.packed_rom_main, dw.packed_rom_detail,
                    dw.packed_bbox_table, dw.MAP_CENTER_X, dw.MAP_CENTER_Y, dw.PRESCALE)
mem = r.sc.mpu.memory
out = []
for (px, py, ab) in POSES:
    c = r.render_frame(px, py, ab, dw.player_floor(px, py))
    fb = bytes(mem[0x5800 + i] for i in range(5120))
    out.append([hashlib.sha1(fb).hexdigest()[:16], c])
json.dump(out, open(sys.argv[1], "w"))
'''


def run(cmd, cwd, timeout=1800):
    return subprocess.run(cmd, cwd=cwd, shell=True, capture_output=True, text=True,
                          timeout=timeout)


def render(wt, out):
    open(os.path.join(wt, '_fuzz_render.py'), 'w').write(RENDER % repr(POSES))
    r = run(f'python3 _fuzz_render.py {out}', wt)
    if r.returncode != 0:
        return None, (r.stdout + r.stderr).strip().split('\n')[-1][:200]
    return json.load(open(os.path.join(wt, out))), None


def build(wt):
    r = run('python3 -c "import asmbuild; asmbuild.build_all(); '
            'asmbuild.build_all(banked=1)"', wt)
    return r.returncode == 0, (r.stdout + r.stderr).strip().split('\n')[-1][:200]


# ---------------------------------------------------------------- zp mode
RES = re.compile(r'^(\w+:)?\s+\.res (\d+)')


def zp_block(text):
    """The ZEROPAGE segment's reservation lines, as (start, end) line indices."""
    lines = text.split('\n')
    try:
        i = next(k for k, l in enumerate(lines) if l.strip().startswith('.segment "ZEROPAGE"'))
    except StopIteration:
        i = next(k for k, l in enumerate(lines) if '.zeropage' in l)
    j = i + 1
    first = None
    while j < len(lines):
        l = lines[j]
        if l.strip().startswith('.segment') and 'ZEROPAGE' not in l:
            break
        if RES.match(l):
            first = j if first is None else first
            last = j
        j += 1
    return lines, first, last


def zp_entries(text):
    lines, a, b = zp_block(text)
    entries, cur = [], None
    for k in range(a, b + 1):
        if RES.match(lines[k]):
            if cur: entries.append(cur)
            cur = [lines[k]]
        elif cur is not None and (lines[k].strip().startswith(';') or not lines[k].strip()):
            cur.append(lines[k])
        else:
            if cur: entries.append(cur); cur = None
    if cur: entries.append(cur)
    return lines, a, b, entries


def zp_name(entry):
    m = re.match(r'^(\w+):', entry[0])
    return m.group(1) if m else '(pad)'


def zp_apply(text, order):
    """Rebuild the ZEROPAGE block with entries in `order` (a permutation of
    the original indices)."""
    lines, a, b, entries = zp_entries(text)
    body = [l for i in order for l in entries[i]]
    return '\n'.join(lines[:a] + body + lines[b + 1:])


def zp_shuffle(text, rng):
    """Shuffle whole reservation ENTRIES (a .res line plus its trailing
    continuation-comment lines, which belong to it)."""
    lines, a, b = zp_block(text)
    entries, cur = [], None
    tail = []
    for k in range(a, b + 1):
        if RES.match(lines[k]):
            if cur: entries.append(cur)
            cur = [lines[k]]
        elif cur is not None and (lines[k].strip().startswith(';') or not lines[k].strip()):
            cur.append(lines[k])
        else:
            if cur: entries.append(cur); cur = None
            tail.append((k, lines[k]))
    if cur: entries.append(cur)
    rng.shuffle(entries)
    body = [l for e in entries for l in e]
    return '\n'.join(lines[:a] + body + lines[b + 1:]), len(entries)


# ------------------------------------------------------------ banked mode
ENTRY = re.compile(r"^(\s*\('([A-Z0-9_]+)',\s*)\*_B\((0x[0-9A-Fa-f]+)\)(.*)$")


def banked_entries(text):
    out = []
    for n, l in enumerate(text.split('\n')):
        m = ENTRY.match(l)
        if m:
            out.append((n, m.group(2), int(m.group(3), 16)))
    return out


def banked_shuffle(text, rng, nmove):
    """Slide individual banked tables to a different page in their bank,
    keeping every base page-aligned and inside the window."""
    lines = text.split('\n')
    ents = banked_entries(text)
    taken = sorted(e[2] for e in ents)
    moved = []
    for (n, name, base) in rng.sample(ents, min(nmove, len(ents))):
        for _ in range(24):
            delta = rng.choice([-0x300, -0x200, -0x100, 0x100, 0x200, 0x300])
            nb = base + delta
            if nb < 0x0100 or nb > 0x3E00:
                continue
            if any(abs(nb - t) < 0x100 for t in taken if t != base):
                continue
            m = ENTRY.match(lines[n])
            lines[n] = f'{m.group(1)}*_B(0x{nb:04X}){m.group(4)}'
            taken.remove(base); taken.append(nb)
            moved.append((name, base, nb))
            break
    return '\n'.join(lines), moved


def bisect_zp(wt, zp_src, base, seed, log):
    """Delta-debug a failing shuffle down to a minimal set of entries whose
    reordering breaks the build or the pixels."""
    _, _, _, entries = zp_entries(zp_src)
    n = len(entries)
    rng = random.Random(seed)
    perm = list(range(n)); rng.shuffle(perm)

    def test(moved):
        """Shuffle ONLY the entries in `moved` (others keep their slots)."""
        order = list(range(n))
        slots = sorted(moved)
        seq = [i for i in perm if i in set(moved)]
        for slot, val in zip(slots, seq):
            order[slot] = val
        open(os.path.join(wt, 'src/zp.inc'), 'w').write(zp_apply(zp_src, order))
        ok, err = build(wt)
        if not ok:
            return False, 'BUILD: ' + err
        got, err = render(wt, 'bis.json')
        if got is None:
            return False, 'RENDER: ' + err
        if [g[0] for g in got] != [b[0] for b in base]:
            return False, 'PIXELS DIFFER'
        return True, ''

    cur = [i for i in range(n) if perm[i] != i]
    ok, why = test(cur)
    if ok:
        log('  bisect: the full shuffle passes now — nothing to localise')
        return
    log(f'  bisect: {len(cur)} moved entries fail ({why})')
    while len(cur) > 1:
        half = len(cur) // 2
        for part in (cur[:half], cur[half:]):
            ok, why2 = test(part)
            if not ok:
                cur, why = part, why2
                log(f'    -> {len(cur)} entries still fail ({why})')
                break
        else:
            log(f'    irreducible at {len(cur)} entries (interaction); stopping')
            break
    names = [zp_name(entries[i]) for i in cur]
    log(f'  CULPRIT SET ({len(cur)}): {names}   [{why}]')


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('mode', nargs='?', default='zp', choices=['zp', 'banked', 'both'])
    ap.add_argument('--iters', type=int, default=10)
    ap.add_argument('--seed', type=int, default=1)
    ap.add_argument('--nmove', type=int, default=3, help='banked: tables moved per iteration')
    ap.add_argument('--keep', action='store_true', help='keep the worktree on failure')
    ap.add_argument('--bisect', type=int, default=None,
                    help='localise a failing zp seed to a minimal entry set')
    ARGS = ap.parse_args()

    wt = os.path.join(os.environ.get('TMPDIR', '/tmp'), f'layout_fuzz_{os.getpid()}')
    run(f'git worktree add -q --detach {wt} HEAD', ROOT)
    try:
        ok, err = build(wt)
        if not ok:
            print('BASELINE BUILD FAILED:', err); return 1
        base, err = render(wt, 'base.json')
        if base is None:
            print('BASELINE RENDER FAILED:', err); return 1
        print(f'baseline: {len(base)} poses, {sum(c for _, c in base):,} cycles')

        zp_src = open(os.path.join(wt, 'src/zp.inc')).read()
        if ARGS.bisect is not None:
            bisect_zp(wt, zp_src, base, ARGS.bisect, lambda m: print(m, flush=True))
            return 0
        abi_src = open(os.path.join(wt, 'tools/gen_abi.py')).read()
        modes = ['zp', 'banked'] if ARGS.mode == 'both' else [ARGS.mode]
        fails = 0
        for it in range(ARGS.iters):
            mode = modes[it % len(modes)]
            rng = random.Random(ARGS.seed * 1000 + it)
            note = ''
            open(os.path.join(wt, 'src/zp.inc'), 'w').write(zp_src)
            open(os.path.join(wt, 'tools/gen_abi.py'), 'w').write(abi_src)
            if mode == 'zp':
                new, n = zp_shuffle(zp_src, rng)
                open(os.path.join(wt, 'src/zp.inc'), 'w').write(new)
                note = f'{n} reservations shuffled'
            else:
                new, moved = banked_shuffle(abi_src, rng, ARGS.nmove)
                open(os.path.join(wt, 'tools/gen_abi.py'), 'w').write(new)
                run('python3 tools/gen_abi.py', wt)
                note = ', '.join(f'{m[0]} ${m[1]:04X}->${m[2]:04X}' for m in moved) or 'nothing moved'
            ok, err = build(wt)
            if not ok:
                print(f'  [{it}] {mode}: BUILD FAIL   {note}\n        {err}')
                fails += 1
                continue
            got, err = render(wt, f'it{it}.json')
            if got is None:
                print(f'  [{it}] {mode}: RENDER FAIL  {note}\n        {err}')
                fails += 1
                continue
            bad = [i for i, (g, b) in enumerate(zip(got, base)) if g[0] != b[0]]
            dcyc = sum(g[1] for g in got) - sum(b[1] for b in base)
            if bad:
                print(f'  [{it}] {mode}: PIXELS DIFFER at poses {bad[:6]}   {note}')
                fails += 1
            else:
                print(f'  [{it}] {mode}: ok   dcyc {dcyc:+,}   {note}')
        print(f'\n{ARGS.iters} iterations, {fails} failure(s)')
        return 1 if fails else 0
    finally:
        if not ARGS.keep:
            run(f'git worktree remove --force {wt}', ROOT)


if __name__ == '__main__':
    sys.exit(main())
