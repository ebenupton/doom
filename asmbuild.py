"""Shared engine build helper — the ONE way tests/harnesses rebuild the 6502
engine. ca65 + ld65 (real objects, real linker); fail-loud (raises on any
assembler/linker error instead of silently loading a stale .bin) and
session-memoized (repeated harness constructions don't re-run the toolchain).

Sources live in src/*.s with one ld65 config per (module, layout). Output
binaries land in the repo root under their historical names, so the py65
harnesses and disc builders are unaffected.

Callers may pass the legacy source name ('bsp_render.asm') or the
module name ('bsp_render') — both resolve to the same target.

C02 selection: pass c02 explicitly, or leave None to respect the DOOM_CPU
env var. The old per-test hardcoded C02=0 rebuilds (which silently
overwrote C02=1 builds mid-regression) are gone.
"""
import os
import subprocess

_ROOT = os.path.dirname(os.path.abspath(__file__)) or '.'
_built = set()
_on_disk = {}    # banked -> c02 variant whose bins currently sit on disk.
                 # The two CPU variants share output filenames, so a
                 # memoized (banked,c02) build is only skippable when the
                 # OTHER variant hasn't overwritten the bins since — else a
                 # harness silently loads the wrong CPU's code (the 2026-07-21
                 # tube walk-gate bug: FlatRef read C02 bins via a memo hit).

# The engine is ONE link: three objects (angle module, span clipper, bsp
# renderer) resolved together, so cross-module calls are linker symbols.
# All legacy per-module names alias the single 'engine' target.
# Link order = CODE layout. bsp_render FIRST (2026-08-09): it carries the
# one .align $100 in CODE (the rns window), so ca65 page-aligns its whole
# fragment — placed first it aligns for free at the region head and the
# unaligned slope_div/span_clip fragments ABUT behind it: no join pads,
# all spare CODE space aggregated at the END (Eben's rule).
_SOURCES = ['src/bsp_render.s', 'src/slope_div.s', 'src/span_clip.s',
            'src/drv/walk_drv.s', 'src/raster.s']
_CFGS = {0: 'src/engine_flat.cfg', 1: 'src/engine_banked.cfg'}
_TARGETS = {'engine': None, 'slope_div': None, 'span_clip': None,
            'bsp_render': None}


def env_c02():
    return 1 if os.environ.get('DOOM_CPU', '').lower() in ('65c02', 'c02', '1') else 0


def _run(argv):
    r = subprocess.run(argv, capture_output=True, text=True, cwd=_ROOT)
    if r.returncode != 0:
        raise RuntimeError(f'{argv[0]} failed:\n{r.stdout}{r.stderr}')
    return r.stdout + r.stderr


def _srcstamp():
    """Fingerprint of everything the engine link reads.

    THE MARKER WAS A VARIANT TAG ONLY (fixed 2026-09-05): it named which
    of the four builds sat on disk and nothing else, so an edited source
    with the same variant on disk skipped the relink entirely and the
    caller measured, gated or asserted against the PREVIOUS binary.  It
    stayed hidden because run_regression and layout_fuzz both alternate
    flat/banked, and the alternation mismatches the tag every time.  A
    single-variant loop -- build banked, edit, build banked -- did not.
    """
    import hashlib
    h = hashlib.sha1()
    roots = [os.path.join(_ROOT, 'src')]
    files = []
    for r in roots:
        for dp, _dn, fn in os.walk(r):
            files += [os.path.join(dp, f) for f in fn
                      if f.endswith(('.s', '.inc', '.cfg', '.asm'))]
    for f in sorted(files):
        try:
            st = os.stat(f)
        except OSError:
            continue
        h.update(f'{f}:{st.st_mtime_ns}:{st.st_size}|'.encode())
    return h.hexdigest()[:16]


