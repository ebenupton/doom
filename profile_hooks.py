#!/usr/bin/env python3
"""Profile the visibility hook operations to see what to focus on."""
import os
os.environ['SDL_VIDEODRIVER'] = 'dummy'
os.environ['PYGAME_HIDE_SUPPORT_PROMPT'] = '1'
import pygame; pygame.init(); pygame.display.set_mode((1, 1))

import doom_wireframe as dw
import fe6502
import spans6502
from fp import PRESCALE, MAP_CENTER_X, MAP_CENTER_Y

POS_LIST = [
    (1056, -3616, 0), (1056, -3616, 64), (1056, -3616, 128), (1056, -3616, 192),
    (1500, -3400, 32), (800, -3100, 96),
]

fe = fe6502.Frontend6502(dw.packed_rom_banks, dw.packed_rom_recip,
                          dw.packed_bbox_table, dw.packed_layout)

counts = {'queue_solid': 0, 'queue_tighten': 0, 'flush': 0,
          'bbox_cull': 0, 'enter_ss': 0,
          'tighten_ops_in_flush': 0, 'solid_ops_in_flush': 0,
          'mark_solid_splits': 0, 'tighten_splits': 0, 'pw_crossovers': 0}

orig_qs = spans6502.SpanState.queue_solid
orig_qt = spans6502.SpanState.queue_tighten
orig_flush = spans6502.SpanState.flush
orig_bbox = spans6502.SpanState.bbox_cull
orig_ess = spans6502.SpanState.enter_ss

def trace_qs(self, mpu):
    counts['queue_solid'] += 1
    orig_qs(self, mpu)
def trace_qt(self, mpu):
    counts['queue_tighten'] += 1
    orig_qt(self, mpu)
def trace_flush(self, mpu):
    counts['flush'] += 1
    for op in self.deferred:
        if op[0] == 'solid':
            counts['solid_ops_in_flush'] += 1
        else:
            counts['tighten_ops_in_flush'] += 1
    orig_flush(self, mpu)
def trace_bbox(self, mpu):
    counts['bbox_cull'] += 1
    orig_bbox(self, mpu)
def trace_ess(self, mpu):
    counts['enter_ss'] += 1
    orig_ess(self, mpu)

spans6502.SpanState.queue_solid = trace_qs
spans6502.SpanState.queue_tighten = trace_qt
spans6502.SpanState.flush = trace_flush
spans6502.SpanState.bbox_cull = trace_bbox
spans6502.SpanState.enter_ss = trace_ess
# Reinstall
fe._span_hooks[spans6502.HK_QUEUE_SOLID] = lambda mpu: trace_qs(fe._span_state, mpu)
fe._span_hooks[spans6502.HK_QUEUE_TIGHTEN] = lambda mpu: trace_qt(fe._span_state, mpu)
fe._span_hooks[spans6502.HK_FLUSH] = lambda mpu: trace_flush(fe._span_state, mpu)
fe._span_hooks[spans6502.HK_BBOX_CULL] = lambda mpu: trace_bbox(fe._span_state, mpu)
fe._span_hooks[spans6502.HK_ENTER_SS] = lambda mpu: trace_ess(fe._span_state, mpu)

for pos in POS_LIST:
    px, py, ab = pos
    fz = dw.player_floor(px, py)
    cmds, cyc = fe.render_frame(px, py, ab, fz)

for k, v in counts.items():
    print(f"  {k}: {v}")
print(f"  avg/frame: qs={counts['queue_solid']/len(POS_LIST):.1f} "
      f"qt={counts['queue_tighten']/len(POS_LIST):.1f} "
      f"flush={counts['flush']/len(POS_LIST):.1f}")
