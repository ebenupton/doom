"""Engine symbol map — the harness's window into the linked engine.

Replaces hand-mirrored magic addresses (entry points, ZP slots, buffer
bases) across the Python harness files. Symbols come from the ld65
--dbgfile output that asmbuild writes next to each object; both labels
and equates (ZP assignments, workspace addresses) are included.

Usage:
    import symmap
    ENTRY_MARK_SOLID = symmap.sym('jt_mark_solid')  # linked address
    ZP_ILO        = symmap.sym('zp_i_l')           # ZP equate

Symbols are per build variant (BANKED/C02 change addresses); the variant
follows DOOM_CPU like the rest of the harness. Names must be unique
within their module; ambiguous (scope-repeated) names are excluded at
generation time and raise here.
"""
import json
import os

import asmbuild

_cache = {}


def _load(banked=0, c02=None):
    if c02 is None:
        c02 = asmbuild.env_c02()
    key = (banked, int(c02))
    if key in _cache:
        return _cache[key]
    table = {}
    ambiguous = set()
    asmbuild.build('engine', banked=banked, c02=c02)
    dbg = os.path.join(asmbuild._ROOT, 'build', f'engine_b{banked}c{int(c02)}.dbg')
    for name, val in _parse_dbg(dbg):
        if name in table and table[name] != val:
            ambiguous.add(name)
        else:
            table[name] = val
    for name in ambiguous:
        del table[name]
    _cache[key] = (table, ambiguous)
    return _cache[key]


def _parse_dbg(path):
    """Yield (name, value) for every label and equate, skipping names that
    repeat with different values inside the module (scope-local labels)."""
    seen = {}
    dup = set()
    with open(path) as f:
        for line in f:
            if not line.startswith('sym'):
                continue
            fields = dict(kv.split('=', 1) for kv in line.split('\t')[1].strip().split(','))
            name = fields['name'].strip('"')
            if 'val' not in fields:
                continue
            val = int(fields['val'], 16)
            if name in seen and seen[name] != val:
                dup.add(name)
            seen[name] = val
    return [(n, v) for n, v in seen.items() if n not in dup]


def sym(name, banked=0, c02=None):
    table, ambiguous = _load(banked, c02)
    if name in table:
        return table[name]
    if name in ambiguous:
        raise KeyError(f'symbol {name!r} is ambiguous across modules/scopes')
    raise KeyError(f'symbol {name!r} not found in engine map')


def dump(banked=0, c02=None):
    """Write build/symbols.json for humans/tools; returns the path."""
    table, _ = _load(banked, c02)
    path = os.path.join(asmbuild._ROOT, 'build', 'symbols.json')
    with open(path, 'w') as f:
        json.dump({k: f'${v:04X}' for k, v in sorted(table.items())}, f, indent=1)
    return path
