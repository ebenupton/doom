"""Profile bsp_render by routine."""
import os, re, ast
os.environ['SDL_VIDEODRIVER'] = 'dummy'
os.environ['PYGAME_HIDE_SUPPORT_PROMPT'] = '1'
import pygame; pygame.init(); pygame.display.set_mode((1, 1))
from test_bsp_render_frame import setup_wad, setup_view, init_pool, clear_screen
from span_clip_6502 import SpanClip6502

# Parse symbols from beebasm dump
with open('/tmp/symdump.txt') as f:
    raw = f.read()
# Convert to Python dict (replace L suffix on long ints)
raw = re.sub(r'(\d+)L', r'\1', raw)
syms = ast.literal_eval(raw)[0]

# Build address → routine map. Top-level routines are dotted entries
# without a sub-label.
# Define routines of interest as ranges from each top-level label to the next.
top_labels = sorted([(addr, name) for name, addr in syms.items()
                     if name.count('.') == 1])  # e.g. .br_to_view (no sub)
top_labels.sort()

# Build (lo, hi, name) ranges
ranges = []
for i, (addr, name) in enumerate(top_labels):
    next_addr = top_labels[i+1][0] if i+1 < len(top_labels) else 0xFFFF
    ranges.append((addr, next_addr - 1, name.lstrip('.')))

# Define ROUTINE_GROUPS: collapse related sub-routines into a single bucket.
GROUPS = {
    'BSP walk':          ['br_render_frame'],
    'side test':         [],
    'back-face test':    ['br_back_face_test'],
    'bbox check':        ['br_bbox_visible', 'bv_proj_one'],
    'br_to_view':        ['br_to_view'],
    'br_rot_int':        ['br_rot_int'],
    'br_recip':          ['br_recip'],
    'br_project_x':      ['br_project_x_subpx', 'br_project_x'],
    'br_project_y':      ['br_project_y'],
    'br_smul_*':         ['br_smul_s8_u8', 'br_smul_s8_s16', 'br_smul_s16_s16_s32', 'br_smul8'],
    'br_view_setup':     ['br_view_setup'],
    'br_frac_rot_term':  ['br_frac_rot_term'],
    'br_seg_xform_vertex': ['br_seg_xform_vertex'],
    'br_render_subsector': ['br_render_subsector'],
    'br_umul8 (wrap)':   ['br_umul8'],
}

addr_to_group = {}
for grp, names in GROUPS.items():
    for n in names:
        for lo, hi, rname in ranges:
            if rname == n:
                for a in range(lo, hi + 1):
                    addr_to_group[a] = grp

# External buckets
EXTERNAL = {
    'span_clip ($2000-$47FF)': (0x2000, 0x47FF),
    'rasteriser ($A900-$B5FF)': (0xA900, 0xB5FF),
}

def profile(px, py, ab):
    sc = SpanClip6502()
    setup_wad(sc); setup_view(sc, px, py, ab); init_pool(sc); clear_screen(sc)
    mpu = sc.mpu; mem = mpu.memory
    mpu.pc = 0x4815; mpu.sp = 0xFD; mpu.p = 0x30
    mem[0x01FF] = 0xFE; mem[0x01FE] = 0xFF
    mpu.processorCycles = 0

    buckets = {}
    for grp in list(GROUPS) + list(EXTERNAL):
        buckets[grp] = 0
    buckets['unaccounted'] = 0
    prev = 0
    while mpu.pc != 0xFF00:
        pc = mpu.pc
        mpu.step()
        delta = mpu.processorCycles - prev
        prev = mpu.processorCycles
        # Try ext first
        ext = None
        for grp, (lo, hi) in EXTERNAL.items():
            if lo <= pc <= hi:
                ext = grp; break
        if ext:
            buckets[ext] += delta
        elif pc in addr_to_group:
            buckets[addr_to_group[pc]] += delta
        else:
            buckets['unaccounted'] += delta
    total = mpu.processorCycles
    return total, buckets

total, buckets = profile(1056, -3616, 64)
print(f"\n== Profile at canonical (1056,-3616,64) ==")
print(f"Total: {total} cycles\n")
for grp in sorted(buckets, key=lambda g: -buckets[g]):
    cyc = buckets[grp]
    if cyc > 0:
        pct = 100.0 * cyc / total
        print(f"  {cyc:>8} cyc  ({pct:5.1f}%)  {grp}")
