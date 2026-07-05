
; ============================================================================
; br_seg_xform_vertex — fetch vertex by index, transform to view, project X.
;   Input:  zp_br_t0:t1 = vertex index (u16).
;   Output: zp_br_resl/h = screen x (s16). zp_seg_skip = 1 if near-clipped.
; ============================================================================
br_seg_xform_vertex:
.scope
PAGE BANK_L0                            ; reads verts (L0) on vcache miss; prior seg's
; projection may have left L2/C paged
ZERO zp_seg_skip

; --- Compute vertex cache index (idx*8 → cache offset) ---
; idx is in zp_br_t0:t1 (u16). vc_offset = idx * 8 (s/o offset for valid).
; valid_byte_offset = idx >> 3, valid_bit = idx & 7.
;
; Save idx for later (cache write) at zp_seg_v_idx_lo/hi.
LDA zp_br_t0
STA zp_seg_v_idx_lo
LDA zp_br_t1
STA zp_seg_v_idx_hi

; --- Check valid bit ---
; valid_byte_offset = idx_lo >> 3 + idx_hi << 5 (since high byte each adds 32 bytes)
LDA zp_br_t0
STA zp_br_t2
LDA zp_br_t1
STA zp_br_t3
LSR zp_br_t3
ROR zp_br_t2
LSR zp_br_t3
ROR zp_br_t2
LSR zp_br_t3
ROR zp_br_t2
; t2:t3 = idx >> 3
CLC
LDA #<VCACHE_VALID_BASE
ADC zp_br_t2
STA zp_br_p
LDA #>VCACHE_VALID_BASE
ADC zp_br_t3
STA zp_br_p_h
; bit mask = 1 << (idx_lo & 7), via table (was a 0..7-iteration shift loop)
LDA zp_br_t0
AND #7
TAX
LDA vc_bit_mask,X
STA zp_seg_v_bitm
LDY #0
LDA (zp_br_p),Y
AND zp_seg_v_bitm
BEQ vc_miss
; (was BNE+JMP)
vc_hit:
; --- Cache hit: load evy, evx, rhi/rlo, sx, near-clip flag from cache ---
; Cache offset = idx*8. Compute base ptr.
LDA zp_seg_v_idx_lo
STA zp_br_t2
LDA zp_seg_v_idx_hi
STA zp_br_t3
ASL zp_br_t2
ROL zp_br_t3
; *2
ASL zp_br_t2
ROL zp_br_t3
; *4
ASL zp_br_t2
ROL zp_br_t3
; *8
CLC
LDA #<VCACHE_BASE
ADC zp_br_t2
STA zp_br_p
LDA #>VCACHE_BASE
ADC zp_br_t3
STA zp_br_p_h
; Load evy, evx (offsets 0, 1) into current slots — needed for near-plane
; crossing math even when the vertex is clipped or a cache hit.
LDY #0
LDA (zp_br_p),Y
STA zp_seg_cur_evy
INY
LDA (zp_br_p),Y
STA zp_seg_cur_evx
; Check near-clip flag at offset 6
LDY #6
LDA (zp_br_p),Y
BEQ vc_hit_ok
LDA #1
STA zp_seg_skip
RTS
vc_hit_ok:
; Load rhi, rlo, sx from cache.
LDY #2
LDA (zp_br_p),Y
STA zp_br_rhi
INY
LDA (zp_br_p),Y
STA zp_br_rlo
INY
LDA (zp_br_p),Y
STA zp_seg_sx_lo
INY
LDA (zp_br_p),Y
STA zp_seg_sx_hi
; Project Y for top + bottom (heights vary per seg, can't cache).
JMP do_project_y

vc_miss:
; --- Set valid bit ---
LDY #0
LDA (zp_br_p),Y
ORA zp_seg_v_bitm
STA (zp_br_p),Y

; --- Compute cache base ptr (idx*8) ---
LDA zp_seg_v_idx_lo
STA zp_br_t2
LDA zp_seg_v_idx_hi
STA zp_br_t3
ASL zp_br_t2
ROL zp_br_t3
ASL zp_br_t2
ROL zp_br_t3
ASL zp_br_t2
ROL zp_br_t3
; *8
CLC
LDA #<VCACHE_BASE
ADC zp_br_t2
STA zp_seg_v_cache_lo
LDA #>VCACHE_BASE
ADC zp_br_t3
STA zp_seg_v_cache_hi

; --- Read s16 vertex x, y from ROM_VERTS + idx*4 ---
LDA zp_seg_v_idx_lo
STA zp_br_t2
LDA zp_seg_v_idx_hi
STA zp_br_t3
ASL zp_br_t2
ROL zp_br_t3
ASL zp_br_t2
ROL zp_br_t3
CLC
LDA zp_rom_verts_lo
ADC zp_br_t2
STA zp_br_p
LDA zp_rom_verts_hi
ADC zp_br_t3
STA zp_br_p_h
LDY #0
LDA (zp_br_p),Y
STA zp_br_dxlo
LDY #1
LDA (zp_br_p),Y
STA zp_br_dxhi
LDY #2
LDA (zp_br_p),Y
STA zp_br_dylo
LDY #3
LDA (zp_br_p),Y
STA zp_br_dyhi

JSR br_to_view

; Save view-space x (vxext:vxhi=int part s16, vxlo=frac part) before
; project_y clobbers vxlo/hi.
LDA zp_br_vxhi
STA zp_v_xint
LDA zp_br_vxlo
STA zp_v_xfrac
LDA zp_br_vxext
STA zp_v_xext

; Compute evx = vxhi (truncated s8) and evy = (vy + 128) >> 8 from the
; full s24 view-y (vyext, vyhi, vylo). Far-behind segs have negative
; vyext that overflows the s16 (vyhi:vylo) representation — using
; only vyhi misses the sign and lets clipped segs through.
LDA zp_br_vxhi
STA zp_seg_cur_evx
LDA zp_br_vylo
ASL A
; carry = bit 7 of vylo
LDA zp_br_vyhi
ADC #0
; A = (vyhi:vylo + 128) >> 8 low byte
STA zp_seg_cur_evy
; Clamp evy to s8 only when the rounded evy16 truly exceeds s8 —
; vyext=$FF is NORMAL for negative vy (s24 sign extension), not an
; overflow. Helper consumes the carry-out of the rounding add.
JSR ev_clamp_evy16

; Pre-write evy/evx into cache (offsets 0/1) — needed on any future
; cache hit, including the near-clipped path.
LDA zp_seg_v_cache_lo
STA zp_br_p
LDA zp_seg_v_cache_hi
STA zp_br_p_h
LDY #0
LDA zp_seg_cur_evy
STA (zp_br_p),Y
INY
LDA zp_seg_cur_evx
STA (zp_br_p),Y

; Near-clip on full s24: clipped iff total_vy < NEAR_88 (= 128 in 8.8).
;   vyext < 0 → clipped (very negative)
;   vyext > 0 → ok      (very positive, ≥ 256)
;   vyext = 0 → check (vyhi + carry from vylo bit 7) >= 1.
LDA zp_br_vyext
BMI nc_fail
BNE nc_ok
LDA zp_seg_cur_evy
BMI nc_fail
BNE nc_ok                               ; evy>0 -> ok (was BEQ+JMP)
nc_fail:
; Mark near-clipped in cache, set skip.
LDY #6
LDA #1
STA (zp_br_p),Y
LDA #1
STA zp_seg_skip
RTS
nc_ok:
; --- Compute reciprocal: vy_idx = s24 total_vy >> 7 (9.1). The old
; code dropped vy_ext ('per s8 vx contract') — but wide-vx segs are
; projected now, and a vertex with vy >= 256 view units got an index
; computed mod 65536 (e.g. vy=262 -> idx 10 instead of 524, recip 23x
; too big, sx=-2296 instead of 77). br_recip clamps to [2,1023]. ---
LDA zp_br_vylo
ASL A
LDA zp_br_vyhi
ROL A
STA zp_br_t0
LDA zp_br_vyext
ROL A
STA zp_br_t1
JSR br_recip                            ; rhi/rlo = reciprocal

; --- Project X using saved view-x integer + fractional parts ---
; br_project_x_auto goes wide when the s16 view-x (vxext:vxint)
; doesn't fit s8: Python projects these full-width (sx far
; off-screen) and their mark_solid and clipped draws still count —
; skipping the seg loses occlusion (e.g. mark_solid(0,81) at
; (800,-3400,96)) and over-emits behind it.
JSR br_project_x_auto
LDA zp_br_resl
STA zp_seg_sx_lo
LDA zp_br_resh
STA zp_seg_sx_hi

; --- Cache the per-vertex results (rhi, rlo, sx, near-clip=0) ---
LDA zp_seg_v_cache_lo
STA zp_br_p
LDA zp_seg_v_cache_hi
STA zp_br_p_h
LDY #2
LDA zp_br_rhi
STA (zp_br_p),Y
INY
LDA zp_br_rlo
STA (zp_br_p),Y
INY
LDA zp_seg_sx_lo
STA (zp_br_p),Y
INY
LDA zp_seg_sx_hi
STA (zp_br_p),Y
INY
LDA #0
STA (zp_br_p),Y
; near_clip = 0
JMP do_project_y
.endscope
