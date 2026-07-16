#!/usr/bin/env python3
"""dfscan — dataflow redundancy scanner for the 6502 engine.

Traces the standard 18-frame cycle suite to ground-truth the executed
instruction set (with per-PC execution counts for ranking), augments it
with statically-reachable successors inside the linked code segments,
builds a CFG, and runs:

  * FORWARD abstract interpretation per basic block to a fixpoint:
      - register constants        (A/X/Y = known byte)
      - register-memory mirrors   (A currently equals ZP/abs slot $xx)
      - memory constants          (stores of known values, killed on
                                   indexed/indirect writes and JSR)
      - flag constants            (C/Z/N/V = 0/1/unknown)
      - Z/N provenance            (zn_src: flags currently reflect reg r)
      - CMP provenance            (Z from CMP reg,#imm — BEQ edge learns
                                   reg == imm)
      - branch-edge refinement    (BCS-taken edge knows C=1, etc.)
  * BACKWARD local liveness within each block (dead register writes,
    dead flag writes, flag-consumption checks for removals).

  JSR is modeled as full havoc (registers, flags, memory, meta) — the
  cross-call register contracts are NOT assumed, so every finding is
  sound under any callee behavior. EXCEPTION (2026-07-15): the ROMSEL
  bank crosses calls via interprocedural summaries — per JSR target,
  'id' (provably never writes $FE30) or 'const k' (every RTS path exits
  bank k), computed by a fixpoint over the call graph with stack-game
  and model-exit guards; unknown callees still havoc the bank. This is
  what lets page_same findings survive a JSR. SMC sites (any instruction whose
  operand bytes are the target of a store into a code segment) are
  excluded from findings and treated as unknown loads.

Findings (each = provably redundant on every modeled path):
  imm_load    LDr #v when r already == v          (flags-safety checked)
  reload      LDr addr when r already mirrors it  (flags-safety checked)
  clc_sec     CLC with C==0 / SEC with C==1
  dead_flag   CLC/SEC overwritten before any C-reader in the block
  dead_write  register written then rewritten, value+flags unconsumed
  cmp_zero    CMP #0 when Z/N already reflect A (C-safety checked)
  identity    AND #$FF / ORA #0 / EOR #0          (flags-safety checked)
  known_store STr addr when addr provably already holds that value
              (LOW CONFIDENCE: verify the slot isn't read mid-frame by
              hooks/harness before acting)

Every finding still goes through the house gate before landing: apply,
verify bit-exact, measure, full regression. This tool only points.

Usage:  python3 tools/dfscan.py            (report to stdout + JSON to
                                            scratchpad if writable)
        python3 tools/dfscan.py --quick    (3 frames only, fast sanity)
"""
import os, sys, json, argparse
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
os.chdir(os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))))
os.environ.setdefault('SDL_VIDEODRIVER', 'dummy')
os.environ.setdefault('PYGAME_HIDE_SUPPORT_PROMPT', '1')

# ── opcode table ─────────────────────────────────────────────────────────
_SPEC = """
00 BRK imp|01 ORA inx|05 ORA zp|06 ASL zp|08 PHP imp|09 ORA imm|0A ASL acc
0D ORA abs|0E ASL abs|10 BPL rel|11 ORA iny|15 ORA zpx|16 ASL zpx|18 CLC imp
19 ORA aby|1D ORA abx|1E ASL abx|20 JSR abs|21 AND inx|24 BIT zp|25 AND zp
26 ROL zp|28 PLP imp|29 AND imm|2A ROL acc|2C BIT abs|2D AND abs|2E ROL abs
30 BMI rel|31 AND iny|35 AND zpx|36 ROL zpx|38 SEC imp|39 AND aby|3D AND abx
3E ROL abx|40 RTI imp|41 EOR inx|45 EOR zp|46 LSR zp|48 PHA imp|49 EOR imm
4A LSR acc|4C JMP abs|4D EOR abs|4E LSR abs|50 BVC rel|51 EOR iny|55 EOR zpx
56 LSR zpx|58 CLI imp|59 EOR aby|5D EOR abx|5E LSR abx|60 RTS imp|61 ADC inx
65 ADC zp|66 ROR zp|68 PLA imp|69 ADC imm|6A ROR acc|6C JMP ind|6D ADC abs
6E ROR abs|70 BVS rel|71 ADC iny|75 ADC zpx|76 ROR zpx|78 SEI imp|79 ADC aby
7D ADC abx|7E ROR abx|81 STA inx|84 STY zp|85 STA zp|86 STX zp|88 DEY imp
8A TXA imp|8C STY abs|8D STA abs|8E STX abs|90 BCC rel|91 STA iny|94 STY zpx
95 STA zpx|96 STX zpy|98 TYA imp|99 STA aby|9A TXS imp|9D STA abx|A0 LDY imm
A1 LDA inx|A2 LDX imm|A4 LDY zp|A5 LDA zp|A6 LDX zp|A8 TAY imp|A9 LDA imm
AA TAX imp|AC LDY abs|AD LDA abs|AE LDX abs|B0 BCS rel|B1 LDA iny|B4 LDY zpx
B5 LDA zpx|B6 LDX zpy|B8 CLV imp|B9 LDA aby|BA TSX imp|BC LDY abx|BD LDA abx
BE LDX aby|C0 CPY imm|C1 CMP inx|C4 CPY zp|C5 CMP zp|C6 DEC zp|C8 INY imp
C9 CMP imm|CA DEX imp|CC CPY abs|CD CMP abs|CE DEC abs|D0 BNE rel|D1 CMP iny
D5 CMP zpx|D6 DEC zpx|D8 CLD imp|D9 CMP aby|DD CMP abx|DE DEC abx|E0 CPX imm
E1 SBC inx|E4 CPX zp|E5 SBC zp|E6 INC zp|E8 INX imp|E9 SBC imm|EA NOP imp
EC CPX abs|ED SBC abs|EE INC abs|F0 BEQ rel|F1 SBC iny|F5 SBC zpx|F6 INC zpx
F8 SED imp|F9 SBC aby|FD SBC abx|FE INC abx
"""
_LEN = {'imp': 1, 'acc': 1, 'imm': 2, 'zp': 2, 'zpx': 2, 'zpy': 2,
        'inx': 2, 'iny': 2, 'rel': 2, 'abs': 3, 'abx': 3, 'aby': 3, 'ind': 3}
