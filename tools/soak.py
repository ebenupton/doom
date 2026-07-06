#!/usr/bin/env python3
"""Long-run randomised exactness soak: engine FB vs pixel-exact Python
reference FB at random in-spec positions/orientations.

Per sample:
  - all-6502 engine frame (BspRender6502, rotation cache OFF) at a random
    (px, py, ab) uniform over the in-spec box (MAP_CENTER +/- 1000) x 0..255
  - pure-Python reference frame (tools/pyref_render.render_ref_fb: python
    BSP/transform, 6502-shadow clipper, nj_raster rasterisation)
  - byte-compare the two 5120-byte FBs
Every WARM_EVERY-th sample additionally soaks the rotation cache: a second
engine instance with RCACHE_ENABLE=1 renders (px,py,ab) then (px,py,ab')
— the second frame runs the warm cached path and must byte-match the
cache-off engine at (px,py,ab').

Engine binaries are loaded ONCE at start; later source edits in the working
tree do not affect a running soak.

Usage: tools/soak.py [hours] [seed]
Log:   build/soak_log.jsonl (one JSON object per sample)
Fails: build/soak_fail_<n>_{eng,ref}.bin FB dumps
"""
import json, os, random, sys, time
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), '..'))
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__))))
os.chdir(os.path.join(os.path.dirname(os.path.abspath(__file__)), '..'))
os.environ.setdefault('SDL_VIDEODRIVER', 'dummy')
os.environ.setdefault('PYGAME_HIDE_SUPPORT_PROMPT', '1')
import pygame; pygame.init()
import doom_wireframe as dw
from bsp_render_6502 import BspRender6502
from symmap import sym
import pyref_render

HOURS = float(sys.argv[1]) if len(sys.argv) > 1 else 8.0
SEED = int(sys.argv[2]) if len(sys.argv) > 2 else int(time.time())
BOX = 1000                 # in-spec s16 8.8 box half-size around MAP_CENTER
WARM_EVERY = 8
LOG = 'build/soak_log.jsonl'
EN = sym('RCACHE_ENABLE')


def mk(enable):
    r = BspRender6502(dw.packed_layout, dw.packed_rom_main, dw.packed_rom_detail,
                      dw.packed_bbox_table, dw.MAP_CENTER_X, dw.MAP_CENTER_Y,
                      dw.PRESCALE)
    r.sc.mpu.memory[EN] = enable
    return r


def fb(r):
    return bytes(r.sc.mpu.memory[r.sc.SCREEN_START:r.sc.SCREEN_START + r.sc.SCREEN_SIZE])


def main():
    rng = random.Random(SEED)
    eng = mk(0)
    engc = mk(1)
    t_end = time.time() + HOURS * 3600
    n = fails = crashes = warm_fails = model_drift = 0
    t0 = time.time()
    print(f'SOAK start: {HOURS}h, seed={SEED}, box=+/-{BOX}, log={LOG}', flush=True)
    with open(LOG, 'a') as log:
        log.write(json.dumps({'event': 'start', 'seed': SEED, 'hours': HOURS,
                              'time': time.time()}) + '\n')
        while time.time() < t_end:
            px = dw.MAP_CENTER_X + rng.randint(-BOX, BOX)
            py = dw.MAP_CENTER_Y + rng.randint(-BOX, BOX)
            ab = rng.randrange(256)
            n += 1
            rec = {'n': n, 'px': px, 'py': py, 'ab': ab}
            try:
                fz = dw.player_floor(px, py)
                cyc = eng.render_frame(px, py, ab, fz)
                done = eng.sc.mpu.pc == 0xFF00
                eng_fb = fb(eng)
                ref_fb, clip_ok = pyref_render.render_ref_fb(px, py, ab)
                same = ref_fb == eng_fb
                rec.update(ok=bool(same and done), cycles=cyc,
                           eng_done=bool(done), model_ok=bool(clip_ok))
                if not clip_ok:
                    model_drift += 1
                if not same or not done:
                    fails += 1
                    rec['ndiff'] = sum(1 for a, b in zip(ref_fb, eng_fb) if a != b)
                    if fails <= 200:      # cap FB dumps; positions in the log suffice
                        open(f'build/soak_fail_{n}_eng.bin', 'wb').write(eng_fb)
                        open(f'build/soak_fail_{n}_ref.bin', 'wb').write(ref_fb)
                    print(f'FAIL #{n} ({px},{py},{ab}) ndiff={rec["ndiff"]} '
                          f'done={done}', flush=True)
                if n % WARM_EVERY == 0:
                    ab2 = (ab + 37) & 0xFF
                    engc.render_frame(px, py, ab, fz)      # populate cache
                    engc.render_frame(px, py, ab2, fz)     # warm cached frame
                    eng.render_frame(px, py, ab2, fz)      # truth (cache off)
                    wok = fb(engc) == fb(eng) and engc.sc.mpu.pc == 0xFF00
                    rec['warm_ok'] = bool(wok)
                    if not wok:
                        warm_fails += 1
                        print(f'WARM FAIL #{n} ({px},{py},{ab}->{ab2})', flush=True)
            except Exception as e:
                crashes += 1
                rec.update(ok=False, error=repr(e))
                print(f'CRASH #{n} ({px},{py},{ab}): {e!r}', flush=True)
            log.write(json.dumps(rec) + '\n')
            log.flush()
            if n % 20 == 0:
                el = time.time() - t0
                print(f'[{el/3600:.2f}h] {n} samples, {fails} FB fails, '
                      f'{warm_fails} warm fails, {crashes} crashes, '
                      f'{model_drift} model-drift, {el/n:.1f}s/sample',
                      flush=True)
    el = time.time() - t0
    print(f'SOAK done: {n} samples in {el/3600:.2f}h — {fails} FB fails, '
          f'{warm_fails} warm fails, {crashes} crashes, '
          f'{model_drift} model-drift frames', flush=True)
    sys.exit(1 if (fails or warm_fails or crashes) else 0)


if __name__ == '__main__':
    main()
