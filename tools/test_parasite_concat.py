#!/usr/bin/env python3
"""THE PURE-CONCATENATION GATE (2026-09-02, Eben's flat-first-class purge).

Compares THE DISC ARTIFACTS -- the bytes that actually ship -- not any
harness memory.  The parasite (CODE + DATA, the C02 build) must be a
pure concatenation of the banked build's files:

    CODE $0F00-$57FF   == LOWC by PLACEMENT for the code segments (DRV,
                          PMOVE, PMH, CODE, SHTAB start where the banked
                          ones do; RWC/RWCARD follow CODE in order) and
                          byte-for-byte for the tables (DRV, RWC, RWCARD,
                          SHTAB).  Code CONTENTS may differ per build
                          (Eben 2026-09-03/04): PAGE is BANKED-only, so
                          the parasite carries NO ROMSEL store in any
                          engine code segment -- asserted here.
    CODE $5800-$77FF   == bank A (BANK0) offsets $0000-$1FFF
    DATA $7C00-$95FF   == bank A offsets $2400-$3DFF (minus the staged
                          window $2400-$25FF, where bank A ships zeros)
    DATA $9600-$D5FF   == bank B (BANK2), SS_PG plane page-rebased
    DATA $D600-$F5FF   == bank C (BANK1C) offsets $0000-$1FFF linearly,
                          with the BANKCHOST host tail shipped as zeros
    DATA $7C00-$7D22   == the STAGE: bank C VEXPL ($2000-$20FF) + VPTAB
                          ($39C2-$39E4), boot-copied to $F800/$F900
    COPROT / COPRES    -- the Tube-ULA driver, the ONE blessed
                          tube-specific artifact (no banked counterpart)

Byte diffs are legal ONLY as consistent link relocations: a 16-bit word
whose banked value B maps to the flat value under the concatenation
(A: -$2800, B: +$1600, C: +$5600 linear, VEXPL -> $F800, VPTAB ->
$F900, host-only entries -> the glue slots), or a lone page-hi byte
under the same map.  Anything else is a BAKED ADDRESS or rot: printed,
and the gate fails.  This is what makes "flat" a derived artifact -- the
only degrees of freedom are the relocation map itself.
"""
import os, sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, ROOT); sys.path.insert(0, os.path.join(ROOT, 'tools'))
os.chdir(ROOT)

SECTOR = 256

# VPTAB's banked home comes from the c02 map (it drifts with the vplot
# tail); parsed once at import.
import re as _re
VPTAB_B, VPTAB_N = 0, 0
for _ln in open(os.path.join(ROOT, 'build/engine_b1c1.map')):
    _m = _re.match(r'^VPTAB\s+00([0-9A-F]{4})\s+00[0-9A-F]{4}\s+00([0-9A-F]{4})', _ln)
    if _m:
        VPTAB_B, VPTAB_N = int(_m.group(1), 16), int(_m.group(2), 16)
assert VPTAB_N, 'VPTAB not in the banked c02 map'


def _segs(path):
    out = {}
    for ln in open(os.path.join(ROOT, path)):
        m = _re.match(r'^(\w+)\s+00([0-9A-F]{4})\s+00([0-9A-F]{4})\s+00([0-9A-F]{4})', ln)
        if m:
            out[m.group(1)] = (int(m.group(2), 16), int(m.group(3), 16), int(m.group(4), 16))
    return out


def _syms(path):
    out = {}
    for ln in open(os.path.join(ROOT, path)):
        m = _re.match(r'sym\s+id=\d+,name="([^"]+)",.*?val=0x([0-9A-F]+)', ln)
        if m and not m.group(1).startswith('LOCAL-MACRO'):
            out.setdefault(m.group(1), set()).add(int(m.group(2), 16))
    return out


BK_SEG = _segs('build/engine_b1c1.map')      # banked C02
FL_SEG = _segs('build/engine_b0c1.map')      # flat C02 = the parasite
LOW_CODE = ('PMOVE', 'PMH', 'CODE')          # engine code in the 22K
LOW_TABLES = ('DRV', 'RWC', 'RWCARD', 'SHTAB')
# THE LINKER'S OWN RELOCATION MAP: a banked address that is a symbol maps
# to the same symbol's flat address.  Code contents differ per build
# (PAGE stripped, .if ::BANKED arms), so every reference into the 22K
# from a data block or bank C is checked against this, not a linear rule.
_bs, _fs = _syms('build/engine_b1c1.dbg'), _syms('build/engine_b0c1.dbg')
SYMMAP = {}
for _n, _bv in _bs.items():
    if _n in _fs and len(_bv) == 1 and len(_fs[_n]) == 1:
        b, f = next(iter(_bv)), next(iter(_fs[_n]))
        if b != f:
            SYMMAP.setdefault(b, set()).add(f)
