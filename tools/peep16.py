#!/usr/bin/env python3
"""peep16 — exhaustive 16-instruction window enumerator + peephole challenger.

Disassembles the linked flat engine image (ground truth: what actually
runs), slides a 16-instruction window over every code segment, dedupes
isomorphic windows, and challenges each against a library of 6502
better-implementation patterns. Incoming branches into a window are
resolved via the full branch-target set (jt entries, branches, JSR/JMP
operands): a finding whose rewrite would span an entry point is flagged
SPLIT so the reviewer knows the transformation needs label surgery.

Report only — application is manual, measured, and gated per house rules.
"""
import os, sys, re
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), '..'))
os.chdir(os.path.join(os.path.dirname(os.path.abspath(__file__)), '..'))
os.environ.setdefault('SDL_VIDEODRIVER', 'dummy')

import asmbuild
from symmap import sym

# --- image + map -------------------------------------------------------------
asmbuild.build('engine', banked=0)
import engine_load
mem = bytearray(65536)
engine_load.load_engine(mem, banked=0)

segs = []
for line in open('build/engine_b0c0.map'):
    m = re.match(r'^([A-Z][A-Z0-9]*)\s+00([0-9A-F]{4})\s+00([0-9A-F]{4})\s+00([0-9A-F]{4})', line)
    if m:
        name, a, b = m.group(1), int(m.group(2), 16), int(m.group(3), 16)
        segs.append((name, a, b))
CODE_SEGS = {'CLIPJT','CLIP','MAIN','LO','LOX','RNSPG','B','D','W','ANG','SEL','ANIMH','ANIML0','ANIML2','ZZTAIL'}
segs = [(n,a,b) for (n,a,b) in segs if n in CODE_SEGS]

# symbols: name->addr and addr->name (for table detection + branch targets)
sym_by_addr = {}
for line in open('build/engine_b0c0.map'):
    for m in re.finditer(r'([A-Za-z_][A-Za-z0-9_]*)\s+00([0-9A-F]{4})\s+R?LA?', line):
        pass
# ld65 map exports section format varies; also read the symmap module's table
import symmap as _sm
try:
    table = _sm._syms  # type: ignore[attr-defined]
except AttributeError:
    table = {}
    for line in open(_sm.__file__.replace('.pyc','.py')):
        pass
table, _amb = _sm._load(banked=0)
addr_names = {}
for k, v in table.items():
    addr_names.setdefault(v, []).append(k)
addr_sorted = sorted(addr_names)
import bisect
def name_of(addr):
    i = bisect.bisect_right(addr_sorted, addr) - 1
    if i < 0: return ''
    base = addr_sorted[i]
    if addr - base > 0x200: return ''
    return addr_names[base][0] + (f'+{addr-base}' if addr != base else '')

# --- disassembler ------------------------------------------------------------
# opcode table: (mnemonic, mode, length, cycles-base)
M = {}
def op(code, mn, mode, ln, cy): M[code] = (mn, mode, ln, cy)
for c,mn in ((0x69,'ADC'),(0x29,'AND'),(0xC9,'CMP'),(0xE0,'CPX'),(0xC0,'CPY'),
             (0x49,'EOR'),(0xA9,'LDA'),(0xA2,'LDX'),(0xA0,'LDY'),(0x09,'ORA'),(0xE9,'SBC')):
    op(c, mn, 'imm', 2, 2)
for c,mn in ((0x65,'ADC'),(0x25,'AND'),(0x06,'ASL'),(0x24,'BIT'),(0xC5,'CMP'),(0xE4,'CPX'),
             (0xC4,'CPY'),(0xC6,'DEC'),(0x45,'EOR'),(0xE6,'INC'),(0xA5,'LDA'),(0xA6,'LDX'),
             (0xA4,'LDY'),(0x46,'LSR'),(0x05,'ORA'),(0x26,'ROL'),(0x66,'ROR'),(0xE5,'SBC'),
             (0x85,'STA'),(0x86,'STX'),(0x84,'STY')):
    op(c, mn, 'zp', 2, 3)
