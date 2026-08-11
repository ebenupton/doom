#!/usr/bin/env python3
"""Post-build code hygiene scan (Eben, 2026-08-09).

Parses the ca65 LISTING files (byte-exact, code/data context intact —
no linear-disassembly misalignment) for two defect classes:

1. ABS-ZP: 3-byte absolute-addressing encodings of page-zero operands
   where a 2-byte zeropage encoding exists (the ca65 forward-reference
   sizing issue — see the abs-zp grind memo). Reported per site with
   source file:line. `z:`-forced or genuinely absolute-only ops
   (JMP/JSR abs, indexed-Y stores etc. are exempt where no zp form
   exists).

2. FILLER: runs of $00 (BRK) or $EA (NOP) bytes emitted INSIDE a code
   region (>= THRESH consecutive bytes) — layout gaps, .res ballast,
   or misassembly that would execute as filler.

Exit status 0 = clean (or known-baseline), 1 = new findings.
Run as part of run_regression (both variants' listings are present
after a build)."""
import glob
import os
import re
import sys

os.chdir(os.path.join(os.path.dirname(os.path.abspath(__file__)), '..'))

THRESH = 8            # filler run length worth flagging
# opcodes (mnemonic, absolute-mode hex) that HAVE a zeropage form:
ABS_OPS = {
    'AD': 'LDA', 'AE': 'LDX', 'AC': 'LDY',
    '8D': 'STA', '8E': 'STX', '8C': 'STY',
    '6D': 'ADC', 'ED': 'SBC', 'CD': 'CMP', 'EC': 'CPX', 'CC': 'CPY',
    '2D': 'AND', '0D': 'ORA', '4D': 'EOR', '2C': 'BIT',
    '0E': 'ASL', '4E': 'LSR', '2E': 'ROL', '6E': 'ROR',
    'EE': 'INC', 'CE': 'DEC',
    'BD': 'LDA,X', 'B9': 'LDA,Y', '9D': 'STA,X',
    'BE': 'LDX,Y', 'BC': 'LDY,X',
    '7D': 'ADC,X', 'FD': 'SBC,X', 'DD': 'CMP,X',
    '3D': 'AND,X', '1D': 'ORA,X', '5D': 'EOR,X',
    'FE': 'INC,X', 'DE': 'DEC,X', '1E': 'ASL,X', '5E': 'LSR,X',
    '3E': 'ROL,X', '7E': 'ROR,X',
}
# abs,Y ops with NO zp,Y form (only LDX/STX have zp,Y): exempt
NO_ZP_FORM = {'B9', '99', 'BC', 'BD', '9D', '7D', 'FD', 'DD', '3D',
              '1D', '5D', 'FE', 'DE', '1E', '5E', '3E', '7E'}
# ^ zp,X forms DO exist for most of these — keep only true exemptions:
NO_ZP_FORM = {'B9', '99'}   # abs,Y loads/stores of A (no zp,Y mode)

line_re = re.compile(r'^([0-9A-F]{6})r?\s+\d+\s+((?:[0-9A-F]{2}r?\s)+)\s*(.*)$')


STORE_ABS = {'8D':'STA','8E':'STX','8C':'STY','9D':'STA,X','99':'STA,Y',
             'EE':'INC','CE':'DEC','0E':'ASL','4E':'LSR','2E':'ROL','6E':'ROR',
             'FE':'INC,X','DE':'DEC,X'}

def scan_listing(path):
    abszp, filler = [], []
    romwr = []
    banked = '_b1' in path
    run_start, run_len, run_byte = None, 0, None
    src_line = ''
    prev_decl = False
    for raw in open(path, errors='replace'):
        m = line_re.match(raw.rstrip('\n'))
        if not m:
            continue
        addr = int(m.group(1), 16)
        octets = [b.rstrip('r') for b in m.group(2).split()]
        text = m.group(3).strip()
        # --- BANKED ROM writes: absolute stores >= $C000 hit OS/lang ROM
        # on the real machine (harness RAM-everywhere is BLIND to this —
        # the $E4F8 zp_ft regression class, 2026-08-10). $FCxx-$FExx =
        # hardware/FRED/JIM/SHEILA are legitimate. ---
        if banked and len(octets) == 3 and octets[0] in STORE_ABS \
                and 'r' not in m.group(2):
            ad = int(octets[2],16)<<8 | int(octets[1],16)
            if 0xC000 <= ad < 0xFC00:
                romwr.append((path, addr, STORE_ABS[octets[0]], ad, text))
        # --- abs-zp: 3-byte encodings with hi operand byte 00 ---
        if len(octets) == 3 and octets[0] in ABS_OPS \
                and octets[0] not in NO_ZP_FORM and octets[2] == '00' \
                and not octets[1].endswith('r'):
            # relocatable operands print 'rr' — skip those (resolved by
            # ld65; segment-relative, not ZP)
            if 'r' not in m.group(2):
                abszp.append((path, addr, ABS_OPS[octets[0]],
                              int(octets[1], 16), text))
        # --- filler runs (skip DECLARED zero data: .byte/.word etc. with
        # explicit values is legitimate state; .res reservations and
        # source-less pad bytes are the findings) ---
        declared = text.lstrip().lower()
        is_decl = any(declared.startswith(d) or (':' in declared and
                      declared.split(':', 1)[1].lstrip().startswith(d))
                      for d in ('.byte', '.word', '.dbyt', '.addr', '.lobytes',
                                '.hibytes'))
        if not text:
            # continuation row of a multi-line emission: inherit the
            # declaring line's class (long zero .byte runs — e.g. the
            # SQD_H even-extension table — are data, not filler)
            is_decl = prev_decl
        prev_decl = is_decl
        for b in octets:
            v = b
            if v in ('00', 'EA') and not is_decl:
                if run_byte != v:
                    run_start, run_len, run_byte, src_line = addr, 0, v, text
                run_len += 1
            else:
                if run_byte and run_len >= THRESH:
                    filler.append((path, run_start, run_byte, run_len, src_line))
                run_byte, run_len = None, 0
    if run_byte and run_len >= THRESH:
        filler.append((path, run_start, run_byte, run_len, src_line))
    return abszp, filler, romwr


def main():
    lsts = sorted(glob.glob('build/*_b[01]c0.lst'))
    if not lsts:
        print('CODESCAN: no listings found — build first (asmbuild emits -l)')
        return 1
    all_abszp, all_filler, all_romwr = [], [], []
    for p in lsts:
        a, f, r = scan_listing(p)
        all_abszp += a
        all_filler += f
        all_romwr += r
    for (p, addr, op, operand, text) in all_abszp:
        print(f'ABS-ZP  {os.path.basename(p)} {addr:06X} {op} ${operand:02X}  | {text}')
    for (p, addr, byte, n, text) in all_filler:
        kind = 'BRK' if byte == '00' else 'NOP'
        print(f'FILLER  {os.path.basename(p)} {addr:06X} {n}x {kind}  | {text}')
    for (p, addr, op, ad, text) in all_romwr:
        print(f'ROM-WR  {os.path.basename(p)} {addr:06X} {op} ${ad:04X}  | {text}')
    print(f'CODESCAN: {len(all_abszp)} abs-zp site(s), '
          f'{len(all_filler)} filler run(s), {len(all_romwr)} banked ROM write(s)')
    if not all_abszp and not all_filler and not all_romwr:
        print('CODESCAN: PASS')
        return 0
    return 1


if __name__ == '__main__':
    sys.exit(main())
