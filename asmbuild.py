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

# module -> (source, {banked: (cfg, ld65 -o or None)}).
# Where the cfg names explicit per-region files (bsp_render), -o is unused.
_TARGETS = {
    'slope_div': ('src/slope_div.s', {
        0: ('src/ang_flat.cfg', 'bsp_render_ang.bin'),
        1: ('src/ang_banked.cfg', 'bsp_render_ang_bk.bin'),
    }),
    'span_clip': ('src/span_clip.s', {
        0: ('src/clip_flat.cfg', 'span_clip.bin'),
        1: ('src/clip_banked.cfg', 'span_clip_bankc.bin'),
    }),
    'bsp_render': ('src/bsp_render.s', {
        0: ('src/bsp_flat.cfg', None),
        1: ('src/bsp_banked.cfg', None),
    }),
}


def env_c02():
    return 1 if os.environ.get('DOOM_CPU', '').lower() in ('65c02', 'c02', '1') else 0


def _run(argv):
    r = subprocess.run(argv, capture_output=True, text=True, cwd=_ROOT)
    if r.returncode != 0:
        raise RuntimeError(f'{argv[0]} failed:\n{r.stdout}{r.stderr}')
    return r.stdout + r.stderr


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
    key = (mod, banked, c02)
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
    src, cfgs = _TARGETS[mod]
    cfg, ofile = cfgs[banked]
    objdir = os.path.join(_ROOT, 'build')
    os.makedirs(objdir, exist_ok=True)
    obj = os.path.join(objdir, f'{mod}_b{banked}c{c02}.o')
    text = _run(['ca65', '-g', '-D', f'C02={c02}', '-D', f'BANKED={banked}',
                 os.path.join(_ROOT, src), '-o', obj])
    ld = ['ld65', '-C', os.path.join(_ROOT, cfg), obj,
          '-m', os.path.join(objdir, f'{mod}_b{banked}c{c02}.map'),
          '--dbgfile', os.path.join(objdir, f'{mod}_b{banked}c{c02}.dbg')]
    if ofile:
        ld += ['-o', os.path.join(_ROOT, ofile)]
    text += _run(ld)
    _built.add(key)
    return text


def build_all(banked=0, c02=None, force=False):
    for mod in _TARGETS:
        build(mod, banked=banked, c02=c02, force=force)