OPTAB = {}
# NB: split on newlines as well as '|' — the spec lines have no trailing
# '|', and the old split('|') glued each line's last entry to the next
# line's first, silently DROPPING 21 opcodes (TAX, BMI, CMP #imm, ADC zp,
# ...) from the table: every block containing one ended early as
# "off-model". Found 2026-07-15 by the bank-summary guards.
for ent in _SPEC.replace('\n', '|').split('|'):
    ent = ent.strip()
    if not ent:
        continue
    parts = ent.split()
    op = int(parts[0], 16)
    mn = parts[1]
    mode = parts[2] if len(parts) > 2 else 'imp'
    OPTAB[op] = (mn, mode, _LEN[mode])

# base cycle costs for the instructions we might flag (no page-cross)
_CYC = {('imm', 'r'): 2, ('zp', 'r'): 3, ('zpx', 'r'): 4, ('zpy', 'r'): 4,
        ('abs', 'r'): 4, ('abx', 'r'): 4, ('aby', 'r'): 4,
        ('zp', 'w'): 3, ('zpx', 'w'): 4, ('abs', 'w'): 4, ('imp', 'r'): 2}
def icost(mn, mode):
    kind = 'w' if mn in ('STA', 'STX', 'STY') else 'r'
    return _CYC.get((mode, kind), 2)

U = ('u',)          # unknown value
def C(v): return ('c', v & 0xFF)
def M(a): return ('m', a)

class St:
    __slots__ = ('r', 'f', 'mem', 'zn', 'cmpm', 'bank')
    def __init__(s):
        s.r = {'A': U, 'X': U, 'Y': U}
        s.f = {'C': None, 'Z': None, 'N': None, 'V': None}
        s.mem = {}
        s.zn = None            # 'A'/'X'/'Y': Z,N reflect that register
        s.cmpm = None          # (reg, imm): Z is (reg == imm)
        s.bank = None          # ROMSEL ($FE30) state: paged bank or unknown
    def clone(s):
        t = St.__new__(St)
        t.r = dict(s.r); t.f = dict(s.f); t.mem = dict(s.mem)
        t.zn = s.zn; t.cmpm = s.cmpm; t.bank = s.bank
        return t
    def havoc(s):
        s.r = {'A': U, 'X': U, 'Y': U}
        s.f = {'C': None, 'Z': None, 'N': None, 'V': None}
        s.mem = {}; s.zn = None; s.cmpm = None
        # NB: bank survives havoc-by-JSR only via transfer()'s own rule
    def join(s, o):
        ch = False
        for k in 'AXY':
            if s.r[k] != o.r[k] and s.r[k] != U:
                s.r[k] = U; ch = True
        for k in 'CZNV':
            if s.f[k] != o.f[k] and s.f[k] is not None:
                s.f[k] = None; ch = True
        for a in list(s.mem):
            if o.mem.get(a) != s.mem[a]:
                del s.mem[a]; ch = True
        if s.zn != o.zn and s.zn is not None:
            s.zn = None; ch = True
        if s.cmpm != o.cmpm and s.cmpm is not None:
            s.cmpm = None; ch = True
        if s.bank != o.bank and s.bank is not None:
            s.bank = None; ch = True
        return ch
    def key(s):
        return (tuple(sorted(s.r.items())), tuple(sorted(s.f.items())),
                tuple(sorted(s.mem.items())), s.zn, s.cmpm, s.bank)

def setZN(st, val, src):
    if val != U and val[0] == 'c':
        st.f['Z'] = 1 if val[1] == 0 else 0
        st.f['N'] = 1 if val[1] & 0x80 else 0
    else:
        st.f['Z'] = st.f['N'] = None
    st.zn = src
    st.cmpm = None

def kill_mirrors(st, addr):
    for k in 'AXY':
        if st.r[k] == ('m', addr):
            st.r[k] = U

def eff_addr(mode, opnd):
    """Concrete address for direct modes, else None."""
    if mode in ('zp',):
        return opnd
    if mode in ('abs',):
        return opnd
    return None

CODE_LO, CODE_HI = 0x2000, 0x5000   # refined at runtime from the map

