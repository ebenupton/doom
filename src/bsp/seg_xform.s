
; ============================================================================
; br_seg_xform_vertex — fetch vertex by index, transform to view, project X.
;
; One call per seg endpoint (subsector.s seg loop). Mirrors the "View
; transform with RAM vcache" + reciprocal + X-projection phase of Python's
; packed_render_seg (fp_to_view / fp_recip / fp_project_x_subpx), with a
; per-frame VERTEX CACHE so a vertex shared by several segs is transformed
; and X-projected only once per frame.
;
;   Input:  zp_seg_v_idx_lo/hi = vertex index (u16), written by the caller
;             (doubles as the cache-write index — no staging copy).
;   Output: zp_seg_cur_evy/evx = rounded s8 view y / truncated s8 view x
;             (ALWAYS set — near-plane crossing math needs both endpoints
;             even when this one is clipped or served from the cache).
;           zp_seg_skip = 1 if near-clipped (vy < NEAR); everything below
;             is then undefined and the caller must not use it.
;           zp_br_rhi/rlo = (M8, S) floating recip FOCAL/vy for this vertex.
;           sx1/sx2 (via zp_seg_ep) and zp_br_resl/h = screen x (s16).
;           zp_seg_sy_* = the four per-seg height projections — the routine
;             tail-calls do_project_y (seg_project.s) with this vertex's
;             reciprocal.
;   Uses:   br_to_view (view.s, s24 rotation), br_recip, br_project_x_auto.
;
; Vertex cache: VCACHE_BASE + idx*8, one 8-byte entry per vertex, plus a
; 1-bit-per-vertex valid bitmap at VCACHE_VALID_BASE (cleared per frame).
; 6502 entry layout (differs from Python's VCACHE_ENTRY, which stores
; vx/vy/vy_idx/sx — here the post-recip results are cached instead):
;   +0 evy (s8)  +1 evx (s8)  +2 rhi  +3 rlo  +4 sx_lo  +5 sx_hi
;   +6 near-clip flag (1 = vertex behind near plane)  +7 unused
;
; Pseudocode:
;   if valid[idx]:                          # cache hit
;       evy, evx = cache[0..1]
;       if cache[6]: skip = 1; return       # cached near-clip verdict
;       rhi, rlo, sx = cache[2..5]
;   else:                                   # cache miss
;       valid[idx] = 1
;       wx, wy = ROM_VERTS[idx]             # s16 prescaled world coords
;       vx, vy = br_to_view(wx, wy)         # s24 view space (8.8 + ext)
;       evx = vx >> 8 (trunc); evy = clamp_s8((vy + 128) >> 8)
;       cache[0..1] = evy, evx              # pre-write: hit path needs them
;       if vy < NEAR (s24 test): cache[6] = 1; skip = 1; return
;       rhi, rlo = br_recip(vy >> 7)        # 9.1 index into recip table
;       sx = br_project_x_auto(vx)          # narrow 3-mul / wide 5-mul
;       cache[2..6] = rhi, rlo, sx, 0
;   do_project_y()                          # per-seg heights, tail call
; ============================================================================
br_seg_xform_vertex:
.scope
   PAGE BANK_L0                            ; reads verts (L0) on vcache miss; prior seg's
; projection may have left L2/C paged
   ZERO zp_seg_skip

; --- Compute vertex cache index (idx*8 → cache offset) ---
; idx is in zp_seg_v_idx_lo/hi (u16). vc_offset = idx * 8 (s/o offset for valid).
; valid_byte_offset = idx >> 3, valid_bit = idx & 7.
;
; --- Check valid bit ---
; valid_byte_offset = idx_lo >> 3 + idx_hi << 5 (since high byte each adds 32 bytes)
; (Can't ride idx_hi in from the caller's last STA: ZERO/PAGE above leave A=0.)
   LDA zp_seg_v_idx_hi
   STA zp_br_t3
   LDA zp_seg_v_idx_lo
   LSR zp_br_t3
   ROR A
   LSR zp_br_t3
   ROR A
   LSR zp_br_t3
   ROR A
