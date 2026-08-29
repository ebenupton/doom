
; ============================================================================
; Debug HUD — position and rotation on the top character row of the display.
;
; Renders "X=hhhh.hh Y=hhhh.hh R=hh F=hh" (map-relative prescaled
; position, s16 integer + 8-bit fraction of the driver's 8.8 fixed point,
; the view angle byte, and the PAL fields the last frame took) into the
; BACK buffer's first character row, after the
; frame render and before the flip, using the OS ROM font.  The fraction
; matters for exact position capture: the engine consumes the full 8.8,
; so an integer-only reading is up to 1 prescaled unit (8 world units)
; away from the true viewpoint.
;
; Mode 4 makes this cheap: a character cell on row 0 is 8 CONSECUTIVE
; bytes at FB + col*8, and an OS glyph is 8 consecutive bytes at
; FONT + (ascii-32)*8 (the full 32..127 set is contiguous) — so a
; character is a straight 8-byte copy, background included (glyph zero
; bits overwrite any rendered line underneath, keeping the text legible).
;
; The font base is NOT fixed: OS 1.2 keeps it at $C000, MOS 3.20 at
; $F900. Hardwiring $C000 blitted MOS code on a Master, which is how the
; HUD came out as garbage there. SEARCHING for it was the next fix and
; was worse: 105 bytes took this segment past $A500 into VDESC and
; pressing H crashed the Model B. The driver now asks the OS which
; machine it is (OSBYTE 129) at entry, while the OS is still alive, and
; leaves the answer in DV_HUD_FONT. Note $F900 is not glyph-aligned the
; way $C000 is, so hud_char's offset add carries — see there.
;
;   for i, ch in enumerate(template):   # "X=....%.. Y=....%.. R=.. F=.."
;       if ch is a hex slot: ch = hexdigit(nibble of the referenced value)
;       dst = back_fb + i*8                  # back_fb page from the driver
;       dst[0..7] = os_font[(ch-32)*8 .. +7]
;
; Driver interface (walk_drv.asm): BOTH sides now derive the variable
; addresses from the abi.inc DV_* equates — private
; address copies are banned here because of the bug this caused: when
; the driver vars moved (2026-07-10) this file's stale hardcoded $3D8x
; copies survived, HUD_BACKHI read an engine-code byte as the FB page,
; and every glyph blit sprayed 192 bytes over a random page — ZP when
; it landed on page 0, corrupting the VZ easing state.  The block's
; layout is documented once, in tools/gen_abi.py, and the base has moved
; twice since (it is NOT $2080/$3D8x any more), which is exactly why no
; address is written down here.  The driver's hud_glue pages BANK_C and
; JSRs hud_draw ($A400) when DV_HUD_EN is nonzero.
;
; Banked-build only: the code lives in the bank C window (HUD region,
; $A400) and reads the OS ROM directly — the flat py65 harness has no OS,
; so the flat build emits nothing (test seeds a fake font instead). The
; region is sized to STOP at $A500, where banked_bsp seeds VDESC, so an
; overgrown HUD is a link error rather than a crash on hardware.
; ============================================================================

.if ::BANKED

; zp scratch — frame-scoped: these sit inside the VX vertex structs
; ($E2-$FF), which are per-seg working state, dead between the frame's
; last seg and the next frame's first (the HUD runs post-render).
zp_hud_src = $EB                        ; font glyph pointer
zp_hud_dst = $ED                        ; framebuffer cell pointer
HUD_VAL    = $F0                        ; byte being hexed

HUD_ANGIDX = DV_ANGIDX                  ; driver vars via abi.inc —
HUD_BACKHI = DV_BACKHI                  ; no private address copies
HUD_XFRAC  = DV_PXF
HUD_XLO    = DV_PXL
HUD_XHI    = DV_PXH
HUD_YFRAC  = DV_PYF
HUD_YLO    = DV_PYL
HUD_YHI    = DV_PYH
HUD_FIELDS = DV_FIELDS                  ; PAL fields the last frame consumed

HUD_FONT   = DV_HUD_FONT                ; font base, chosen by the driver's
                                        ; OSBYTE 129 probe at boot; 0 = the
                                        ; probe never ran (py65 harnesses)
zp_hud_t   = $F1                        ; hud_char scratch (frame-scoped, as
                                        ; the pointers above)

.segment "HUD"

; --- hud_draw ($A400): entry. Emits the whole line. Clobbers A,X,Y. ---
hud_draw:
.scope
   LDA HUD_FONT+1                          ; the driver picks this at boot from
   BNE hd_have                             ; the OS version; 0 = never set (no
   RTS                                     ; driver ran), so draw nothing
