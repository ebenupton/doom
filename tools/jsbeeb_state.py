#!/usr/bin/env python3
"""jsbeeb save-state post-mortem: python3 tools/jsbeeb_state.py <state.json.gz> [tree-root]

Decodes a jsbeeb snapshot (format 'jsbeeb-snapshot' v3: state.ram is 128K
base64 — 64K main + shadow; sideways RAM banks and the OS ROM are NOT in
it, $8000-$FFFF read $FF; media.disc1ImageData is the mounted .ssd, so
its crc32 identifies the build) and reports, against the tree's banked
build symbols: registers, the DV pose (world coordinates, heading,
fields, D_FWD, HUD), zp vectors, every byte of $0F00-$57FF that differs
from the built images (known SMC sites: rwp_*, rwc_*, px_go_op,
rns_go_op, oa_rd*, render_subsector+1 = the anim hook), and a stack
parse with symbols.

READ THIS FIRST (2026-09-03 finding): a BRK on the game's trashed OS
workspace enters OS 1.2's BRK handler, which issues service call 6 to
every ROM slot — writing $F4/$FE30 for slots 15..0 and JSRing $8003 in
EACH, i.e. into our RAM banks' data/code — before JMP (BRKV) (= the sqr
table at $0202 -> $8201).  That loop fills page 1 with the 9-byte frame
'B5 05 80 7D F1 0D 45 DC 0D' (P, $8005, $F17D, $DC45 returns), leaves
romsel=13/$F4=$0D, pc=$DC1C, and can trash zp on the way (the zeroed
zp_tail_vec hi byte).  The ORIGINAL fault address is gone; only the DV
pose, pm state and cache-class vector survive.  'halted' just means the
emulator was paused.
"""
import gzip, json, base64, os, sys, bisect
root = sys.argv[2] if len(sys.argv) > 2 else os.path.dirname(os.path.dirname(os.path.abspath(__file__))); os.chdir(root); sys.path.insert(0, root); os.environ['SDL_VIDEODRIVER']='dummy'
from symmap import _parse_dbg
import engine_load, asmbuild, abi
F = sys.argv[1]
d = json.load(gzip.open(F)); st = d['state']; ram = base64.b64decode(st['ram']['data'])[:0x10000]
t = dict(_parse_dbg('build/engine_b1c0.dbg'))
inv = sorted((v,k) for k,v in t.items() if 0x100 <= v < 0x10000 and not k.startswith('LOCAL'))
keys = [v for v,_ in inv]
def near(a):
    i = bisect.bisect_right(keys, a) - 1
    return f'{inv[i][1]}+{a-inv[i][0]}' if i >= 0 and a - inv[i][0] < 0x200 else '?'
# --- zp pointers: any 2-byte little-endian value that looks like a vector into weird places
zps = sorted((v,k) for k,v in t.items() if v < 0x100)
st_ = st
print(f"pc=${st_['pc']:04X} a={st_['a']} x={st_['x']} y={st_['y']} s=${st_['s']:02X} p=${st_['p']:02X} romsel={st_['romsel']} halted={st_.get('halted')} ts={d['timestamp']}")
import zlib; disc = base64.b64decode(d['media']['disc1ImageData']['data']); print('disc crc32', zlib.crc32(disc) & 0xFFFFFFFF, '(compare: git show <rev>:doom_walk.ssd)')
def s24(a): v = ram[a] | ram[a+1]<<8 | ram[a+2]<<16; return v - (1<<24) if v & 0x800000 else v
px, py = s24(abi.DV_PXF), s24(abi.DV_PYF)
pmvz = t.get('pm_vz'); vz = ram[pmvz] - (256 if ram[pmvz] >= 128 else 0) if pmvz else None
print(f'pose: world ({1200 + px/32:.1f}, {-3248 + py/32:.1f}) angidx={ram[abi.DV_ANGIDX]} ab={ram[abi.DV_ANGIDX]*4&0xFF} fields={ram[abi.DV_FIELDS]} D_FWD={ram[abi.D_FWD]} HUD={ram[abi.DV_HUD_EN]} pm_vz={vz}')
print('zp vectors of interest:')
for n in ['zp_bv_entry','zp_tail_vec','zp_node_ch_l','zp_bsp_stack_sp','zp_head','zp_hg_cache','zp_seg_v_bitm','zp_i_l','bca_ilo','bca_ihi']:
    if n in t: a = t[n]; print(f'  {n:16s} ${a:02X} = {ram[a]:02X} {ram[a+1]:02X}  ({near(ram[a]|ram[a+1]<<8)})')
# --- code integrity: load the build's images into a fresh 64K and diff main RAM code areas
fresh = bytearray(0x10000)
for start, fname in engine_load._regions(1):
    if start >= 0x8000: continue
    code = open(fname,'rb').read(); fresh[start:start+len(code)] = code
diffs = []
for a in range(0x0F00, 0x5800):
    if fresh[a] != ram[a]: diffs.append(a)
def ranges(xs):
    out = []; 
    for a in xs:
        if out and a == out[-1][1] + 1: out[-1][1] = a
        else: out.append([a, a])
    return out
rs = ranges(diffs)
print(f'code/table bytes differing from the build image in $0F00-$57FF: {len(diffs)} in {len(rs)} ranges')
for lo, hi in rs[:40]:
    print(f'  ${lo:04X}-${hi:04X} ({hi-lo+1:4d} B) {near(lo)}')
# --- stack parse: from SP+1 up, try (lo,hi) return addresses
sp = st['s']; print(f"stack from ${0x100+sp+1:04X} (SP=${sp:02X}):")
i = sp + 1
while i < 0x100:
    lo = ram[0x100+i]; hi = ram[0x100+i+1] if i+1 < 0x100 else 0
    a = lo | hi << 8
    tag = near(a + 1) if 0x0F00 <= a < 0xC000 else ''
    print(f'  ${0x100+i:04X}: {lo:02X} {hi:02X}  -> ${a:04X}  {tag}')
    i += 1
