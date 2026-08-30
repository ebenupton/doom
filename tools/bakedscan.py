#!/usr/bin/env python3
"""bakedscan -- find BAKED ADDRESSES: storage written as a literal.

    python3 tools/bakedscan.py              census by class
    python3 tools/bakedscan.py --list WORK  every site in one class
    python3 tools/bakedscan.py --overlaps   equates that share bytes
    python3 tools/bakedscan.py --gate       exit 1 if the count rose

WHY THIS EXISTS.  A baked address is a COPY OF A FACT.  When the real
thing moves the copy does not, and nothing tells you: it is not a build
error, it is a silent read or write of whatever lives there now.  The
map's whole scar list is this one shape -- psi planes landing on anim
tables, zp_ft at $E4F8 landing on OS ROM, PMOVE probed into a hole the
harness happened not to touch, a cfg region whose declared size was a
lie because a Python seeder owned the next address.

The fix is always the same: declare the storage in a segment and let
ld65 place it, then reference it by LABEL.

CLASSES.  Not every literal is equally bad, so they are separated:
  ZP        zero page. The hand-allocated ABI; a literal here is the
            allocation itself, and ca65 cannot beat it for addressing
            mode.  Reported but not counted against the gate.
  ABI       abi.inc / layout.inc -- the cross-language contract that
            Python seeders and tools read.  These are baked BY DESIGN,
            but they are also the ones the linker cannot police, so
            they are counted separately and should shrink over time.
  WORK      scratch/workspace variables in the writable arena.  THE
            strip target: these have no reason to be literals at all.
  TABLE     table/plane homes above the arena, including per-build
            .if BANKED splits.
  HIGH      $C000+ -- flat-build-only homes.
"""
import re, os, sys, collections, json

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
EQ = re.compile(r'^([A-Za-z_][A-Za-z0-9_]*)\s*=\s*\$([0-9A-Fa-f]{1,4})\s*(?:;(.*))?$')
BASELINE = os.path.join(ROOT, 'build', 'bakedscan.json')


# NOT addresses: sizes, lengths, and offsets into the packed WAD blob.
# LAY_OFF_VERTS = $0B00 is an offset into rom_main, not a location, and
# counting it as a baked address makes the ratchet dishonest.
NOT_ADDR = re.compile(r'(^LAY_)|(_OFF$)|(_LEN$)|(_BYTES$)|(_SIZE$)|'
                      r'(_STRIDE$)|(_COUNT$)|(_MAX$)|(_BITS$)|(^OBJ_MAXSLOT$)')


def classify(path, addr, name):
    if NOT_ADDR.search(name):
        return None
    base = os.path.basename(path)
    if addr < 0x100:
        return 'ZP'
    if base in ('abi.inc', 'layout.inc'):
        return 'ABI'
    if 0x0600 <= addr < 0x0F00:
        return 'WORK'
    if addr >= 0xC000:
        return 'HIGH'
    return 'TABLE'


def scan():
    out = []
    for root, _, files in os.walk(os.path.join(ROOT, 'src')):
        for f in sorted(files):
            if not f.endswith(('.s', '.inc')):
                continue
            p = os.path.join(root, f)
            rel = os.path.relpath(p, ROOT)
            for i, ln in enumerate(open(p), 1):
                m = EQ.match(ln.rstrip('\n'))
                if not m:
                    continue
                a = int(m.group(2), 16)
                c = classify(p, a, m.group(1))
                if c is None:
                    continue
                out.append(dict(file=rel, line=i, name=m.group(1), addr=a,
                                cls=c, comment=(m.group(3) or '').strip()))
    return out


def main():
    rows = scan()
    by = collections.Counter(r['cls'] for r in rows)

    if '--list' in sys.argv:
        want = sys.argv[sys.argv.index('--list') + 1].upper()
        for r in sorted([r for r in rows if r['cls'] == want],
                        key=lambda r: r['addr']):
            print(f"  ${r['addr']:04X}  {r['name']:22s} {r['file']}:{r['line']}")
        print(f"\n{by[want]} site(s) in {want}")
        return 0

    if '--overlaps' in sys.argv:
        # equates sharing an address are either a deliberate phase-disjoint
        # overlay or a live bug; either way a .res conversion would change
        # behaviour, so they must be looked at by hand.
        seen = collections.defaultdict(list)
        for r in rows:
            if r['cls'] in ('WORK', 'TABLE'):
                seen[r['addr']].append(r)
        n = 0
        for a in sorted(seen):
            if len(seen[a]) > 1:
                n += 1
                print(f"  ${a:04X}  " + ', '.join(
                    f"{r['name']} ({r['file']}:{r['line']})" for r in seen[a]))
        print(f"\n{n} address(es) with more than one name -- check each before "
              f"converting: a naive .res would de-overlay them and grow the arena.")
        return 0

    print("BAKED ADDRESSES -- storage written as a literal")
    print("  (rule: declare it in a segment, let ld65 place it, use the LABEL)\n")
    order = ['WORK', 'TABLE', 'HIGH', 'ABI', 'ZP']
    for c in order:
        note = {'ZP': 'hand-allocated ABI, not gated',
                'ABI': 'cross-language contract; linker cannot police these',
                'WORK': 'THE strip target -- no reason to be literals',
                'TABLE': 'table/plane homes, incl. per-build splits',
                'HIGH': 'flat-build-only homes'}[c]
        print(f"  {by[c]:4d}  {c:6s} {note}")
    gated = sum(by[c] for c in ('WORK', 'TABLE', 'HIGH', 'ABI'))
    print(f"\n  {gated:4d}  TOTAL non-ZP (the number that must go down)")

    print("\n  by file:")
    ff = collections.Counter(r['file'] for r in rows if r['cls'] != 'ZP')
    for f, c in ff.most_common(12):
        print(f"    {c:4d}  {f}")

    if '--gate' in sys.argv:
        prev = None
        if os.path.exists(BASELINE):
            prev = json.load(open(BASELINE)).get('non_zp')
        if prev is not None and gated > prev:
            print(f"\nBAKEDSCAN: FAIL -- non-ZP baked addresses rose "
                  f"{prev} -> {gated}. New baked addresses are forbidden.")
            return 1
        if '--rebaseline' in sys.argv or prev is None:
            os.makedirs(os.path.dirname(BASELINE), exist_ok=True)
            json.dump({'non_zp': gated, 'by_class': dict(by)},
                      open(BASELINE, 'w'), indent=1)
            print(f"\nBAKEDSCAN: baseline written ({gated})")
        else:
            print(f"\nBAKEDSCAN: PASS ({gated} <= {prev})")
    return 0


if __name__ == '__main__':
    sys.exit(main())