HI_PAIRS = {(b >> 8, f >> 8) for b, fs_ in SYMMAP.items() for f in fs_ if (b >> 8) != (f >> 8)}
# PAGE / PAGE_X / PAGE_Y as the banked build emits them: an immediate
# load of a real bank number followed by the ROMSEL store.
_BANKS = ''.join(chr(int(m.group(1))) for m in _re.finditer(r'^BANK_[A-Z_]+\s*=\s*(\d+)', open(os.path.join(ROOT, 'src/abi.inc')).read(), _re.M))
assert _BANKS, 'no BANK_* equates in abi.inc'
_B = _BANKS.encode('latin1')
PAGE_RE = _re.compile(rb'(?:\xa9[' + _B + rb']\x8d|\xa2[' + _B + rb']\x8e|\xa0[' + _B + rb']\x8c)\x30\xfe', _re.S)


def read_ssd(path):
    d = open(path, 'rb').read()
    n = d[SECTOR + 5] // 8
    out = {}
    for i in range(1, n + 1):
        name = d[i * 8:i * 8 + 7].decode('ascii').strip()
        m = SECTOR + i * 8
        load = d[m] | (d[m + 1] << 8)
        ln = d[m + 4] | (d[m + 5] << 8) | (((d[m + 6] >> 4) & 3) << 16)
        ss = d[m + 7] | ((d[m + 6] & 3) << 8)
        out[name] = (load, d[ss * SECTOR: ss * SECTOR + ln])
    return out


def reloc_candidates(b):
    out = []
    for k in range(4):                      # sym, sym+1 .. sym+3
        for f in SYMMAP.get(b - k, ()):
            out.append(f + k)
    if 0x8000 <= b < 0xC000:
        out.append(b - 0x2800)              # bank A laid at $5800
        out.append(b + 0x1600)              # bank B laid at $9600
        if 0x8000 <= b < 0xA000:
            out.append(b + 0x5600)          # bank C linear at $D600
        if 0xA000 <= b < 0xA100:
            out.append(b + 0x5800)          # VEXPL exception -> $F800
        if VPTAB_B <= b < VPTAB_B + VPTAB_N:
            out.append(b - VPTAB_B + 0xF900)  # VPTAB exception -> $F900
        out += [0xF610, 0xF613, 0xF616, 0xF619]   # glue slots / pinned RTS
    return out


def classify(diffs, bk, fl, base):
    bad = []
    for d in diffs:
        ok = False
        for w in (d - 1, d):
            if w < 0 or w + 1 >= len(bk):
                continue
            if bk[w] == fl[w] and bk[w + 1] == fl[w + 1]:
                continue
            if d not in (w, w + 1):
                continue
            b16 = bk[w] | (bk[w + 1] << 8)
            f16 = fl[w] | (fl[w + 1] << 8)
            if f16 in reloc_candidates(b16):
                ok = True
                break
        if not ok and (fl[d] << 8) in reloc_candidates(bk[d] << 8):
            ok = True                       # lone page-hi byte
        if not ok and (bk[d], fl[d]) in HI_PAIRS:
            ok = True                       # lone page-hi byte of a symbol
        if not ok and d >= 1 and bk[d - 1] == 0xA9 and fl[d - 1] == 0xA9:
            # split immediate: LDA #<addr ... LDA #>addr (plotq_off's
            # plot_v aim).  Find the partner LDA within 8 bytes and try
            # both lo/hi pairings.
            for e in range(max(1, d - 8), min(len(bk) - 1, d + 8)):
                if e == d or bk[e - 1] != 0xA9 or fl[e - 1] != 0xA9:
                    continue
                for lo, hi in ((d, e), (e, d)):
                    b16 = bk[lo] | (bk[hi] << 8)
                    f16 = fl[lo] | (fl[hi] << 8)
                    if f16 in reloc_candidates(b16):
                        ok = True
                if ok:
                    break
        if not ok:
            bad.append(base + d)
    return bad


