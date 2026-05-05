"""Per-routine call counts and cycles-per-call."""
import os, re, ast
os.environ['SDL_VIDEODRIVER'] = 'dummy'
os.environ['PYGAME_HIDE_SUPPORT_PROMPT'] = '1'
import pygame; pygame.init(); pygame.display.set_mode((1, 1))
from test_bsp_render_frame import setup_wad, setup_view, init_pool, clear_screen
from span_clip_6502 import SpanClip6502

with open('/tmp/symdump.txt') as f:
    raw = re.sub(r'(\d+)L', r'\1', f.read())
syms = ast.literal_eval(raw)[0]

# Map address → routine name (top-level, no sub-label).
top_labels = sorted([(addr, name.lstrip('.').split('.')[-1]) for name, addr in syms.items()
                     if name.count('.') == 1])
top_labels.sort()
ranges = []
for i, (addr, name) in enumerate(top_labels):
    next_addr = top_labels[i+1][0] if i+1 < len(top_labels) else 0xFFFF
    ranges.append((addr, next_addr - 1, name))

def addr_to_name(a):
    for lo, hi, n in ranges:
        if lo <= a <= hi: return n
    if 0x2000 <= a <= 0x47FF: return 'span_clip'
    if 0xA900 <= a <= 0xB5FF: return 'rasteriser'
    return None

# External jump table addresses we care about
EXT = {0x2021: 'SC_UMUL8', 0x2024: 'SC_UDIV16_8', 0x201E: 'SC_DRAW_S16',
       0x2003: 'SC_MARK_SOLID', 0x2009: 'SC_HAS_GAP'}

sc = SpanClip6502()
setup_wad(sc); setup_view(sc, 1056, -3616, 64); init_pool(sc); clear_screen(sc)
mpu = sc.mpu; mem = mpu.memory
mpu.pc = 0x4815; mpu.sp = 0xFD; mpu.p = 0x30
mem[0x01FF] = 0xFE; mem[0x01FE] = 0xFF
mpu.processorCycles = 0

# Track function call counts via JSR opcode.
calls = {}
total_cyc_in = {}
prev = 0
call_stack = []
while mpu.pc != 0xFF00:
    pc = mpu.pc
    op = mem[pc]
    if op == 0x20:  # JSR
        target = mem[pc+1] | (mem[pc+2] << 8)
        name = EXT.get(target) or addr_to_name(target)
        if name:
            calls[name] = calls.get(name, 0) + 1
    mpu.step()
print(f"Total cycles: {mpu.processorCycles}")
print()
print(f"{'Calls':>8}  {'Routine'}")
for name, n in sorted(calls.items(), key=lambda x: -x[1]):
    if n >= 5:
        print(f"  {n:>6}  {name}")
