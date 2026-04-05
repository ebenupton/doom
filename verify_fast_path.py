#!/usr/bin/env python3
"""Compare 6502 cmd stream byte-for-byte against the pre-fast-path HEAD build.

Rebuilds the current asm, captures cmds, then checks out HEAD's asm, rebuilds,
captures cmds, then compares.  Exits 0 iff every command matches.
"""
import os, sys, subprocess, shutil, pickle
os.environ['SDL_VIDEODRIVER'] = 'dummy'
os.environ['PYGAME_HIDE_SUPPORT_PROMPT'] = '1'
import pygame; pygame.init(); pygame.display.set_mode((1, 1))

POSITIONS = [
    (1056, -3616, 64),
    (1056, -3616, 0),
    (1056, -3616, 32),
    (1056, -3616, 96),
    (1200, -3300, 64),
]

def capture_cmds():
    # Force fresh import of doom_wireframe / fe6502 after rebuild
    for m in list(sys.modules):
        if m.startswith(('doom_wireframe', 'fe6502', 'engine6502', 'line6502',
                         'raster6502')):
            del sys.modules[m]
    import doom_wireframe as dw
    from fe6502 import Frontend6502
    fe = Frontend6502(dw.packed_rom_main, dw.packed_rom_detail,
                      dw.packed_rom_recip, dw.packed_layout)
    out = []
    for px, py, ab in POSITIONS:
        fz = dw.player_floor(px, py)
        cmds, cyc = fe.render_frame(px, py, ab, fz)
        out.append((cyc, cmds))
    return out

def rebuild():
    r = subprocess.run(['./beebasm', '-i', 'doom_fe.asm'],
                       capture_output=True, text=True)
    if r.returncode != 0:
        print("BUILD FAILED:", r.stderr)
        sys.exit(1)

# 1. Current state (with fast path)
print("Rebuilding current asm...")
rebuild()
print("Capturing cmds from current build...")
cur = capture_cmds()

# 2. HEAD state
print("Saving current asm, checking out HEAD...")
shutil.copy('doom_fe.asm', '/tmp/doom_fe_new.asm')
subprocess.run(['git', 'checkout', '--', 'doom_fe.asm'], check=True)
print("Rebuilding HEAD asm...")
rebuild()
print("Capturing cmds from HEAD build...")
head = capture_cmds()

# 3. Restore
print("Restoring new asm...")
shutil.copy('/tmp/doom_fe_new.asm', 'doom_fe.asm')
rebuild()

# 4. Compare
print("\n=== Comparison ===")
total_cur = sum(c[0] for c in cur)
total_head = sum(c[0] for c in head)
print(f"HEAD cycles:    {total_head:>10}")
print(f"NEW  cycles:    {total_cur:>10}")
print(f"Delta:          {total_cur - total_head:>+10}  "
      f"({(total_cur - total_head) / total_head * 100:+.1f}%)")

all_match = True
for i, (pos, c, h) in enumerate(zip(POSITIONS, cur, head)):
    cyc_c, cmds_c = c
    cyc_h, cmds_h = h
    if cmds_c == cmds_h:
        print(f"  pos {i}: MATCH  ({len(cmds_c)} cmds, "
              f"{cyc_c - cyc_h:+d} cyc)")
    else:
        all_match = False
        print(f"  pos {i}: MISMATCH  head={len(cmds_h)} cur={len(cmds_c)}")
        # Find first difference
        for j, (a, b) in enumerate(zip(cmds_h, cmds_c)):
            if a != b:
                print(f"    first diff at cmd {j}:")
                print(f"      head: {a}")
                print(f"      cur:  {b}")
                break
        if len(cmds_h) != len(cmds_c):
            print(f"    length mismatch {len(cmds_h)} vs {len(cmds_c)}")

print()
if all_match:
    print("ALL POSITIONS BYTE-IDENTICAL — fast path is correct")
    sys.exit(0)
else:
    print("MISMATCH — fast path introduces regressions")
    sys.exit(1)