for c,mn in ((0x75,'ADC'),(0x35,'AND'),(0x16,'ASL'),(0xD5,'CMP'),(0xD6,'DEC'),(0x55,'EOR'),
             (0xF6,'INC'),(0xB5,'LDA'),(0xB4,'LDY'),(0x56,'LSR'),(0x15,'ORA'),(0x36,'ROL'),
             (0x76,'ROR'),(0xF5,'SBC'),(0x95,'STA'),(0x94,'STY')):
    op(c, mn, 'zpx', 2, 4)
op(0xB6,'LDX','zpy',2,4); op(0x96,'STX','zpy',2,4)
for c,mn in ((0x6D,'ADC'),(0x2D,'AND'),(0x0E,'ASL'),(0x2C,'BIT'),(0xCD,'CMP'),(0xEC,'CPX'),
             (0xCC,'CPY'),(0xCE,'DEC'),(0x4D,'EOR'),(0xEE,'INC'),(0xAD,'LDA'),(0xAE,'LDX'),
             (0xAC,'LDY'),(0x4E,'LSR'),(0x0D,'ORA'),(0x2E,'ROL'),(0x6E,'ROR'),(0xED,'SBC'),
             (0x8D,'STA'),(0x8E,'STX'),(0x8C,'STY')):
    op(c, mn, 'abs', 3, 4)
for c,mn in ((0x7D,'ADC'),(0x3D,'AND'),(0x1E,'ASL'),(0xDD,'CMP'),(0xDE,'DEC'),(0x5D,'EOR'),
             (0xFE,'INC'),(0xBD,'LDA'),(0xBC,'LDY'),(0x5E,'LSR'),(0x1D,'ORA'),(0x3E,'ROL'),
             (0x7E,'ROR'),(0xFD,'SBC'),(0x9D,'STA')):
    op(c, mn, 'absx', 3, 4)
for c,mn in ((0x79,'ADC'),(0x39,'AND'),(0xD9,'CMP'),(0x59,'EOR'),(0xB9,'LDA'),(0xBE,'LDX'),
             (0x19,'ORA'),(0xF9,'SBC'),(0x99,'STA')):
    op(c, mn, 'absy', 3, 4)
for c,mn in ((0x61,'ADC'),(0x21,'AND'),(0xC1,'CMP'),(0x41,'EOR'),(0xA1,'LDA'),(0x01,'ORA'),
             (0xE1,'SBC'),(0x81,'STA')):
    op(c, mn, 'izx', 2, 6)
for c,mn in ((0x71,'ADC'),(0x31,'AND'),(0xD1,'CMP'),(0x51,'EOR'),(0xB1,'LDA'),(0x11,'ORA'),
             (0xF1,'SBC'),(0x91,'STA')):
    op(c, mn, 'izy', 2, 5)
for c,mn,cy in ((0x0A,'ASL',2),(0x4A,'LSR',2),(0x2A,'ROL',2),(0x6A,'ROR',2),
                (0x18,'CLC',2),(0x38,'SEC',2),(0xD8,'CLD',2),(0xF8,'SED',2),(0x58,'CLI',2),
                (0x78,'SEI',2),(0xB8,'CLV',2),(0xCA,'DEX',2),(0x88,'DEY',2),(0xE8,'INX',2),
                (0xC8,'INY',2),(0xEA,'NOP',2),(0xAA,'TAX',2),(0xA8,'TAY',2),(0xBA,'TSX',2),
                (0x8A,'TXA',2),(0x9A,'TXS',2),(0x98,'TYA',2),(0x48,'PHA',3),(0x08,'PHP',3),
                (0x68,'PLA',4),(0x28,'PLP',4),(0x40,'RTI',6),(0x60,'RTS',6),(0x00,'BRK',7)):
    op(c, mn, 'imp', 1, cy)
for c,mn in ((0x90,'BCC'),(0xB0,'BCS'),(0xF0,'BEQ'),(0x30,'BMI'),(0xD0,'BNE'),
             (0x10,'BPL'),(0x50,'BVC'),(0x70,'BVS')):
    op(c, mn, 'rel', 2, 2)
op(0x4C,'JMP','abs',3,3); op(0x6C,'JMP','ind',3,5); op(0x20,'JSR','abs',3,6)

