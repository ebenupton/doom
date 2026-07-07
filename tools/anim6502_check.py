#!/usr/bin/env python3
"""6502 animated-sectors validation (flat engine, DOOM_ANIM build).

Three layers:
 1. PHASE LOCKSTEP — for each mover and phase, poke the engine's logical
    state (ANIM_WS pos + dirty bit) to the same prescaled height the
    python reference applies, render both, byte-compare FBs.  The engine
    patches itself lazily via the anim_ss_hook -> anim_hub path.
 2. STALENESS — change a mover's height while the camera is at spawn
    (mover invisible: its dirty bit must survive the frame untouched),
    then return to the mover: the first frame back must match python.
 3. TICK LOCKSTEP — run jt_anim_tick N times and compare every mover's
    (pos, state/timer) trajectory against a python simulation of the
    same integer state machine over the same CFG bytes.
"""
import os, struct, sys
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), '..'))
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
os.chdir(os.path.join(os.path.dirname(os.path.abspath(__file__)), '..'))
os.environ['DOOM_ANIM'] = '1'
os.environ.setdefault('SDL_VIDEODRIVER', 'dummy')
os.environ.setdefault('PYGAME_HIDE_SUPPORT_PROMPT', '1')
import pygame; pygame.init()
import doom_wireframe as dw
import anim_sectors as an
import pyref_render
from bsp_render_6502 import BspRender6502
from symmap import sym

ANIM_WS, ANIM_DIRTY, ANIM_ENABLE = 0x05EB, 0x05EA, 0x05E9
ORDER = sorted(dw.ANIM_SECTORS)


def fb_of(r):
    return bytes(r.sc.mpu.memory[0x5800:0x5800 + 5120])


def set_engine_phase(mem, mi, world_h):
    ps = dw._prescale_height(world_h)
    mem[ANIM_WS + mi * 3 + 0] = 0
    mem[ANIM_WS + mi * 3 + 1] = ps & 0xFF
    mem[ANIM_DIRTY] |= (1 << mi)


def set_python_phase(sec, world_h):
    m = an.MOVERS[sec]
    m.pos = float(world_h)
    an.flush_all()


def main():
    eng = BspRender6502(dw.packed_layout, dw.packed_rom_main, dw.packed_rom_detail,
                        dw.packed_bbox_table, dw.MAP_CENTER_X, dw.MAP_CENTER_Y,
                        dw.PRESCALE)
    mem = eng.sc.mpu.memory
    an.install_6502_tables(mem, flat=True)
    eng.sc._run(sym('jt_anim_init'))
    assert mem[ANIM_ENABLE] == 1

    bad = 0

    # ── 1. phase lockstep ────────────────────────────────────────────
    for sec in ORDER:
        m = an.MOVERS[sec]
        px, py, ab = an.camera_for(m)
        lo, hi = (m.closed, m.open) if m.kind == 'ceil' else (m.bottom, m.top)
        for t in (0.0, 0.3, 0.65, 1.0):
            h = round(lo + t * (hi - lo))
            set_python_phase(sec, h)
            set_engine_phase(mem, ORDER.index(sec), h)
            fz = dw.player_floor(px, py)
            eng.render_frame(px, py, ab, fz)
            ref, _ = pyref_render.render_ref_fb(px, py, ab)
            if fb_of(eng) != ref:
                nd = sum(1 for a, b in zip(fb_of(eng), ref) if a != b)
                print(f'PHASE MISMATCH sector {sec} t={t}: {nd} bytes')
                bad += 1
        # park the mover back at rest for the next tests
        set_python_phase(sec, lo if m.kind == 'ceil' else hi)
        set_engine_phase(mem, ORDER.index(sec), lo if m.kind == 'ceil' else hi)
    # settle both sides at rest with one visible render per mover
    for sec in ORDER:
        px, py, ab = an.camera_for(an.MOVERS[sec])
        eng.render_frame(px, py, ab, dw.player_floor(px, py))
    print(f'phase lockstep: {"PASS" if bad == 0 else "FAIL"}')

    # ── 2. staleness across invisible frames ────────────────────────
    sec = 4
    mi = ORDER.index(sec)
    m = an.MOVERS[sec]
    h_open = m.open
    set_python_phase(sec, h_open)
    set_engine_phase(mem, mi, h_open)
    eng.render_frame(1056, -3616, 128, dw.player_floor(1056, -3616))  # spawn
    if not (mem[ANIM_DIRTY] & (1 << mi)):
        print('STALENESS: dirty bit lost on an invisible frame'); bad += 1
    px, py, ab = an.camera_for(m)
    eng.render_frame(px, py, ab, dw.player_floor(px, py))
    if mem[ANIM_DIRTY] & (1 << mi):
        print('STALENESS: dirty bit not cleared after a visible frame'); bad += 1
    ref, _ = pyref_render.render_ref_fb(px, py, ab)
    if fb_of(eng) != ref:
        print('STALENESS: first visible frame after unseen change mismatches'); bad += 1
    print(f'staleness: {"PASS" if bad == 0 else "FAIL"}')

    # ── 3. tick trajectory lockstep ──────────────────────────────────
    tabs = an.gen_6502_tables(flat=True)
    cfg = tabs[0xE680]
    # reset engine state machines to CFG start
    eng.sc._run(sym('jt_anim_init'))
    sim = []
    for mi2 in range(6):
        c = struct.unpack_from('<hhHBBhBB', cfg, mi2 * 12)
        sim.append({'min': c[0], 'max': c[1], 'sp': c[2], 'wa': c[3],
                    'wb': c[4], 'pos': c[5], 'st': c[6]})
    tick_bad = 0
    for step in range(400):
        eng.sc._run(sym('jt_anim_tick'))
        for mi2, s in enumerate(sim):
            state, timer = s['st'] & 0xC0, s['st'] & 0x3F
            if state in (0x00, 0x80):
                timer = (timer - 1) & 0x3F
                if timer == 0:
                    state = (state + 0x40) & 0xC0
            elif state == 0x40:
                s['pos'] = s['pos'] + s['sp']
                if s['pos'] >= s['max']:
                    s['pos'], state, timer = s['max'], 0x80, s['wb']
            else:
                s['pos'] = s['pos'] - s['sp']
                if s['pos'] <= s['min']:
                    s['pos'], state, timer = s['min'], 0x00, s['wa']
            s['st'] = state | timer
            got_pos = mem[ANIM_WS + mi2*3] | (mem[ANIM_WS + mi2*3 + 1] << 8)
            if got_pos >= 0x8000: got_pos -= 0x10000
            got_st = mem[ANIM_WS + mi2*3 + 2]
            if got_pos != s['pos'] or got_st != s['st']:
                if tick_bad < 5:
                    print(f'TICK step {step} mover {mi2}: '
                          f'6502 pos={got_pos} st=${got_st:02X} '
                          f'sim pos={s["pos"]} st=${s["st"]:02X}')
                tick_bad += 1
    bad += tick_bad
    print(f'tick lockstep (400 steps x 6): {"PASS" if tick_bad == 0 else f"FAIL ({tick_bad})"}')

    print(f'ANIM6502: {"PASS" if bad == 0 else "FAIL"}')
    sys.exit(1 if bad else 0)


if __name__ == '__main__':
    main()