def build(asm, banked=0, c02=None, out=None, force=False):
    """Build one engine module. Raises RuntimeError on any tool error.

    `asm` is a module name ('span_clip') or legacy source name
    ('span_clip.asm'). `out` is accepted for backward compatibility and
    ignored (the ld65 config determines the outputs).
    """
    mod = os.path.basename(asm).replace('.asm', '').replace('.s', '')
    if mod not in _TARGETS:
        raise RuntimeError(f'unknown engine module: {asm}')
    if c02 is None:
        c02 = env_c02()
    c02 = int(c02)
    banked = int(banked)
    # DOOM_ASMDEFS (2026-09-03): extra "SYM=val,SYM2=val" ca65 defines for
    # POLICY EXPERIMENTS (dwalk_bench builds D-cache variants).  Part of the
    # build key AND the on-disk marker, so a variant never masquerades as
    # the plain build in a later process (the _on_disk landmine, again).
    defs = os.environ.get('DOOM_ASMDEFS', '')
    dflags = []
    for d in filter(None, defs.split(',')):
        dflags += ['-D', d]
    key = ('engine', banked, c02, defs)
    # CROSS-PROCESS variant marker (2026-09-02): the four variants share
    # output filenames (engine_drv.bin etc.), so "outputs exist" says
    # nothing about WHICH variant is on disk -- a fresh process reading
    # them raw got whatever the last build left (the walkdrv_loop wedge:
    # a C02 driver on an NMOS rig, exposed when the flat purge moved the
    # variants apart).  The marker names the on-disk variant; a mismatch
    # forces the relink.
    _marker = os.path.join(_ROOT, 'build', 'engine_on_disk')
    try:
        _disk = open(_marker).read()
    except OSError:
        _disk = ''
    _stamp = _srcstamp()
    if key in _built and _disk == f'{banked},{c02},{defs},{_stamp}' and not force:
        return ''
    # refuse to build with unallocated ZP declarations (name = ?) pending —
    # run tools/zpcheck.py --alloc to assign them
    zp = open(os.path.join(_ROOT, 'src', 'zp.inc')).read()
    import re as _re
    m = _re.search(r'^\s*([A-Za-z_]\w*)\s*=\s*\?', zp, _re.M)
    if m:
        raise RuntimeError(f'unallocated ZP declaration {m.group(1)!r} in src/zp.inc '
                           f'— run: python3 tools/zpcheck.py --alloc')
    objdir = os.path.join(_ROOT, 'build')
    os.makedirs(objdir, exist_ok=True)
    # BUILD LOCK (2026-09-03): parallel bench processes each relinked the
    # shared outputs and read each other's half-written files (ld65 "Read
    # error at position 53248").  One builder at a time; the marker check
    # repeats under the lock so the waiters skip the rebuild.
    import fcntl
    with open(os.path.join(objdir, '.build.lock'), 'w') as _lk:
        fcntl.flock(_lk, fcntl.LOCK_EX)
        try:
            _disk = open(_marker).read()
        except OSError:
            _disk = ''
        if _disk == f'{banked},{c02},{defs},{_stamp}' and not force:
            _built.add(key)
            _on_disk[banked] = c02
            return ''
        return _build_locked(asm, banked, c02, defs, dflags, key, objdir,
                             _marker, _stamp)


def _build_locked(asm, banked, c02, defs, dflags, key, objdir, _marker, _stamp):
    text = ''
    objs = []
    for src in _SOURCES:
        name = os.path.basename(src).replace('.s', '')
        obj = os.path.join(objdir, f'{name}_b{banked}c{c02}.o')
        text += _run(['ca65', '-g', '-D', f'C02={c02}', '-D', f'BANKED={banked}']
                     + dflags + ['-l', os.path.join(objdir, f'{name}_b{banked}c{c02}.lst'),
                      os.path.join(_ROOT, src), '-o', obj])
        objs.append(obj)
    text += _run(['ld65', '-C', os.path.join(_ROOT, _CFGS[banked])] + objs +
                 ['-m', os.path.join(objdir, f'engine_b{banked}c{c02}.map'),
                  '--dbgfile', os.path.join(objdir, f'engine_b{banked}c{c02}.dbg')])
    _built.add(key)
    _on_disk[banked] = c02
    with open(_marker, 'w') as _mf:
        _mf.write(f'{banked},{c02},{defs},{_stamp}')
    return text


def build_all(banked=0, c02=None, force=False):
    build('engine', banked=banked, c02=c02, force=force)