def disasm_range(a, b):
    out = []
    pc = a
    while pc <= b:
        o = mem[pc]
        if o not in M:
            out.append((pc, 'DB', 'data', 1, 0, mem[pc])); pc += 1; continue
        mn, mode, ln, cy = M[o]
        opnd = 0
        if ln == 2: opnd = mem[pc+1]
        elif ln == 3: opnd = mem[pc+1] | (mem[pc+2] << 8)
        out.append((pc, mn, mode, ln, cy, opnd))
        pc += ln
    return out

instrs = []
for (n, a, b) in segs:
    instrs += disasm_range(a, b)
instrs.sort()

# --- branch-target / entry-point set -----------------------------------------
targets = set()
for (pc, mn, mode, ln, cy, opnd) in instrs:
    if mn == 'JSR' or (mn == 'JMP' and mode == 'abs'):
        targets.add(opnd)
    elif mode == 'rel':
        dest = pc + 2 + (opnd - 256 if opnd >= 128 else opnd)
        targets.add(dest)
for v in getattr(_sm, '_syms', {}).values():
    targets.add(v)

# --- window enumeration + dedupe ---------------------------------------------
N = 16
sigs = {}
for i in range(len(instrs) - N + 1):
    w = instrs[i:i+N]
    if any(x[1] == 'DB' for x in w):            # crosses data — skip
        continue
    if w[-1][0] - w[0][0] > 64:                 # crossed a segment gap
        continue
    sig = tuple((x[1], x[2]) for x in w)
    sigs.setdefault(sig, []).append(i)
print(f"instructions: {len(instrs)}  windows: {len(instrs)-N+1}  unique-16-seq shapes: {len(sigs)}")

# --- challenge patterns -------------------------------------------------------
def fmt(w):
    return ' | '.join(f"{x[1]}{'#' if x[2]=='imm' else ''}"
                      f"{format(x[5], 'x') if x[3] > 1 else ''}" for x in w)

