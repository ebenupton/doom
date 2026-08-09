#!/usr/bin/env python3
"""Engine call-graph generator — SOURCE-PARSE style (the useful one,
2026-07-12 lineage; this replaced a linked-image disassembly variant
that drowned the structure in raw addresses, 2026-07-22).
2026-07-25: vertex-span descriptors era — emit_vert_sx*/ap_edge_one
died with the NOVT web; vs_fresh1/2 (the emit-serve descriptor entries)
and the dcl vertical fastpath join the curated set.

Parses every JSR/JMP in src/{bsp,ang,clip}/*.s + hud.s, resolves
symbol aliases (SC_* equates), clusters routines by defining source
file, and emits graphviz -> build/callgraph.{dot,pdf}.

Reading: solid = JSR (aliases resolved) - bold dashed = tail JMP -
red dashed = vector/SMC dispatch (zp_bv_entry / zp_tail_vec frame-
class vectors, rns_go, rot_select) - bold border = hot path.

HAND-CURATED sections (update when the architecture moves):
  extra   — roots + interfaces reached only via vectors/fall-through
  vec     — the vector/SMC dispatch fan-outs
  MACRO_OWNERS — macro-generated labels with no textual definition
  HOT     — the hot-path emphasis set
"""
import re, glob, os, subprocess
os.chdir(os.path.join(os.path.dirname(os.path.abspath(__file__)), '..'))

files = sorted(glob.glob('src/bsp/*.s') + glob.glob('src/ang/*.s')
               + glob.glob('src/clip/*.s') + ['src/hud.s'])
label_re = re.compile(r'^(?:::)?([A-Za-z_][A-Za-z0-9_]*):(.*)$')
call_re  = re.compile(r'\b(JSR|JMP)\s+([A-Za-z_][A-Za-z0-9_]*)\b')
equ_re   = re.compile(r'^\s*(?:::)?([A-Za-z_][A-Za-z0-9_]*)\s*=\s*([A-Za-z_][A-Za-z0-9_]*)\s*(;.*)?$')

MACRO_OWNERS = {                      # CPM_ENTRY expansions (ang/bca.s)
    'corner_phi_nn': 'src/ang/bca.s', 'corner_phi_pn': 'src/ang/bca.s',
    'corner_phi_np': 'src/ang/bca.s', 'corner_phi_pp': 'src/ang/bca.s',
}

# Calls INSIDE a .macro definition have no enclosing routine label, so
# the edge scan used to drop them silently (vxq_shl2 vanished from the
# graph when the fetch arms were absorbed into SXV_BODY — Eben's catch,
# 2026-08-09). Attribute each known macro's body to the routine its
# expansion lives in. Macros absent here still scan as before (their
# calls attribute to the last label — fine for in-routine macros like
# cross_compute was).
MACRO_CALLERS = {
    'SXV_BODY':  'sx_vert_lo',        # expanded as sx_vert_lo/hi
    'vxc_frame': 'br_view_setup',     # single expansion (view setup)
    'apv_stage': 'bf_seg_front',      # emit-cascade expansions
    'ap_edges':  'bf_seg_front',
}

owner, jsr_targets, alias = dict(MACRO_OWNERS), set(), {}
for f in files:
    for ln in open(f):
        code = ln.split(';')[0].rstrip()
        m = label_re.match(code)
        if m:
            owner.setdefault(m.group(1), f)
            code = m.group(2)
        me = equ_re.match(ln.split(';')[0].rstrip())
        if me and not me.group(2)[0].isdigit():
            alias[me.group(1)] = me.group(2)
        for kind, tgt in call_re.findall(code):
            if kind == 'JSR':
                jsr_targets.add(tgt)

def resolve(n, d=0):
    if d > 5 or n in owner and n not in alias:
        return n
    if n in alias and (alias[n] in owner or alias[n] in alias):
        return resolve(alias[n], d + 1)
    return n

extra = {'br_back_face_test','bf_seg_front','s_advance','s_advance_l0','vc_miss',
 'vxc_arm_lo','vxc_arm_hi','br_to_view','bbox_check_angle','box_classify',
 'dbox_check','bt_store','bca_tail_postrc','br_render_subsector',
 'br_project_x','br_project_y','rns_go','slope_div_le','cp_havepsi',
 'br_render_frame','br_view_setup','br_init_frame','anim_tick','anim_init',
 'span_init','span_has_gap','span_mark_solid','ev_clamp_hi_nz',
 'tighten_from_records','draw_clipped_line','draw_clipped_line_s16',
 'draw_clipped_line_s16_h','anim_hub','br_bbox_visible','br_bbox_visible_l2',
 'umul8','udiv16_8','interp_store','vf_plain0','vf_plain1','bca_frame','rc_wipe',
 'bcls_s0','bcls_s1','vs_fresh1','vs_fresh2','vsx_do_c3',
 'dcl_vert','dcl_vert_on','dcl_vertical',
 'reproject_at_crossing','br_recip','hud_draw',
 'corner_phi_nn','corner_phi_pn','corner_phi_np','corner_phi_pp',
 'rot_core_sin','rot_core_cos','rot_gen_pair','dpy_back_v1',
 'do_project_y_v1','do_project_y_v2'}
