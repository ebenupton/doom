"""Shared engine build helper — the ONE way tests/harnesses rebuild the 6502
engine. ca65 + ld65 (real objects, real linker); fail-loud (raises on any
assembler/linker error instead of silently loading a stale .bin) and
session-memoized (repeated harness constructions don't re-run the toolchain).

Sources live in src/*.s with one ld65 config per (module, layout). Output
binaries land in the repo root under their historical names, so the py65
harnesses and disc builders are unaffected.

Callers may pass the legacy beebasm source name ('bsp_render.asm') or the
module name ('bsp_render') — both resolve to the same target.

C02 selection: pass c02 explicitly, or leave None to respect the DOOM_CPU
env var. The old per-test hardcoded C02=0 rebuilds (which silently
overwrote C02=1 builds mid-regression) are gone.
"""
import os
import subprocess

_ROOT = os.path.dirname(os.path.abspath(__file__)) or '.'
_built = set()

# The engine is ONE link: three objects (angle module, span clipper, bsp
# renderer) resolved together, so cross-module calls are linker symbols.
# All legacy per-module names alias the single 'engine' target.
_SOURCES = ['src/slope_div.s', 'src/span_clip.s', 'src/bsp_render.s']
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


def build(asm, banked=0, c02=None, out=None, force=False):
    _build_raster()
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
    key = ('engine', banked, c02)
    if key in _built and not force:
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
    text = ''
    objs = []
    for src in _SOURCES:
        name = os.path.basename(src).replace('.s', '')
        obj = os.path.join(objdir, f'{name}_b{banked}c{c02}.o')
        text += _run(['ca65', '-g', '-D', f'C02={c02}', '-D', f'BANKED={banked}',
                      os.path.join(_ROOT, src), '-o', obj])
        objs.append(obj)
    text += _run(['ld65', '-C', os.path.join(_ROOT, _CFGS[banked])] + objs +
                 ['-m', os.path.join(objdir, f'engine_b{banked}c{c02}.map'),
                  '--dbgfile', os.path.join(objdir, f'engine_b{banked}c{c02}.dbg')])
    _built.add(key)
    return text


def _build_raster():
    """Regenerate the NJ rasteriser bin (read at load by span_clip_6502 and
    the banked images). beebasm is vendored; output is deterministic."""
    import subprocess
    src = os.path.join(_ROOT, 'linedraw_or_reloc.asm')
    out = os.path.join(_ROOT, 'linedraw_or_reloc.bin')
    if (not os.path.exists(out)
            or os.path.getmtime(out) < os.path.getmtime(src)):
        subprocess.run([os.path.join(_ROOT, 'beebasm'), '-i', src],
                       cwd=_ROOT, check=True, capture_output=True)


def build_all(banked=0, c02=None, force=False):
    _build_raster()
    build('engine', banked=banked, c02=c02, force=force)


def gen_engine_syms():
    """Emit engine_syms.inc for beebasm drivers: real engine entry
    addresses resolved by SYMBOL from the banked ld65 map. Jump tables
    are forbidden — the linker resolves cross-module dependencies; this
    file regenerates on every driver assembly so it can never go stale."""
    import symmap
    entries = [('ENG_VIEW_SETUP',   'br_view_setup',  'PAGE BANK_L0 first'),
               ('ENG_RENDER_FRAME', 'br_render_frame','PAGE BANK_L0 first'),
               ('ENG_SPAN_INIT',    'span_init',      'PAGE BANK_C first'),
               ('ENG_ANIM_TICK',    'anim_tick',      'PAGE BANK_L2 first'),
               ('ENG_ANIM_INIT',    'anim_init',      'PAGE BANK_L2 first'),
               ('ENG_TAIL_POSTRC',  'bca_tail_postrc','zp_tail_vec moving seed'),
               ('ENG_BOX_CLASSIFY', 'box_classify',   'zp_bv_entry moving seed')]
    path = os.path.join(_ROOT, 'engine_syms.inc')
    with open(path, 'w') as f:
        f.write('\\ GENERATED by asmbuild.gen_engine_syms() from the banked ld65 map'
                ' - DO NOT EDIT.\n'
                '\\ Real engine entry addresses (no jump table; linker-resolved).\n')
        for name, sym, note in entries:
            f.write(f'{name} = &{symmap.sym(sym, banked=1):04X}'.ljust(40)
                    + f'\\ {sym} ({note})\n')
    return path