findings = []
def scan(w, i0):
    f = []
    for j in range(len(w) - 1):
        a, b = w[j], w[j+1]
        # dead store->load same zp
        if a[1] == 'STA' and b[1] == 'LDA' and a[2] == b[2] == 'zp' and a[5] == b[5]:
            f.append((j, 'STA/LDA same zp — LDA is dead (A already holds it)'))
        # LDA after LDA (dead first load)
        if a[1] == 'LDA' and b[1] == 'LDA':
            f.append((j, 'LDA/LDA — first load dead unless flags consumed'))
        # CLC/ADC #0-style
        if a[1] == 'CLC' and b[1] == 'ADC' and b[2] == 'imm' and b[5] == 0:
            f.append((j, 'CLC/ADC #0 — no-op pair unless carry-in matters'))
        # TAX/TXA and TAY/TYA round trips
        if (a[1], b[1]) in (('TAX','TXA'),('TXA','TAX'),('TAY','TYA'),('TYA','TAY')):
            f.append((j, f'{a[1]}/{b[1]} round trip — drop second unless flags'))
        # SEC/SBC #0
        if a[1] == 'SEC' and b[1] == 'SBC' and b[2] == 'imm' and b[5] == 0:
            f.append((j, 'SEC/SBC #0 — no-op pair'))
        # LDA #0 / STA -> consider shared zero source
        # JMP to next instruction
        if a[1] == 'JMP' and a[2] == 'abs' and a[5] == b[0]:
            f.append((j, 'JMP to fall-through — delete'))
    for j in range(len(w) - 2):
        a, b, c = w[j], w[j+1], w[j+2]
        # LDA x / STA t / LDA y ... STA using stale A patterns
        if a[1] == 'LDA' and b[1] == 'STA' and c[1] == 'LDA' and a[2] == c[2] and a[5] == c[5]:
            f.append((j, 'LDA x/STA/LDA x — reload of unclobbered A'))
        # branch over single JMP: Bxx +3 / JMP far / target -> invert branch,
        # ONLY actionable when the JMP target is within branch reach of the
        # branch site (else the pair exists precisely because it isn't).
        if a[2] == 'rel' and b[1] == 'JMP':
            dest = a[0] + 2 + (a[5] - 256 if a[5] >= 128 else a[5])
            if dest == c[0]:
                delta = b[5] - (a[0] + 2)
                if -128 <= delta <= 127:
                    f.append((j, f'branch-over-JMP: INVERTIBLE (target {delta:+d} in range) — saves 3B/2-3cyc'))
        # ADC #0 carry materialisation -> BCC/INC shape (house rule)
        if a[1] == 'LDA' and b[1] == 'ADC' and b[2] == 'imm' and b[5] == 0 and c[1] == 'STA' \
           and a[2] == 'zp' and c[2] == 'zp' and a[5] == c[5]:
            f.append((j, 'LDA t/ADC #0/STA t — carry bump: BCC/INC is 2 bytes shorter, faster off-carry'))
    # --- windowed A-liveness: STA t ... LDA t with no A-clobber between ---
    ACLOB = {'LDA','TXA','TYA','PLA','ADC','SBC','AND','ORA','EOR','ASL','LSR','ROL','ROR'}
    for j in range(len(w)):
        a = w[j]
        if a[1] != 'STA' or a[2] not in ('zp','abs'):
            continue
        for k in range(j+1, min(j+7, len(w))):
            x = w[k]
            if x[1] == 'LDA' and x[2] == a[2] and x[5] == a[5]:
                f.append((j, f'STA/LDA {a[5]:x} reload across {k-j} instrs — A survives'))
                break
            if x[1] in ACLOB and not (x[1] in ('ASL','LSR','ROL','ROR') and x[2] != 'imp'):
                break
            if x[2] == 'rel' or x[1] in ('JMP','JSR','RTS'):
                break
            if x[1] in ('STA','STX','STY') and x[2] == a[2] and x[5] == a[5]:
                break
    for j in range(len(w) - 1):
        a, b = w[j], w[j+1]
        # CMP #0 after an A-flag-setting op
        if b[1] == 'CMP' and b[2] == 'imm' and b[5] == 0 and \
           a[1] in ('LDA','AND','ORA','EOR','TXA','TYA','PLA','ADC','SBC','ASL','LSR','ROL','ROR'):
            f.append((j, 'CMP #0 after A-op — flags already set (Z/N; note C differs!)'))
    for j in range(len(w) - 1):
        a, b = w[j], w[j+1]
        # JSR x / RTS -> JMP x (tail call): -9cyc, -1B
        if a[1] == 'JSR' and b[1] == 'RTS':
            f.append((j, 'JSR/RTS — tail-call as JMP (-9cyc, -1B)'))
        # PHA/PLA adjacent round trip
        if a[1] == 'PHA' and b[1] == 'PLA':
            f.append((j, 'PHA/PLA adjacent — A unchanged (flags refresh only)'))
    return f

for sig, occ in sigs.items():
    i0 = occ[0]
    w = instrs[i0:i0+N]
    f = scan(w, i0)
    if f:
        # incoming-branch resolution: which finding positions have entry points INSIDE the affected pair/triple
        for (j, desc) in f:
            span = w[j:j+3]
            split = any(x[0] in targets and k > 0 for k, x in enumerate(span))
            findings.append((len(occ), w[j][0], desc, split, fmt(w[j:j+3])))

findings.sort(key=lambda t: -t[0])
seen_addr = set()
print(f"\nfindings (deduped by address):")
n_out = 0
for (cnt, addr, desc, split, txt) in findings:
    if addr in seen_addr: continue
    seen_addr.add(addr)
    nm = name_of(addr)
    flag = ' [SPLIT: incoming branch]' if split else ''
    print(f"  x{cnt:<3} ${addr:04X} {nm:34s} {desc}{flag}\n        {txt}")
    n_out += 1
    if n_out >= 40: 
        print(f"  ... ({len(set(a for _,a,_,_,_ in findings)) - n_out} more)")
        break

# --- most-frequent window shapes: the idioms worth manual challenge ----------
print("\n=== top repeated 16-instruction shapes (manual-challenge queue) ===")
by_freq = sorted(sigs.items(), key=lambda kv: -len(kv[1]))
for sig, occ in by_freq[:12]:
    if len(occ) < 3: break
    i0 = occ[0]
    w = instrs[i0:i0+N]
    print(f"\n  x{len(occ)} @ " + ' '.join(f"${instrs[i][0]:04X}({name_of(instrs[i][0])})" for i in occ[:4]))
    print("    " + fmt(w))
