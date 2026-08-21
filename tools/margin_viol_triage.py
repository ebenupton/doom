#!/usr/bin/env python3
"""Triage bbox_margin_cert violations: for each violating (viewpoint,
node, side), replay the subtree's claiming segs and compare each claim
against the seg's FLOAT-TRUE column extent (float angles, no engine
arithmetic).  Verdicts per violation:
  STAGING  the engine claim exceeds the seg's float extent by > 2 cols
           (the standing projection-overflow class) AND the float
           extents all fit inside the gate extent -> not a margin bug
  MARGIN   float agrees the subtree really reaches past the gate extent
           -> a genuine angular->screen margin failure
"""
import os, sys, json, math
sys.path.insert(0, '/Users/ebenupton/doom')
sys.path.insert(0, '/Users/ebenupton/doom/tools')
os.chdir('/Users/ebenupton/doom')
os.environ.setdefault('SDL_VIDEODRIVER', 'dummy')
os.environ.setdefault('PYGAME_HIDE_SUPPORT_PROMPT', '1')
import importlib.util as ilu
spec = ilu.spec_from_file_location('cert', 'tools/bbox_margin_cert.py')
cert = ilu.module_from_spec(spec)
spec.loader.exec_module(cert)
dw, fp = cert.dw, cert.fp
import pygame
from wad_packed import spans_init_full


def replay(px, py, ab):
    """(ssid, seg, lo, hi) claim rows for one forced-open frame."""
    rows = []
    cur_seg = [None]
    orig_seg = dw.packed_render_seg
    orig_bbox = dw.fp_bbox_visible_fixed
    orig_ss = dw.packed_render_subsector
    orig_evs = dw.emit_vertex_spans
    orig_sc = dw._span_clip_6502
    orig_ab = dw._VIEW_AB

    class Rec2(cert.RecClips):
        def tighten(self, lo, hi, *a, **k):
            rows.append((self.ssid, cur_seg[0], lo, hi))
        def mark_solid(self, lo, hi, **k):
            rows.append((self.ssid, cur_seg[0], lo, hi))

    clips = Rec2()
    dw._VIEW_AB = ab
    try:
        px_88 = int((px - dw.MAP_CENTER_X) * 256 / dw.PRESCALE)
        py_88 = int((py - dw.MAP_CENTER_Y) * 256 / dw.PRESCALE)
        ctx = fp.fp_view_context(px_88, py_88, fp.fp_sincos(ab))
        vz = dw._prescale_height(dw.player_floor(px, py) + 41)
        cos_f = pygame.math.Vector2(1, 0).rotate(ab * 360 / 256).x
        sin_f = pygame.math.Vector2(1, 0).rotate(ab * 360 / 256).y
        ram = bytearray(dw.packed_layout['ram_size'])
        spans_init_full(ram, dw.packed_layout['ram_spans'],
                        dw.FP_RENDER_W, dw.FP_RENDER_H - 1)
        def seg_wrap(si, cl, c, v, surf, rm, d=None):
            cur_seg[0] = si
            return orig_seg(si, cl, c, v, surf, rm, d)
        def ss_wrap(idx, cl, c, v, surf, rm):
            cl.ssid = idx
            return orig_ss(idx, cl, c, v, surf, rm)
        dw.fp_bbox_visible_fixed = lambda n, s, c: (0, 255)
        dw.packed_render_subsector = ss_wrap
        dw.packed_render_seg = seg_wrap
        dw.emit_vertex_spans = lambda *a, **k: None
        dw._span_clip_6502 = cert._SCStub()
        surf = pygame.Surface((dw.FP_RENDER_W, dw.FP_RENDER_H))
        dw.packed_render_bsp(cert._ROOT, clips, ctx, vz,
                             px, py, cos_f, sin_f, surf, ram)
    finally:
        dw._VIEW_AB = orig_ab
        dw.fp_bbox_visible_fixed = orig_bbox
        dw.packed_render_subsector = orig_ss
        dw.packed_render_seg = orig_seg
        dw.emit_vertex_spans = orig_evs
        dw._span_clip_6502 = orig_sc
    return rows


