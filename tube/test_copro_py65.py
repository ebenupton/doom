#!/usr/bin/env python3
"""Run the ACTUAL COPROT driver binary + parasite image in py65 with a
Tube-register model (ObservableMemory): R1 status reads scripted so the
mask channel and FIFO behave; emitted bytes are captured and checked for
protocol shape (4-byte commands, EOF framing). This is the copro half of
the Tube version, gate-style: if it runs N frames cleanly here, any
on-machine failure is environmental (interrupts/client ROM), not logic."""
import os, sys, subprocess

os.environ['DOOM_CPU'] = '65c02'    # BEFORE any project import: the rig
                                    # binds the CPU at import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, ROOT)
os.chdir(ROOT)
os.environ.setdefault('SDL_VIDEODRIVER', 'dummy')
os.environ.setdefault('PYGAME_HIDE_SUPPORT_PROMPT', '1')
import pygame; pygame.init()
import doom_wireframe as dw
from bsp_render_6502 import BspRender6502
import symmap
from py65.devices.mpu65c02 import MPU     # the copro is a 65C02
from py65.memory import ObservableMemory

FRAMES = int(os.environ.get('TUBE_FRAMES', '5'))
MASKS = [0, 0, 0, 1, 1, 8, 8, 0]        # still, fwd, turn — exercise movement


# Use line 0 is the door at raw x=336, y=816..688; stand just west of it
# facing +x.  Raw center-relative units, the space colmap's tables use.
USE_DOOR_RAW = (296, 752)
USE_DOOR_ANG = 0


def build_image():
    # (env set at module top; the rig below is coherently C02)
    r = BspRender6502(dw.packed_layout, dw.packed_rom_main, dw.packed_rom_detail,
                      dw.packed_bbox_table, dw.MAP_CENTER_X, dw.MAP_CENTER_Y,
                      dw.PRESCALE)
    mem = bytearray(r.sc.mpu.memory[0:0x10000])
    import importlib, build_anim_ssd as _anim, anim_sectors as _an, colmap as _cm
    btg = importlib.import_module('build_tube_game')
    btg.write_tube_syms()               # tube_syms.inc from the CURRENT map
    # THE PARASITE GEOMETRY (2026-09-02, resident re-cut): the glue +
    # emitters live in the RESIDENT block at $F600-$F7FF (COPRES, shipped
    # inside DATA); the flat engine's plot_h/plot_v/RASTER_ENTRY are RTS
    # stubs poked to JMP the fixed emitter slots $F610/$F613/$F616.
    # sincos is engine data at ROM_DRV_SINCOS_C.
    _an.install_6502_tables(mem, flat=True)   # anim CFG/TABL0/SSMASK
    _cm.install(mem, flat=True)               # collision/use tables
    _sc = _anim.sincos_table()
    _scb = symmap.sym('ROM_DRV_SINCOS_C')
    mem[_scb:_scb + len(_sc)] = _sc
    # (no plot pokes: plot_h/plot_v/RASTER_ENTRY are equates to the
    # glue's emitter slots; loading COPRES below provides the bodies)
    sys.path.insert(0, os.path.join(ROOT, 'tools'))
    import build_boot                  # ca65 since 2026-09-05
    _coprot, _copres = build_boot.tubedrv()
    # OBJECTS ON for the copro (2026-09-02, full-object parity): the
    # engine default is off (ok_state=1 -> anim_init zeroes OBJ_ANYB);
    # the parasite carries the FULL 52-billboard set since phase 2, and
    # the pipeline gate proves it against the banked reference.
    mem[symmap.sym('ok_state')] = 0
    res = _copres                             # boot stub: not needed here
    mem[0xF600:0xF600 + len(res)] = res       # RESIDENT at the top of memory
    return mem