def transfer(st, ins, volatile):
    pc, mn, mode, opnd = ins['pc'], ins['mn'], ins['mode'], ins['opnd']
    vol = pc in volatile

    def read_val():
        if vol:
            return U
        if mode == 'imm':
            return C(opnd)
        a = eff_addr(mode, opnd)
        if a is not None:
            if a in st.mem:
                return st.mem[a]
            return M(a)
        return U

    if mn in ('STA',) and mode == 'abs' and opnd == 0xFE30:
        v = st.r['A']
        st.bank = v[1] if (v != U and v[0] == 'c') else None
        return st
    if mn in ('LDA', 'LDX', 'LDY'):
        reg = mn[2]
        v = read_val()
        st.r[reg] = v
        setZN(st, v, reg)
    elif mn in ('STA', 'STX', 'STY'):
        reg = mn[2]
        a = eff_addr(mode, opnd)
        if a is not None:
            kill_mirrors(st, a)
            v = st.r[reg]
            if v != U and v[0] == 'c':
                st.mem[a] = v
            else:
                st.mem.pop(a, None)
                if v == U:
                    st.r[reg] = M(a)     # reg now mirrors what it stored
        else:
            # indexed/indirect store: unknown target. ZP consts survive an
            # abs,X/abs,Y store whose base is >= $0200 (can't wrap into ZP);
            # everything else is killed.
            base_safe = mode in ('abx', 'aby') and opnd >= 0x0200
            for k in list(st.mem):
                if not (base_safe and k < 0x100):
                    del st.mem[k]
            for k in 'AXY':
                if st.r[k] != U and st.r[k][0] == 'm':
                    if not (base_safe and st.r[k][1] < 0x100):
                        st.r[k] = U
    elif mn in ('TAX', 'TAY'):
        st.r[mn[2]] = st.r['A']; setZN(st, st.r['A'], mn[2])
    elif mn in ('TXA', 'TYA'):
        st.r['A'] = st.r[mn[1]]; setZN(st, st.r['A'], 'A')
    elif mn == 'TSX':
        st.r['X'] = U; setZN(st, U, 'X')
    elif mn == 'TXS':
        pass
    elif mn == 'CLC':
        st.f['C'] = 0
    elif mn == 'SEC':
        st.f['C'] = 1
    elif mn == 'CLV':
        st.f['V'] = 0
    elif mn in ('CLI', 'SEI', 'CLD', 'SED', 'NOP'):
        pass
    elif mn in ('INX', 'INY', 'DEX', 'DEY'):
        reg = mn[2]
        v = st.r[reg]
        if v != U and v[0] == 'c':
            nv = C(v[1] + (1 if mn[0] == 'I' else -1))
            st.r[reg] = nv; setZN(st, nv, reg)
        else:
            st.r[reg] = U; setZN(st, U, reg)
    elif mn in ('INC', 'DEC'):
        a = eff_addr(mode, opnd)
        if a is not None:
            kill_mirrors(st, a)
            v = st.mem.get(a)
            if v is not None:
                nv = C(v[1] + (1 if mn == 'INC' else -1))
                st.mem[a] = nv; setZN(st, nv, None)
            else:
                st.mem.pop(a, None); setZN(st, U, None)
        else:
            base_safe = mode == 'abx' and opnd >= 0x0200
            for k in list(st.mem):
                if not (base_safe and k < 0x100):
                    del st.mem[k]
            for k in 'AXY':
                if st.r[k] != U and st.r[k][0] == 'm':
                    st.r[k] = U
            setZN(st, U, None)
    elif mn in ('AND', 'ORA', 'EOR'):
        v = read_val(); a = st.r['A']
        if v != U and v[0] == 'c' and a != U and a[0] == 'c':
            r = {'AND': a[1] & v[1], 'ORA': a[1] | v[1],
                 'EOR': a[1] ^ v[1]}[mn]
            st.r['A'] = C(r)
        elif mn == 'AND' and v == C(0):
            st.r['A'] = C(0)
        elif mn == 'ORA' and v == C(0xFF):
            st.r['A'] = C(0xFF)
        else:
            st.r['A'] = U
        setZN(st, st.r['A'], 'A')
    elif mn in ('ADC', 'SBC'):
        v = read_val(); a = st.r['A']; c = st.f['C']
        if (v != U and v[0] == 'c' and a != U and a[0] == 'c'
                and c is not None):
            if mn == 'ADC':
                t = a[1] + v[1] + c
                st.f['V'] = 1 if (~(a[1] ^ v[1]) & (a[1] ^ t) & 0x80) else 0
            else:
                t = a[1] + (v[1] ^ 0xFF) + c
                st.f['V'] = 1 if ((a[1] ^ v[1]) & (a[1] ^ t) & 0x80) else 0
            st.f['C'] = 1 if t > 0xFF else 0
            st.r['A'] = C(t)
        else:
            st.r['A'] = U; st.f['C'] = st.f['V'] = None
        setZN(st, st.r['A'], 'A')
    elif mn in ('ASL', 'LSR', 'ROL', 'ROR'):
        if mode == 'acc':
            a = st.r['A']; c = st.f['C']
            if a != U and a[0] == 'c' and (mn in ('ASL', 'LSR')
                                           or c is not None):
                v = a[1]
                if mn == 'ASL':
                    st.f['C'] = (v >> 7) & 1; nv = (v << 1) & 0xFF
                elif mn == 'LSR':
                    st.f['C'] = v & 1; nv = v >> 1
                elif mn == 'ROL':
                    st.f['C'] = (v >> 7) & 1; nv = ((v << 1) | c) & 0xFF
                else:
                    st.f['C'] = v & 1; nv = (v >> 1) | (c << 7)
                st.r['A'] = C(nv)
            else:
                st.r['A'] = U; st.f['C'] = None
            setZN(st, st.r['A'], 'A')
        else:
            a = eff_addr(mode, opnd)
            if a is not None:
                kill_mirrors(st, a); st.mem.pop(a, None)
            else:
                st.mem.clear()
                for k in 'AXY':
                    if st.r[k] != U and st.r[k][0] == 'm':
                        st.r[k] = U
            st.f['C'] = None; setZN(st, U, None)
    elif mn in ('CMP', 'CPX', 'CPY'):
        reg = {'CMP': 'A', 'CPX': 'X', 'CPY': 'Y'}[mn]
        v = read_val(); rv = st.r[reg]
        if v != U and v[0] == 'c' and rv != U and rv[0] == 'c':
            d = (rv[1] - v[1]) & 0x1FF
            st.f['C'] = 1 if rv[1] >= v[1] else 0
            st.f['Z'] = 1 if rv[1] == v[1] else 0
            st.f['N'] = 1 if d & 0x80 else 0
            st.zn = None; st.cmpm = None
        else:
            st.f['C'] = st.f['Z'] = st.f['N'] = None
            st.zn = None
            st.cmpm = (reg, opnd) if (mode == 'imm' and not vol) else None
    elif mn == 'BIT':
        st.f['Z'] = st.f['N'] = st.f['V'] = None
        st.zn = None; st.cmpm = None
    elif mn == 'PLA':
        st.r['A'] = U; setZN(st, U, 'A')
    elif mn == 'PHA':
        pass
    elif mn == 'PLP':
        st.f = {'C': None, 'Z': None, 'N': None, 'V': None}
        st.zn = None; st.cmpm = None
    elif mn == 'PHP':
        pass
    elif mn == 'JSR':
        st.havoc()
        # interprocedural bank summary (pass 2; pass 1 has none -> UNK):
        # 'id' = callee provably never writes ROMSEL on any RTS path,
        # ('const', k) = every RTS path exits with bank k paged.
        eff = _BANK_SUM.get(opnd)
        if eff == ('id',):
            pass                            # st.bank survives the call
        elif eff is not None and eff[0] == 'const':
            st.bank = eff[1]
        else:
            st.bank = None                  # unknown callee effect
    # JMP/branches/RTS/RTI/BRK handled by CFG
    return st

