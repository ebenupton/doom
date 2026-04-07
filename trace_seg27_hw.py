#!/usr/bin/env python3
"""Read the 6502's frac_vx, frac_vy and seg 27's computed sx/sy from memory."""
import os
os.environ['SDL_VIDEODRIVER'] = 'dummy'
os.environ['PYGAME_HIDE_SUPPORT_PROMPT'] = '1'
import pygame; pygame.init(); pygame.display.set_mode((1, 1))

import doom_wireframe as dw
import fe6502
import spans6502

SEG = 27
fe = fe6502.Frontend6502(dw.packed_rom_banks, dw.packed_rom_recip,
                          dw.packed_bbox_table, dw.packed_layout)

def _capture_all(self):
    def rs16(a):
        v = self.mem[a] | (self.mem[a+1] << 8)
        return v - 65536 if v >= 32768 else v
    captured['fvx'] = rs16(0x1C); captured['fvy'] = rs16(0x1E)
    captured['sin_mag'] = self.mem[0x16]; captured['sin_neg'] = self.mem[0x17]
    captured['sin_unity'] = self.mem[0x18]
    captured['cos_mag'] = self.mem[0x19]; captured['cos_neg'] = self.mem[0x1A]
    captured['cos_unity'] = self.mem[0x1B]
    captured['px_int'] = self.mem[0x10]; captured['py_int'] = self.mem[0x11]
    captured['px_lo'] = self.mem[0x12]; captured['py_lo'] = self.mem[0x13]
    captured['sx1'] = rs16(0x20); captured['sx2'] = rs16(0x22)
    captured['ft1'] = rs16(0x24); captured['fb1'] = rs16(0x26)
    captured['ft2'] = rs16(0x28); captured['fb2'] = rs16(0x2A)
    captured['vx1'] = rs16(0x30); captured['vy1'] = rs16(0x32); captured['vi1'] = rs16(0x34)
    captured['vx2'] = rs16(0x36); captured['vy2'] = rs16(0x38); captured['vi2'] = rs16(0x3A)
    captured['ex1'] = rs16(0x3C); captured['ey1'] = rs16(0x3E)
    captured['ex2'] = rs16(0x40); captured['ey2'] = rs16(0x42)
    captured['rxh'] = self.mem[0x44]; captured['rxl'] = self.mem[0x45]
captured = {}
all_segs = []
_orig_qs = spans6502.SpanState.queue_solid
_orig_qt = spans6502.SpanState.queue_tighten
def _qs(self, mpu):
    ptr = self.mem[0x5E] | (self.mem[0x5F] << 8)
    base = 0x2000 + dw.packed_layout['off_seg_hdr']
    idx = (ptr - base) // 12
    all_segs.append(idx)
    _orig_qs(self, mpu)
    if idx == SEG:
        _capture_all(self)
def _qt(self, mpu):
    ptr = self.mem[0x5E] | (self.mem[0x5F] << 8)
    base = 0x2000 + dw.packed_layout['off_seg_hdr']
    idx = (ptr - base) // 12
    all_segs.append(idx)
    _orig_qt(self, mpu)
    if idx == SEG:
        _capture_all(self)
spans6502.SpanState.queue_solid = _qs
spans6502.SpanState.queue_tighten = _qt
# Re-install the hook table so the bound methods point at the new callables
fe._span_hooks[spans6502.HK_QUEUE_SOLID] = lambda mpu: _qs(fe._span_state, mpu)
fe._span_hooks[spans6502.HK_QUEUE_TIGHTEN] = lambda mpu: _qt(fe._span_state, mpu)

px, py, ab = (1056, -3616, 64)
fz = dw.player_floor(px, py)
cmds, cyc = fe.render_frame(px, py, ab, fz)

print(f"All emitted seg indices (count={len(all_segs)}): {sorted(set(all_segs))[:40]}")
if not captured:
    print(f"Seg {SEG} was not emitted by 6502")
else:
    print(f"Seg {SEG} 6502 values at prescale={dw.PRESCALE}:")
    for k in ('px_int','py_int','px_lo','py_lo',
              'sin_mag','sin_neg','sin_unity','cos_mag','cos_neg','cos_unity',
              'fvx','fvy','vx1','vy1','vi1','vx2','vy2','vi2',
              'ex1','ey1','ex2','ey2','rxh','rxl',
              'sx1','sx2','ft1','fb1','ft2','fb2'):
        print(f"  {k:9s} = {captured[k]}")
