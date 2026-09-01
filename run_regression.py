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
# Likewise: require every pose to have actually WALKED (asm N, hyb N with
# N > 0), not merely to have agreed about nothing.
ct = run('compare_traversal', ['compare_traversal.py'],
         lambda o: (o.count('diff=0 px') == 18 and 'DIFFER' not in o
                    # Guard the VACUOUS case (every pose walking nothing)
                    # without banning the legitimate ones: two suite poses
                    # genuinely see no geometry -- (192,-2368,99) and
                    # (3648,-2368,35) are the ~1.9k/~3.9k-cycle near-empty
                    # frames, and BOTH rigs report them as zero.
                    and o.count('(asm 0, hyb 0)') < 9))
# The subsector count must be NON-ZERO.  "TOTAL: 0/0 subsectors divergent,
# 0 pixel/span-affecting, 0 px" satisfied the old predicate perfectly --
# so a differential that visited nothing at all reported GREEN.  That is
# how the banked-rig port nearly shipped broken (2026-08-30).
run('compare_subsector', ['compare_subsector.py'],
    lambda o: (re.search(r'TOTAL:.*0 pixel/span-affecting, 0 px', o) is not None
               and re.search(r'TOTAL: \d+/([1-9]\d*) subsectors', o) is not None))
run('rotcache_check', ['tools/rotcache_check.py'], lambda o: 'PASS' in o and 'MISMATCH' not in o)
run('vxcache_check', ['tools/vxcache_check.py'], lambda o: 'PASS' in o and 'MISMATCH' not in o)
run('tube_pipeline', ['tube/test_pipeline_py65.py'], lambda o: 'PIPELINE CONVERGED' in o)
# The copro gate also covers SPACE 'use': DR doors are shut until used, so a
# parasite with no use path has permanently frozen doors while anim_tick,
# anim_hub and the mover state machine all look perfect. Nothing else here
# catches it -- anim6502_check POKES mover state instead of triggering it.
run('tube_copro', ['tube/test_copro_py65.py'], lambda o: 'copro_py65: PASS' in o)
# HOSTT's half of the split HUD: the copro ships a pose packet, the host
# draws the readout. The pipeline gate drives drawcmd directly and never
# sees the packet, so without this the host half is untested.
run('tube_hud', ['tube/test_hostt_hud.py'], lambda o: 'HOSTT-HUD: PASS' in o)
run('tube_doors', ['tube/test_tube_doors.py'], lambda o: 'TUBEDOORS: PASS' in o)
# Multi-POSE tube convergence (walk + turns, FB byte-exact per frame).
# The pipeline gate above covers ONE pose (spawn); this is the gate that
# would have caught the 2026-08-25 psi-plane-on-anim-tables spray, which
# corrupted the copro engine only at non-spawn poses/angles. NOTE its
# mask model must ride a field count in b4-6 -- a bare key mask moves
# nothing since pmove (that diet is how the hole opened).
run('tube_walk', ['tube/test_walk_convergence.py'],
    lambda o: 'WALK CONVERGENCE: PASS' in o)
run('table_overlap', ['tools/test_table_overlap.py'],
    lambda o: 'TABLEOVERLAP: PASS' in o)
run('bare_boot', ['test_bare_boot.py'],
    lambda o: 'PASS' in o and 'FAIL' not in o)
run('walkdrv_loop', ['tools/test_walkdrv_loop.py'],
    lambda o: 'WALKDRV LOOP: PASS' in o)
run('pm_fuzz', ['tools/pm_fuzz.py'],
    lambda o: 'TOTAL divergences: 44' in o)  # the standing-44 (known mom +-1vz class); growth = regression
