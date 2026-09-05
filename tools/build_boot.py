#!/usr/bin/env python3
"""Assemble the boot stubs and tube glue with ca65/ld65.

These were beebasm sources until 2026-09-05.  Every output here was proved
byte-identical to the beebasm one before beebasm was removed; the configs
in src/boot/cfg carry the ORG (and, for the parasite driver, the SKIPTO
pad fill and the two SAVE blocks) that beebasm's directives used to.
"""
import os, subprocess, sys

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BOOT = os.path.join(ROOT, 'src', 'boot')
CFG = os.path.join(BOOT, 'cfg')


def build(name, defs=(), out=None, labels=None):
    """Assemble src/boot/<name>.s with src/boot/cfg/<name>.cfg.  Returns the
    output path prefix; multi-file configs append their own suffixes.
    `labels`, if given, is a path for ld65's VICE label dump (-Ln)."""
    import asmbuild
    asmbuild.gen_engine_syms()
    obj = os.path.join(ROOT, 'build', f'{name}.o')
    os.makedirs(os.path.join(ROOT, 'build'), exist_ok=True)
    out = out or os.path.join(ROOT, 'build', name.upper())
    cmd = ['ca65', '-I', BOOT]
    for d in defs:
        cmd += ['-D', d]
    cmd += [os.path.join(BOOT, f'{name}.s'), '-o', obj]
    subprocess.run(cmd, cwd=ROOT, check=True)
    link = ['ld65', '-C', os.path.join(CFG, f'{name}.cfg'), obj, '-o', out]
    if labels:
        link += ['-Ln', labels]
    subprocess.run(link, cwd=ROOT, check=True)
    return out


def symbols(path):
    """Parse an ld65 VICE label dump into {name: addr}."""
    out = {}
    for line in open(path):
        f = line.split()
        if len(f) >= 3 and f[0] == 'al':
            out[f[2].lstrip('.')] = int(f[1], 16)
    return out


def read(name, defs=(), suffix=''):
    p = build(name, defs)
    with open(p + suffix, 'rb') as f:
        return f.read()


def hostt(labels=None):
    """The tube HOST program (was `beebasm -i tube/hostg.asm` -> HOSTT)."""
    p = build('hostg', ('BANKED=1',), labels=labels)
    return open(p, 'rb').read()


def tubedrv():
    """(COPROT, COPRES) for the parasite: the transient $7800 boot stub and
    the resident $F600 glue + emitters (was tubedrv.asm's two SAVEs; the
    SKIPTO pad between res and emit is the config's fill now)."""
    p = build('tubedrv', ('BANKED=0',))
    return (open(p + '.boot', 'rb').read(),
            open(p + '.res', 'rb').read() + open(p + '.emit', 'rb').read())


if __name__ == '__main__':
    for n, d in (('detect', ()), ('hostg', ('BANKED=1',)), ('tubedrv', ('BANKED=0',)),
                 ('banked_boot', ('BANKED=1',)), ('modelb_boot', ('BANKED=1',))):
        p = build(n, d)
        print(f'  {n:14s} -> {p}')
