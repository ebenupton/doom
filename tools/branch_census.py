#!/usr/bin/env python3
"""Dynamic branch census — instrument every conditional branch the engine
executes over the full cycle suite and flag ARRANGEMENT opportunities:
mostly-taken forward branches whose common case should fall through
(the project.s M8==0 pattern, caught by hand 2026-07-26 — this tool
exists so the next one is caught by census).

Method: monkey-patch SpanClip6502._run with a stepping loop that, for the
8 conditional-branch opcodes, records (exec, taken) per site plus the
static target (direction, page-cross). Attribution via the ld65 dbg file
(addr -> file:line) and nearest preceding label; source text inlined.

Classes flagged (defaults: --min-exec 1000, --taken 0.75):
  FWD-TAKEN  forward branch taken >= threshold — invert / hoist the rare
             block so the common case falls through. net@invert (cycles
             over the whole suite) = taken - nottaken + pagecross*taken
             (the rare arm inherits the hop; its page-cost after the
             restructure is layout-dependent, so treat as an upper bound
             and MEASURE the real win via run_regression MEAN).
  ALWAYS     taken == exec. Either an invertible dispatch (win) or a
             deliberate branch-always idiom (byte-saving short JMP —
             equal speed same-page, SLOWER by 1 if page-crossing).
  BACK-NT    backward branch mostly NOT taken — a loop that usually runs
             once, or a rare retreat; listed FYI (arrange-forward may pay).
Backward mostly-taken branches are loop-backs (already optimal): silent.

Usage:
  python3 tools/branch_census.py [--frames N] [--min-exec N] [--taken F]
                                 [--json PATH] [--all]
"""
import argparse
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
os.environ.setdefault('SDL_VIDEODRIVER', 'dummy')
os.environ.setdefault('PYGAME_HIDE_SUPPORT_PROMPT', '1')

BR = {0x10: 'BPL', 0x30: 'BMI', 0x50: 'BVC', 0x70: 'BVS',
      0x90: 'BCC', 0xB0: 'BCS', 0xD0: 'BNE', 0xF0: 'BEQ'}


def parse_dbg(path):
    """Return (addr -> (file, line), sorted [(addr, label)]) from ld65 dbg."""
    files, segs, spans = {}, {}, {}
    line_recs, syms = [], []
    with open(path) as f:
        for raw in f:
            kind, _, rest = raw.partition('\t')
            if kind not in ('file', 'seg', 'span', 'line', 'sym'):
                continue
            fields = dict(kv.split('=', 1) for kv in rest.strip().split(','))
            if kind == 'file':
                files[fields['id']] = fields['name'].strip('"')
            elif kind == 'seg':
                segs[fields['id']] = int(fields['start'], 16)
            elif kind == 'span':
                spans[fields['id']] = (fields['seg'],
                                       int(fields['start']),
                                       int(fields['size']))
            elif kind == 'line':
                if 'span' in fields:
                    line_recs.append((fields['file'], int(fields['line']),
                                      fields['span'].split('+')))
            elif kind == 'sym':
                if fields.get('type') == 'lab' and 'val' in fields and 'seg' in fields:
                    syms.append((int(fields['val'], 16),
                                 fields['name'].strip('"')))
    addr2line = {}
    for fid, lno, span_ids in line_recs:
        fname = files.get(fid, '?')
        for sid in span_ids:
            if sid not in spans:
                continue
            seg_id, start, size = spans[sid]
            base = segs.get(seg_id)
            if base is None:
                continue
            for a in range(base + start, base + start + size):
                # keep the FIRST (innermost) attribution seen
                addr2line.setdefault(a, (fname, lno))
    syms.sort()
    return addr2line, syms


def nearest_label(syms, addr):
    lo, hi = 0, len(syms)
    while lo < hi:
        mid = (lo + hi) // 2
        if syms[mid][0] <= addr:
            lo = mid + 1
        else:
            hi = mid
    if lo == 0:
        return '?', 0
    val, name = syms[lo - 1]
    return name, addr - val


_src_cache = {}