# The banked (non-copro) HUD has the same font search. The MOS font is not
# at a fixed address -- OS 1.2 $C000, MOS 3.20 $F900 -- and hardwiring
# $C000 is what corrupted the readout on a Master.
run('hud_font', ['tools/test_hud_font.py'], lambda o: 'HUDFONT: PASS' in o)
run('hud_draw', ['tools/test_hud_draw.py'], lambda o: 'HUDDRAW: PASS' in o)
# ^ the parasite shares the flat image but carries its OWN map glue
# (emit overlay, ship ranges, boot zeroing) — layout arcs rot it
# silently without a gate (the 2026-08-10 black screen: three arcs
# of slide between tube-convergence and the first tube boot)
run('walkseq_check', ['tools/walkseq_check.py'], lambda o: 'walkseq_check: OK' in o)
run('hud_e2e', ['tools/test_hud_e2e.py'], lambda o: 'HUDFONT-E2E: PASS' in o)
# bankedcmp_check RETIRED 2026-08-30.  It rendered the same frames on both
# builds and byte-compared the framebuffers -- but the flat build no longer
# HAS a framebuffer, and banked is the reference, so "check banked against
# flat" is backwards now.  Its coverage survives intact in tube_walk: the
# copro runs the FLAT engine and its draw commands must reproduce the
# BANKED framebuffer bit-exactly across 30 walking frames, which is the
# same flat-vs-banked divergence check done through the parasite.  The file
# is kept for its history (the mask_done fall-through landmine it was born
# from) but is no longer run.
run('anim6502_check', ['tools/anim6502_check.py'], lambda o: 'ANIM6502: PASS' in o)
# The call graph is a FIRST-CLASS OUTPUT (Eben, 2026-08-09): always
# rebuilt with the gates — this also runs its file-DAG acyclicity check,
# so a reintroduced call cycle fails the regression here.
run('callgraph', ['tools/gen_callgraph.py'], lambda o: 'build/callgraph.pdf' in o and 'CYCLE' not in o)
run('codescan', ['tools/codescan.py'], lambda o: 'CODESCAN: PASS' in o)
# BAKED ADDRESSES (Eben, 2026-08-30: "forbidden to ever create a baked
# address").  A literal address is a copy of a fact -- when the real thing
# moves the copy does not, and it is a silent read/write, never a build
# error.  This ratchets: the non-ZP count may fall, never rise.
run('bakedscan', ['tools/bakedscan.py', '--gate'],
    lambda o: 'BAKEDSCAN: PASS' in o or 'baseline written' in o)
# project_y raw-body domain certificate: every (recip, h) pair, S=1..11,
# vs fp_project_y — the proof behind the |h| <= 127 projection fence
# (the HALF-UNIT mover tier lives on it, 2026-08-25)
run('projy_range', ['tools/test_projy_range.py'],
    lambda o: 'PROJY-RANGE: PASS' in o)
run('lamp_ladder', ['tools/test_lamp_ladder.py'],
    lambda o: 'LAMPLADDER: PASS' in o)
run('pickup_ladders', ['tools/test_pickup_ladders.py'],
    lambda o: 'PICKUPLADDERS: PASS' in o)
run('object_draws', ['tools/test_object_draws.py'],
    lambda o: 'OBJDRAWS: PASS' in o)

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
VERIFY_POSITIONS = [(1792.34375, -3351.375, 108),
                    (1056, -3616, 64), (1500, -3700, 0), (800, -3400, 96),
                    (1056, -3328, 14), (1200, -3000, 129),
                    # far-from-spawn, in-spec (+/-1023 units of MAP_CENTER)
                    (2112, -2368, 35), (1984, -2496, 67),
                    # beyond the old box (s16 player int)
                    (3648, -4800, 131),
                    # zero-record off-screen-aperture portal reproducer
                    (-486, -3307, 243),
                    # RE-ENTERING LINE: the deferred-emit restructure closed
                    # the second fragment at the FIRST one's end (stale ox1),
                    # 99px over-draw the whole suite above missed.  HUD reads
                    # X=000C.B0 Y=0052.BD R=B0.
                    (1301.5, -2586.09375, 0xB0)]
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
    # THE REFERENCE IS THE BANKED BUILD (2026-08-29, Eben): that is what
    # ships on a Model B, so it is what the numbers must describe. The
    # flat build survives only as the tube parasite's engine.
    from banked_bsp import BankedBspRender as BspRender6502
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
