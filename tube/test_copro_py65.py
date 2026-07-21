#!/usr/bin/env python3
"""Run the ACTUAL COPROT driver binary + parasite image in py65 with a
Tube-register model (ObservableMemory): R1 status reads scripted so the
mask channel and FIFO behave; emitted bytes are captured and checked for
protocol shape (4-byte commands, EOF framing). This is the copro half of
the Tube version, gate-style: if it runs N frames cleanly here, any
on-machine failure is environmental (interrupts/client ROM), not logic."""
import os, sys, subprocess

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, ROOT)
os.chdir(ROOT)
os.environ.setdefault('SDL_VIDEODRIVER', 'dummy')
os.environ.setdefault('PYGAME_HIDE_SUPPORT_PROMPT', '1')
import pygame; pygame.init()
import doom_wireframe as dw
from bsp_render_6502 import BspRender6502
import symmap
from py65.devices.mpu6502 import MPU
from py65.memory import ObservableMemory

FRAMES = int(os.environ.get('TUBE_FRAMES', '5'))
MASKS = [0, 0, 0, 1, 1, 8, 8, 0]        # still, fwd, turn — exercise movement


def build_image():
    r = BspRender6502(dw.packed_layout, dw.packed_rom_main, dw.packed_rom_detail,
                      dw.packed_bbox_table, dw.MAP_CENTER_X, dw.MAP_CENTER_Y,
                      dw.PRESCALE)
    mem = bytearray(r.sc.mpu.memory[0:0x10000])
    subprocess.run(['./beebasm', '-i', 'tube/emit.asm'], check=True,
                   capture_output=True)
    emit = open('EMIT', 'rb').read(); os.remove('EMIT')
    mem[0xA900:0xB600] = bytes(0xB600 - 0xA900)
    mem[0xA900:0xA900 + len(emit)] = emit
    for name, target in (('plot_h', 0xA910), ('plot_v', 0xA920)):
        a = symmap.sym(name)
        mem[a] = 0x4C; mem[a+1] = target & 0xFF; mem[a+2] = target >> 8
    subprocess.run(['./beebasm', '-i', 'tube/tubedrv.asm'], check=True,
                   capture_output=True)
    cop = open('COPROT', 'rb').read(); os.remove('COPROT')
    mem[0x5800:0x5800 + len(cop)] = cop
    mem[0x6400:0x6700] = mem[0xF800:0xFB00]   # stage the high table like
    return mem                                # the disc (driver copies up)


def main():
    img = build_image()
    base = ObservableMemory()
    base[0:0x10000] = img

    state = {'frame': 0, 'out': [], 'eofs': 0, 'lines': 0, 'mask_reads': 0, 'avail': False, 'polls': 0}

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
        state['mask_reads'] += 1
        state['avail'] = False
        m = MASKS[min(state['frame'], len(MASKS) - 1)]
        return m

    def r1d_write(addr, value):
        state['out'].append(value)
        if len(state['out']) % 4 == 0:
            c = state['out'][-4:]
            if c == [0xFF] * 4:
                state['eofs'] += 1
                state['frame'] += 1
            else:
                state['lines'] += 1
                assert c[1] < 160 and c[3] < 160, f"bad y in {c}"

    base.subscribe_to_read([0xFEF8], r1s_read)
    base.subscribe_to_read([0xFEF9], r1d_read)
    base.subscribe_to_write([0xFEF9], r1d_write)

    mpu = MPU(memory=base)
    mpu.pc = 0x5803                      # harness entry: init + frame loop
    mpu.sp = 0xFD
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
    print(f"copro_py65: {'PASS' if ok else 'FAIL'} — {state['eofs']} frames, "
          f"{state['lines']} lines, {state['mask_reads']} mask reads, "
          f"{steps} steps")
    sys.exit(0 if ok else 1)


if __name__ == '__main__':
    main()