routines = ({resolve(t) for t in jsr_targets} | extra) & set(owner)

edges = set()
macro_re = re.compile(r'^\s*\.macro\s+([A-Za-z_][A-Za-z0-9_]*)', re.I)
endm_re = re.compile(r'^\s*\.endmacro', re.I)
for f in files:
    cur = None
    macro_cur = None
    for ln in open(f):
        code = ln.split(';')[0].rstrip()
        mm = macro_re.match(code)
        if mm:
            macro_cur = MACRO_CALLERS.get(mm.group(1))
            if macro_cur is not None:
                cur = macro_cur
            continue
        if endm_re.match(code):
            if macro_cur is not None:
                cur = None
            macro_cur = None
            continue
        m = label_re.match(code)
        if m:
            if m.group(1) in routines:
                cur = m.group(1)
            code = m.group(2)
        if not cur:
            continue
        for kind, tgt0 in call_re.findall(code):
            tgt = resolve(tgt0)
            if tgt in routines and tgt != cur:
                edges.add((cur, tgt, kind))

vec = [('zp_bv_entry (vector)','bbox_check_angle'),
       ('zp_bv_entry (vector)','box_classify'),
       ('zp_bv_entry (vector)','dbox_check'),
       ('zp_tail_vec (vector)','bt_store'),
       ('zp_tail_vec (vector)','bca_tail_postrc'),
       ('rns_go (SMC)','interp_store'),
       ('rot_select (SMC)','rot_core_sin'),('rot_select (SMC)','rot_core_cos'),
       ('rot_select (SMC)','rot_gen_pair')]
edges.add(('br_bbox_visible','zp_bv_entry (vector)','JMP'))
for cp in ('corner_phi_nn','corner_phi_pn','corner_phi_np','corner_phi_pp'):
    edges.add((cp,'zp_tail_vec (vector)','JMP'))
edges = {(a,b,k) for a,b,k in edges if (a,b) not in [(x,y) for x,y in vec]}
edges = {(a,b,k) for a,b,k in edges if not b.startswith('rns_s')}

MOD = lambda f: ('bsp' if '/bsp/' in f else 'ang' if '/ang/' in f
                 else 'clip' if '/clip/' in f else 'hud')
COLORS = {'bsp':'#dbe9ff','ang':'#ffe9d6','clip':'#e2f5df','hud':'#f2e2f5'}
HOT = {'br_render_subsector','sx_vert_lo','sx_vert_hi','br_back_face_test',
 'br_to_view','br_project_y','br_project_x','vxc_arm','umul8','interp_store',
 'rns_go','br_render_frame','span_has_gap','draw_clipped_line_s16',
 'draw_clipped_line_s16_h','bf_seg_front','bbox_check_angle','box_classify',
 'dbox_check','bcls_s0','bcls_s1',
 'corner_phi_nn','corner_phi_pn','corner_phi_np','corner_phi_pp'}

nodes = set()
for a,b,k in edges: nodes.update((a,b))
for a,b in vec: nodes.update((a,b))
import datetime
today = datetime.date.today().isoformat()
out = ['digraph engine {',
 '  rankdir=LR; fontname="Helvetica"; concentrate=true; ranksep=1.1;',
 '  node [shape=box, style="rounded,filled", fontname="Helvetica", fontsize=9];',
 '  edge [color="#666666", arrowsize=0.6];',
 f'  label="6502 DOOM engine call graph - {today}\\nsolid = JSR (aliases resolved) - bold dashed = tail JMP - red dashed = vector/SMC dispatch - bold border = hot path";',
 '  labelloc=top; fontsize=12;']
