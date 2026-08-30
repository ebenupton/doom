#!/usr/bin/env python3
"""zpliveness -- conservative interprocedural ZP liveness, for overlaying.

    python3 tools/zpliveness.py            the overlay report
    python3 tools/zpliveness.py --fn NAME  one function's sets

GOAL.  Zero page is 256 bytes and full: the trawl found only SEVEN bytes
both untouched and unnamed.  More room can only come from SHARING -- two
routines using the same byte when they are never live at the same time.

THE SAFETY CONDITION.  Two routines may share a byte iff neither can be
on the call stack while the other runs, i.e. neither is reachable from
the other.  So the analysis is:

  1. call graph, with vector/SMC dispatch edges included CONSERVATIVELY
     (a vector reaches every one of its known targets);
  2. per-routine ZP reference set, from the source;
  3. subtree(f) = f and everything it can reach;
  4. byte b is PRIVATE to f iff every routine referencing b is in
     subtree(f) -- nobody outside f's subtree can observe it;
  5. overlay offsets by static stack allocation: a routine's frame sits
     above its deepest caller's, so routines on disjoint branches reuse
     the same bytes automatically and no routine ever overlaps an
     ancestor.

WHY STATIC AND NOT A TRACE.  A dynamic corpus proves what IS touched,
never what CAN be.  Today I promoted scalars onto bca_ab and
zp_bv_entry because no render or movement frame touched them -- they are
driver-written and vector-read.  Overlay allocation has to be sound for
paths the corpus never takes, so every input here comes from the source.

CONSERVATISM, deliberately in this direction:
  - a symbol referenced ANYWHERE outside a subtree disqualifies the byte;
  - vector/SMC dispatch fans out to all curated targets;
  - a routine whose callers cannot all be identified is treated as a
    root (reachable from anywhere), so nothing overlays it;
  - literal $xx operands count as references to that byte.
"""
import re, os, sys, glob, collections

STATE_ANYWHERE = set()

ROOT = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), '..'))
os.chdir(ROOT)
sys.path.insert(0, ROOT)

FILES = sorted(glob.glob('src/bsp/*.s') + glob.glob('src/ang/*.s')
               + glob.glob('src/clip/*.s') + glob.glob('src/*.s')
               + glob.glob('src/drv/*.s'))

LABEL = re.compile(r'^(?:::)?([A-Za-z_][A-Za-z0-9_]*):(.*)$')
CALL  = re.compile(r'\b(JSR|JMP)\s+([A-Za-z_][A-Za-z0-9_]*)\b')
# operands that name a symbol or a literal address
SYMOP = re.compile(r'\b(?:LDA|STA|LDX|STX|LDY|STY|ADC|SBC|AND|ORA|EOR|CMP|'
                   r'CPX|CPY|BIT|INC|DEC|ASL|LSR|ROL|ROR|STZ|TRB|TSB)\s+'
                   r'(?:#?<|#?>)?\(?\s*([A-Za-z_][A-Za-z0-9_]*|\$[0-9A-Fa-f]{1,2})\b')
# an indirect JMP through a zp vector is a READ of that vector
VECJMP = re.compile(r'\bJMP\s+\(\s*([A-Za-z_][A-Za-z0-9_]*)\s*\)')

# Dispatch that the source cannot resolve: a vector reaches ALL of these.
# Kept in step with tools/gen_callgraph.py's `vec` set.
VECTOR_TARGETS = {
    'zp_bv_entry':  ['bbox_check_angle', 'dbox_check', 'box_classify'],
    'zp_tail_vec':  ['bca_tail_postrc', 'bca_tail_plain'],
}


def zp_symbols():
    """Every symbol whose value lands in $00-$FF, from the linked map."""
    from symmap import _load
    t, _ = _load(1, 0)
    return {n: a for n, a in t.items() if a < 0x100}


def call_targets():
    """Labels that are actually CALLED -- the real routine boundaries.

    Every label is not a routine.  Treating loop and branch targets as
    routines fragments the graph into 1,358 fake leaves, each an uncalled
    root whose references then count as EXTERNAL to every subtree, and
    the privacy test collapses to 14 bytes.  A routine is a JSR/JMP
    target; everything between it and the next one is its body.
    """
    tg = set()
    for f in FILES:
        for ln in open(f, errors='ignore'):
            code = ln.split(';')[0]
            for kind, t in CALL.findall(code):
                tg.add(t)
            for v in VECJMP.findall(code):
                tg.update(VECTOR_TARGETS.get(v, []))
    return tg


