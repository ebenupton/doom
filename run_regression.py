#!/usr/bin/env python3
"""One-shot regression + metrics for the optimization grind.

Rebuilds the engine, runs all correctness checks, compares ground-truth
verify positions and per-position frame cycles against a recorded baseline,
prints a compact PASS/FAIL summary. Exit 0 iff all green.

    python3 run_regression.py                # gate against baseline.json
    python3 run_regression.py --rebaseline   # accept current cycles/verify
                                             # numbers as the new baseline

The baseline (baseline.json) holds per-position frame cycles and the
two-sided verify metrics at the ground-truth positions. Gates:
  - correctness scripts must pass (as before)
  - verify: over/miss displacement must not exceed the recorded values
    (positions recorded CLEAN must stay CLEAN)
  - cycles: suite total must not regress more than CYCLE_TOL vs baseline
Improvements are reported and accepted silently; run --rebaseline after a
deliberate optimisation to tighten the gate.
"""
import os, sys, subprocess, re, json
os.environ['SDL_VIDEODRIVER'] = 'dummy'
os.environ['PYGAME_HIDE_SUPPORT_PROMPT'] = '1'

ROOT = os.path.dirname(os.path.abspath(__file__))
os.chdir(ROOT)
BASELINE_PATH = os.path.join(ROOT, 'baseline.json')
CYCLE_TOL = 0.0025          # 0.25% suite-total regression turns the board red
REBASELINE = '--rebaseline' in sys.argv

fails = []

# ---- builds (fail-loud via the shared helper) -----------------------------
import asmbuild
for banked in (0, 1):     # banked build catches memory-map overflows the
    try:                  # flat-only tests never see (e.g. anim_drv at $3C00)
        asmbuild.build('engine', banked=banked)
    except RuntimeError as e:
        fails.append(f'build banked={banked}: ' + str(e).strip().splitlines()[-1])


def run(label, argv, want):
    try:
        r = subprocess.run([sys.executable] + argv, capture_output=True, text=True, timeout=1200)
    except subprocess.TimeoutExpired:
        fails.append(f'{label}: TIMEOUT'); print(f'  {label}: TIMEOUT'); return ''
    out = r.stdout + r.stderr
    ok = want(out)
    print(f'  {label}: {"OK" if ok else "FAIL"}')
    if not ok:
        fails.append(label)
        print('    ' + '\n    '.join(out.strip().splitlines()[-6:]))
    return out


print('== correctness ==')
run('test_slope_div', ['test_slope_div.py'], lambda o: 'PASS' in o and 'FAIL' not in o)
run('test_bca',       ['test_bca.py'],       lambda o: 'PASS' in o and 'FAIL' not in o)
run('test_bsp_render',['test_bsp_render.py'],lambda o: 'All tests passed' in o)
run('check_angle',    ['check_angle_calls.py'], lambda o: re.search(r'TOTAL .*: 0 differ vs python, 0 differ', o) is not None)
ct = run('compare_traversal', ['compare_traversal.py'], lambda o: o.count('diff=0 px') == 10 and 'DIFFER' not in o)
run('compare_subsector', ['compare_subsector.py'], lambda o: re.search(r'TOTAL:.*0 pixel/span-affecting, 0 px', o) is not None)

baseline = None
if os.path.exists(BASELINE_PATH):
    with open(BASELINE_PATH) as f:
        baseline = json.load(f)
new_baseline = {'verify': {}, 'cycles': {}, 'total_cycles': 0}

# ---- ground truth: two-sided verify at fixed positions --------------------
# Over-direction: pixels the 6502 lit that Python didn't (over-draw).
# Miss-direction: pixels Python lit that the 6502 didn't (missing lines are
# bugs). Both gated against the recorded baseline so neither can creep.
print('== verify vs Python (two-sided) ==')
VERIFY_POSITIONS = [(1056, -3616, 64), (1500, -3700, 0), (800, -3400, 96),
                    (1056, -3328, 14), (1200, -3000, 129)]
try:
    import pygame; pygame.init(); pygame.display.set_mode((1, 1))
    import verify_6502_vs_python as V
    for (px, py, ab) in VERIFY_POSITIONS:
        mo, no, mm, nm, cyc, done = V.compare(px, py, ab)
        key = f'{px},{py},{ab}'
        new_baseline['verify'][key] = [mo, no, mm, nm]
        status = 'CLEAN' if (mo <= V.ALIAS_PX and mm <= V.ALIAS_PX) else 'DIVERGENT'
        line = f'  ({key}): {status} over={mo}px({no}) miss={mm}px({nm})'
        if not done:
            fails.append(f'verify {key}: TRUNCATED'); line += ' TRUNCATED'
        if baseline and not REBASELINE:
            old = baseline.get('verify', {}).get(key)
            if old:
                if mo > old[0] or mm > old[2]:
                    fails.append(f'verify {key}: worsened over={mo}(was {old[0]}) '
                                 f'miss={mm}(was {old[2]})')
                    line += f'  WORSE (was over={old[0]} miss={old[2]})'
                elif (mo, no, mm, nm) != tuple(old):
                    line += f'  (improved/changed, was {old})'
        print(line)
except Exception as e:
    fails.append(f'verify: {e}')
    print(f'  verify error: {e}')

# ---- frame cycles (gated) --------------------------------------------------
print('== frame cycles ==')
try:
    import pygame; pygame.init(); pygame.display.set_mode((1, 1))
    import doom_wireframe as dw
    from bsp_render_6502 import BspRender6502
    import compare_renders as C
    r = BspRender6502(dw.packed_layout, dw.packed_rom_main, dw.packed_rom_detail,
                      dw.packed_bbox_table, dw.MAP_CENTER_X, dw.MAP_CENTER_Y, dw.PRESCALE)
    tot = 0
    for (px, py, ab) in C.POSITIONS:
        cyc = r.render_frame(px, py, ab, dw.player_floor(px, py))
        tot += cyc
        new_baseline['cycles'][f'{px},{py},{ab}'] = cyc
    new_baseline['total_cycles'] = tot
    line = f'  TOTAL {tot:,}  MEAN {tot//len(C.POSITIONS):,}'
    if baseline and not REBASELINE and baseline.get('total_cycles'):
        old_tot = baseline['total_cycles']
        delta = (tot - old_tot) / old_tot
        line += f'  ({delta:+.2%} vs baseline {old_tot:,})'
        if delta > CYCLE_TOL:
            fails.append(f'cycles: total {tot:,} regressed {delta:+.2%} vs {old_tot:,}')
            for k, v in new_baseline['cycles'].items():
                ov = baseline.get('cycles', {}).get(k)
                if ov and v > ov:
                    print(f'    {k}: {ov:,} -> {v:,} ({(v-ov)/ov:+.2%})')
    print(line)
except Exception as e:
    fails.append(f'cycles: {e}')
    print(f'  frame-cycle measure error: {e}')

print('== binary sizes ==')
for b in ('span_clip.bin', 'bsp_render.bin', 'bsp_render_ang.bin'):
    if os.path.exists(b):
        print(f'  {b}: {os.path.getsize(b)}')

if REBASELINE and not fails:
    with open(BASELINE_PATH, 'w') as f:
        json.dump(new_baseline, f, indent=1, sort_keys=True)
    print(f'\nbaseline written to {BASELINE_PATH}')
elif baseline is None:
    print(f'\nNOTE: no {BASELINE_PATH}; cycles/verify not gated. '
          f'Run with --rebaseline to record one.')

print('\n' + ('ALL GREEN' if not fails else 'FAILURES: ' + ', '.join(fails)))
sys.exit(1 if fails else 0)
