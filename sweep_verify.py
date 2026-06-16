"""Broad correctness sweep: Python(angle) vs 6502 over a grid of positions/
angles. Confirms the aggressive optimizations stay pixel-exact beyond the 10
reference frames. Reuses compare_traversal's trace_asm/trace_hybrid."""
import os, sys
os.environ['SDL_VIDEODRIVER']='dummy'; os.environ['PYGAME_HIDE_SUPPORT_PROMPT']='1'
import pygame; pygame.init(); pygame.display.set_mode((1,1))
import compare_traversal as ct
bad=0; n=0
for px in range(900, 1600, 220):
    for py in range(-3700, -2900, 260):
        for ab in range(1, 256, 37):   # off-axis angles
            n+=1
            try:
                at,af = ct.trace_asm(px,py,ab)
                ht,hf = ct.trace_hybrid(px,py,ab)
            except Exception as e:
                print(f"({px},{py},{ab}) EXC {e}"); bad+=1; continue
            diff = sum(bin(a^b).count('1') for a,b in zip(af,hf))
            ass=[c[1] for c in at if c[0]=='ss']; hss=[c[1] for c in ht if c[0]=='ss']
            if diff!=0 or ass!=hss:
                bad+=1
                print(f"({px},{py},{ab}) DIFFER fb={diff}px ss(asm{len(ass)}/hyb{len(hss)})")
print(f"\nswept {n} positions: {bad} divergent")
sys.exit(1 if bad else 0)