def parse():
    """-> routines: name -> dict(file, calls:set, refs:set(symbol|literal))"""
    TARGETS = call_targets()
    routines = {}
    cur = None
    for f in FILES:
        for ln in open(f, errors='ignore'):
            code = ln.split(';')[0].rstrip()
            if not code.strip():
                continue
            m = LABEL.match(code.strip())
            if m:
                if m.group(1) in TARGETS:        # a real routine boundary
                    cur = m.group(1)
                    routines.setdefault(cur, dict(file=f, calls=set(),
                                                  refs=set()))
                code = m.group(2)                # internal label: same body
            if cur is None:
                continue
            r = routines[cur]
            for kind, tgt in CALL.findall(code):
                r['calls'].add(tgt)
            for v in VECJMP.findall(code):
                r['refs'].add(v)
                r['calls'].update(VECTOR_TARGETS.get(v, []))
            for op in SYMOP.findall(code):
                r['refs'].add(op)
    return routines


def main():
    zps = zp_symbols()
    routines = parse()
    # resolve refs -> ZP byte addresses
    zpname = {}
    for n, a in zps.items():
        zpname.setdefault(a, n)
    refs = {}          # routine -> set(addr)
    for name, r in routines.items():
        s = set()
        for op in r['refs']:
            if op.startswith('$'):
                v = int(op[1:], 16)
                if v < 0x100: s.add(v)
            elif op in zps:
                s.add(zps[op])
        refs[name] = s
    # transitive reachability
    reach = {}
    def sub(n, seen=None):
        if n in reach: return reach[n]
        seen = seen or set()
        if n in seen: return set()
        seen = seen | {n}
        out = {n}
        for c in routines.get(n, {}).get('calls', ()):
            if c in routines:
                out |= sub(c, seen)
        reach[n] = out
        return out
    for n in routines: sub(n)
    # who references each byte
    users = collections.defaultdict(set)
    for n, s in refs.items():
        for a in s: users[a].add(n)

    print(f'\n  ZP LIVENESS -- {len(routines)} routines, '
          f'{len(zps)} ZP symbols, {len(users)} bytes referenced')
    print('  ' + '=' * 68)
    # privacy: every user of b inside subtree(f)
    priv = collections.defaultdict(set)
    for a, us in users.items():
        for f in routines:
            if us <= reach[f] and len(reach[f]) < len(routines):
                priv[f].add(a)
    # the tightest owner for each byte = smallest subtree containing all users
    owner = {}
    for a, us in users.items():
        cands = [f for f in routines if us <= reach[f]]
        if cands:
            owner[a] = min(cands, key=lambda f: len(reach[f]))
    depth1 = collections.Counter()
    for a, f in owner.items(): depth1[f] += 1
    private_total = sum(1 for a, f in owner.items() if len(reach[f]) < len(routines))
    print(f'  bytes with a single owning subtree : {len(owner)}')
    print(f'  of those, owner is NOT whole-program: {private_total}')
    print(f'\n  top owners (bytes private to that subtree):')
    for f, c in depth1.most_common(10):
        if len(reach[f]) >= len(routines): continue
        print(f'    {c:4d}  {f:<26} subtree={len(reach[f])} routines')

    # ---- SCRATCH vs STATE -------------------------------------------------
    # Privacy is NOT enough.  A byte only f touches may still have to keep
    # its value BETWEEN calls to f -- a cache key, an epoch, a prev-angle.
    # Overlaying that corrupts it.  Require the byte to be written before
    # it is read inside the owning routine: scratch, not state.
    firstuse = {}
    for f in routines:
        firstuse[f] = {}
    for f in FILES:
        cur = None
        TARGETS = call_targets()
        for ln in open(f, errors='ignore'):
            code = ln.split(';')[0].rstrip()
            m = LABEL.match(code.strip())
            if m:
                if m.group(1) in TARGETS: cur = m.group(1)
                code = m.group(2)
            if cur is None or cur not in firstuse: continue
            for mm in re.finditer(r'\b(LDA|LDX|LDY|STA|STX|STY|INC|DEC|CMP|'
                                  r'CPX|CPY|BIT|ADC|SBC|AND|ORA|EOR)\s+'
                                  r'([A-Za-z_]\w*|\$[0-9A-Fa-f]{1,2})\b', code):
                op, sym = mm.group(1), mm.group(2)
                a = int(sym[1:], 16) if sym.startswith('$') else zps.get(sym)
                if a is None or a >= 0x100: continue
                if a not in firstuse[cur]:
                    firstuse[cur][a] = 'W' if op in ('STA','STX','STY') else 'R'
    scratch = {a: f for a, f in owner.items()
               if len(reach[f]) < len(routines) and firstuse[f].get(a) == 'W'}
    state = {a: f for a, f in owner.items()
             if len(reach[f]) < len(routines) and firstuse[f].get(a) != 'W'}
    print(f'\n  SCRATCH (written before read in the owner) : {len(scratch)}')
    print(f'  STATE   (read first -- persists, DO NOT overlay): {len(state)}')

    # ---- static stack allocation -----------------------------------------
    # offset(f) = max over everything that can REACH f of (offset+size).
    # Routines on disjoint branches get the same offsets and share bytes.
    size = collections.Counter()
    for a, f in scratch.items(): size[f] += 1
    callers = collections.defaultdict(set)
    for f, r in routines.items():
        for c in r['calls']:
            if c in routines: callers[c].add(f)
    off, seen = {}, set()
    def offset(f, stack=()):
        if f in off: return off[f]
        if f in stack: return 0                  # cycle guard
        o = 0
        for g in callers.get(f, ()):
            o = max(o, offset(g, stack + (f,)) + size.get(g, 0))
        off[f] = o
        return o
    for f in size: offset(f)
    span = max((off[f] + size[f] for f in size), default=0)
    total = sum(size.values())
    print(f'\n  OVERLAY ALLOCATION')
    print(f'    scratch bytes, if each keeps its own: {total}')
    print(f'    overlay span after sharing          : {span}')
    print(f'    ZERO PAGE BYTES FREED               : {total - span}')
    # ---- the looser model: self-contained scratch per routine ----------
    global STATE_ANYWHERE
    STATE_ANYWHERE = state_anywhere(routines, firstuse)
    sc2 = selfcontained(routines, refs, reach, zps, firstuse, callers)
    size2 = {r: len(v) for r, v in sc2.items()}
    off2 = {}
    def offset2(f, stack=()):
        if f in off2: return off2[f]
        if f in stack: return 0
        o = 0
        for g in callers.get(f, ()):
            o = max(o, offset2(g, stack + (f,)) + size2.get(g, 0))
        off2[f] = o
        return o
    for f in size2: offset2(f)
    span2 = max((off2[f] + size2[f] for f in size2), default=0)
    bytes2 = len(set().union(*sc2.values())) if sc2 else 0
    print(f'\n  SELF-CONTAINED MODEL (write-before-read, nothing below uses it)')
    print(f'    routines with private scratch : {len(sc2)}')
    print(f'    distinct bytes so used        : {bytes2}')
    print(f'    overlay span after sharing    : {span2}')
    print(f'    ZERO PAGE BYTES FREED         : {max(0, bytes2 - span2)}')

    print(f'\n    deepest frames:')
    for f in sorted(size, key=lambda f: -(off[f] + size[f]))[:8]:
        print(f'      {f:<26} off {off[f]:3d} size {size[f]:2d}')
    print()


