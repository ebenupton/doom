"""Shared beebasm build helper — the ONE way tests/harnesses rebuild .asm.

Fail-loud (raises on assembler error instead of silently loading a stale
.bin) and session-memoized (repeated harness constructions don't re-run
beebasm for the same target).

C02 selection: pass c02 explicitly, or leave None to respect the DOOM_CPU
env var exactly like run_regression.py does — this fixes the old bug where
individual tests hardcoded C02=0 and silently overwrote the C02=1 build
mid-regression.
"""
import os
import subprocess

_ROOT = os.path.dirname(os.path.abspath(__file__)) or '.'
_built = set()


def env_c02():
    return 1 if os.environ.get('DOOM_CPU', '').lower() in ('65c02', 'c02', '1') else 0


def build(asm, banked=0, c02=None, out=None, force=False):
    """Assemble `asm` with beebasm. Raises RuntimeError on any assembler error.

    Returns the beebasm stdout+stderr text (callers that scrape the listing
    can pass force=True to bypass the memo and get fresh output).
    """
    if c02 is None:
        c02 = env_c02()
    key = (asm, banked, c02, out)
    if key in _built and not force:
        return ''
    argv = [os.path.join(_ROOT, 'beebasm'), '-i', os.path.join(_ROOT, asm),
            '-D', f'BANKED={banked}', '-D', f'C02={c02}']
    if out:
        argv += ['-o', os.path.join(_ROOT, out)]
    r = subprocess.run(argv, capture_output=True, text=True, cwd=_ROOT)
    text = r.stdout + r.stderr
    if r.returncode != 0 or 'error' in text.lower() or 'Assert' in text:
        raise RuntimeError(f'beebasm failed for {asm} (BANKED={banked}, C02={c02}):\n{text}')
    _built.add(key)
    return text
