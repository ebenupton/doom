#!/usr/bin/env python3
"""Engine call-graph generator: disassembles the LINKED flat image
(so macro expansions and fused JMP interfaces are captured), maps
JSR/JMP sites to owning routines via the ld65 symbol table, clusters
by defining source file, and emits graphviz -> PDF.

Solid edges = JSR. Dashed = JMP tail-call/fused interface (only when
the target is a known routine head). SMC-dispatched sites (rot_s13,
rns_go, bca_check_op) show their static default operand, dotted.
"""
import os, re, sys, subprocess, glob, bisect
os.chdir(os.path.join(os.path.dirname(os.path.abspath(__file__)), '..'))
sys.path.insert(0, '.')
os.environ.setdefault('SDL_VIDEODRIVER', 'dummy')
os.environ.setdefault('PYGAME_HIDE_SUPPORT_PROMPT', '1')
import pygame; pygame.init(); pygame.display.set_mode((1, 1))
import doom_wireframe as dw
from bsp_render_6502 import BspRender6502

r = BspRender6502(dw.packed_layout, dw.packed_rom_main, dw.packed_rom_detail,
                  dw.packed_bbox_table, dw.MAP_CENTER_X, dw.MAP_CENTER_Y, dw.PRESCALE)
mem = r.sc.mpu.memory

# --- symbols ---
syms = {}
for line in open('build/engine_b0c0.dbg'):
    if line.startswith('sym') and 'type=lab' in line:      # LABELS only —
        m = re.search(r'name="([^"]+)".*?val=0x([0-9A-Fa-f]+)', line)
        if m and not m.group(1).startswith(('LOCAL', '.')):  # equates (DRV_ORG
            syms.setdefault(m.group(1), int(m.group(2), 16)) # etc) poison ownership
addr2names = {}
for n, v in syms.items():
    addr2names.setdefault(v, []).append(n)

# --- defining file per label (for clustering) ---
label_file = {}
for f in glob.glob('src/**/*.s', recursive=True):
    short = os.path.basename(f).replace('.s', '')
    src = open(f).read()
    for m in re.finditer(r'^(?:::)?([A-Za-z_][A-Za-z0-9_]*):', src, re.M):
        label_file.setdefault(m.group(1), short)
# macro-generated labels (CPM_ENTRY instances, thunk sites) have no
# textual definition — hand-map them to their generating file
for n in ('corner_phi_nn','corner_phi_pn','corner_phi_np','corner_phi_pp'):
    label_file[n] = 'bca'
for n in ('rpt_jsr','rpt_jmp','d_nz'):
    label_file[n] = 'arith'
label_file.setdefault('dpy_back_v1', 'seg_project')
label_file.setdefault('do_project_y_v1', 'seg_project')
label_file.setdefault('do_project_y_v2', 'seg_project')
label_file.setdefault('br_project_x', 'project')

# --- code regions from the cfg (flat) ---
cfg = open('src/engine_flat.cfg').read()
regions = [(int(m.group(1), 16), int(m.group(1), 16) + int(m.group(2), 16))
           for m in re.finditer(r'start\s*=\s*\$([0-9A-Fa-f]+),\s*size\s*=\s*\$([0-9A-Fa-f]+)', cfg)]

# --- scan for JSR/JMP; collect raw edges by address ---
raw = []   # (site_addr, opcode, target_addr)
for lo, hi in regions:
    a = lo
    while a < hi - 2:
        op = mem[a]
        if op in (0x20, 0x4C):
            tgt = mem[a+1] | (mem[a+2] << 8)
            if any(l <= tgt < h for l, h in regions):
                raw.append((a, op, tgt))
        a += 1   # byte-wise scan: ok for edge harvesting (operand bytes
                 # that decode as 20/4C give targets outside regions or
                 # non-symbol addresses and are filtered below)

# routine heads = all JSR targets that ARE symbols, plus known interfaces
jsr_targets = {t for _, op, t in raw if op == 0x20 and t in addr2names}
KNOWN = ['span_has_gap', 'bca_tail', 'cp_havepsi', 'full_vis', 'cull',
         'draw_clipped_line_s16', 'draw_clipped_line_s16_h', 'span_mark_solid',
         'tighten_from_records', 'br_render_frame', 'bbox_check_angle',
         'bbox_check_angle_cached', 'span_init', 'ns_khave', 'mask_done',
         'lf_ns', 'br_bbox_visible', 'vertex_fetch', 'rot_gen_pair',
         'rot_core_cos_nz', 'rns_go', 'udiv16_8', 'umul8', 'SC_UMUL8',
         'br_view_setup', 'br_to_view', 'br_to_view_fetch', 'br_recip',
         'br_project_x', 'br_project_y', 'do_project_y_v1', 'do_project_y_v2',
         'dpy_back_v1', 'br_seg_xform_vertex', 'br_dcache_frame', 'bca_frame',
         'br_back_face_test', 'reproject_at_crossing', 'anim_hub', 'anim_tick',
         'rot_pair_thunk', 'angx_head', 'ang_head']