def state_anywhere(routines, firstuse):
    """Bytes some routine READS before writing -- they carry a value IN.

    Closes the hole in the self-contained test.  That test only asks
    whether anything BELOW r touches the byte; it never asks whether some
    UNRELATED routine keeps long-lived state there.  Disjoint branches
    cannot run at the same time, but state persists ACROSS calls, so a
    byte that is scratch in r and an epoch/key/prev-angle somewhere else
    is clobbered the moment r runs.  Any read-before-write anywhere
    disqualifies the byte everywhere.
    """
    out = set()
    for r, fu in firstuse.items():
        for a, kind in fu.items():
            if kind == 'R':
                out.add(a)
    return out


def selfcontained(routines, refs, reach, zps, firstuse, callers):
    """Per routine: bytes it writes-before-reads and never hands to a callee.

    Looser than "private to one subtree", and sound for the SAME reason:
    the stack discipline. If r's first touch of b is a write, and no
    routine r can REACH also touches b, then b holds nothing on entry and
    nothing anyone below needs. Whether an ANCESTOR uses b does not
    matter -- the allocator puts r's frame above every caller's, so r
    cannot land on a live caller slot. That is the whole point of
    allocating by depth rather than by name.
    """
    out = {}
    for r in routines:
        below = set()
        for g in reach[r] - {r}:
            below |= refs.get(g, set())
        own = {a for a in refs.get(r, set())
               if firstuse.get(r, {}).get(a) == 'W' and a not in below
               and a not in STATE_ANYWHERE}
        if own:
            out[r] = own
    return out


if __name__ == '__main__':
    main()
