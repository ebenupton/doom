"""Quantify the per-child bbox-visibility work: how many bbox tests, how many
8x8 multiplies and divides each costs, and how that compares to the number of
subsectors actually rendered.

Counts events while inside the br_bbox_visible call frame (sp-tracked), so
umul8/udiv called for bbox corners are attributed to the child test.
"""
import os
os.environ['SDL_VIDEODRIVER'] = 'dummy'
os.environ['PYGAME_HIDE_SUPPORT_PROMPT'] = '1'
import pygame; pygame.init(); pygame.display.set_mode((1, 1))
import doom_wireframe as dw
import trace_compare as tc

BBOX   = 0x4EB7          # br_bbox_visible
SUBSEC = 0x511D          # br_render_subsector
UMUL8  = {0x2030, 0x2021}
UDIV   = {0x2024}        # udiv16_8 (recip uses tables, not this)
CRXDIV = None            # crx_udiv resolved below
RECIP_RAW = 0x4875       # br_recip body (table lookup; counts as a "divide")
ROTPAIR = None           # rot_pair_cached resolved below

POS = [(1056,-3616,65),(1500,-3700,1),(1024,-3500,65),
       (800,-3400,96),(1200,-3000,129),(1056,-3616,129)]


def resolve():
    import subprocess, re
    out = subprocess.run(['./beebasm','-i','bsp_render.asm','-D','BANKED=0','-D','C02=0','-v'],
                         capture_output=True, text=True).stdout
    addr = {}
    for m in re.finditer(r'\.([A-Za-z_][A-Za-z0-9_]*)\n\s+([0-9A-F]{4})', out):
        addr.setdefault(m.group(1), int(m.group(2), 16))
    return addr


def run(px, py, ab, crx, rotpair):
    _ = dw.Instrumented6502Spans()
    sc = dw._span_clip_6502
    tc.setup_wad(sc); tc.setup_view_zp(sc, px, py, ab)
    sc._run(tc.ENTRY_BR_VIEW_SETUP)
    sc.init(); sc.clear_screen(); sc._run(0x481B)
    mpu = sc.mpu; mem = mpu.memory
    mpu.pc = 0x4815; mpu.sp = 0xFD; mpu.p = 0x30
    mem[0x01FF] = 0xFE; mem[0x01FE] = 0xFF
    mpu.processorCycles = 0
    c = dict(bbox=0, subsec=0, mul=0, mul_bbox=0, div_bbox=0, recip_bbox=0,
             rotpair_bbox=0, bbox_cyc=0)
    bbox_sp = None   # sp threshold while inside a bbox test
    prev = 0
    while mpu.pc != 0xFF00:
        pc = mpu.pc; sp = mpu.sp
        if bbox_sp is not None and sp > bbox_sp:
            bbox_sp = None
        in_bbox = bbox_sp is not None
        if pc == BBOX:
            c['bbox'] += 1
            bbox_sp = sp                   # sp at entry (already post-JSR)
            in_bbox = True
        elif pc == SUBSEC:
            c['subsec'] += 1
        if pc in UMUL8:
            c['mul'] += 1
            if in_bbox: c['mul_bbox'] += 1
        if in_bbox:
            if pc in UDIV or pc == crx: c['div_bbox'] += 1
            if pc == RECIP_RAW: c['recip_bbox'] += 1
            if pc == rotpair: c['rotpair_bbox'] += 1
        mpu.step()
        cyc = mpu.processorCycles
        if in_bbox: c['bbox_cyc'] += cyc - prev
        prev = cyc
    return c


if __name__ == '__main__':
    a = resolve()
    crx = a.get('crx_udiv')
    rotpair = a.get('rot_pair_cached')
    tot = dict(bbox=0, subsec=0, mul=0, mul_bbox=0, div_bbox=0, recip_bbox=0,
               rotpair_bbox=0, bbox_cyc=0)
    print(f'{"scene":20s} {"tests":>6s} {"ss":>4s} {"t/ss":>5s} '
          f'{"mul/t":>6s} {"recip/t":>8s} {"cyc/t":>6s}')
    for p in POS:
        c = run(*p, crx, rotpair)
        for k in tot: tot[k] += c[k]
        b = c['bbox']
        print(f'{str(p):20s} {b:6d} {c["subsec"]:4d} {b/max(c["subsec"],1):5.1f} '
              f'{c["mul_bbox"]/b:6.1f} {c["recip_bbox"]/b:8.2f} {c["bbox_cyc"]/b:6.0f}')
    b = tot['bbox']
    print(f'\n--- suite totals ---')
    print(f'bbox tests (children)      : {b}')
    print(f'subsectors rendered        : {tot["subsec"]}')
    print(f'bbox tests per subsector   : {b/tot["subsec"]:.1f}')
    print(f'umul8 calls total          : {tot["mul"]}')
    print(f'umul8 calls inside bbox    : {tot["mul_bbox"]}  ({100*tot["mul_bbox"]/tot["mul"]:.0f}% of all multiplies)')
    print()
    print(f'per bbox test (avg over {b} tests):')
    print(f'  8x8 multiplies   : {tot["mul_bbox"]/b:.1f}')
    print(f'  recip lookups    : {tot["recip_bbox"]/b:.2f}')
    print(f'  divides (cross)  : {tot["div_bbox"]/b:.2f}')
    print(f'  rot_pair calls   : {tot["rotpair_bbox"]/b:.2f}')
    print(f'  cycles           : {tot["bbox_cyc"]/b:.0f}')