def gen_engine_syms():
    """Emit engine_syms.inc for the boot stubs: real engine entry
    addresses resolved by SYMBOL from the banked ld65 map. Jump tables
    are forbidden — the linker resolves cross-module dependencies; this
    file regenerates on every driver assembly so it can never go stale."""
    import symmap
    entries = [('ENG_VIEW_SETUP',   'view_setup',  'PAGE BANK_L0 first'),
               ('ENG_RENDER_FRAME', 'render_frame','PAGE BANK_L0 first'),
               ('ENG_SPAN_INIT',    'span_init',      'PAGE BANK_C first'),
               ('ENG_ANIM_TICK',    'anim_tick',      'PAGE BANK_L2 first'),
               ('ENG_ANIM_FIELDS',  'ANIM_FIELDS',    'store the frame FIELD count before the tick (0 ticks as 1)'),
               ('ENG_ANIM_INIT',    'anim_init',      'PAGE BANK_L2 first'),
               ('ENG_TAIL_POSTRC',  'bca_tail_postrc','zp_tail_vec moving seed'),
               ('ENG_BOX_CLASSIFY', 'box_classify',   'zp_bv_entry moving seed'),
               ('ENG_PQ_PUMP_OP',   'pq_pump_op',     'run-ahead queue pump SMC site (poke +1/+2)'),
               ('ENG_PLOTQ_DRAIN',  'plotq_drain',    'drain the plot queue (bank C paged)'),
               ('ENG_PLOTQ_ARM',    'plotq_arm',      'queue ON: retarget dv_emit_op + set plotq_mode (BANK C MUST BE PAGED — dv_emit_op lives there)'),
               ('ENG_PLOTQ_OFF',    'plotq_off',      'queue OFF: same, back to direct (bank C paged)'),
               ('ENG_SQR_FILL',     'sqr_fill_cold',  'regenerate the quarter-square quad at $0200 + pm displacement-cache cold-init (bank-independent)'),
               ('ENG_OBJ_FILL',     'obj_anyb_fill',  'copy OBJ_BITS into its main-RAM home (pages SEG, leaves WALK)'),
               ('ENG_FB_CLR0',      'fb_clr0',        'clear framebuffer 0 (PAGE BANK_C first)'),
               ('ENG_FB_CLR1',      'fb_clr1',        'clear framebuffer 1 (PAGE BANK_C first)'),
               ('ENG_FB_CLR_BACK',  'fb_clr_back',    'clear the hidden buffer per DV_BACKHI (PAGE BANK_C first)'),
               ('ENG_PMOVE_TRY',    'pmove_try',      'P_TryMove: cand in $90-$93, pages WALK'),
               ('ENG_PMOVE_USE',    'pmove_use',      'SPACE use-trace (pm_ux staged)'),
               ('ENG_PM_OLDX',      'pm_oldx',        'committed raw pos (oldy = +2)'),
               ('ENG_PM_VZ',        'pm_vz',          'current vz in/out (prescaled s8)'),
               ('ENG_BR_PXF',       'zp_br_px',       'player x FRACTION byte (WORK segment; boot must seed)'),
               ('ENG_BR_PYF',       'zp_br_py',       'player y fraction byte'),
               ('ENG_BR_PX2H',      'zp_br_px2_h',    'tie-broken doubled raw x HI (lo stays zp)'),
               ('ENG_BR_PY2L',      'zp_br_py2_l',    'doubled raw y LO'),
               ('ENG_BR_PY2H',      'zp_br_py2_h',    'doubled raw y HI'),
               ('ENG_PM_UX',        'pm_ux',          'use-trace delta (uy = +2)'),
               ('ENG_PMOVE_ZONLY',  'pmove_zonly',    'z-only revalidate (no box scan)'),
               ('ENG_PM_FRAME',     'pm_frame',       '35Hz momentum frame: A=fields, X=input bits'),
               ('ENG_BCA_AB',       'bca_ab',         'per-frame view angle byte (zp; was the baked abi BCA_AB)')]
    path = os.path.join(_ROOT, 'engine_syms.inc')
    with open(path, 'w') as f:
        f.write('; GENERATED by asmbuild.gen_engine_syms() from the banked ld65 map'
                ' - DO NOT EDIT.\n'
                '; Real engine entry addresses (no jump table; linker-resolved).\n')
        for name, sym, note in entries:
            f.write(f'{name} = ${symmap.sym(sym, banked=1):04X}'.ljust(40)
                    + f'; {sym} ({note})\n')
    return path