# --- L-R FLOW RULE (Eben 2026-07-25; PURE since 2026-08-09): the
# SOURCE now enforces it — the file-level call graph is a DAG (the
# subsector<->backface cycle died with the bsp/seg_emit.s split; the
# dcl<->dcl_s16 cycle died when s16_interp moved to clip/arith.s), and
# the drawn routine graph is acyclic too (checked at generation below).
# So clusters are back to ONE PER FILE (BAND high = no banding) and
# every edge flows left to right structurally, not by banding luck.
# If a future change reintroduces a cycle, this script FAILS — restore
# acyclicity in the source rather than re-enabling the bands.
# Depth = longest path from the roots over the call edges (vector edges
# included so dispatch targets rank right of their dispatchers).
_adj = {}
for a, b, k in edges:
    _adj.setdefault(a, set()).add(b)
for a, b in vec:
    _adj.setdefault(a, set()).add(b)
# LONGEST-path depth (BFS-shortest measured useless: everything lands
# 4 levels deep off br_render_frame). Iterative relaxation, capped to
# survive the few call cycles; the cap never binds on the real graph.
_depth = {n: 0 for n in nodes}
for _pass in range(24):
    changed = False
    for a in _adj:
        for b in _adj[a]:
            want = min(_depth.get(a, 0) + 1, 23)
            if _depth.get(b, 0) < want:
                _depth[b] = want
                changed = True
    if not changed:
        break
BAND = 99                             # no banding: the file graph is a
                                      # DAG (2026-08-09 source reorg) —
                                      # one cluster per file is pure L-R
# acyclicity gate: the invariant is the FILE-level DAG (a file cycle is
# what forces a backward edge between cluster boxes). Lift the routine
# edges to (owner file -> owner file) and DFS for a cycle; fail loudly
# and point at the offending routine pairs.
_fadj = {}
for _a, _bs in _adj.items():
    _fa = owner.get(_a)
    for _b in _bs:
        _fb = owner.get(_b)
        if _fa and _fb and _fa != _fb:
            _fadj.setdefault(_fa, {}).setdefault(_fb, []).append((_a, _b))
_done = set()
def _cyc(v, path):
    path.append(v)
    for w in _fadj.get(v, ()):
        if w in path:
            loop = path[path.index(w):] + [w]
            why = '; '.join(f'{a}->{b}' for x, y in zip(loop, loop[1:])
                            for a, b in _fadj[x][y][:2])
            raise SystemExit(f'FILE CYCLE reintroduced: {" -> ".join(loop)}\n'
                             f'  via: {why}\n'
                             'Move the offending routine (see the 2026-08-09 splits) — '
                             'do not re-enable banding.')
        if w not in _done:
            _cyc(w, path)
    path.pop(); _done.add(v)
for _f in sorted(_fadj):
    if _f not in _done:
        _cyc(_f, [])
bykey = {}
for n in sorted(nodes):
    f = owner.get(n)
    key = None if f is None else (f, _depth[n] // BAND)
    bykey.setdefault(key, []).append(n)
import sys as _sys
_bands = {}
for k2 in bykey:
    if k2: _bands.setdefault(k2[0], set()).add(k2[1])
print('split files:', {f.replace('src/',''): sorted(b) for f, b in _bands.items() if len(b) > 1}, file=_sys.stderr)
print('depth reach:', len(_depth), 'of', len(nodes), file=_sys.stderr)
_percount = {}
ci = 0
for key, ns in sorted(bykey.items(), key=lambda kv: (str(kv[0]),)):
    if key is None:
        for n in ns:
            out.append(f'  "{n}" [fillcolor="#ffd6d6", shape=diamond];')
        continue
    f, band = key
    ci += 1
    _percount[f] = _percount.get(f, 0) + 1
    nbands = sum(1 for k2 in bykey if k2 and k2[0] == f)
    lbl = f.replace("src/", "")
    if nbands > 1:
        lbl += f' ({_percount[f]})'
    out.append(f'  subgraph cluster_{ci} {{ label="{lbl}"; '
               'style=filled; fillcolor="#f7f7f7"; color="#cccccc";')
    for n in ns:
        pen = ',penwidth=2.2' if n in HOT else ''
        out.append(f'    "{n}" [fillcolor="{COLORS[MOD(f)]}"{pen}];')
    out.append('  }')
for a,b,k in sorted(edges):
    st = '' if k=='JSR' else ' [style=dashed,penwidth=1.5,color="#333333"]'
    out.append(f'  "{a}" -> "{b}"{st};')
for a,b in vec:
    out.append(f'  "{a}" -> "{b}" [style=dashed,color="#cc2222"];')
out.append('}')
os.makedirs('build', exist_ok=True)
open('build/callgraph.dot','w').write('\n'.join(out))
print('nodes:', len(nodes), 'edges:', len(edges)+len(vec))
subprocess.run(['dot','-Tpdf','build/callgraph.dot','-o','build/callgraph.pdf'],
               check=True)
print('build/callgraph.pdf')