def main():
    # Cut the disc HERE: the gate compares disc bytes against the current
    # build maps, and other tests rebuild variants freely -- a stale
    # doom_walk.ssd (or a stale map) turns purity violations into noise
    # and vice versa.  ~30 s, and the gate is self-consistent.
    import subprocess
    subprocess.run([sys.executable, 'build_walk_ssd.py'], check=True,
                   capture_output=True)
    files = read_ssd('doom_walk.ssd')
    for want in ('LOWC', 'BANK0', 'BANK1C', 'BANK2', 'CODE', 'DATA'):
        assert want in files, f'{want} missing from the disc'
    lowc = files['LOWC'][1]
    la = files['BANK0'][1]
    c = files['BANK1C'][1]
    lb = files['BANK2'][1]
    code = files['CODE'][1]
    data = files['DATA'][1]
    assert files['CODE'][0] & 0xFFFF == 0x0F00 and \
        files['DATA'][0] & 0xFFFF == 0x7C00, 'parasite load addresses moved'

    ok = True
    total_diffs = 0

    def compare(name, bk, fl, base):
        nonlocal ok, total_diffs
        n = min(len(bk), len(fl))
        diffs = [i for i in range(n) if bk[i] != fl[i]]
        total_diffs += len(diffs)
        bad = classify(diffs, bk, fl, base)
        print(f'  {name}: {len(diffs)} relocated bytes, {len(bad)} unexplained')
        if bad:
            ok = False
            for a in bad[:10]:
                i = a - base
                print(f'    ${a:04X}: banked {bk[i]:02X} parasite {fl[i]:02X}')

    # 1. the shared low image ($0F00-$57FF): PLACEMENT for code, BYTES
    #    for tables, and no ROMSEL store anywhere in engine code.
    for n in LOW_CODE + LOW_TABLES:
        bs, be, bsz = BK_SEG[n]; fs, fe, fsz = FL_SEG[n]
        if n in ('PMH', 'RWC', 'RWCARD'):   # riders: PMH behind PMOVE, the
            prev = {'PMH': 'PMOVE', 'RWC': 'CODE', 'RWCARD': 'RWC'}[n]   # tail
            good = fs == FL_SEG[prev][1] + 1 and bs == BK_SEG[prev][1] + 1   # tables behind CODE
        else:
            good = fs == bs
        print(f'  22K {n:6s}: banked ${bs:04X}-${be:04X} parasite ${fs:04X}-${fe:04X} '
              f'{"in place" if good else "MOVED"}')
        ok = ok and good
        fl = code[fs - 0x0F00:fe + 1 - 0x0F00]
        if n in LOW_CODE:
            hit = PAGE_RE.search(fl)
            if hit:
                ok = False
                print(f'    ROMSEL store in the parasite at ${fs + hit.start():04X}')
        else:
            compare(f'22K {n}', lowc[bs - 0x0F00:be + 1 - 0x0F00], fl, bs)
    # 2. bank A: $5800-$77FF from CODE, $7C00-$95FF from DATA
    compare('bankA $5800-$77FF', la[0x0000:0x2000], code[len(lowc):], 0x5800)
    assert not any(la[0x2000:0x2400]), 'bank A VXC window ships content'
    assert not any(la[0x2400:0x2800]), \
        'bank A $A400-$A7FF ships content -- the stage window is not free'
    assert not any(data[0x0200:0x0400]), 'parasite $7E00-$7FFF not clear'
    compare('bankA $8000-$95FF', la[0x2800:0x3E00], data[0x0400:0x1A00], 0x8000)
    assert not any(la[0x3E00:]), 'bank A top 512 ships content'
    # 3. bank B, SS_PG plane rebased to the parasite's header pages
    os.environ.setdefault('SDL_VIDEODRIVER', 'dummy')
    os.environ['PYGAME_HIDE_SUPPORT_PROMPT'] = '1'
    import pygame; pygame.init()
    import doom_wireframe as dw
    L = dw.packed_layout
    lbx = bytearray(lb)
    for i in range(L['n_ss']):
        o = L['off_ss'] + i
        lbx[o] = (lbx[o] + 0x58 - 0x80) & 0xFF
    compare('bankB $9600-$D5FF', bytes(lbx), data[0x1A00:0x5A00], 0x9600)
    # 4. bank C linear, host tail zeroed
    import re
    seg = {}
    for ln in open('build/engine_b1c1.map'):
        m = re.match(r'^(BANKCHOST)\s+00([0-9A-F]{4})\s+00([0-9A-F]{4})', ln)
        if m:
            seg['H'] = (int(m.group(2), 16), int(m.group(3), 16))
    hs, he = seg['H']
    cbk = bytearray(c[:0x2000])
    cbk[hs - 0x8000:he - 0x8000 + 1] = bytes(he - hs + 1)
    compare('bankC $D600-$F5FF', bytes(cbk), data[0x5A00:0x7A00], 0xD600)
    # 5. the staged exceptions
    compare('VEXPL stage', c[0x2000:0x2100], data[0x0000:0x0100], 0xF800)
    vo = VPTAB_B - 0x8000
    compare('VPTAB stage', c[vo:vo + VPTAB_N], data[0x0100:0x0100 + VPTAB_N], 0xF900)

    print(f'CONCAT: {"PASS" if ok else "FAIL"} '
          f'({total_diffs} total relocated bytes across the map)')
    return 0 if ok else 1


if __name__ == '__main__':
    sys.exit(main())