_BANK_SUM = {}    # JSR target -> ('id',) | ('const', k); absent = unknown

_BR = {'BPL': ('N', 0), 'BMI': ('N', 1), 'BVC': ('V', 0), 'BVS': ('V', 1),
       'BCC': ('C', 0), 'BCS': ('C', 1), 'BNE': ('Z', 0), 'BEQ': ('Z', 1)}

def refine(st, mn, taken):
    """Apply branch-edge knowledge to a cloned state."""
    fl, tv = _BR[mn]
    val = tv if taken else 1 - tv
    st.f[fl] = val
    if fl == 'Z' and val == 1:
        if st.zn in ('A', 'X', 'Y') and st.r[st.zn] == U:
            st.r[st.zn] = C(0)
        if st.cmpm is not None:
            reg, imm = st.cmpm
            if st.r[reg] == U:
                st.r[reg] = C(imm)
    return st


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--quick', action='store_true')
    ap.add_argument('--banked', action='store_true',
                    help='trace the BANKED model (PAGE ops visible)')
    ap.add_argument('--json', default=None)
    args = ap.parse_args()

    import pygame; pygame.init()
    import doom_wireframe as dw, compare_renders as CR, fp
    from bsp_render_6502 import (BspRender6502,
                                 ZP_PX, ZP_PY, ZP_VZ, ZP_PXRAW_LO,
                                 ZP_PYRAW_LO, ZP_SMAG, ZP_SNEG, ZP_SONE,
                                 ZP_CMAG, ZP_CNEG, ZP_CONE)
    from symmap import sym as _sym0, _load
    BK = 1 if args.banked else 0
    def sym(n): return _sym0(n, banked=BK)
    table, _amb = _load(banked=BK)
    code_syms = sorted((v, k) for k, v in table.items() if 0x1000 <= v <= 0xFE00)
    import bisect
    def sym_near(pc):
        i = bisect.bisect_right(code_syms, (pc, '\xff')) - 1
        if i < 0:
            return ('?', 0)
        return (code_syms[i][1], pc - code_syms[i][0])

    # code segments from the linker map
    segs = []
    mapf = os.path.join('build', f'engine_b{1 if args.banked else 0}c0.map')
    with open(mapf) as f:
        inseg = False
        for ln in f:
            if ln.startswith('Segment list'):
                inseg = True
            elif inseg and ln.strip() == '' and segs:
                break
            elif inseg:
                p = ln.split()
                if len(p) == 5 and p[0] not in ('Name',) and '-' not in p[0]:
                    try:
                        segs.append((int(p[1], 16), int(p[2], 16)))
                    except ValueError:
                        pass
    def in_code(pc):
        return any(lo <= pc <= hi for lo, hi in segs)

    if args.banked:
        from banked_bsp import BankedBspRender as _RC
    else:
        _RC = BspRender6502
    r = _RC(dw.packed_layout, dw.packed_rom_main,
            dw.packed_rom_detail, dw.packed_bbox_table,
            dw.MAP_CENTER_X, dw.MAP_CENTER_Y, dw.PRESCALE)
    ENTRY_VIEW = sym('br_view_setup')
    ENTRY_RENDER = sym('br_render_frame')
    sc = r.sc; mpu = sc.mpu; mem = mpu.memory

    # ── trace ────────────────────────────────────────────────────────────
    count = {}
    seen = {}
    pagew = {}      # pc -> [same_bank, total] for STA $FE30 sites (banked)
    curbank = [None]
    positions = CR.POSITIONS[:3] if args.quick else CR.POSITIONS
    for (px, py, ab) in positions:
        fl = dw.player_floor(px, py)
        px88 = int((px - r.map_center_x) * 256 / r.prescale)
        py88 = int((py - r.map_center_y) * 256 / r.prescale)
        mem[ZP_PX] = px88 & 0xFF; mem[ZP_PX+1] = (px88 >> 8) & 0xFF
        mem[ZP_PY] = py88 & 0xFF; mem[ZP_PY+1] = (py88 >> 8) & 0xFF
        mem[sym('zp_br_px_x')] = (px88 >> 16) & 0xFF
        mem[sym('zp_br_py_x')] = (py88 >> 16) & 0xFF
        vz = ((fl + 41) * 6 + 2) // (r.prescale * 5)
        mem[ZP_VZ] = vz & 0xFF
        rpx = int(px) - r.map_center_x; rpy = int(py) - r.map_center_y
        mem[ZP_PXRAW_LO] = rpx & 0xFF; mem[ZP_PXRAW_LO+1] = (rpx >> 8) & 0xFF
        mem[ZP_PYRAW_LO] = rpy & 0xFF; mem[ZP_PYRAW_LO+1] = (rpy >> 8) & 0xFF
        sm, sn, so, cm, cn, co = fp.fp_sincos(ab)
        mem[ZP_SMAG] = sm; mem[ZP_SNEG] = 1 if sn else 0
        mem[ZP_SONE] = 1 if so else 0
        mem[ZP_CMAG] = cm; mem[ZP_CNEG] = 1 if cn else 0
        mem[ZP_CONE] = 1 if co else 0
        mem[sym('bca_ab')] = ab & 0xFF
        sc._run(ENTRY_VIEW); sc.init(); sc.clear_screen()
        mpu.pc = ENTRY_RENDER; mpu.sp = 0xFD; mpu.p = 0x30
        mem[0x01FF] = 0xFE; mem[0x01FE] = 0xFF
        for _ in range(10000000):
            pc = mpu.pc
            if pc == 0xFF00:
                break
            if pc in count:
                count[pc] += 1
            else:
                count[pc] = 1
                seen[pc] = (mem[pc], mem[pc+1], mem[pc+2])
            if seen[pc][0] == 0x8D and seen[pc][1] == 0x30 and seen[pc][2] == 0xFE:
                st = pagew.setdefault(pc, [0, 0])
                st[1] += 1
                if mpu.a == curbank[0]:
                    st[0] += 1
                curbank[0] = mpu.a
            mpu.step()
    print(f"trace: {len(positions)} frames, {sum(count.values())} steps, "
          f"{len(seen)} distinct PCs", file=sys.stderr)

    # ── decode + static expansion ───────────────────────────────────────
    def decode(pc, byts=None):
        b = byts or (mem[pc], mem[pc+1], mem[pc+2])
        if b[0] not in OPTAB:
            return None
        mn, mode, ln = OPTAB[b[0]]
        if mode in ('imm', 'zp', 'zpx', 'zpy', 'inx', 'iny'):
            opnd = b[1]
        elif mode == 'rel':
            d = b[1]
            opnd = (pc + 2 + (d - 256 if d >= 128 else d)) & 0xFFFF
        elif ln == 3:
            opnd = b[1] | (b[2] << 8)
        else:
            opnd = None
        return {'pc': pc, 'mn': mn, 'mode': mode, 'len': ln, 'opnd': opnd,
                'traced': pc in count}

    ins = {}
    for pc in seen:
        d = decode(pc, seen[pc])
        if d:
            ins[pc] = d
    # successors (also queue static-only targets inside code segments)
    def succs(i):
        mn, mode = i['mn'], i['mode']
        pc, ln, op = i['pc'], i['len'], i['opnd']
        if mn in ('RTS', 'RTI', 'BRK'):
            return []
        if mn == 'JMP':
            return [op] if mode == 'abs' else []
        if mode == 'rel':
            return [pc + ln, op]
        return [pc + ln]
    queue = list(ins)
    while queue:
        pc = queue.pop()
        i = ins.get(pc)
        if i is None:
            continue
        for s in succs(i):
            if s not in ins and in_code(s):
                d = decode(s)
                if d:
                    ins[s] = d
                    queue.append(s)

    # ── SMC detection: stores whose target lands inside an instruction ──
    ibytes = set()
    for i in ins.values():
        for k in range(i['len']):
            ibytes.add(i['pc'] + k)
    volatile = set()
    for i in ins.values():
        if i['mn'] in ('STA', 'STX', 'STY', 'INC', 'DEC') and \
           i['mode'] in ('zp', 'abs') and i['opnd'] in ibytes:
            # mark every instruction whose bytes include the store target
            for j in ins.values():
                if j['pc'] <= i['opnd'] < j['pc'] + j['len']:
                    volatile.add(j['pc'])
    print(f"static: {len(ins)} instructions, {len(volatile)} SMC-volatile",
          file=sys.stderr)

    # ── basic blocks ─────────────────────────────────────────────────────
    leaders = set()
    has_pred = set()
    jsr_targets = set()
    for i in ins.values():
        ss = succs(i)
        if i['mn'] == 'JSR':
            jsr_targets.add(i['opnd'])
            if i['opnd'] in ins:
                leaders.add(i['opnd'])
        if i['mode'] == 'rel' or i['mn'] == 'JMP':
            for s in ss:
                leaders.add(s)
        if i['mode'] == 'rel':
            leaders.add(i['pc'] + i['len'])
        for s in ss:
            has_pred.add(s)
    for pc in ins:
        if pc not in has_pred:
            leaders.add(pc)
    blocks = {}     # leader -> [instrs]
    for pc in sorted(ins):
        if pc in leaders:
            cur = blocks[pc] = []
            curpc = pc
        try:
            cur
        except UnboundLocalError:
            cur = blocks[pc] = []
        i = ins[pc]
        cur.append(i)
        nxt = pc + i['len']
        if (i['mn'] in ('RTS', 'RTI', 'BRK', 'JMP', 'JSR') or
                i['mode'] == 'rel' or nxt in leaders or nxt not in ins):
            if i['mn'] == 'JSR' and nxt in ins and nxt not in leaders:
                leaders.add(nxt)      # split after JSR for clean havoc
            cur = None
            del cur

    # rebuild cleanly now leaders are final
    blocks = {}
    order = sorted(ins)
    idx = 0
    while idx < len(order):
        pc = order[idx]
        if pc not in leaders:
            idx += 1
            continue
        blk = []
        p = pc
        while p in ins:
            i = ins[p]
            blk.append(i)
            nx = p + i['len']
            if (i['mn'] in ('RTS', 'RTI', 'BRK', 'JMP') or i['mode'] == 'rel'
                    or i['mn'] == 'JSR' or nx in leaders):
                break
            p = nx
        blocks[pc] = blk
        idx += 1
    blk_succ = {}
    for lead, blk in blocks.items():
        last = blk[-1]
        ss = []
        if last['mn'] == 'JSR':
            nx = last['pc'] + last['len']
            if nx in ins:
                ss = [(nx, None)]
        elif last['mode'] == 'rel':
            ss = [(last['pc'] + last['len'], (last['mn'], False)),
                  (last['opnd'], (last['mn'], True))]
        elif last['mn'] == 'JMP' and last['mode'] == 'abs':
            ss = [(last['opnd'], None)]
        elif last['mn'] in ('RTS', 'RTI', 'BRK') or last['mode'] == 'ind':
            ss = []
        else:
            nx = last['pc'] + last['len']
            if nx in ins:
                ss = [(nx, None)]
        blk_succ[lead] = [(t, e) for (t, e) in ss if t in blocks]

    # ── forward fixpoint ────────────────────────────────────────────────
    entries = set(jsr_targets & set(blocks)) | {ENTRY_RENDER}
    for lead in blocks:
        if lead not in has_pred:
            entries.add(lead)

    def run_fixpoint():
        IN = {}
        wl = []
        for e in entries:
            if e in blocks:
                IN[e] = St()
                wl.append(e)
        it = 0
        while wl:
            it += 1
            if it > 400000:
                print("fixpoint budget exceeded", file=sys.stderr)
                break
            lead = wl.pop()
            st = IN[lead].clone()
            for i in blocks[lead]:
                transfer(st, i, volatile)
            for (t, edge) in blk_succ[lead]:
                ts = st.clone()
                if edge is not None:
                    refine(ts, edge[0], edge[1])
                if t not in IN:
                    IN[t] = ts
                    wl.append(t)
                else:
                    if IN[t].join(ts):
                        wl.append(t)
        return IN

    if os.environ.get('DFSCAN_PROBE'):
        for hx in os.environ['DFSCAN_PROBE'].split(','):
            P = int(hx, 16)
            inb = [l for l, blk in blocks.items()
                   if any(i['pc'] == P for i in blk)]
            print(f"PROBE ${P:04X}: in ins={P in ins} "
                  f"decode={ins.get(P)} leader={P in leaders} "
                  f"haspred={P in has_pred} inblocks={[hex(x) for x in inb]}")
            print(f"  count={count.get(P)} seen={seen.get(P)} "
                  f"mem[{P-2:04X}..]={' '.join(f'{mem[P-2+k]:02X}' for k in range(8))}")
            if inb:
                l = inb[0]
                print(f"  block ${l:04X}: " + " ".join(
                    f"{i['mn']}@{i['pc']:04X}" for i in blocks[l])
                    + f"  succ={[(hex(t), e) for t, e in blk_succ[l]]}")

    _BANK_SUM.clear()
    IN = run_fixpoint()          # pass 1: every JSR is bank-unknown

    # ── interprocedural bank summaries ──────────────────────────────────
    # Per JSR target: ('id',) = provably never writes ROMSEL on any
    # entry->RTS path; ('const', k) = every RTS path exits bank k; None =
    # unknown. Computed on pass-1 states (A-const facts at STA $FE30
    # sites don't depend on bank state, so one summary round + one global
    # re-run reaches the fixpoint). Soundness guards below refuse any
    # body that plays stack games (RTS-dispatch pushes / return-drop
    # pops: PHA/PLA imbalance over the body union) or leaves the modeled
    # CFG (RTI/BRK/indirect JMP/edges filtered out of blk_succ). NB a
    # JMP abs whose operand is SMC follows the STATIC image — sound
    # today because the one such site (rns_go) only dispatches RNS
    # kernels, which are pure ('id',) leaves; a new SMC JMP into paging
    # code would need a volatile check here.

    _SUMWHY = {}

    def _compose(pre, c):
        if c is None:
            return None
        if c == ('id',):
            return pre
        return c                            # ('const', k)

    def _join_eff(a, b):
        if a == 'bot':
            return b
        if b == 'bot' or a == b:
            return a
        return None

    _EXP = {'RTS': 0, 'RTI': 0, 'BRK': 0}

    def _eval(entry, sums):
        seen = set()
        stk = [entry]
        while stk:                          # intraprocedural body (RTS=exit,
            b = stk.pop()                   # JSR = fall-through edge only)
            if b in seen or b not in blocks:
                continue
            seen.add(b)
            for (t, _e) in blk_succ[b]:
                stk.append(t)
        pha = pla = 0
        for b in seen:
            for i in blocks[b]:
                if i['mn'] == 'PHA':
                    pha += 1
                elif i['mn'] == 'PLA':
                    pla += 1
            last = blocks[b][-1]
            if last['mn'] in ('RTI', 'BRK') or last['mode'] == 'ind':
                _SUMWHY[entry] = f"exit-insn {last['mn']}/{last['mode']} at ${last['pc']:04X}"
                return None
            exp = _EXP.get(last['mn'], 2 if last['mode'] == 'rel' else 1)
            if len(blk_succ[b]) < exp:
                _SUMWHY[entry] = f"edge off-model at ${last['pc']:04X} {last['mn']}"
                return None                 # an edge left the model
        if pha != pla:
            _SUMWHY[entry] = f"PHA/PLA imbalance {pha}/{pla}"
            return None                     # RTS-dispatch / return-drop
        EFF = {entry: ('id',)}
        wl = [entry]
        res = 'bot'
        it = 0
        while wl:
            it += 1
            if it > 100000:
                return None
            b = wl.pop()
            eff = EFF[b]
            st = IN[b].clone() if b in IN else None
            for i in blocks[b]:
                if (i['mn'] == 'STA' and i['mode'] == 'abs'
                        and i['opnd'] == 0xFE30):
                    v = st.r['A'] if st is not None else U
                    eff = (('const', v[1]) if (v != U and v[0] == 'c')
                           else None)
                elif i['mn'] == 'JSR':
                    eff = _compose(eff, sums.get(i['opnd']))
                if st is not None:
                    transfer(st, i, volatile)
            if blocks[b][-1]['mn'] == 'RTS':
                res = _join_eff(res, eff)
                continue
            for (t, _e) in blk_succ[b]:
                if t not in EFF:
                    EFF[t] = eff
                    wl.append(t)
                elif EFF[t] != eff:
                    j = EFF[t] if EFF[t] == eff else (
                        eff if EFF[t] == 'bot' else
                        (EFF[t] if eff == 'bot' else None))
                    if j != EFF[t]:
                        EFF[t] = j
                        wl.append(t)
        if res == 'bot':
            _SUMWHY[entry] = "no RTS reached"
            return None
        if res is None:
            _SUMWHY[entry] = "conflicting/unknown paths"
        return res

    subs = sorted(jsr_targets & set(blocks))
    sums = {e: ('id',) for e in subs}       # optimistic init, iterate to fix
    for _round in range(30):
        new = {e: _eval(e, sums) for e in subs}
        if new == sums:
            break
        sums = new
    _BANK_SUM.update({e: v for e, v in sums.items() if v is not None})
    n_id = sum(1 for v in _BANK_SUM.values() if v == ('id',))
    n_ct = len(_BANK_SUM) - n_id
    print(f"bank summaries: {len(subs)} subroutines -> "
          f"{n_id} id, {n_ct} const-exit, {len(subs)-len(_BANK_SUM)} unknown")
    if os.environ.get('DFSCAN_SUMS'):
        for e in subs:
            v = sums.get(e)
            why = '' if v is not None else '  [' + _SUMWHY.get(e, '?') + ']'
            sn, so = sym_near(e)
            lbl = f"{sn}+{so}" if so else sn
            print(f"  ${e:04X} {lbl:34s} {v!r}{why}")

    IN = run_fixpoint()          # pass 2: JSRs consult the summaries

    # ── findings ────────────────────────────────────────────────────────
    findings = []

    def flags_dead_after(blk, k, flags):
        """True if none of `flags` set by blk[k] can be read before being
        rewritten, scanning to block end (conservative: block end,
        branch, JSR, RTS, PHP = live)."""
        READS = {'C': {'ADC', 'SBC', 'ROL', 'ROR', 'BCC', 'BCS'},
                 'Z': {'BNE', 'BEQ'}, 'N': {'BPL', 'BMI'},
                 'V': {'BVC', 'BVS'}}
        WRITES = {'C': {'ADC', 'SBC', 'ASL', 'LSR', 'ROL', 'ROR', 'CMP',
                        'CPX', 'CPY', 'CLC', 'SEC'},
                  'Z': {'LDA', 'LDX', 'LDY', 'ADC', 'SBC', 'AND', 'ORA',
                        'EOR', 'ASL', 'LSR', 'ROL', 'ROR', 'CMP', 'CPX',
                        'CPY', 'INC', 'DEC', 'INX', 'INY', 'DEX', 'DEY',
                        'TAX', 'TAY', 'TXA', 'TYA', 'TSX', 'PLA', 'BIT'},
                  'V': {'ADC', 'SBC', 'CLV', 'BIT'}}
        WRITES['N'] = WRITES['Z'] | {'BIT'}
        live = set(flags)
        for j in range(k + 1, len(blk)):
            mnj = blk[j]['mn']
            if mnj in ('JSR', 'RTS', 'RTI', 'PHP', 'BRK'):
                return False
            for fl in list(live):
                if mnj in READS[fl]:
                    return False
                if mnj in WRITES[fl]:
                    live.discard(fl)
            if not live:
                return True
        return False    # reached block end with a flag still live

    def reg_reads(i, reg):
        mn, mode = i['mn'], i['mode']
        if reg == 'A':
            return (mn in ('STA', 'TAX', 'TAY', 'PHA', 'CMP', 'ADC', 'SBC',
                           'AND', 'ORA', 'EOR', 'BIT')
                    or (mn in ('ASL', 'LSR', 'ROL', 'ROR')
                        and mode == 'acc'))
        if reg == 'X':
            return (mn in ('STX', 'TXA', 'TXS', 'CPX', 'INX', 'DEX')
                    or mode in ('zpx', 'abx', 'inx'))
        if reg == 'Y':
            return (mn in ('STY', 'TYA', 'CPY', 'INY', 'DEY')
                    or mode in ('zpy', 'aby', 'iny'))
        return False

    def reg_writes(i, reg):
        mn, mode = i['mn'], i['mode']
        return ((mn in ('LDA', 'TXA', 'TYA', 'PLA', 'ADC', 'SBC', 'AND',
                        'ORA', 'EOR') and reg == 'A')
                or (mn in ('ASL', 'LSR', 'ROL', 'ROR') and mode == 'acc'
                    and reg == 'A')
                or (mn in ('LDX', 'TAX', 'TSX', 'INX', 'DEX')
                    and reg == 'X')
                or (mn in ('LDY', 'TAY', 'INY', 'DEY') and reg == 'Y'))

    for lead, blk in blocks.items():
        if lead not in IN:
            continue        # unreachable in model
        st = IN[lead].clone()
        for k, i in enumerate(blk):
            pc, mn, mode, opnd = i['pc'], i['mn'], i['mode'], i['opnd']
            n = count.get(pc, 0)
            if pc not in volatile:
                # F1: redundant immediate load
                if mn in ('LDA', 'LDX', 'LDY') and mode == 'imm':
                    reg = mn[2]
                    if st.r[reg] == C(opnd):
                        zok = (st.f['Z'] == (1 if opnd == 0 else 0)
                               and st.f['N'] == (1 if opnd & 0x80 else 0))
                        if zok or flags_dead_after(blk, k, 'ZN') \
                           or st.zn == reg:
                            findings.append(dict(
                                cat='imm_load', pc=pc, n=n,
                                save=icost(mn, mode) * n,
                                txt=f"{mn} #${opnd:02X} — {reg} already "
                                    f"${opnd:02X}"))
                # F3: redundant reload
                if mn in ('LDA', 'LDX', 'LDY') and mode in ('zp', 'abs'):
                    reg = mn[2]
                    same = (st.r[reg] == M(opnd) or
                            (opnd in st.mem and st.r[reg] != U
                             and st.r[reg] == st.mem[opnd]))
                    if same:
                        zok = st.zn == reg
                        if not zok and st.r[reg] != U \
                           and st.r[reg][0] == 'c':
                            v = st.r[reg][1]
                            zok = (st.f['Z'] == (1 if v == 0 else 0)
                                   and st.f['N'] == (1 if v & 0x80 else 0))
                        if zok or flags_dead_after(blk, k, 'ZN'):
                            findings.append(dict(
                                cat='reload', pc=pc, n=n,
                                save=icost(mn, mode) * n,
                                txt=f"{mn} ${opnd:04X} — {reg} already "
                                    f"holds it"))
                # F2: redundant CLC/SEC
                if mn == 'CLC' and st.f['C'] == 0:
                    findings.append(dict(cat='clc_sec', pc=pc, n=n,
                                         save=2 * n, txt="CLC — C already 0"))
                if mn == 'SEC' and st.f['C'] == 1:
                    findings.append(dict(cat='clc_sec', pc=pc, n=n,
                                         save=2 * n, txt="SEC — C already 1"))
                # F6: dead CLC/SEC (overwritten before read, same block)
                if mn in ('CLC', 'SEC') and st.f['C'] != (0 if mn == 'CLC'
                                                          else 1):
                    if flags_dead_after(blk, k, 'C'):
                        findings.append(dict(cat='dead_flag', pc=pc, n=n,
                                             save=2 * n,
                                             txt=f"{mn} — C rewritten "
                                                 f"before any reader"))
                # F7: CMP #0 with flags already reflecting A
                if mn == 'CMP' and mode == 'imm' and opnd == 0 \
                        and st.zn == 'A':
                    if st.f['C'] == 1 or flags_dead_after(blk, k, 'C'):
                        findings.append(dict(cat='cmp_zero', pc=pc, n=n,
                                             save=2 * n,
                                             txt="CMP #0 — Z/N already "
                                                 "from A"))
                # F8: identity logic ops
                if ((mn == 'AND' and mode == 'imm' and opnd == 0xFF) or
                        (mn in ('ORA', 'EOR') and mode == 'imm'
                         and opnd == 0)):
                    if st.zn == 'A' or flags_dead_after(blk, k, 'ZN'):
                        findings.append(dict(cat='identity', pc=pc, n=n,
                                             save=2 * n,
                                             txt=f"{mn} #${opnd:02X} — "
                                                 f"identity"))
                # F4: store of already-present value (low confidence)
                if mn in ('STA', 'STX', 'STY') and mode in ('zp', 'abs'):
                    reg = mn[2]
                    if (opnd in st.mem and st.r[reg] != U
                            and st.r[reg][0] == 'c'
                            and st.mem[opnd] == st.r[reg]
                            and opnd < 0x5800 and n > 0):
                        findings.append(dict(cat='known_store', pc=pc, n=n,
                                             save=icost(mn, mode) * n,
                                             txt=f"{mn} ${opnd:04X} — slot "
                                                 f"already holds "
                                                 f"${st.r[reg][1]:02X}"))
                # F9: redundant PAGE — STA $FE30 with the bank already
                # current on every modeled path (LDA #bank + STA pair)
                if mn == 'STA' and mode == 'abs' and opnd == 0xFE30:
                    v = st.r['A']
                    if v != U and v[0] == 'c' and st.bank == v[1]:
                        findings.append(dict(cat='page_same', pc=pc, n=n,
                                             save=6 * n,
                                             txt=f"PAGE {v[1]} — bank "
                                                 f"already {v[1]}"))
                # F5: dead register write (rewritten in-block, unread,
                #     flags unconsumed)
                if mn in ('LDA', 'LDX', 'LDY', 'TXA', 'TYA', 'TAX', 'TAY') \
                        and mode in ('imm', 'zp', 'abs', 'imp', 'zpx',
                                     'abx', 'aby'):
                    reg = 'A' if mn in ('LDA', 'TXA', 'TYA') else mn[2]
                    if mn in ('TAX', 'TAY'):
                        reg = mn[2]
                    dead = None
                    for j in range(k + 1, len(blk)):
                        nj = blk[j]
                        if nj['mn'] in ('JSR', 'RTS', 'RTI', 'BRK'):
                            break
                        if reg_reads(nj, reg):
                            break
                        if reg_writes(nj, reg):
                            dead = j
                            break
                    if dead is not None and flags_dead_after(blk, k, 'ZN'):
                        findings.append(dict(cat='dead_write', pc=pc, n=n,
                                             save=icost(mn, mode) * n,
                                             txt=f"{mn} — {reg} rewritten at "
                                                 f"${blk[dead]['pc']:04X} "
                                                 f"unread"))
            transfer(st, i, volatile)

    # dedupe + rank
    best = {}
    for f in findings:
        key = (f['pc'], f['cat'])
        if key not in best or f['save'] > best[key]['save']:
            best[key] = f
    findings = sorted(best.values(), key=lambda f: -f['save'])

    def near(pc):
        try:
            s, off = sym_near(pc)
            return f"{s}+{off}" if off else s
        except Exception:
            return "?"

    if pagew:
        print("\nPAGE sites (dynamic same-bank rate; 100% = elision candidate "
              "pending caller audit):")
        for pc, (same, tot) in sorted(pagew.items(), key=lambda kv: -kv[1][0]):
            if same:
                print(f"  ${pc:04X} {near(pc):34} same {same}/{tot}"
                      f" ({100*same/tot:.0f}%)  save {6*same}")
    total = sum(f['save'] for f in findings if f['cat'] != 'known_store')
    print(f"\n{len(findings)} findings; est. cycle savings (excl. "
          f"known_store): {total} on the traced suite\n")
    print(f"{'addr':6} {'symbol':34} {'cat':11} {'execs':>7} {'save':>7}  "
          f"detail")
    for f in findings:
        if f['n'] == 0 and f['save'] == 0:
            continue
        print(f"${f['pc']:04X} {near(f['pc']):34} {f['cat']:11} "
              f"{f['n']:7} {f['save']:7}  {f['txt']}")
    cold = [f for f in findings if f['n'] == 0]
    if cold:
        print(f"\n({len(cold)} additional findings on never-executed "
              f"static paths — listed in the JSON)")
    out = args.json
    if out is None:
        sp = os.environ.get('CLAUDE_SCRATCHPAD')
        out = os.path.join(sp, 'dfscan.json') if sp else 'build/dfscan.json'
    with open(out, 'w') as fh:
        json.dump([dict(f, sym=near(f['pc'])) for f in findings], fh,
                  indent=1)
    print(f"\nJSON: {out}")


if __name__ == '__main__':
    main()
