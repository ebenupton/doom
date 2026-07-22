#!/usr/bin/env python3
"""Engine call-graph generator — SOURCE-PARSE style (the useful one,
2026-07-12 lineage; this replaced a linked-image disassembly variant
that drowned the structure in raw addresses, 2026-07-22).

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
 'vxc_arm','br_to_view_fetch','br_to_view','bbox_check_angle','box_classify',
 'dbox_check','bt_store','bca_tail_postrc','br_render_subsector',
 'br_project_x','br_project_y','rns_go','slope_div_le','cp_havepsi',
 'br_render_frame','br_view_setup','br_init_frame','anim_tick','anim_init',
 'span_init','span_has_gap','span_is_full','span_mark_solid','ev_clamp_hi_nz',
 'tighten_from_records','draw_clipped_line','draw_clipped_line_s16',
 'draw_clipped_line_s16_h','anim_hub','br_bbox_visible','br_bbox_visible_l2',
 'umul8','udiv16_8','interp_store','vertex_fetch','bca_frame','rc_wipe',
 'bcls_s0','bcls_s1','emit_vert_sx1','emit_vert_sx2','ap_edge_one',
 'reproject_at_crossing','br_recip','hud_draw',
 'corner_phi_nn','corner_phi_pn','corner_phi_np','corner_phi_pp',
 'rot_core_sin','rot_core_cos','rot_gen_pair','dpy_back_v1',
 'do_project_y_v1','do_project_y_v2'}
routines = ({resolve(t) for t in jsr_targets} | extra) & set(owner)

edges = set()
for f in files:
    cur = None
    for ln in open(f):
        code = ln.split(';')[0].rstrip()
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
HOT = {'br_render_subsector','br_seg_xform_vertex','br_back_face_test',
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
byfile = {}
for n in sorted(nodes):
    byfile.setdefault(owner.get(n), []).append(n)
ci = 0
for f, ns in sorted(byfile.items(), key=lambda kv: str(kv[0])):
    if f is None:
        for n in ns:
            out.append(f'  "{n}" [fillcolor="#ffd6d6", shape=diamond];')
        continue
    ci += 1
    out.append(f'  subgraph cluster_{ci} {{ label="{f.replace("src/","")}"; '
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