def main():
    img = build_image()
    base = ObservableMemory()
    base[0:0x10000] = img

    state = {'frame': 0, 'out': [], 'eofs': 0, 'lines': 0, 'mask_reads': 0,
             'avail': False, 'polls': 0, 'space': 0,
             'hudleft': 0, 'hud': [], 'hudpkts': 0}

    def r1s_read(addr):
        # b6 (space): always. b7 (mask avail): FIFO model — empty until the
        # "vsync" (every 2000 empty polls) posts one mask byte, so .rdrain
        # exits and .wm paces exactly like the real host.
        if state['avail']:
            return 0xC0
        state['polls'] += 1
        if state['polls'] >= 2000:
            state['polls'] = 0
            state['avail'] = True
            return 0xC0
        return 0x40

    def r1d_read(addr):
        # TWO-BYTE MASK (2026-09-02): b7=0 movement (keys+fields),
        # b7=1 buttons (b0 SPACE, b1 O) -- sent only on level change,
        # like the real host.  One byte per 'vsync' post, as before.
        state['mask_reads'] += 1
        state['avail'] = False
        want_x = 0x80 | (1 if state.get('space') else 0) | state.get('okey', 0)
        if want_x != state.get('xsent', 0x80):
            state['xsent'] = want_x
            return want_x
        m = MASKS[min(state['frame'], len(MASKS) - 1)]
        return m

    def r1d_write(addr, value):
        state['out'].append(value)
        if len(state['out']) % 4 == 0:
            c = state['out'][-4:]
            if state['hudleft']:                      # HUD payload tuple
                state['hudleft'] -= 1
                state['hud'] += c
                # EVERY payload tuple must end in 00: that is what keeps
                # the packet 4-tuple aligned for the host's skip-ahead
                # parser AND stops a run of FFs in the position bytes
                # faking the ISR's 4-consecutive-FF end-of-frame marker.
                assert c[3] == 0, f"HUD payload tuple not 00-padded: {c}"
            elif c == [0xFF] * 4:
                state['eofs'] += 1
                state['frame'] += 1
            elif c == [0xFE] * 4:                     # HUD packet marker
                state['hudleft'] = 3
                state['hud'] = []
                state['hudpkts'] += 1
            else:
                state['lines'] += 1
                assert c[1] < 160 and c[3] < 160, f"bad y in {c}"

    base.subscribe_to_read([0xFEF8], r1s_read)
    base.subscribe_to_read([0xFEF9], r1d_read)
    base.subscribe_to_write([0xFEF9], r1d_write)

    mpu = MPU(memory=base)
    mpu.pc = 0xF600                      # harness entry: RESIDENT head (JMP init)
    mpu.sp = 0xDD
    steps = 0
    ring = [0] * 64
    while state['eofs'] < FRAMES and steps < 3_000_000 * FRAMES:
        ring[steps & 63] = mpu.pc
        mpu.step(); steps += 1
        if mpu.sp < 0x20 or mpu.pc < 0x100:
            print(f"FAIL at pc={mpu.pc:04x} sp={mpu.sp:02x} step {steps}")
            trail = [ring[(steps + i) & 63] for i in range(64)]
            print("trail:", " ".join(f"{p:04x}" for p in trail[-40:]))
            print(f"vec63={base[0x63]:02x}{base[0x64]:02x} vecCA={base[0xCA]:02x}{base[0xCB]:02x}")
            sys.exit(1)
    ok = state['eofs'] >= FRAMES

    # ---- SPACE 'use' phase --------------------------------------------
    # Every DR door on the map is "shut until used" (anim_sectors), so a
    # parasite with no use path has doors frozen shut FOREVER while
    # anim_tick, anim_hub and the mover state machine all look perfect --
    # which is exactly how it shipped.  Nothing here was covered: the
    # pipeline gate compares one view, this test ran 5 frames, and
    # anim6502_check POKES mover state rather than triggering it.  So
    # trigger it: teleport onto a door line, hold SPACE, and require a
    # CEIL mover (a door, not a self-cycling lift) to advance.
    import doom_wireframe as _dw, anim_sectors as _an, re as _re
    T = {}
    for _l in open(os.path.join(ROOT, 'tube/tube_syms.inc')):
        _m = _re.match(r'T_(\w+) = [&$]([0-9A-F]+)', _l.strip())
        if _m:
            T[_m.group(1)] = int(_m.group(2), 16)
    AW = symmap.sym('ANIM_WS', banked=0, c02=1)
    doors = [i for i, (sec, mv) in enumerate(sorted(_an.MOVERS.items()))
             if mv.kind == 'ceil']
    for nm, raw in (('PX', USE_DOOR_RAW[0]), ('PY', USE_DOOR_RAW[1])):
        v = (raw * 256 // _dw.PRESCALE) & 0xFFFFFF
        base[T['DV_' + nm + 'F']] = v & 0xFF
        base[T['DV_' + nm + 'L']] = (v >> 8) & 0xFF
        base[T['DV_' + nm + 'H']] = (v >> 16) & 0xFF
    base[T['DV_ANGIDX']] = USE_DOOR_ANG
    before = bytes(base[AW:AW + 3 * len(_an.MOVERS)])
    state['space'] = 0x80
    target = state['eofs'] + 40
    steps = 0
    while state['eofs'] < target and steps < 3_000_000 * 40:
        mpu.step(); steps += 1
    after = bytes(base[AW:AW + 3 * len(_an.MOVERS)])
    opened = [i for i in doors if before[3*i:3*i+3] != after[3*i:3*i+3]]
    use_ok = bool(opened)
    if not use_ok:
        print("USE FAIL: SPACE on a door line moved no ceil mover — "
              "the parasite's door-sense path is dead")
    ok = ok and use_ok

    # ---- O: objects toggle over the wire (2026-09-02 two-byte mask) ----
    # The image booted with objects ON (ok_state=0, harness poke).  Press
    # O: the host ships the level in the X byte's b1, the copro edge-
    # detects and JSRs ok_flip -> ok_state flips to 1 (OFF) and OBJ_ANYB
    # zeroes.  Release, press again: back ON, bitmap refilled.  This is
    # the ONLY end-to-end coverage of the O plumbing -- without it a
    # broken wire ships green (the SPACE lesson, again).
    OKS = symmap.sym('ok_state', banked=0, c02=1)    # the image IS the C02
    ANYB = symmap.sym('OBJ_ANYB', banked=0, c02=1)   # build; env was reset
    def run_frames(n):
        tgt = state['eofs'] + n
        k = 0
        while state['eofs'] < tgt and k < 3_000_000 * n:
            mpu.step(); k += 1
    o_ok = True
    for press, want_state, want_bitmap in ((1, 1, 'zero'), (2, 0, 'nonzero')):
        state['okey'] = 2
        run_frames(3)
        state['okey'] = 0
        run_frames(3)
        got = base[OKS]
        bm = any(base[ANYB + i] for i in range(25))
        bm_ok = (bm is False) if want_bitmap == 'zero' else bm
        if got != want_state or not bm_ok:
            o_ok = False
            print(f"O FAIL: press {press}: ok_state={got} (want {want_state}), "
                  f"OBJ_ANYB {'nonzero' if bm else 'zero'} (want {want_bitmap})")
    if o_ok:
        print("O toggle: PASS (off->zeroed bitmap, on->refilled)")
    ok = ok and o_ok

    # ---- HUD packet ----------------------------------------------------
    # The copro ships its pose every frame so the HOST can draw the HUD
    # (the parasite has no framebuffer and no OS font). One packet per
    # frame, carrying the driver's live DV_* pose.
    hud_ok = state['hudpkts'] >= state['eofs'] - 1 and len(state['hud']) == 12
    if hud_ok:
        h = state['hud']
        want = [base[T['DV_ANGIDX']], base[T['DV_PXF']], base[T['DV_PXL']], 0,
                base[T['DV_PXH']], base[T['DV_PYF']], base[T['DV_PYL']], 0,
                base[T['DV_PYH']],
                base[T['ZP_TW']] if 'ZP_TW' in T else 0,
                base[T['FIELDS']] if 'FIELDS' in T else None, None]
        if want[10] is None:                       # `fields` is a driver var,
            want[10] = h[10]                       # not an exported symbol
        # byte 11 is a 0 PAD again (2026-09-04): the extent cache is gone,
        # so the copro has no frame class to report.
        want[11] = 0

        hud_ok = (h == want)
        if not hud_ok:
            print(f"HUD FAIL: packet {h} != driver pose {want}")
    elif state['hudpkts'] == 0:
        print("HUD FAIL: the copro sent no HUD packet - the host has "
              "nothing to draw the readout from")
    ok = ok and hud_ok
    print(f"copro_py65: {'PASS' if ok else 'FAIL'} — {state['eofs']} frames, "
          f"{state['lines']} lines, {state['mask_reads']} mask reads, "
          f"{steps} steps, doors opened by SPACE: {opened}, "
          f"HUD packets: {state['hudpkts']}")
    sys.exit(0 if ok else 1)


if __name__ == '__main__':
    main()