hd_have:
; The Master keeps its CURRENT character definitions in ANDY ($8900-$8FFF,
; chars 32-255), paged over $8000-$8FFF by ROMSEL bit 7 — its font is NOT
; in the MOS ROM (the old $F900 constant was MOS code, and drawing it as
; glyphs is exactly the garbage HUD). Page ANDY in for the whole draw:
; hud_draw calls nothing below $9000 (only hud_char/hud_hex, its own
; segment at $A400), the framebuffer and its state are main RAM, and
; hud_glue re-pages a render bank the instant we return. A $C000 base is
; MOS ROM on a Model B and needs no paging at all.
   CMP #>HUD_FONT_B
   BCS hd_go
   LDA #$80 | BANK_C                       ; ANDY over $8000-$8FFF, bank C
   STA $FE30                               ; still at $9000-$BFFF (this code)
hd_go:
   ZERO zp_hud_dst                         ; cell 0 (col*8 accumulates below).
                                           ; NOT branched on: ZERO is STZ on the
                                           ; C02 host build and sets no flags.
   LDA HUD_BACKHI
   STA zp_hud_dst+1                        ; row-0 block = FB page start
; "X="
   LDA #'X'
   JSR hud_char
   LDA #'='
   JSR hud_char
   LDA HUD_XHI
   JSR hud_hex
   LDA HUD_XLO
   JSR hud_hex
   LDA #'.'
   JSR hud_char
   LDA HUD_XFRAC
   JSR hud_hex
   LDA #' '
   JSR hud_char
; "Y="
   LDA #'Y'
   JSR hud_char
   LDA #'='
   JSR hud_char
   LDA HUD_YHI
   JSR hud_hex
   LDA HUD_YLO
   JSR hud_hex
   LDA #'.'
   JSR hud_char
   LDA HUD_YFRAC
   JSR hud_hex
   LDA #' '
   JSR hud_char
; "R="
   LDA #'R'
   JSR hud_char
   LDA #'='
   JSR hud_char
   LDA HUD_ANGIDX
   ASL A
   ASL A                                   ; angle byte = angidx*4
   JSR hud_hex
; "F=" — PAL fields the last frame took. This is the frame cost in the
; only unit that matters on the machine: a 50Hz frame is 1, and the
; movement code scales its walk and turn by exactly this count, so the
; readout is the number the motion used rather than a second estimate.
   LDA #' '
   JSR hud_char
   LDA #'F'
   JSR hud_char
   LDA #'='
   JSR hud_char
   LDA HUD_FIELDS
; fall through to hud_hex for the final value
.endscope

; --- hud_hex: A = byte -> two hex digit cells. Clobbers A,X,Y. ---
hud_hex:
.scope
   PHA
   LSR A
   LSR A
   LSR A
   LSR A
   TAX
   LDA hexdig,X
   JSR hud_char
   PLA
   AND #$0F
   TAX
   LDA hexdig,X
; fall through to hud_char
.endscope

; --- hud_char: A = ascii -> blit the OS glyph at the current cell and
;     advance one cell (zp_hud_dst += 8). Clobbers A,Y. ---
hud_char:
.scope
; font ptr = HUD_FONT + (A-32)*8: (A-32) < 96 so the product is 11 bits
; and BOTH halves matter — the base is no longer page-aligned ($F900 on
; a Master), so the low add can carry.
   SEC
   SBC #32
   STA zp_hud_t
   LSR A
   LSR A
   LSR A
   LSR A
   LSR A
   STA zp_hud_t+1                          ; hi = (A-32) >> 5
   LDA zp_hud_t
   ASL A
   ASL A
   ASL A                                   ; lo = ((A-32) << 3) & $FF
   CLC
   ADC HUD_FONT
   STA zp_hud_src
   LDA zp_hud_t+1
   ADC HUD_FONT+1                          ; + the carry out of the low add
   STA zp_hud_src+1
   LDY #7
hc_row:
   LDA (zp_hud_src),Y
   STA (zp_hud_dst),Y
   DEY
   BPL hc_row
   CLC
   LDA zp_hud_dst
   ADC #8
   STA zp_hud_dst                          ; next cell (row 0 never crosses
   RTS                                     ; the page: 32 cells * 8 = 256)
.endscope

hexdig:
   .byte "0123456789ABCDEF"


; restore the segment for subsequently-included parts (they inherit)
SEG_CODE

.endif
