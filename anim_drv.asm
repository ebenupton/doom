; anim_drv.asm — autobooting rotating E1M1 wireframe for the banked renderer.
; Spins the view in place at spawn (1056,-3616): position-derived ZP is constant,
; only sincos ($05-$0A) + bca_ab ($3A2F) change per frame, read from a 64-entry
; table (8 bytes/entry) the build overlays at $3E00. Double-buffered: render to
; the hidden buffer ($5800/$6C00), then flip CRTC R12/R13 to show it.
;
; Lives in the clipper-vacated low space ($3C00-$47FF) the render never touches.
; Loaded as part of LOW; !BOOT just *SRLOADs the banks, *LOADs LOW, MODE 4, and
; JMP $3C00. No separate DRV file.

angidx = &3D80          ; frame index 0..63
ptlo   = &3D81          ; running table pointer
pthi   = &3D82
backhi = &3D83          ; hidden-buffer page hi ($58 or $6C)
tabbase = &3E00         ; sincos table (build-overlaid): 64 x 8 bytes

ORG &3C00
.drv
    SEI
    ; --- Master 128: clear ACCCON so $8000-$8FFF is the sideways bank (not ANDY),
    ;     $3000-$7FFF is main RAM, and the display reads main (no shadow). This
    ;     makes the Master behave like a plain Model B + SWRAM. Harmless on a B
    ;     (no $FE34). Without this the DFS may leave ANDY paged over our bank
    ;     window's first 4K -> render reads garbage. ---
    LDA #0 : STA &FE34
    ; --- fixed (position-derived) ZP for spawn 1056,-3616 ---
    LDA #&00:STA &00 : LDA #&EE:STA &01             ; PX = $EE00
    LDA #&40:STA &02 : LDA #&D2:STA &03             ; PY = $D240
    LDA #&06:STA &04                                ; VZ
    LDA #&70:STA &90 : LDA #&FF:STA &91             ; PXRAW
    LDA #&92:STA &92 : LDA #&FE:STA &93             ; PYRAW
    ; --- ROM table pointers ---
    LDA #&4C:STA &42 : LDA #&87:STA &43             ; zp_rom_nodes -> $874C
    LDA #235:STA &4C : LDA #0:STA &4D               ; zp_root_node = n_nodes-1
    LDX #15
.pcpy
    LDA ptrtab,X : STA &0BE8,X : DEX : BPL pcpy
    ; --- CRTC: narrow 256x160 centred, cursor off (R12/R13 set per flip) ---
    LDA #1 :STA &FE00: LDA #32 :STA &FE01
    LDA #2 :STA &FE00: LDA #45 :STA &FE01
    LDA #6 :STA &FE00: LDA #20 :STA &FE01
    LDA #7 :STA &FE00: LDA #28 :STA &FE01
    LDA #10:STA &FE00: LDA #&20:STA &FE01
    ; --- init animation state ---
    LDA #0   :STA angidx
    LDA #LO(tabbase):STA ptlo : LDA #HI(tabbase):STA pthi
    LDA #&6C :STA backhi                            ; first hidden buffer = FB1
.frame
    ; --- load per-frame sincos + view angle from the table ---
    LDA ptlo:STA &EC : LDA pthi:STA &ED
    LDY #0
    LDA (&EC),Y:STA &05                             ; s_mag
    INY:LDA (&EC),Y:STA &06                         ; s_neg
    INY:LDA (&EC),Y:STA &07                         ; s_one
    INY:LDA (&EC),Y:STA &08                         ; c_mag
    INY:LDA (&EC),Y:STA &09                         ; c_neg
    INY:LDA (&EC),Y:STA &0A                         ; c_one
    INY:LDA (&EC),Y:STA &3A2F                       ; bca_ab (view angle)
    ; --- render one frame into the hidden buffer ---
    LDA backhi:STA &70                              ; rasteriser scrstrt hi
    LDA #4 :STA &FE30 : JSR &4809                   ; br_view_setup
    LDA #6 :STA &FE30 : JSR &8000                   ; span_init / pool
    ; --- clear hidden buffer (unrolled; one routine per buffer location) ---
    LDA backhi : CMP #&58 : BNE cb_fb1
    JSR clr_5800 : JMP cb_done
.cb_fb1
    JSR clr_6C00
.cb_done
    LDA #4 :STA &FE30 : JSR &481B : JSR &4815       ; init_frame + render_frame
    ; --- flip CRTC to show the buffer we just drew ---
    LDA #12:STA &FE00 : LDA backhi:LSR A:LSR A:LSR A:STA &FE01          ; R12=hi>>3
    LDA #13:STA &FE00 : LDA backhi:AND #7:ASL A:ASL A:ASL A:ASL A:ASL A:STA &FE01
    LDA backhi:EOR #(&58 EOR &6C):STA backhi        ; toggle $58<->$6C
    ; --- advance to next frame (wrap at 64) ---
    INC angidx
    LDA angidx:CMP #64:BCC adv
    LDA #0:STA angidx
    LDA #LO(tabbase):STA ptlo : LDA #HI(tabbase):STA pthi
    JMP frame
.adv
    CLC:LDA ptlo:ADC #8:STA ptlo : LDA pthi:ADC #0:STA pthi
    JMP frame
.ptrtab
    EQUB &00,&24, &00,&8E, &00,&80, &00,&00         ; fhch bbox verts (unused)
    EQUB &0C,&96, &C0,&99, &00,&A2, &00,&24         ; ss seg_hdr vwh detail
.drv_end

; --- unrolled framebuffer clears (in the $4000-$47FF the render never touches).
;     A=0 stored through 20 absolute,Y stores per Y; Y walks 0..255. One routine
;     per buffer so the page addresses are fixed immediates (STA abs,Y = 5cyc). ---
ORG &4000
.clr_5800
    LDA #0 : TAY
.c0
    STA &5800,Y : STA &5900,Y : STA &5A00,Y : STA &5B00,Y
    STA &5C00,Y : STA &5D00,Y : STA &5E00,Y : STA &5F00,Y
    STA &6000,Y : STA &6100,Y : STA &6200,Y : STA &6300,Y
    STA &6400,Y : STA &6500,Y : STA &6600,Y : STA &6700,Y
    STA &6800,Y : STA &6900,Y : STA &6A00,Y : STA &6B00,Y
    INY : BNE c0
    RTS
.clr_6C00
    LDA #0 : TAY
.c1
    STA &6C00,Y : STA &6D00,Y : STA &6E00,Y : STA &6F00,Y
    STA &7000,Y : STA &7100,Y : STA &7200,Y : STA &7300,Y
    STA &7400,Y : STA &7500,Y : STA &7600,Y : STA &7700,Y
    STA &7800,Y : STA &7900,Y : STA &7A00,Y : STA &7B00,Y
    STA &7C00,Y : STA &7D00,Y : STA &7E00,Y : STA &7F00,Y
    INY : BNE c1
    RTS
.clr_end
SAVE "ANIMDRV", &3C00, clr_end, &3C00