def source_text(fname, lno):
    if fname not in _src_cache:
        try:
            with open(fname) as f:
                _src_cache[fname] = f.readlines()
        except OSError:
            _src_cache[fname] = []
    lines = _src_cache[fname]
    if 0 < lno <= len(lines):
        return lines[lno - 1].strip()
    return ''


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--frames', type=int, default=0,
                    help='limit to first N suite positions (0 = all)')
    ap.add_argument('--min-exec', type=int, default=1000)
    ap.add_argument('--taken', type=float, default=0.75)
    ap.add_argument('--json', default=None)
    ap.add_argument('--all', action='store_true',
                    help='dump every site, not just flagged ones')
    args = ap.parse_args()

    import pygame
    pygame.init()
    pygame.display.set_mode((1, 1))
    import doom_wireframe as dw
    from bsp_render_6502 import BspRender6502
    import compare_renders as C
    import span_clip_6502 as scmod
    import asmbuild

    dbg = os.path.join(asmbuild._ROOT, 'build', 'engine_b0c0.dbg')
    addr2line, syms = parse_dbg(dbg)

    r = BspRender6502(dw.packed_layout, dw.packed_rom_main,
                      dw.packed_rom_detail, dw.packed_bbox_table,
                      dw.MAP_CENTER_X, dw.MAP_CENTER_Y, dw.PRESCALE)
    sc = r.sc
    mpu = sc.mpu
    mem = mpu.memory
    plot_pcs = scmod.PLOT_PCS
    rz = (scmod.RZ_X0, scmod.RZ_Y0, scmod.RZ_X1, scmod.RZ_Y1)

    stats = {}   # pc -> [exec, taken]

    def prof_run(entry, max_cycles=500000):
        mpu.pc = entry
        mpu.sp = 0xFD
        mpu.p = 0x30
        mem[0x01FF] = 0xFE
        mem[0x01FE] = 0xFF
        mpu.processorCycles = 0
        lines = sc.last_lines = []
        get = stats.get
        for _ in range(max_cycles):
            pc = mpu.pc
            if pc == 0xFF00:
                break
            if pc in plot_pcs:
                lines.append((mem[rz[0]], mem[rz[1]], mem[rz[2]], mem[rz[3]]))
            if mem[pc] in BR:
                mpu.step()
                st = get(pc)
                if st is None:
                    st = stats[pc] = [0, 0]
                st[0] += 1
                if mpu.pc != (pc + 2) & 0xFFFF:
                    st[1] += 1
            else:
                mpu.step()
        sc.last_cycles = mpu.processorCycles
        sc.total_cycles += mpu.processorCycles
        return mpu.processorCycles

    sc._run = prof_run

    positions = C.POSITIONS[:args.frames] if args.frames else C.POSITIONS
    total = 0
    for i, (px, py, ab) in enumerate(positions):
        total += r.render_frame(px, py, ab, dw.player_floor(px, py))
        print(f'  frame {i + 1}/{len(positions)} done', file=sys.stderr)
    print(f'total cycles ({len(positions)} frames): {total:,}\n')

    rows = []
    for pc, (n_exec, n_taken) in stats.items():
        op = mem[pc]
        offs = mem[(pc + 1) & 0xFFFF]
        if offs >= 0x80:
            offs -= 256
        target = (pc + 2 + offs) & 0xFFFF
        fwd = target > pc
        pgx = ((pc + 2) & 0xFF00) != (target & 0xFF00)
        frac = n_taken / n_exec
        n_nt = n_exec - n_taken
        net = n_taken - n_nt + (n_taken if pgx else 0)
        if n_taken == n_exec:
            klass = 'ALWAYS'
        elif fwd and frac >= args.taken:
            klass = 'FWD-TAKEN'
        elif not fwd and frac < 0.5:
            klass = 'BACK-NT'
        else:
            klass = ''
        if 0x2000 <= pc < 0x2900 and pc not in addr2line:
            label, off = '(raster-blob-SEALED)', pc - 0x2000
            fname, lno = '?', 0
        else:
            label, off = nearest_label(syms, pc)
            fname, lno = addr2line.get(pc, ('?', 0))
        rows.append({
            'pc': pc, 'op': BR[op], 'target': target,
            'dir': 'fwd' if fwd else 'back', 'pgx': pgx,
            'exec': n_exec, 'taken': n_taken, 'frac': frac,
            'net_invert': net, 'class': klass,
            'label': f'{label}+{off}' if off else label,
            'file': os.path.relpath(fname) if fname != '?' else '?',
            'line': lno, 'src': source_text(fname, lno),
        })

    # BACK-NT (rare backward hop) is usually the ALREADY-OPTIMAL cold-block-
    # above arrangement — FYI only, never a flag (see px_shrink at HEAD).
    flagged = [r_ for r_ in rows
               if r_['class'] in ('FWD-TAKEN', 'ALWAYS')
               and r_['exec'] >= args.min_exec]
    flagged.sort(key=lambda r_: -r_['net_invert'])

    hdr = (f"{'addr':>5} {'op':<3} {'dir':<4} {'pgx':<3} {'exec':>9} "
           f"{'taken%':>6} {'net@inv':>8}  {'class':<9} "
           f"{'label':<26} {'where':<32} src")
    print(hdr)
    print('-' * len(hdr))
    for r_ in flagged:
        print(f"${r_['pc']:04X} {r_['op']:<3} {r_['dir']:<4} "
              f"{'Y' if r_['pgx'] else '.':<3} {r_['exec']:>9,} "
              f"{100 * r_['frac']:>5.1f}% {r_['net_invert']:>8,}  "
              f"{r_['class']:<9} {r_['label']:<26} "
              f"{r_['file']}:{r_['line']:<5} {r_['src'][:60]}")
    print(f'\n{len(flagged)} flagged / {len(rows)} branch sites '
          f'(min-exec {args.min_exec}, taken >= {args.taken:.0%})')

    if args.all:
        print('\n== all sites ==')
        for r_ in sorted(rows, key=lambda r_: -r_['exec']):
            print(f"${r_['pc']:04X} {r_['op']:<3} {r_['dir']:<4} "
                  f"{'Y' if r_['pgx'] else '.':<3} {r_['exec']:>9,} "
                  f"{100 * r_['frac']:>5.1f}% {r_['net_invert']:>8,}  "
                  f"{r_['class']:<9} {r_['label']:<26} "
                  f"{r_['file']}:{r_['line']}")

    if args.json:
        import json
        with open(args.json, 'w') as f:
            json.dump(rows, f, indent=1)
        print(f'wrote {args.json}')


if __name__ == '__main__':
    main()