def seg_world(si):
    """Prescaled world endpoints of seg si (packed-plane reads)."""
    layout = dw.packed_layout
    rom = dw.packed_rom_main
    from wad_packed import seg_hdr_off, SH_V1, SH_V2
    seg_off = layout['off_seg_hdr'] + seg_hdr_off(si)
    _w1 = rom[seg_off + SH_V1] | (rom[seg_off + SH_V1 + 1] << 8)
    _w2 = rom[seg_off + SH_V2] | (rom[seg_off + SH_V2 + 1] << 8)
    v1 = (_w1 >> 8) * 8 + (_w1 & 7)
    v2 = (_w2 >> 8) * 8 + (_w2 & 7)
    verts_off = layout['off_verts']
    def _vpg(i):
        ox = rom[verts_off + (i >> 8) * 256 + (i & 0xFF)]
        oy = rom[verts_off + 0x200 + (i >> 8) * 256 + (i & 0xFF)]
        pg = rom[verts_off + 0x400 + (i >> 8) * 256 + (i & 0xFF)]
        return ((((pg & 3) - 2) << 8) + ox,
                ((((pg >> 2) & 3) - 2) << 8) + oy)
    return _vpg(v1), _vpg(v2)


def float_cols(si, px, py, ab):
    """Float-true visible column extent of seg si, or None."""
    (wx1, wy1), (wx2, wy2) = seg_world(si)
    pxs = (px - dw.MAP_CENTER_X) / dw.PRESCALE
    pys = (py - dw.MAP_CENTER_Y) / dw.PRESCALE
    th = ab * 2 * math.pi / 256
    c, s = math.cos(th), math.sin(th)
    lo = hi = None
    N = 256
    for i in range(N + 1):
        f = i / N
        wx = wx1 + (wx2 - wx1) * f
        wy = wy1 + (wy2 - wy1) * f
        dx, dy = wx - pxs, wy - pys
        # view space: vy = depth along view axis, vx = rightward
        vy = dx * c + dy * s
        vx = -dx * s + dy * c
        if vy <= 0.01:
            continue
        col = 128 - 128 * (vx / vy)      # ENGINE convention (screen x
                                         # mirrors view-space rightward)
        col = max(-4096.0, min(4096.0, col))
        lo = col if lo is None else min(lo, col)
        hi = col if hi is None else max(hi, col)
    return None if lo is None else (lo, hi)


def main():
    d = json.load(open('build/margin_cert_viol.json'))
    frames = {}
    for v in d['viol']:
        frames.setdefault((v['px'], v['py'], v['ab']), []).append(v)
    print(f"{len(d['viol'])} violations over {len(frames)} frames; "
          f"{len(d['cull'])} cull-violations")
    counts = {'STAGING': 0, 'MARGIN': 0, 'ODD': 0}
    margin_cases = []
    fkeys = list(frames)
    for fi, key in enumerate(fkeys):
        px, py, ab = key
        rows = replay(px, py, ab)
        for v in frames[key]:
            target = set(cert.SUBTREE[(v['nid'], v['side'])])
            ilo, ihi = v['br']
            # engine claims inside this subtree, clamped
            bad = []           # segs whose engine claim pokes past ihi/ilo
            for (ssid, si, lo, hi) in rows:
                if ssid not in target:
                    continue
                clo, chi = max(0, lo), min(255, hi)
                if chi <= clo:
                    continue
                if chi > ihi or clo < ilo:
                    bad.append((si, lo, hi))
            verdict = None
            fl_max = -1e9; fl_min = 1e9
            for (si, lo, hi) in bad:
                fc = float_cols(si, px, py, ab)
                if fc is None:
                    continue
                # only the ON-SCREEN part of the float extent matters:
                # the gate owes coverage over [0,255) alone
                flo, fhi = max(0.0, fc[0]), min(255.0, fc[1])
                if fhi <= flo:
                    continue
                fl_min = min(fl_min, flo); fl_max = max(fl_max, fhi)
            # float truth of the poking segs vs the gate extent
            if fl_max < -1e8:
                verdict = 'STAGING'      # bad segs have no on-screen truth
            elif fl_max <= ihi + 0.5 and fl_min >= ilo - 0.5:
                verdict = 'STAGING'      # engine claim escaped its own seg
            else:
                verdict = 'MARGIN'
                margin_cases.append((v, [(si, lo, hi,
                                          float_cols(si, px, py, ab))
                                         for (si, lo, hi) in bad]))
            counts[verdict] += 1
        if fi % 40 == 39:
            print(f"  ... {fi+1}/{len(fkeys)} frames", flush=True)
    print("verdicts:", counts)
    for (v, segs) in margin_cases[:8]:
        print("\nMARGIN case:", v)
        for row in segs:
            print("   seg", row)


if __name__ == '__main__':
    main()
