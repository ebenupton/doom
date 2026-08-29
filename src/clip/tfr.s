
; ============================================================================
; clip/tfr.s — clipper fragment 8 of 13 (module map: clip/header.s).
; Contents: tg_append_x (list builder + merge — fused_merge_range's
; value test), the DCLV_*/LC_* absolute working sets for the s16
; clipper (code in clip/dcl_s16.s), and seg_zero_rec_solid (exported
; to bsp/subsector.s). The records sweep died 2026-08-25 (clip/fused.s).
; ============================================================================

; (TG_APPEND_X died 2026-08-25 with the sweep — its only callers. Its
;  merge condition survives as fused_merge_range's 8-field value test,
;  which enforces the same no-value-equal-abutting-pair postcondition.)

; (FLUSH_PEND macro died with the sweep, 2026-08-25)

SEG_BANKC
; TFS state block — the 3-cursor event walk's working set.
; (Moved here from the deleted 6-byte-records legacy file.)
; ZP SWEEP (2026-08-11, profiled): the HOT members moved to the zp
; bytes freed by the TRUE16/TRIG5 arcs (heat-ranked py65 profile,
; ~1k cyc/frame in this block alone); the cold tail stays in the
; $06xx scratch page. Every promoted byte is logged in src/zp.inc —
; the free-list is the trap (the $CB/zp_tail_vec near-miss). The
; PROMOTED equates live in src/zp.inc (must be seen before all code
; or ca65 sizes the operands absolute — codescan caught exactly that).
; PEND_* is a 1-deep output buffer: the interval most recently produced
; by the sweep, held back so the next interval can extend it in place
; (same top/bot sources) instead of allocating a new pool span.
; SOURCE-ANCHORED BOUNDARIES (2026-08-22). Each side is carried as its
; SOURCE line's own (anchor_lo, den, y_lo, y_hi) rather than the two
; values interpolated onto the interval's ends, so a pure side costs
; four copies instead of two interp_store calls. The MIXED arms (max/
; min of pool and record) cannot be one line, so they still interpolate
; onto [cur_x, next_x] and anchor there.
; ALL 28 PROMOTED TO ZERO PAGE 2026-08-22 — the equates are in
; src/zp.inc (they MUST be seen before any code or ca65 sizes the
; operands absolute; codescan gates exactly that).  Measured 2,379
; accesses to this block on the heavy frame, so the promotion is
; worth ~2,379 cycles and one byte per instruction.
; --- verdict-record support (2026-07-13 off-screen-aperture fix) ---
; $091C/$091D free (TFS_*_VERD retired — verdicts tested lazily at the
; consumption points, 2026-07-13)
DCLV_X0 = $0A20                         ; dcl_rec_flat range args
DCLV_X1 = $0A21
DCLV_SX = $0A22                         ; X save across dcl_rec_flat
DCLV_YV = $0A23                         ; verdict y value latch
DCLV_S16VY = $0A24
DCLS_FIRST = $0AD1                      ; dcl_solid_pair's first-span memo
                                        ; (WORK page free run $0AD1-$0AFF;
                                        ; written by dcl_pair_seek, read by
                                        ; dcl_pair_resume — pairs only, the
                                        ; normal walker never touches it)
; --- EVICTED FROM ZERO PAGE 2026-08-22 ---------------------------------
; Priced with tools/zpheat.py on the heavy frame: a ZP byte's only honest
; cost is how often it is touched (1 cycle and 1 byte per access to move
; it out).  These are the clipper's coldest ZP residents and all three are
; plain scalars — no (zp),Y, no zp,X — so the move is an address change:
;   zp_cb_top2  18 accesses/frame     zp_cb_bot2  16
;   zp_save1     8
; 42 cycles a frame buys three of the 28 bytes the TFS sweep state needs.
zp_cb_top2 = $0A25                      ; u8, span top at cx2
zp_cb_bot2 = $0A26                      ; u8, span bot at cx2
zp_save1   = $0A27                      ; dcl_boundary_ix's clip_p1 save                      ; s16-clip pending right verdict ($80 = none)