; A:t3 = idx >> 3 (lo rides in A straight into the base add)
   CLC
   ADC #<VCACHE_VALID_BASE
   STA zp_br_p
   LDA zp_br_t3
   ADC #>VCACHE_VALID_BASE
   STA zp_br_p_h
; bit mask = 1 << (idx_lo & 7), via table (was a 0..7-iteration shift loop)
   LDA zp_seg_v_idx_lo
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
; idx*8 with VCACHE_BASE page-aligned: byte-at-a-time, no 16-bit chain.
; hi = (idx_lo >> 5) | (idx_hi << 3) + >VCACHE_BASE, lo = idx_lo << 3.
   LDA zp_seg_v_idx_lo
   LSR A
   LSR A
   LSR A
   LSR A
   LSR A
   STA zp_br_t2                            ; idx_lo >> 5
   LDA zp_seg_v_idx_hi
   ASL A
   ASL A
   ASL A
   ORA zp_br_t2
   CLC
   ADC #>VCACHE_BASE
   STA zp_br_p_h
   LDA zp_seg_v_idx_lo
   ASL A
   ASL A
   ASL A
   STA zp_br_p
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
   JSR rns_select                          ; cached S → re-pick the shifter
                                        ; (preserves Y; the vector belongs
                                        ; to whoever wrote rlo LAST)
   LDA zp_seg_ep
   LSR A
   TAX                                     ; X = sx offset (0=v1, 2=v2)
   LDY #4
   LDA (zp_br_p),Y
   STA $0061,X                             ; sx_lo → sx1/sx2 direct
   LDY #5
   LDA (zp_br_p),Y
   STA $0062,X                             ; sx_hi
; Project Y for top + bottom (heights vary per seg, can't cache).
   JMP do_project_y

vc_miss:
; --- Cache miss: mark valid now (entry bytes are filled as they are
; computed below — evy/evx first, so even the near-clipped path leaves
; a usable entry). ---
; --- Set valid bit ---
   LDY #0
   LDA (zp_br_p),Y
   ORA zp_seg_v_bitm
   STA (zp_br_p),Y

; --- Compute cache base ptr (idx*8) ---
; idx*8, page-aligned base (see the hit path above)
   LDA zp_seg_v_idx_lo
   LSR A
   LSR A
   LSR A
   LSR A
   LSR A
   STA zp_br_t2
   LDA zp_seg_v_idx_hi
   ASL A
   ASL A
   ASL A
   ORA zp_br_t2
   CLC
   ADC #>VCACHE_BASE
   STA zp_seg_v_cache_hi
   LDA zp_seg_v_idx_lo
   ASL A
   ASL A
   ASL A
   STA zp_seg_v_cache_lo

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

; Scope split: vxc_jsr_site must be a GLOBAL label — vxc_frame SMC-patches
; this JSR's operand between br_to_view (VXC disabled: byte-identical
; original path) and vxc_to_view (translation-coherent vertex cache).
; No local labels cross this boundary (verified: vc_* live above, nc_*
; below in their own scope).
.endscope
vxc_jsr_site:
   JSR br_to_view
.scope

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
   LDA zp_seg_ep
   LSR A
   TAX                                     ; X = sx offset (0=v1, 2=v2)
   LDA zp_br_resl
   STA $0061,X                             ; sx_lo → sx1/sx2 direct
   LDA zp_br_resh
   STA $0062,X                             ; sx_hi

; --- Cache the per-vertex results (rhi, rlo, sx, near-clip=0) ---
; (X still = sx offset; the cache reads sx back from $0061,X.)
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
   LDA $0061,X
   STA (zp_br_p),Y
   INY
   LDA $0062,X
   STA (zp_br_p),Y
   INY
   LDA #0
   STA (zp_br_p),Y
; near_clip = 0
   JMP do_project_y
.endscope
