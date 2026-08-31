#!/usr/bin/env python3
"""THE TUBE CONVERGENCE GATE: copro emissions -> host rasterizer -> compare
byte-exact against the flat build's framebuffer for the same pose.

Stage 1 (copro): the real COPROT binary + parasite image run in py65 with
a Tube model; frame-1 line commands are captured.
Stage 2 (host): the real HOSTT binary runs in py65; each command is fed
through its drawcmd entry (&1903) with scrstrt = $58.
Stage 3: the $5800 framebuffer must equal the BANKED build's render of the
same spawn pose EXACTLY (0 differing bytes)."""
import os, sys, subprocess

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, ROOT)
os.chdir(ROOT)
os.environ.setdefault('SDL_VIDEODRIVER', 'dummy')
os.environ.setdefault('PYGAME_HIDE_SUPPORT_PROMPT', '1')
import pygame; pygame.init()
import doom_wireframe as dw
from banked_bsp import BankedBspRender as BspRender6502
import symmap
from py65.devices.mpu6502 import MPU
from py65.devices.mpu65c02 import MPU as MPU_C02
from py65.memory import ObservableMemory

SPAWN = (1056, -3616, 64)


def copro_frame_commands():
    src = open('tube/test_copro_py65.py').read()
    ns = {'__name__': 'lib', '__file__': os.path.abspath('tube/test_copro_py65.py')}
    exec(compile(src.replace("if __name__ == '__main__':\n    main()", ""),
                 'tcp', 'exec'), ns)
    img = ns['build_image']()
    base = ObservableMemory()
    base[0:0x10000] = img
    state = {'out': [], 'avail': False, 'polls': 0, 'done': False}

    def r1s(a):
        if state['avail']:
            return 0xC0
        state['polls'] += 1
        if state['polls'] >= 2000:
            state['polls'] = 0
            state['avail'] = True
            return 0xC0
        return 0x40

    def r1d(a):
        state['avail'] = False
        return 0

    def r1w(a, v):
        state['out'].append(v)

    base.subscribe_to_read([0xFEF8], r1s)
    base.subscribe_to_read([0xFEF9], r1d)
    base.subscribe_to_write([0xFEF9], r1w)
    mpu = MPU_C02(memory=base)              # the copro is a 65C02
    mpu.pc = 0xEA03
    mpu.sp = 0xDD
    steps = 0
    while (len(state['out']) < 4 or state['out'][-4:] != [0xFF] * 4) \
            and steps < 4_000_000:
        mpu.step(); steps += 1
    cmds = state['out'][:-4]
    assert len(cmds) % 4 == 0 and cmds, "no frame captured"
    tuples = [tuple(cmds[i:i+4]) for i in range(0, len(cmds), 4)]
    # Strip the HUD packet the way the host's `main` does. This gate drives
    # `drawcmd` directly, so it never runs the dispatch that recognises
    # FE FE FE FE -- feed the packet in as geometry and its 12 payload
    # bytes rasterise as garbage across row 0.
    out, skip = [], 0
    for t in tuples:
        if skip:
            skip -= 1
            assert t[3] == 0, f"HUD payload tuple not 00-padded: {t}"
        elif t == (0xFE,) * 4:
            skip = 3
        else:
            out.append(t)
    return out


def host_rasterize(cmds):
    subprocess.run(['./beebasm', '-i', 'tube/hostg.asm'], check=True,
                   capture_output=True)
    host = open('HOSTT', 'rb').read()
    os.remove('HOSTT')
    mem = bytearray(0x10000)
    mem[0x1900:0x1900 + len(host)] = host
    mpu = MPU()
    mpu.memory[0:0x10000] = mem
    m = mpu.memory
    m[0x70] = 0x58                          # scrstrt = the flat FB page
    for x0, y0, x1, y1 in cmds:
        m[0x82], m[0x83], m[0x84], m[0x85] = x0, y0, x1, y1
        mpu.pc = 0x1903
        mpu.sp = 0xDD
        m[0x1DE] = 0xFF; m[0x1DF] = 0xFE    # RTS at S=$DD pops $1DE/$1DF
        n = 0                               # -> $FF00 done marker (the old
        while mpu.pc != 0xFF00 and n < 200_000:   # $1FE/$1FF sentinel was
            mpu.step(); n += 1              # never popped: BRK-sled exit)
        assert mpu.pc == 0xFF00, f"drawcmd wedged on {(x0,y0,x1,y1)}"
    return bytes(m[0x5800:0x6C00])


def main():
    from banked_bsp import limit_objects_legacy
    r = BspRender6502(dw.packed_layout, dw.packed_rom_main,
                      dw.packed_rom_detail, dw.packed_bbox_table,
                      dw.MAP_CENTER_X, dw.MAP_CENTER_Y, dw.PRESCALE)
    limit_objects_legacy(r)          # the tube runs the FLAT 18-object subset
    px, py, ab = SPAWN
    r.render_frame(px, py, ab, dw.player_floor(px, py))
    # The reference is the BANKED framebuffer (2026-08-29).  It used to be
    # the flat build's harness FB at $EA00, but the parasite is losing its
    # framebuffer and rasterisers, so the flat image can no longer answer
    # "what should this frame look like".
    ref = bytes(r.sc.mpu.memory[0x5800:0x6C00])

    cmds = copro_frame_commands()
    got = host_rasterize(cmds)
    diff = sum(1 for a, b in zip(ref, got) if a != b)
    print(f"pipeline gate: {len(cmds)} commands, {diff} differing FB bytes "
          f"(ref set={sum(1 for v in ref if v)})")
    if diff:
        shown = 0
        for i, (a, b) in enumerate(zip(ref, got)):
            if a != b and shown < 10:
                y = (i >> 8) * 8 + (i & 7)
                print(f"  &{0x5800+i:04X} x={i & 0xF8}+ y={y} ref={a:02x} got={b:02x}")
                shown += 1
        sys.exit(1)
    print("PIPELINE CONVERGED - tube FB == banked FB, bit-exact")


if __name__ == '__main__':
    main()