; ===================================================================
; (tighten_from_records, its 3-cursor sweep, tfs_flush_pending and
;  emit_unchanged_subspan DIED with the FUSED cutover 2026-08-25 —
;  clip/fused.s applies boundaries during the armed draw itself.
;  tg_append_x survives above (fused_merge_range's test is its test);
;  seg_zero_rec_solid survives below (the zero-touch dispatch).)
; ===================================================================
; ===================================================================

; ---- s16 line input (wrapper writes these) ----
; Lo bytes alias zp_line_* (the same u8 slots DCL reads). Hi bytes
; alias the CB-clip / tighten-secondary ZP block ($B2-$B5) — those
; slots are used DOWNSTREAM of the s16 clipper (DCL clobbers them
; during emission), but the wrapper rewrites them before each call,
; so there's no conflict. ZP access shaves ~7 cycles off the in-range
; fast-path detect (4 ORAs of zp vs absolute).
; (LC_*_LO alias layer removed 2026-07-10: the s16 clipper reads the
; zp_line_* slots by their real names.)
; ---- saved originals for interp (snapped at start of x-clip / y-clip) ----
LC_OX1_LO = $0A38
LC_OX1_HI = $0A39
LC_OY1_LO = $0A3A
LC_OY1_HI = $0A3B
LC_OX2_LO = $0A3C
LC_OX2_HI = $0A3D
LC_OY2_LO = $0A3E
LC_OY2_HI = $0A3F
; ---- math working (ZP SWEEP 2026-08-11: the hot subset — the u16
; mul/div workspace dominates the profile — moved to freed zp; cold
; members stay $06xx) ----
LC_DY_NEG = $0A46
LC_M_R2 = $0A4D
LC_M_R3 = $0A4E
LC_TMP_HI = $0A54
LC_RES_LO = $0A55
LC_RES_HI = $0A56
LC_TGT_LO = $0A57                       ; clip target value (s16)
; $0658 FREE (LC_TGT_HI retired 2026-08-23 -- provably constant 0)

; ---------------------------------------------------------------------------
SEG_HIGH
; (Relocated to the LO segment 2026-07-13: cold classifier, and the CLIP region is
; at its ceiling — main RAM is always mapped, so bank-C callers are fine.
; Slated for deletion by Part 2 of the aperture fix.)
; seg_zero_rec_solid — classify a portal whose aperture-edge DCL emissions
; produced ZERO records. That is ambiguous: either the opening covers the
; whole screen (the tighten is a genuine no-op -> skip), or the opening is
; entirely OFF-screen (every visible row in the seg's columns shows wall or
; flat -> the columns must be CLOSED). The packed-Python reference
; (endpoint_spans records verdicts: top 'below' or bot 'above' -> solid)
; already closes; the 6502 skipped, leaving the columns open — found via
; the (-486,-3307,243) phantom, where a screen-wide portal whose aperture
; projects wholly above the screen left columns 0..69 open and the far
; rooms drew through the wall (276px cross-impl divergence).
;
; In:  the packed ZP vertex structs (zp.inc VX1/VX2) biased s16 sy pairs,
;      zp_seg_flags (SF_NEEDBT=$04, SF_NEEDBB=$08).
; Out: C=1 -> aperture band provably empty on screen (caller appends a
;      SOLID over [ilo, ihi)); C=0 -> genuine no-op (skip).
; Caller: bsp/subsector.s seg-emit tail (direct .import, not a jt slot;
; bank C paged in the banked build). Clobbers A,X.
;
; Band bottom = min(fb, bb when SF_NEEDBB); band top = max(ft, bt when
; SF_NEEDBT). Empty on screen iff bottom < Y_BIAS at BOTH endpoints
; (min < k <=> either < k), or top > Y_BIAS+159 at both.
; ---------------------------------------------------------------------------
SZR_PROJ = $E2                          ; = VX1 (zp.inc vertex structs).
; X offsets below = struct offsets: +5 top, +7 bot, +9 btop, +11 bbot;
; +15 more for the v2 struct. (Old SEG_PROJ_BUF interleave retired
; 2026-07-10.) ZP,X addressing: abs,X on a ZP base still works; keep the
; absolute form for the +1 hi-byte reads (no page crossing: max $FC+1).
.export seg_zero_rec_solid

; --- s16 threshold helpers for seg_zero_rec_solid ---------------------
; X = lo-byte offset of a projection in SZR_PROJ. C=1 iff value < Y_BIAS.
; s16 compare via full SBC pair — NO V-correction (2026-07-17 sweep):
; projections are bounded by construction (sy = HALF_H - rns(h*m9, S),
; |h*m9| <= 127*511, S >= 1 -> |sy| <= 32,577), so value-6 and
; 165-value both stay inside s16 (margins 191 / 26) and N IS the sign.
szr_lt:
   LDA SZR_PROJ,X
   SEC
   SBC #Y_BIAS
   LDA SZR_PROJ+1,X
   SBC #0
   BMI szr_yes
   CLC
   RTS
; C=1 iff value > Y_BIAS+159.
; Same idiom, operands reversed: sign of ((Y_BIAS+159) - value) < 0.
szr_gt:
   LDA #<(Y_BIAS+159)
   SEC
   SBC SZR_PROJ,X
   LDA #>(Y_BIAS+159)
   SBC SZR_PROJ+1,X
   BMI szr_yes
   CLC
   RTS
szr_yes:
   SEC
   RTS

seg_zero_rec_solid:
.scope
; Band bottom = min(fb, bb-if-NEEDBB), so "bottom < Y_BIAS" at an
; endpoint iff fb < Y_BIAS OR (NEEDBB and bb < Y_BIAS). Endpoint 1
; first; only if it passes do we pay for endpoint 2 (szr_b1).
; bottom family: band bottom above the screen top at endpoint 1?
   LDX #zp_seg_sy1_bot_l - VX1            ; sy1_bot (fb1)
   JSR szr_lt
   BCS szr_b1
   LDA zp_seg_flags
   AND #$08                                ; SF_NEEDBB
   BEQ szr_top
   LDX #zp_seg_sy1_bbot_l - VX1            ; sy1_bbot (bb1)
   JSR szr_lt
   BCC szr_top
szr_b1:
; ... and at endpoint 2?
   LDX #zp_seg_sy2_bot_l - VX1            ; sy2_bot (fb2)
   JSR szr_lt
   BCS szr_closed
   LDA zp_seg_flags
   AND #$08
   BEQ szr_top
   LDX #zp_seg_sy2_bbot_l - VX1            ; sy2_bbot (bb2)
   JSR szr_lt
   BCS szr_closed
szr_top:
; top family: band top below the screen bottom at endpoint 1?
; Band top = max(ft, bt-if-NEEDBT), and max(a,b) > k iff a > k OR
; b > k — the same either-of-two test per endpoint as the bottom
; family above, with szr_gt in place of szr_lt.
   LDX #zp_seg_sy1_top_l - VX1            ; sy1_top (ft1)
   JSR szr_gt
   BCS szr_t1
   LDA zp_seg_flags
   AND #$04                                ; SF_NEEDBT
   BEQ szr_open
   LDX #zp_seg_sy1_btop_l - VX1            ; sy1_btop (bt1)
   JSR szr_gt
   BCC szr_open
szr_t1:
   LDX #zp_seg_sy2_top_l - VX1            ; sy2_top (ft2)
   JSR szr_gt
   BCS szr_closed
   LDA zp_seg_flags
   AND #$04
   BEQ szr_open
   LDX #zp_seg_sy2_btop_l - VX1            ; sy2_btop (bt2)
   JMP szr_gt                              ; TAIL: the last test's carry IS
                                        ; the verdict, so the old
                                        ; BCS szr_closed + fall-into-szr_open
                                        ; pair was just re-encoding szr_gt's
                                        ; own C.  -14 cycles, -5 bytes.
                                        ; The two labels below MUST stay:
                                        ; five other branches target them
                                        ; (szr_closed x3, szr_open x2).
szr_open:
   RTS                                     ; C=0 — every arrival is a
                                        ; BCS-not-taken or a BCC, and the
                                        ; intervening LDA/AND leave C alone
szr_closed:
   SEC
   RTS
.endscope
SEG_BANKC