heads = set(jsr_targets) | {syms[k] for k in KNOWN if k in syms}
head_list = sorted(heads)
def region_of(a):
    for i, (lo, hi) in enumerate(regions):
        if lo <= a < hi: return i
    return None
def owner(a):
    i = bisect.bisect_right(head_list, a) - 1
    if i < 0: return None
    h = head_list[i]
    return h if region_of(h) == region_of(a) else None    # no cross-region bleed
def best_name(addr):
    names = addr2names.get(addr, [])
    if not names: return None
    return sorted(names, key=len)[0]

SMC_SITES = {syms[k] for k in ('rot_s13', 'rot_s2', 'rot_s4', 'bca_check_op') if k in syms}
edges = {}
for a, op, tgt in raw:
    if tgt not in heads: continue
    src = owner(a)
    if src is None or src == tgt: continue
    sn, tn = best_name(src), best_name(tgt)
    if not sn or not tn: continue
    style = 'dashed' if op == 0x4C else 'solid'
    if any(abs(a - s) <= 2 for s in SMC_SITES): style = 'dotted'
    key = (sn, tn, style)
    edges[key] = edges.get(key, 0) + 1

# drop pure-solid duplicates of dotted/dashed pairs, keep strongest
CLUSTER_COLOR = {
    'bca': '#2f6f4f', 'rcache': '#2f6f4f', 'header_div': '#2f6f4f',
    'walk': '#31456e', 'bbox': '#31456e', 'view': '#31456e', 'arith': '#31456e',
    'project': '#31456e', 'seg_project': '#31456e', 'seg_xform': '#31456e',
    'subsector': '#31456e', 'backface': '#31456e', 'lo': '#31456e',
    'inline': '#31456e', 'vxcache': '#31456e', 'anim': '#7a5a2f',
    'resolve_crossing': '#31456e', 'defq': '#31456e',
    'dcl': '#6e3140', 'dcl_s16': '#6e3140', 'tfr': '#6e3140',
    'interp': '#6e3140', 'mark_solid': '#6e3140', 'pool': '#6e3140',
    'query': '#6e3140', 'plot_axis': '#6e3140', 'header': '#6e3140',
    'hud': '#7a5a2f',
}
GROUP = {'bca':'angle','rcache':'angle','header_div':'angle','slope_div':'angle',
         'dcl':'clipper','dcl_s16':'clipper','tfr':'clipper','interp':'clipper',
         'mark_solid':'clipper','pool':'clipper','query':'clipper','plot_axis':'clipper',
         'anim':'anim','hud':'anim'}
nodes = {}
for (sn, tn, _), _n in edges.items():
    for n in (sn, tn):
        f = label_file.get(n, '?')
        nodes[n] = GROUP.get(f, 'traversal' if f != '?' else 'other')

out = ['digraph engine {',
       '  rankdir=LR; fontname="Helvetica"; fontsize=10;',
       '  node [fontname="Helvetica", fontsize=9, shape=box, style="rounded,filled", fillcolor="#f5f2ea", color="#555555"];',
       '  edge [fontname="Helvetica", fontsize=7, color="#666666", arrowsize=0.6];',
       '  label="BBC DOOM engine call graph — linked flat image, ' +
       'solid=JSR dashed=JMP(fused/tail) dotted=SMC-dispatched (static default) — 2026-07-20"; labelloc=t;']
GCOLOR = {'angle': '#e4efe7', 'traversal': '#e6eaf3', 'clipper': '#f3e6ea', 'anim': '#f3eede', 'other': '#eeeeee'}
for g in sorted(set(nodes.values())):
    out.append(f'  subgraph cluster_{g} {{ label="{g}"; style=filled; color="#bbbbbb"; fillcolor="{GCOLOR[g]}";')
    for n, ng in sorted(nodes.items()):
        if ng == g:
            f = label_file.get(n, '')
            disp = 'corner arms' if n == 'angx_head' else n
            out.append(f'    "{n}" [label="{disp}\\n({f}.s)"];')
    out.append('  }')
for (sn, tn, style), cnt in sorted(edges.items()):
    pen = min(3.0, 0.6 + 0.25 * cnt)
    lbl = f' xlabel="{cnt}"' if cnt > 1 else ''
    out.append(f'  "{sn}" -> "{tn}" [style={style}, penwidth={pen:.2f}{lbl}];')
out.append('}')
open('build/callgraph.dot', 'w').write('\n'.join(out))
subprocess.run(['dot', '-Tpdf', 'build/callgraph.dot', '-o', 'build/callgraph.pdf'], check=True)
print(f'nodes: {len(nodes)}  edges: {len(edges)}  -> build/callgraph.pdf')
